-- analytics_md_fix.create_user_posts_engagement_table_full
-- Full (re)build of the GLOBAL (cross-project) engagement object — TABLE, not
-- MATERIALIZED VIEW. Keeps the same object name (mv_user_posts_engagement) the old
-- matview used, so any live consumer referencing it by name keeps working. Run
-- 00_drop_old_mv_and_procs.sql once first to drop the old MATERIALIZED VIEW.
--
-- Mirrors analytics.create_user_posts_engagement_view: roots = top-level posts/quotes
-- (NOT reply, NOT retweet) from mindshare.user_post; engagements = replies, quotes and
-- retweets INNER JOINed to their root. Same as the original, roots with zero engagement
-- are simply absent (no placeholder row) — there's no "posts_with_no_engagement" branch
-- here, unlike the per-project engagement table.
--
-- Logged to engagement_run_log same as the per-project version (project_keyword = NULL
-- for this scope) — see engagement_logging.sql / create_engagement_table_full.sql.

CREATE OR REPLACE PROCEDURE analytics_md_fix.create_user_posts_engagement_table_full()
LANGUAGE plpgsql AS $proc$
DECLARE
    v_watermark      timestamptz;
    v_user_watermark timestamptz := clock_timestamp();
    v_rows           bigint;
    v_run_id         bigint := analytics_md_fix.next_engagement_run_id();
BEGIN
    PERFORM analytics_md_fix._log_engagement_run(
        v_run_id, 'global', NULL, 'full', 'running', 'building', 'full rebuild starting');

    BEGIN
        SET LOCAL work_mem = '64MB';

        DROP TABLE IF EXISTS analytics_md_fix.mv_user_posts_engagement CASCADE;

        CREATE TABLE analytics_md_fix.mv_user_posts_engagement AS
        WITH roots AS MATERIALIZED (
            SELECT p.post_id, p.user_x_id, p.post_created_at, p.is_post, p.is_quote, p.is_reply,
                   p.favorite_count, p.reply_count, u.x_username AS root_username
            FROM mindshare.user_post p
            LEFT JOIN mindshare.mindshare_user u ON u.x_id = p.user_x_id
            WHERE (p.is_post OR p.is_quote) AND NOT p.is_reply AND NOT p.is_retweet
        ),
        engaged_tweets AS MATERIALIZED (
            SELECT post_id, user_x_id, is_reply, is_quote, is_retweet, post_created_at,
                   replied_post_id, quoted_post_id, retweeted_post_id
            FROM mindshare.user_post
            WHERE replied_post_id IS NOT NULL OR quoted_post_id IS NOT NULL OR retweeted_post_id IS NOT NULL
        ),
        engagements AS (
            SELECT r.post_id AS root_post_id, r.user_x_id AS root_user_id, r.root_username,
                   r.post_created_at AS root_tweet_created_at, r.is_post AS is_root_post,
                   r.is_quote AS is_root_quote, r.is_reply AS is_root_reply,
                   r.favorite_count AS root_favorite_count, r.reply_count AS root_reply_count,
                   e.post_id AS engaged_tweet_id, e.user_x_id AS engaged_user_id,
                   e.is_reply AS is_engaged_reply, e.is_quote AS is_engaged_quote, e.is_retweet AS is_engaged_repost,
                   e.post_created_at AS engaged_tweet_created_at
            FROM roots r JOIN engaged_tweets e ON e.replied_post_id = r.post_id
            UNION ALL
            SELECT r.post_id, r.user_x_id, r.root_username, r.post_created_at, r.is_post, r.is_quote, r.is_reply,
                   r.favorite_count, r.reply_count, e.post_id, e.user_x_id, e.is_reply, e.is_quote, e.is_retweet,
                   e.post_created_at
            FROM roots r JOIN engaged_tweets e ON e.quoted_post_id = r.post_id AND e.replied_post_id IS NULL
            UNION ALL
            SELECT r.post_id, r.user_x_id, r.root_username, r.post_created_at, r.is_post, r.is_quote, r.is_reply,
                   r.favorite_count, r.reply_count, e.post_id, e.user_x_id, e.is_reply, e.is_quote, e.is_retweet,
                   e.post_created_at
            FROM roots r JOIN engaged_tweets e ON e.retweeted_post_id = r.post_id
        )
        SELECT e.*, COALESCE(mu.score, 0) AS engaged_user_score
        FROM engagements e
        LEFT JOIN mindshare.mindshare_user mu ON mu.x_id = e.engaged_user_id;

        CREATE UNIQUE INDEX IF NOT EXISTS ix_mv_user_posts_engagement_tweet ON analytics_md_fix.mv_user_posts_engagement (engaged_tweet_id);
        CREATE INDEX IF NOT EXISTS ix_mv_user_posts_engagement_root ON analytics_md_fix.mv_user_posts_engagement (root_post_id);
        CREATE INDEX IF NOT EXISTS ix_mv_user_posts_engagement_root_user ON analytics_md_fix.mv_user_posts_engagement (root_user_id);

        SELECT count(*) INTO v_rows FROM analytics_md_fix.mv_user_posts_engagement;

        SELECT COALESCE(MAX(GREATEST(created_at, updated_at)), '-infinity'::timestamptz)
          INTO v_watermark
          FROM mindshare.user_post
          WHERE replied_post_id IS NOT NULL OR quoted_post_id IS NOT NULL OR retweeted_post_id IS NOT NULL
             OR ((is_post OR is_quote) AND NOT is_reply AND NOT is_retweet);

        INSERT INTO analytics_md_fix.engagement_refresh_state
            (scope_key, last_ingest_ts, last_user_ts, last_run_at, rows_inserted)
        VALUES ('user_posts_engagement', v_watermark, v_user_watermark, now(), v_rows)
        ON CONFLICT (scope_key) DO UPDATE
           SET last_ingest_ts = EXCLUDED.last_ingest_ts, last_user_ts = EXCLUDED.last_user_ts,
               last_run_at = now(), rows_inserted = EXCLUDED.rows_inserted,
               placeholders_removed = 0, placeholders_inserted = 0, rows_updated = 0;

        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'global', NULL, 'full', 'success', 'done',
            format('built %s rows, watermark=%s', v_rows, v_watermark), v_rows, 0, 0, NULL, NULL, NULL, NULL, true);

        RAISE NOTICE 'analytics_md_fix.mv_user_posts_engagement built full (% rows), watermark=%', v_rows, v_watermark;
    EXCEPTION WHEN OTHERS THEN
        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'global', NULL, 'full', 'failed', 'error', SQLERRM,
            0, 0, 0, SQLSTATE, SQLERRM, PG_EXCEPTION_DETAIL, PG_EXCEPTION_CONTEXT, true);
        RAISE;
    END;
END;
$proc$;
