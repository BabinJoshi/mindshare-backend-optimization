-- analytics_md_fix.refresh_user_posts_engagement_incremental
-- Watermark-driven incremental refresh for the global mv_user_posts_engagement table.
-- No placeholder rows exist for this scope (matches the original view: roots with zero
-- engagement are simply absent), so new engagement is pure append: find replies/quotes/
-- retweets ingested since the watermark, resolve each to its root, INSERT ... ON CONFLICT
-- DO NOTHING.
--
-- Second, independent watermark (last_user_ts) tracks mindshare_user changes (score
-- recalculated, or renamed) -- existing rows referencing a dirty user get
-- root_username/engaged_user_score UPDATEd in place, same mechanism as
-- refresh_engagement_incremental.sql (see that file's header for why this stays cheap:
-- ~0.1-0.6% of users touched per day on this DB).
--
-- Same stale-checkpoint self-heal as refresh_engagement_incremental.sql (checkpoint
-- existing isn't proof the table exists), and same run-log wiring — see
-- engagement_logging.sql.

CREATE OR REPLACE PROCEDURE analytics_md_fix.refresh_user_posts_engagement_incremental()
LANGUAGE plpgsql AS $proc$
DECLARE
    v_watermark          timestamptz;
    v_new_watermark      timestamptz;
    v_user_watermark     timestamptz;
    v_new_user_watermark timestamptz;
    v_new_rows           bigint := 0;
    v_post_metric_updates bigint := 0;
    v_score_updates      bigint := 0;
    v_username_updates   bigint := 0;
    v_rows_updated       bigint := 0;
    v_run_id             bigint := analytics_md_fix.next_engagement_run_id();
    v_err_detail         text;
    v_err_context        text;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('analytics_engagement:user_posts_engagement'));

    SELECT last_ingest_ts, last_user_ts INTO v_watermark, v_user_watermark
    FROM analytics_md_fix.engagement_refresh_state
    WHERE scope_key = 'user_posts_engagement';

    IF NOT FOUND OR NOT EXISTS (
        SELECT 1 FROM pg_tables WHERE schemaname = 'analytics_md_fix' AND tablename = 'mv_user_posts_engagement'
    ) THEN
        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'global', NULL, 'incremental', 'success', 'delegated_to_full_build',
            'no checkpoint or table missing -> delegating to create_user_posts_engagement_table_full (see that run''s own log row)',
            0, 0, 0, NULL, NULL, NULL, NULL, true);
        CALL analytics_md_fix.create_user_posts_engagement_table_full();
        RETURN;
    END IF;

    PERFORM analytics_md_fix._log_engagement_run(
        v_run_id, 'global', NULL, 'incremental', 'running', 'scanning_dirty', 'incremental refresh starting');

    BEGIN
        SET LOCAL work_mem = '64MB';

        CREATE TEMP TABLE tmp_changed_up ON COMMIT DROP AS
        SELECT post_id, user_x_id, post_created_at, is_post, is_quote, is_reply, is_retweet,
               favorite_count, reply_count, replied_post_id, quoted_post_id, retweeted_post_id,
               GREATEST(created_at, updated_at) AS ingest_ts
        FROM mindshare.user_post
        WHERE GREATEST(created_at, updated_at) > v_watermark
          AND (
                replied_post_id IS NOT NULL OR quoted_post_id IS NOT NULL OR retweeted_post_id IS NOT NULL
                OR ((is_post OR is_quote) AND NOT is_reply AND NOT is_retweet)
              );

        CREATE TEMP TABLE tmp_dirty_users_up ON COMMIT DROP AS
        SELECT x_id, score, x_username, GREATEST(created_at, updated_at) AS user_ts
        FROM mindshare.mindshare_user
        WHERE GREATEST(created_at, updated_at) > v_user_watermark;

        IF NOT EXISTS (SELECT 1 FROM tmp_changed_up) AND NOT EXISTS (SELECT 1 FROM tmp_dirty_users_up) THEN
            UPDATE analytics_md_fix.engagement_refresh_state
               SET last_run_at = now(), rows_inserted = 0, rows_updated = 0
             WHERE scope_key = 'user_posts_engagement';
            PERFORM analytics_md_fix._log_engagement_run(
                v_run_id, 'global', NULL, 'incremental', 'success', 'done',
                'no-op incremental (0 dirty posts, 0 dirty users)', 0, 0, 0, NULL, NULL, NULL, NULL, true);
            RAISE NOTICE 'analytics_md_fix.mv_user_posts_engagement: no-op incremental (0 dirty posts, 0 dirty users).';
            RETURN;
        END IF;

        IF EXISTS (SELECT 1 FROM tmp_changed_up) THEN
            -- COALESCE picks reply > quote > retweet root, same precedence the original's
            -- "quote AND replied_post_id IS NULL" guard enforced — at most one root per engaged tweet.
            INSERT INTO analytics_md_fix.mv_user_posts_engagement
            SELECT r.post_id, r.user_x_id, ru.x_username, r.post_created_at, r.is_post, r.is_quote, r.is_reply,
                   r.favorite_count, r.reply_count, c.post_id, c.user_x_id, c.is_reply, c.is_quote, c.is_retweet,
                   c.post_created_at, COALESCE(eu.score, 0)
            FROM tmp_changed_up c
            JOIN mindshare.user_post r
              ON r.post_id = COALESCE(c.replied_post_id, c.quoted_post_id, c.retweeted_post_id)
             AND (r.is_post OR r.is_quote) AND NOT r.is_reply AND NOT r.is_retweet
            LEFT JOIN mindshare.mindshare_user ru ON ru.x_id = r.user_x_id
            LEFT JOIN mindshare.mindshare_user eu ON eu.x_id = c.user_x_id
            WHERE c.replied_post_id IS NOT NULL OR c.quoted_post_id IS NOT NULL OR c.retweeted_post_id IS NOT NULL
            ON CONFLICT (engaged_tweet_id) DO NOTHING;
            GET DIAGNOSTICS v_new_rows = ROW_COUNT;

            -- Existing rows whose ROOT post's own favorite_count/reply_count changed.
            UPDATE analytics_md_fix.mv_user_posts_engagement t
            SET root_favorite_count = c.favorite_count, root_reply_count = c.reply_count
            FROM tmp_changed_up c
            WHERE t.root_post_id = c.post_id
              AND (t.root_favorite_count IS DISTINCT FROM c.favorite_count
                   OR t.root_reply_count IS DISTINCT FROM c.reply_count);
            GET DIAGNOSTICS v_post_metric_updates = ROW_COUNT;

            SELECT MAX(ingest_ts) INTO v_new_watermark FROM tmp_changed_up;
        ELSE
            v_new_watermark := v_watermark;
        END IF;

        IF EXISTS (SELECT 1 FROM tmp_dirty_users_up) THEN
            UPDATE analytics_md_fix.mv_user_posts_engagement t
            SET engaged_user_score = u.score
            FROM tmp_dirty_users_up u
            WHERE t.engaged_user_id = u.x_id
              AND t.engaged_user_score IS DISTINCT FROM u.score;
            GET DIAGNOSTICS v_score_updates = ROW_COUNT;

            UPDATE analytics_md_fix.mv_user_posts_engagement t
            SET root_username = u.x_username
            FROM tmp_dirty_users_up u
            WHERE t.root_user_id = u.x_id
              AND t.root_username IS DISTINCT FROM u.x_username;
            GET DIAGNOSTICS v_username_updates = ROW_COUNT;

            SELECT MAX(user_ts) INTO v_new_user_watermark FROM tmp_dirty_users_up;
        ELSE
            v_new_user_watermark := v_user_watermark;
        END IF;

        v_rows_updated := v_post_metric_updates + v_score_updates + v_username_updates;

        UPDATE analytics_md_fix.engagement_refresh_state
           SET last_ingest_ts = v_new_watermark,
               last_user_ts = v_new_user_watermark,
               last_run_at = now(),
               rows_inserted = v_new_rows,
               rows_updated = v_rows_updated
         WHERE scope_key = 'user_posts_engagement';

        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'global', NULL, 'incremental', 'success', 'done',
            format('incremental +%s engagement rows, ~%s rows refreshed (post metrics + user score/username), post_watermark=%s, user_watermark=%s',
                   v_new_rows, v_rows_updated, v_new_watermark, v_new_user_watermark),
            v_new_rows, 0, 0, NULL, NULL, NULL, NULL, true);

        RAISE NOTICE 'analytics_md_fix.mv_user_posts_engagement: incremental +% engagement rows, ~% rows refreshed, post_watermark=%, user_watermark=%',
            v_new_rows, v_rows_updated, v_new_watermark, v_new_user_watermark;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_err_detail = PG_EXCEPTION_DETAIL, v_err_context = PG_EXCEPTION_CONTEXT;
        PERFORM analytics_md_fix._log_engagement_run(
            v_run_id, 'global', NULL, 'incremental', 'failed', 'error', SQLERRM,
            0, 0, 0, SQLSTATE, SQLERRM, v_err_detail, v_err_context, true);
        RAISE;
    END;
END;
$proc$;
