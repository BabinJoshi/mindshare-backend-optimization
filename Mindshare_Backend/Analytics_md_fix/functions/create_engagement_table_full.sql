-- analytics_md_fix.create_engagement_table_full
-- Full (re)build of the per-project engagement object — TABLE, not MATERIALIZED VIEW.
-- Keeps the SAME object name (mv_engagement_<project>) the old matview used: several
-- live functions (e.g. get_v2_user_posts_analytics) do `analytics_md_fix.%I` with this
-- exact name — renaming would silently break them. Only the object KIND changes.
-- Run 00_drop_old_mv_and_procs.sql once first to drop the old MATERIALIZED VIEW (this
-- proc's own DROP TABLE IF EXISTS only works once the name is already a table).
--
-- Same single-pass query as the old analytics_md_fix.create_engagement_view, but a
-- real table so refresh_engagement_incremental() can append/UPSERT into it instead of
-- DROP+CREATE-ing a matview every run. Also seeds engagement_refresh_state so the
-- very next incremental call knows where to resume from.
--
-- Bootstrap path: called automatically by refresh_engagement_incremental() the first
-- time a project has no checkpoint row. Call directly to force a from-scratch rebuild.
--
-- Every call is logged to engagement_run_log (see engagement_logging.sql) — start,
-- success or failure with full SQLSTATE/message/detail/context — via an autonomous
-- dblink commit, so a failed run's error details survive even though this procedure's
-- own transaction rolls back. Debug a specific run with:
--   SELECT * FROM analytics_md_fix.get_engagement_run_status(<run_id>);
--   SELECT * FROM analytics_md_fix.get_recent_engagement_failures();

CREATE OR REPLACE PROCEDURE analytics_md_fix.create_engagement_table_full(IN p_project_keyword text)
LANGUAGE plpgsql AS $proc$
DECLARE
    v_project_keyword text;
    v_table       text;
    v_scope       text;
    v_watermark   timestamptz;
    v_user_watermark timestamptz := clock_timestamp();
    v_rows        bigint;
    v_run_id      bigint := analytics_md_fix.next_engagement_run_id();
BEGIN
    SELECT project_name INTO v_project_keyword
    FROM mindshare.mindshare_project
    WHERE lower(project_name) = lower(p_project_keyword)
    LIMIT 1;

    IF NOT FOUND THEN
        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'project', p_project_keyword, 'full', 'failed', 'resolving_project',
            format('No project found matching %s (case-insensitive)', p_project_keyword),
            0, 0, 0, 'P0002', format('No project found matching %s', p_project_keyword), NULL, NULL, true);
        RAISE EXCEPTION 'No project found matching % (case-insensitive) in mindshare.mindshare_project', p_project_keyword;
    END IF;

    v_table := 'mv_engagement_' || LOWER(replace(v_project_keyword, ' ', '_'));
    v_scope := 'project:' || LOWER(replace(v_project_keyword, ' ', '_'));

    PERFORM analytics_md_fix._log_engagement_run(
        v_run_id, 'project', v_project_keyword, 'full', 'running', 'building', 'full rebuild starting');

    BEGIN
        SET LOCAL enable_mergejoin = off;
        SET LOCAL work_mem = '64MB';

        EXECUTE format('DROP TABLE IF EXISTS analytics_md_fix.%I CASCADE', v_table);

        EXECUTE format($sql$
            CREATE TABLE analytics_md_fix.%I AS
            WITH all_posts AS MATERIALIZED (
                SELECT mp.post_id, mp.user_x_id, mp.post_created_at,
                       mp.is_post, mp.is_quote, mp.is_reply, mp.is_retweet,
                       mp.favorite_count, mp.reply_count,
                       mp.replied_post_id, mp.quoted_post_id,
                       mu.x_username, mu.score
                FROM mindshare.mindshare_post mp
                LEFT JOIN mindshare.mindshare_user mu ON mu.x_id::text = mp.user_x_id
                WHERE mp.project_keyword = %L
                  AND (mp.is_post OR mp.is_reply OR mp.is_quote)
            ),
            engager_posts AS MATERIALIZED (
                SELECT * FROM all_posts
                WHERE replied_post_id IS NOT NULL OR quoted_post_id IS NOT NULL
            ),
            engagements AS MATERIALIZED (
                SELECT r.post_id AS root_post_id, r.user_x_id AS root_user_id,
                       r.x_username AS root_username, r.post_created_at AS root_tweet_created_at,
                       r.is_post AS is_root_post, r.is_quote AS is_root_quote, r.is_reply AS is_root_reply,
                       r.favorite_count AS root_favorite_count, r.reply_count AS root_reply_count,
                       e.post_id AS engaged_tweet_id, e.user_x_id AS engaged_user_id,
                       e.is_reply AS is_engaged_reply, e.is_quote AS is_engaged_quote,
                       e.is_retweet AS is_engaged_repost, e.post_created_at AS engaged_tweet_created_at,
                       e.score AS engaged_user_score
                FROM all_posts r JOIN engager_posts e ON e.replied_post_id = r.post_id
                UNION ALL
                SELECT r.post_id, r.user_x_id, r.x_username, r.post_created_at,
                       r.is_post, r.is_quote, r.is_reply, r.favorite_count, r.reply_count,
                       e.post_id, e.user_x_id, e.is_reply, e.is_quote, e.is_retweet, e.post_created_at,
                       e.score
                FROM all_posts r JOIN engager_posts e ON e.quoted_post_id = r.post_id AND e.replied_post_id IS NULL
            ),
            posts_with_no_engagement AS (
                SELECT r.post_id, r.user_x_id, r.x_username, r.post_created_at,
                       r.is_post, r.is_quote, r.is_reply, r.favorite_count, r.reply_count,
                       NULL::text, NULL::text, NULL::boolean, NULL::boolean,
                       NULL::boolean, NULL::timestamptz, NULL::numeric
                FROM all_posts r
                LEFT JOIN engagements eng ON eng.root_post_id = r.post_id
                WHERE eng.root_post_id IS NULL
            )
            SELECT * FROM engagements
            UNION ALL
            SELECT * FROM posts_with_no_engagement
        $sql$, v_table, v_project_keyword);

        EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %I ON analytics_md_fix.%I (engaged_tweet_id)',
            'ix_' || v_table || '_tweet', v_table);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON analytics_md_fix.%I (root_post_id)',
            'ix_' || v_table || '_root', v_table);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON analytics_md_fix.%I (engaged_user_id)',
            'ix_' || v_table || '_user', v_table);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON analytics_md_fix.%I (engaged_tweet_created_at)',
            'ix_' || v_table || '_eng_created', v_table);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON analytics_md_fix.%I (root_tweet_created_at)',
            'ix_' || v_table || '_root_created', v_table);

        EXECUTE format('SELECT count(*) FROM analytics_md_fix.%I', v_table) INTO v_rows;

        SELECT COALESCE(MAX(GREATEST(created_at, updated_at)), '-infinity'::timestamptz)
          INTO v_watermark
          FROM mindshare.mindshare_post
          WHERE project_keyword = v_project_keyword
            AND NOT is_retweet;

        -- last_user_ts seeded to clock_timestamp() captured at proc entry (before the
        -- CTAS read mindshare_user) -- every user's score/username is fresh as of that
        -- moment, so only user changes strictly after it are "dirty" for the next
        -- incremental run. See refresh_engagement_incremental.sql for how this drives
        -- UPDATEs to already-existing rows (root_username, engaged_user_score).
        INSERT INTO analytics_md_fix.engagement_refresh_state
            (scope_key, last_ingest_ts, last_user_ts, last_run_at, rows_inserted)
        VALUES (v_scope, v_watermark, v_user_watermark, now(), v_rows)
        ON CONFLICT (scope_key) DO UPDATE
           SET last_ingest_ts = EXCLUDED.last_ingest_ts,
               last_user_ts = EXCLUDED.last_user_ts,
               last_run_at = now(),
               rows_inserted = EXCLUDED.rows_inserted,
               placeholders_removed = 0,
               placeholders_inserted = 0,
               rows_updated = 0;

        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'project', v_project_keyword, 'full', 'success', 'done',
            format('built %s rows, watermark=%s', v_rows, v_watermark), v_rows, 0, 0, NULL, NULL, NULL, NULL, true);

        RAISE NOTICE 'analytics_md_fix.% built full (% rows), watermark=%', v_table, v_rows, v_watermark;
    EXCEPTION WHEN OTHERS THEN
        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'project', v_project_keyword, 'full', 'failed', 'error', SQLERRM,
            0, 0, 0, SQLSTATE, SQLERRM, PG_EXCEPTION_DETAIL, PG_EXCEPTION_CONTEXT, true);
        RAISE;
    END;
END;
$proc$;
