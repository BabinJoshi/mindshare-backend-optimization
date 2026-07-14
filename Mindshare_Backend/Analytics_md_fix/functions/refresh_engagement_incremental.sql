-- analytics_md_fix.refresh_engagement_incremental
-- Watermark-driven incremental refresh for one project's engagement_<project> table.
-- Replaces the old "REFRESH MATERIALIZED VIEW CONCURRENTLY" full-recompute path —
-- CONCURRENTLY only avoids locking, it still recomputes everything. This recomputes
-- nothing: it only reads mindshare_post/mindshare_user rows touched since the last
-- watermark.
--
-- First call ever for a project (no checkpoint row), OR a checkpoint row whose table has
-- since been dropped (stale checkpoint self-heal) -> falls back to a full build.
--
-- TWO independent dirty-scans, because two different things can go stale:
--   1. mindshare_post changed (new post, or an existing post's own favorite_count/
--      reply_count changed) -> tmp_changed, watermarked by last_ingest_ts. New
--      engagements/placeholders get INSERTed as before; existing rows whose ROOT post
--      is in tmp_changed get root_favorite_count/root_reply_count UPDATEd in place.
--   2. mindshare_user changed (score recalculated, or username changed) -> tmp_dirty_users,
--      watermarked separately by last_user_ts. Existing rows referencing that user
--      (as root_user_id or engaged_user_id) get root_username/engaged_user_score
--      UPDATEd in place.
-- Checked live on this DB: ~400-2,400 users/day touched out of 414,810 total (~0.1-0.6%),
-- so this stays cheap in practice — it does NOT turn into a full-table rewrite.
--
-- Every call is logged to engagement_run_log (see engagement_logging.sql), same as
-- create_engagement_table_full — debug a failure with
-- get_engagement_run_status(run_id) / get_recent_engagement_failures().

CREATE OR REPLACE PROCEDURE analytics_md_fix.refresh_engagement_incremental(IN p_project_keyword text)
LANGUAGE plpgsql AS $proc$
DECLARE
    v_project_keyword       text;
    v_table                 text;
    v_scope                 text;
    v_watermark             timestamptz;
    v_new_watermark         timestamptz;
    v_user_watermark        timestamptz;
    v_new_user_watermark    timestamptz;
    v_new_engagements       bigint := 0;
    v_placeholders_removed  bigint := 0;
    v_placeholders_inserted bigint := 0;
    v_post_metric_updates   bigint := 0;
    v_score_updates         bigint := 0;
    v_username_updates      bigint := 0;
    v_rows_updated          bigint := 0;
    v_run_id                bigint := analytics_md_fix.next_engagement_run_id();
    v_err_detail            text;
    v_err_context           text;
BEGIN
    SELECT project_name INTO v_project_keyword
    FROM mindshare.mindshare_project
    WHERE lower(project_name) = lower(p_project_keyword)
    LIMIT 1;

    IF NOT FOUND THEN
        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'project', p_project_keyword, 'incremental', 'failed', 'resolving_project',
            format('No project found matching %s (case-insensitive)', p_project_keyword),
            0, 0, 0, 'P0002', format('No project found matching %s', p_project_keyword), NULL, NULL, true);
        RAISE EXCEPTION 'No project found matching % (case-insensitive) in mindshare.mindshare_project', p_project_keyword;
    END IF;

    v_table := 'mv_engagement_' || LOWER(replace(v_project_keyword, ' ', '_'));
    v_scope := 'project:' || LOWER(replace(v_project_keyword, ' ', '_'));

    PERFORM pg_advisory_xact_lock(hashtext('analytics_engagement:' || v_scope));

    SELECT last_ingest_ts, last_user_ts INTO v_watermark, v_user_watermark
    FROM analytics_md_fix.engagement_refresh_state
    WHERE scope_key = v_scope;

    -- A checkpoint row existing is NOT proof the table exists — it can have been dropped
    -- (manually, or by a prior failed run) without the checkpoint being cleared. Trusting
    -- the checkpoint alone here silently no-ops forever against a table that's gone: the
    -- dirty-check finds nothing new (since the watermark is stale-but-present) and returns
    -- before ever touching the target table. Check both; self-heal via full build if either
    -- is missing.
    IF NOT FOUND OR NOT EXISTS (
        SELECT 1 FROM pg_tables WHERE schemaname = 'analytics_md_fix' AND tablename = v_table
    ) THEN
        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'project', v_project_keyword, 'incremental', 'success', 'delegated_to_full_build',
            'no checkpoint or table missing -> delegating to create_engagement_table_full (see that run''s own log row)',
            0, 0, 0, NULL, NULL, NULL, NULL, true);
        CALL analytics_md_fix.create_engagement_table_full(v_project_keyword);
        RETURN;
    END IF;

    PERFORM analytics_md_fix._log_engagement_run(
        v_run_id, 'project', v_project_keyword, 'incremental', 'running', 'scanning_dirty', 'incremental refresh starting');

    BEGIN
        SET LOCAL work_mem = '64MB';

        -- New/changed, non-retweet posts for this project since the watermark. Ingest-time
        -- (GREATEST(created_at,updated_at)), not post_created_at, so late-arriving/backfilled
        -- posts are still picked up on the run after they land, not lost. Also catches posts
        -- whose OWN favorite_count/reply_count changed (not just brand-new posts).
        CREATE TEMP TABLE tmp_changed ON COMMIT DROP AS
        SELECT mp.post_id, mp.user_x_id, mp.post_created_at, mp.is_post, mp.is_quote, mp.is_reply,
               mp.favorite_count, mp.reply_count, mp.replied_post_id, mp.quoted_post_id,
               GREATEST(mp.created_at, mp.updated_at) AS ingest_ts
        FROM mindshare.mindshare_post mp
        WHERE mp.project_keyword = v_project_keyword
          AND NOT mp.is_retweet
          AND GREATEST(mp.created_at, mp.updated_at) > v_watermark;

        -- Users touched since last_user_ts (score recalculated, or renamed) who are relevant
        -- to THIS project's table (root poster or engager) get their stored snapshot in
        -- existing rows refreshed. Separate watermark from posts -- these are independent
        -- events (a user's score can change without them posting anything new).
        CREATE TEMP TABLE tmp_dirty_users ON COMMIT DROP AS
        SELECT x_id, score, x_username, GREATEST(created_at, updated_at) AS user_ts
        FROM mindshare.mindshare_user
        WHERE GREATEST(created_at, updated_at) > v_user_watermark;

        IF NOT EXISTS (SELECT 1 FROM tmp_changed) AND NOT EXISTS (SELECT 1 FROM tmp_dirty_users) THEN
            UPDATE analytics_md_fix.engagement_refresh_state
               SET last_run_at = now(), rows_inserted = 0, placeholders_removed = 0,
                   placeholders_inserted = 0, rows_updated = 0
             WHERE scope_key = v_scope;
            PERFORM analytics_md_fix._log_engagement_run(
                v_run_id, 'project', v_project_keyword, 'incremental', 'success', 'done',
                'no-op incremental (0 dirty posts, 0 dirty users)', 0, 0, 0, NULL, NULL, NULL, NULL, true);
            RAISE NOTICE 'analytics_md_fix.%: no-op incremental (0 dirty posts, 0 dirty users).', v_table;
            RETURN;
        END IF;

        IF EXISTS (SELECT 1 FROM tmp_changed) THEN
            -- New engagement rows: dirty rows that are themselves a reply/quote, resolved
            -- against their root (root may be an old, already-stored post or itself brand-new).
            CREATE TEMP TABLE tmp_new_engagements ON COMMIT DROP AS
            SELECT
                r.post_id         AS root_post_id,
                r.user_x_id       AS root_user_id,
                ru.x_username     AS root_username,
                r.post_created_at AS root_tweet_created_at,
                r.is_post         AS is_root_post,
                r.is_quote        AS is_root_quote,
                r.is_reply        AS is_root_reply,
                r.favorite_count  AS root_favorite_count,
                r.reply_count     AS root_reply_count,
                c.post_id         AS engaged_tweet_id,
                c.user_x_id       AS engaged_user_id,
                c.is_reply        AS is_engaged_reply,
                c.is_quote        AS is_engaged_quote,
                false             AS is_engaged_repost,
                c.post_created_at AS engaged_tweet_created_at,
                eu.score          AS engaged_user_score
            FROM tmp_changed c
            JOIN mindshare.mindshare_post r
              ON r.post_id = COALESCE(c.replied_post_id, c.quoted_post_id)
             AND r.project_keyword = v_project_keyword
            LEFT JOIN mindshare.mindshare_user ru ON ru.x_id = r.user_x_id
            LEFT JOIN mindshare.mindshare_user eu ON eu.x_id = c.user_x_id
            WHERE c.replied_post_id IS NOT NULL OR c.quoted_post_id IS NOT NULL;

            -- Roots getting their first-ever engagement now: drop their stale placeholder row.
            EXECUTE format($q$
                DELETE FROM analytics_md_fix.%I
                WHERE engaged_tweet_id IS NULL
                  AND root_post_id IN (SELECT DISTINCT root_post_id FROM tmp_new_engagements)
            $q$, v_table);
            GET DIAGNOSTICS v_placeholders_removed = ROW_COUNT;

            EXECUTE format($q$
                INSERT INTO analytics_md_fix.%I
                SELECT * FROM tmp_new_engagements
                ON CONFLICT (engaged_tweet_id) DO NOTHING
            $q$, v_table);
            GET DIAGNOSTICS v_new_engagements = ROW_COUNT;

            -- Brand-new roots with zero engagement so far (nobody replied/quoted them in this batch).
            EXECUTE format($q$
                INSERT INTO analytics_md_fix.%I
                SELECT c.post_id, c.user_x_id, cu.x_username, c.post_created_at,
                       c.is_post, c.is_quote, c.is_reply, c.favorite_count, c.reply_count,
                       NULL::text, NULL::text, NULL::boolean, NULL::boolean,
                       NULL::boolean, NULL::timestamptz, NULL::numeric
                FROM tmp_changed c
                LEFT JOIN mindshare.mindshare_user cu ON cu.x_id = c.user_x_id
                WHERE NOT EXISTS (SELECT 1 FROM tmp_new_engagements e WHERE e.root_post_id = c.post_id)
                  AND NOT EXISTS (SELECT 1 FROM analytics_md_fix.%I existing WHERE existing.root_post_id = c.post_id)
            $q$, v_table, v_table);
            GET DIAGNOSTICS v_placeholders_inserted = ROW_COUNT;

            -- Existing rows whose ROOT post is dirty (favorite_count/reply_count changed on an
            -- OLD post, no new engagement involved) -- refresh in place instead of leaving stale.
            EXECUTE format($q$
                UPDATE analytics_md_fix.%I t
                SET root_favorite_count = c.favorite_count, root_reply_count = c.reply_count
                FROM tmp_changed c
                WHERE t.root_post_id = c.post_id
                  AND (t.root_favorite_count IS DISTINCT FROM c.favorite_count
                       OR t.root_reply_count IS DISTINCT FROM c.reply_count)
            $q$, v_table);
            GET DIAGNOSTICS v_post_metric_updates = ROW_COUNT;

            SELECT MAX(ingest_ts) INTO v_new_watermark FROM tmp_changed;
        ELSE
            v_new_watermark := v_watermark;
        END IF;

        IF EXISTS (SELECT 1 FROM tmp_dirty_users) THEN
            -- Engaged-side: refresh engaged_user_score for every existing row where that
            -- engager's score changed, regardless of how old the row is.
            EXECUTE format($q$
                UPDATE analytics_md_fix.%I t
                SET engaged_user_score = u.score
                FROM tmp_dirty_users u
                WHERE t.engaged_user_id = u.x_id
                  AND t.engaged_user_score IS DISTINCT FROM u.score
            $q$, v_table);
            GET DIAGNOSTICS v_score_updates = ROW_COUNT;

            -- Root-side: refresh root_username for existing rows if that poster renamed.
            EXECUTE format($q$
                UPDATE analytics_md_fix.%I t
                SET root_username = u.x_username
                FROM tmp_dirty_users u
                WHERE t.root_user_id = u.x_id
                  AND t.root_username IS DISTINCT FROM u.x_username
            $q$, v_table);
            GET DIAGNOSTICS v_username_updates = ROW_COUNT;

            SELECT MAX(user_ts) INTO v_new_user_watermark FROM tmp_dirty_users;
        ELSE
            v_new_user_watermark := v_user_watermark;
        END IF;

        v_rows_updated := v_post_metric_updates + v_score_updates + v_username_updates;

        UPDATE analytics_md_fix.engagement_refresh_state
           SET last_ingest_ts = v_new_watermark,
               last_user_ts = v_new_user_watermark,
               last_run_at = now(),
               rows_inserted = v_new_engagements + v_placeholders_inserted,
               placeholders_removed = v_placeholders_removed,
               placeholders_inserted = v_placeholders_inserted,
               rows_updated = v_rows_updated
         WHERE scope_key = v_scope;

        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'project', v_project_keyword, 'incremental', 'success', 'done',
            format('incremental +%s engagement rows, +%s placeholders, -%s stale placeholders, ~%s rows refreshed (post metrics + user score/username), post_watermark=%s, user_watermark=%s',
                   v_new_engagements, v_placeholders_inserted, v_placeholders_removed, v_rows_updated, v_new_watermark, v_new_user_watermark),
            v_new_engagements, v_placeholders_removed, v_placeholders_inserted, NULL, NULL, NULL, NULL, true);

        RAISE NOTICE 'analytics_md_fix.%: incremental +% engagement rows, +% placeholders, -% stale placeholders, ~% rows refreshed, post_watermark=%, user_watermark=%',
            v_table, v_new_engagements, v_placeholders_inserted, v_placeholders_removed, v_rows_updated, v_new_watermark, v_new_user_watermark;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_err_detail = PG_EXCEPTION_DETAIL, v_err_context = PG_EXCEPTION_CONTEXT;
        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'project', v_project_keyword, 'incremental', 'failed', 'error', SQLERRM,
            0, 0, 0, SQLSTATE, SQLERRM, v_err_detail, v_err_context, true);
        RAISE;
    END;
END;
$proc$;
