-- ============================================================================
-- decay_11_calculate_decay_scores_incremental.sql   (PROJECT incremental)
--   Recomputes only the repliers whose data changed since the last successful run,
--   producing results identical to a full rebuild. Reuses the shared core
--   test_mindshare_score._decay_apply_project (decay_02_*).
--
-- "Changed" = on the INGEST timestamp GREATEST(created_at, updated_at) (NOT tweet time):
--   (1) the replier has a reply ingested/updated since the watermark, OR
--   (2) a parent post the replier replied to was ingested/updated since the watermark, OR
--   (3) the replier's base score (mindshare_user.score) differs from what was last stored.
-- A dirty replier's rows are DELETEd from contribution_scores and the replier's FULL
-- timeline is replayed. The watermark advances only if the whole run commits.
-- ============================================================================

CREATE OR REPLACE FUNCTION test_mindshare_score.calculate_decay_scores_incremental(
    p_project_keyword text,
    p_reset_interval  interval DEFAULT '30 days',
    p_run_id          bigint   DEFAULT NULL,
    p_log_every       integer  DEFAULT 50000
) RETURNS bigint
LANGUAGE plpgsql
SET random_page_cost = 1.1
SET work_mem = '256MB'
SET search_path = test_mindshare, test_mindshare_score, public
AS $func$
DECLARE
    v_run_id  bigint := COALESCE(p_run_id, nextval('test_mindshare_score.decay_run_id_seq'));
    v_scope   text   := 'project:' || p_project_keyword;
    v_since      timestamptz;
    v_new        timestamptz;
    v_user_since timestamptz;
    v_user_new   timestamptz;
    v_dirty   bigint := 0;
    v_count   bigint := 0;
BEGIN
    -- serialize runs for this scope (auto-released at txn end)
    PERFORM pg_advisory_xact_lock(hashtext('decay:' || v_scope));

    PERFORM test_mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'running','init',
        format('INCREMENTAL decay run started (project=%s, reset_interval=%s)', p_project_keyword, p_reset_interval), 0);

    SELECT last_ingest_ts, last_user_ingest_ts INTO v_since, v_user_since
    FROM test_mindshare_score.decay_run_state WHERE scope = v_scope;

    -- new watermark: max ingest over this project's posts (covers replies AND parents).
    -- backward index scan on ix_tmp_mp_ingest within the project's partition.
    SELECT max(GREATEST(created_at, updated_at)) INTO v_new
    FROM test_mindshare.mindshare_post WHERE project_keyword = p_project_keyword;
    -- separate watermark for base-score changes (mindshare_user is global; ix_tmp_mu_ingest)
    SELECT max(GREATEST(created_at, updated_at)) INTO v_user_new
    FROM test_mindshare.mindshare_user;

    IF v_since IS NULL THEN
        -- first run for this scope == full build
        PERFORM test_mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'running','computing',
            'First run: full rebuild for project', 0);
        DELETE FROM test_mindshare_score.contribution_scores WHERE project_keyword = p_project_keyword;
        v_count := test_mindshare_score._decay_apply_project(p_project_keyword, p_reset_interval, v_run_id, false, p_log_every);
        v_dirty := NULL;  -- 'all'
    ELSE
        -- ---- build the dirty set as (replier_x_id, t_min) -----------------
        -- t_min = earliest CHANGED reply time per replier; we recompute only the
        -- TAIL (post_created_at >= t_min), seeding the window from stored rows.
        -- Materialize the small set of posts ingested since the watermark (the delta),
        -- so detection is O(delta), not O(project). Both branch 1 (changed replies) and
        -- branch 2 (parent-late) are driven from this small set.
        DROP TABLE IF EXISTS tmp_changed;
        CREATE TEMP TABLE tmp_changed ON COMMIT DROP AS
        SELECT post_id, user_x_id, replied_post_id, post_created_at
        FROM test_mindshare.mindshare_post
        WHERE project_keyword = p_project_keyword
          AND GREATEST(created_at, updated_at) >  v_since
          AND GREATEST(created_at, updated_at) <= v_new;
        CREATE INDEX ON tmp_changed (post_id);
        ANALYZE tmp_changed;

        DROP TABLE IF EXISTS tmp_dirty;
        CREATE TEMP TABLE tmp_dirty (replier_x_id text PRIMARY KEY, t_min timestamptz) ON COMMIT DROP;

        INSERT INTO tmp_dirty (replier_x_id, t_min)
        SELECT replier_x_id, min(t_min) AS t_min FROM (
            -- (1) changed posts that are themselves replies
            SELECT c.user_x_id AS replier_x_id, c.post_created_at AS t_min
            FROM tmp_changed c
            WHERE c.replied_post_id IS NOT NULL
            UNION ALL
            -- (2) replies whose PARENT is a changed post (driven from the small changed set
            --     via ix_tmp_mp_replied_post_id, NOT a full scan of all replies)
            SELECT r.user_x_id, r.post_created_at
            FROM tmp_changed c
            JOIN test_mindshare.mindshare_post r
              ON r.replied_post_id = c.post_id AND r.project_keyword = p_project_keyword
            WHERE r.replied_post_id IS NOT NULL
            UNION ALL
            -- (3) base-score drift: only users whose row changed since the watermark
            --     (via ix_tmp_mu_ingest); recompute their whole tail (t_min = earliest reply)
            SELECT p.user_x_id, p.post_created_at
            FROM test_mindshare.mindshare_user u
            JOIN test_mindshare.mindshare_post p
              ON p.user_x_id = u.x_id
             AND p.project_keyword = p_project_keyword
             AND p.replied_post_id IS NOT NULL
            WHERE GREATEST(u.created_at, u.updated_at) >  COALESCE(v_user_since, '-infinity'::timestamptz)
              AND GREATEST(u.created_at, u.updated_at) <= v_user_new
        ) d
        GROUP BY replier_x_id;

        GET DIAGNOSTICS v_dirty = ROW_COUNT;
        ANALYZE tmp_dirty;

        PERFORM test_mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'running','computing',
            format('%s dirty repliers to recompute (tail-from-t_min)', v_dirty), 0);

        IF v_dirty > 0 THEN
            -- delete only the TAIL (>= t_min) per dirty replier; rows before t_min stay
            DELETE FROM test_mindshare_score.contribution_scores cs
            USING tmp_dirty d
            WHERE cs.project_keyword = p_project_keyword
              AND cs.replier_x_id = d.replier_x_id
              AND cs.post_created_at >= d.t_min;

            v_count := test_mindshare_score._decay_apply_project_tail(
                           p_project_keyword, p_reset_interval, v_run_id, p_log_every);
        END IF;
    END IF;

    -- advance watermark (only persists if the whole run commits)
    INSERT INTO test_mindshare_score.decay_run_state (scope, last_ingest_ts, last_user_ingest_ts, last_run_at, last_run_id, dirty_repliers, rows_written)
    VALUES (v_scope, COALESCE(v_new, now()), v_user_new, now(), v_run_id, v_dirty, v_count)
    ON CONFLICT (scope) DO UPDATE SET
        last_ingest_ts      = EXCLUDED.last_ingest_ts,
        last_user_ingest_ts = EXCLUDED.last_user_ingest_ts,
        last_run_at         = EXCLUDED.last_run_at,
        last_run_id         = EXCLUDED.last_run_id,
        dirty_repliers      = EXCLUDED.dirty_repliers,
        rows_written        = EXCLUDED.rows_written;

    PERFORM test_mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'success','done',
        format('Completed (%s): %s repliers recomputed, %s rows written',
               CASE WHEN v_dirty IS NULL THEN 'full rebuild (first run)' ELSE 'incremental' END,
               COALESCE(v_dirty::text,'ALL'), v_count), v_count, NULL,NULL,NULL,NULL, true);
    RETURN v_run_id;

EXCEPTION WHEN OTHERS THEN
    DECLARE
        v_state text := SQLSTATE; v_msg text := SQLERRM; v_detail text; v_context text;
    BEGIN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL, v_context = PG_EXCEPTION_CONTEXT;
        PERFORM test_mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'failed','error',
            format('FAILED (incremental): %s', v_msg), v_count, v_state, v_msg, v_detail, v_context, true);
    END;
    RAISE;   -- propagate; watermark advance rolled back -> next run reprocesses
END;
$func$;
