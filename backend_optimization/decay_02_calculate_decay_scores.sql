-- ============================================================================
-- decay_02_calculate_decay_scores.sql   (PROJECT decay: shared core + full rebuild)
--   * _decay_apply_project(...)  -- the per-replier decay loop (ONE copy of the math),
--                                   optionally restricted to a tmp_dirty_repliers temp table.
--   * calculate_decay_scores(...) -- FULL rebuild wrapper (delete project, replay everyone).
--   The INCREMENTAL wrapper lives in decay_11_*.sql and reuses the same core.
--
--   Reads base tables from test_mindshare; writes test_mindshare_score.contribution_scores;
--   logs progress/failure autonomously via decay_run_log; SSD planner settings baked in.
--   Decay math is identical to production; the only logic change is dropping the redundant
--   `is_reply = true` predicate so the partial index ix_tmp_mp_replier_time applies.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- CORE: per-replier rolling-window decay loop.
--   p_only_dirty = true  -> driving query is restricted to repliers present in the
--                           caller-populated TEMP TABLE tmp_dirty_repliers(replier_x_id).
--   Returns the number of contribution rows written. May RAISE (caller logs/handles).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test_mindshare_score._decay_apply_project(
    p_project_keyword text,
    p_reset_interval  interval,
    p_run_id          bigint,
    p_only_dirty      boolean,
    p_log_every       integer
) RETURNS bigint
LANGUAGE plpgsql
SET random_page_cost = 1.1
SET work_mem = '256MB'
SET search_path = test_mindshare, test_mindshare_score, public
AS $func$
DECLARE
    v_count  bigint := 0;
    v_query  text;

    rec              RECORD;
    prev_replier     TEXT          := '';
    base_score       NUMERIC       := 0;
    min_floor        NUMERIC       := 0;
    calc_score       NUMERIC       := 0;
    effective_score  NUMERIC       := 0;
    reply_seq        INT           := 0;
    local_seq        INT           := 0;
    dtype            TEXT          := '';
    new_mult         NUMERIC       := 1.0;
    penalty_mults    NUMERIC[]     := ARRAY[]::NUMERIC[];
    penalty_times    TIMESTAMPTZ[] := ARRAY[]::TIMESTAMPTZ[];
    penalty_authors  TEXT[]        := ARRAY[]::TEXT[];
    i                INT;
    n                INT;
    active_product   NUMERIC;
    cutoff_time      TIMESTAMPTZ;
    new_mults        NUMERIC[];
    new_times        TIMESTAMPTZ[];
    new_authors      TEXT[];
BEGIN
    -- driving query: replies for this project, time-ordered per replier (ix_tmp_mp_replier_time)
    v_query :=
        'SELECT p.project_keyword, p.post_id, op.post_id AS original_post_id, '
        '       p.user_x_id AS replier_x_id, p.post_created_at, '
        '       op.user_x_id AS original_author_x_id, u.score AS replier_base_score '
        'FROM test_mindshare.mindshare_post p '
        'INNER JOIN test_mindshare.mindshare_post op '
        '    ON p.replied_post_id = op.post_id AND p.project_keyword = op.project_keyword '
        'INNER JOIN test_mindshare.mindshare_user u ON p.user_x_id = u.x_id '
        'WHERE p.replied_post_id IS NOT NULL AND p.project_keyword = $1 ';
    IF p_only_dirty THEN
        v_query := v_query || 'AND p.user_x_id IN (SELECT replier_x_id FROM tmp_dirty_repliers) ';
    END IF;
    -- post_id is a deterministic tiebreaker: without it, replies sharing the same
    -- (user_x_id, post_created_at) get a non-deterministic order, so reply_number/decay_type
    -- can differ between a full scan and a dirty replay -> incremental != full. (Latent in
    -- the original production functions too.)
    v_query := v_query || 'ORDER BY p.user_x_id, p.post_created_at, p.post_id';

    FOR rec IN EXECUTE v_query USING p_project_keyword
    LOOP
        IF rec.replier_x_id IS DISTINCT FROM prev_replier THEN
            prev_replier    := rec.replier_x_id;
            base_score      := rec.replier_base_score;
            min_floor       := ROUND(base_score * 0.01, 2);
            reply_seq       := 0;
            penalty_mults   := ARRAY[]::NUMERIC[];
            penalty_times   := ARRAY[]::TIMESTAMPTZ[];
            penalty_authors := ARRAY[]::TEXT[];
        END IF;

        reply_seq := reply_seq + 1;

        cutoff_time := rec.post_created_at - p_reset_interval;
        new_mults   := ARRAY[]::NUMERIC[];
        new_times   := ARRAY[]::TIMESTAMPTZ[];
        new_authors := ARRAY[]::TEXT[];
        n := COALESCE(array_length(penalty_mults, 1), 0);
        FOR i IN 1 .. n LOOP
            IF penalty_times[i] > cutoff_time THEN
                new_mults   := array_append(new_mults,   penalty_mults[i]);
                new_times   := array_append(new_times,   penalty_times[i]);
                new_authors := array_append(new_authors, penalty_authors[i]);
            END IF;
        END LOOP;
        penalty_mults   := new_mults;
        penalty_times   := new_times;
        penalty_authors := new_authors;

        local_seq := 0;
        n := COALESCE(array_length(penalty_authors, 1), 0);
        FOR i IN 1 .. n LOOP
            IF penalty_authors[i] = rec.original_author_x_id THEN
                local_seq := local_seq + 1;
            END IF;
        END LOOP;
        local_seq := local_seq + 1;

        active_product := 1.0;
        n := COALESCE(array_length(penalty_mults, 1), 0);
        FOR i IN 1 .. n LOOP
            active_product := active_product * penalty_mults[i];
        END LOOP;
        effective_score := GREATEST(ROUND(base_score * active_product, 2), min_floor);
        calc_score      := effective_score;

        IF n = 0 THEN
            dtype := 'FIRST_REPLY'; new_mult := 1.0;
        ELSIF local_seq > 1 THEN
            new_mult := 0.50; calc_score := GREATEST(ROUND(calc_score * 0.50, 2), min_floor); dtype := 'LOCAL_DECAY';
        ELSE
            new_mult := 0.90; calc_score := GREATEST(ROUND(calc_score * 0.90, 2), min_floor); dtype := 'GLOBAL_DECAY';
        END IF;

        penalty_mults   := array_append(penalty_mults,   new_mult);
        penalty_times   := array_append(penalty_times,   rec.post_created_at);
        penalty_authors := array_append(penalty_authors, rec.original_author_x_id);

        INSERT INTO test_mindshare_score.contribution_scores (
            project_keyword, reply_post_id, original_post_id, replier_x_id, original_author_x_id,
            post_created_at, replier_base_score, effective_score, contribution_score,
            active_multipliers, reply_number, local_reply_count, decay_type
        ) VALUES (
            rec.project_keyword, rec.post_id, rec.original_post_id, rec.replier_x_id, rec.original_author_x_id,
            rec.post_created_at, rec.replier_base_score, effective_score, ROUND(calc_score, 2),
            penalty_mults, reply_seq, local_seq, dtype
        );

        v_count := v_count + 1;
        IF p_log_every > 0 AND v_count % p_log_every = 0 THEN
            PERFORM test_mindshare_score._decay_log(p_run_id,'project',p_project_keyword,'running','writing',
                format('%s rows written...', v_count), v_count);
        END IF;
    END LOOP;

    RETURN v_count;
END;
$func$;


-- ---------------------------------------------------------------------------
-- FULL rebuild wrapper (unchanged behaviour; now delegates the loop to the core)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test_mindshare_score.calculate_decay_scores(
    p_project_keyword text,
    p_reset_interval  interval DEFAULT '30 days',
    p_run_id          bigint   DEFAULT NULL,
    p_log_every       integer  DEFAULT 50000
) RETURNS bigint
LANGUAGE plpgsql
SET search_path = test_mindshare, test_mindshare_score, public
AS $func$
DECLARE
    v_run_id bigint := COALESCE(p_run_id, nextval('test_mindshare_score.decay_run_id_seq'));
    v_count  bigint := 0;
BEGIN
    PERFORM test_mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'running','init',
        format('FULL decay run started (project=%s, reset_interval=%s)', p_project_keyword, p_reset_interval), 0);

    PERFORM test_mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'running','clearing',
        'Clearing previous contribution rows for project', 0);
    DELETE FROM test_mindshare_score.contribution_scores WHERE project_keyword = p_project_keyword;

    PERFORM test_mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'running','computing',
        'Scanning replies and computing decay (full)', 0);

    v_count := test_mindshare_score._decay_apply_project(
                   p_project_keyword, p_reset_interval, v_run_id, false, p_log_every);

    PERFORM test_mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'success','done',
        format('Completed (full): %s contribution rows written', v_count), v_count, NULL,NULL,NULL,NULL, true);
    RETURN v_run_id;

EXCEPTION WHEN OTHERS THEN
    DECLARE
        v_state text := SQLSTATE; v_msg text := SQLERRM; v_detail text; v_context text;
    BEGIN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL, v_context = PG_EXCEPTION_CONTEXT;
        PERFORM test_mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'failed','error',
            format('FAILED (full): %s', v_msg), 0, v_state, v_msg, v_detail, v_context, true);
    END;
    RAISE;
END;
$func$;
