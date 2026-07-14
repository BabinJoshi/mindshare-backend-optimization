-- test_engagement_pipeline_suite.sql
-- End-to-end regression suite for the incremental engagement pipeline
-- (refresh_engagement_incremental / refresh_user_posts_engagement_incremental).
--
-- Unlike test_change_propagation.sql (4 spot-checks on real data), this suite:
--   - uses fully synthetic, disposable rows (post_id/x_id prefixed ZT_P_/ZT_G_)
--     so every test case has a known, deterministic before/after state
--   - simulates MULTIPLE ingest batches (insert -> CALL incremental -> insert
--     more -> CALL incremental again), exactly how this runs in production
--   - never aborts on the first failure: every assertion is recorded into a
--     `results` temp table (PASS/FAIL/detail), so one broken test case
--     doesn't hide the results of the other 20
--   - runs entirely inside one transaction and ROLLBACKs at the end -- zero
--     permanent side effects (engagement_run_log rows from the CALLs are the
--     one exception, see test_change_propagation.sql header for why)
--
-- Run in DBeaver (script mode, auto-commit OFF) or `psql -f`. Read the final
-- two SELECTs for the summary and per-test detail.
--
-- Test map:
--   Section 1 (TC01-04): baseline value-change propagation on real data
--     (regression coverage also in test_change_propagation.sql)
--   Section 2 (TC05-09, TC14-18): project-scope synthetic lifecycle -- new
--     root+reply same batch, username rename, new engager on existing root,
--     placeholder creation+removal, concurrent batch of replies, orphan
--     engaging user, cross-project isolation, idempotent re-run, and a
--     forced real-failure regression test (TC18, see below)
--   Section 3 (TC11-13): global-scope synthetic lifecycle -- new root+reply,
--     retweet engagement type, quote engagement type
--   Section 4 (TC15b): orphan engaged-user asymmetry (project NULL vs global 0)
--   Section 5 (TC17): stale-checkpoint self-heal (table dropped, checkpoint
--     survives -> must delegate to full build)
--   Section 6 (TC19-27): project-scope edge cases -- quote engagement, retweet
--     exclusion, cross-project link isolation, late-arriving/backfilled post,
--     multi-row root-metric + user-score updates, row-level re-ingest
--     idempotency, watermark-advances-to-batch-max
--   Section 7 (TC28): global reply+quote precedence (replied wins, one row)
--   Section 8 (TC29): PARITY CAPSTONE -- incremental-maintained table must be
--     EXCEPT-ALL-identical (both directions) to a fresh full build over the
--     same source. Catches any divergence the targeted tests miss.
--
-- Note: mindshare_user.score is NOT NULL in the schema, so an existing
-- user's score can never literally become NULL -- there is no "score set to
-- NULL" test case here. The only way engaged_user_score is ever NULL/0 is
-- the orphan-user path (engaging user has no mindshare_user row at all),
-- covered by TC15a/TC15b.

BEGIN;

CREATE TEMP TABLE results (test_id text PRIMARY KEY, status text, detail text) ON COMMIT DROP;

CREATE FUNCTION pg_temp.assert_eq(p_test_id text, p_actual anyelement, p_expected anyelement, p_detail text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    IF p_actual IS NOT DISTINCT FROM p_expected THEN
        INSERT INTO results VALUES (p_test_id, 'PASS', p_detail);
    ELSE
        INSERT INTO results VALUES (p_test_id, 'FAIL', format('%s -- got %s, want %s', p_detail, p_actual, p_expected));
    END IF;
END;
$f$;

------------------------------------------------------------------------------
-- SECTION 1: baseline value-change propagation on real, existing data
------------------------------------------------------------------------------
DO $$
DECLARE
    v_project     text := 'Acurast';
    v_table       text := 'mv_engagement_' || lower(replace(v_project, ' ', '_'));
    v_post_id     text;
    v_old_fav     int;
    v_old_reply   int;
    v_new_fav     int;
    v_new_reply   int;
    v_fav_after   int;
    v_reply_after int;
    v_user_id     text;
    v_old_score   numeric;
    v_new_score   numeric;
    v_score_after numeric;
    v_g_post_id   text;
    v_g_old_fav   int;
    v_g_old_reply int;
    v_g_new_fav   int;
    v_g_new_reply int;
    v_g_fav_after int;
    v_g_reply_after int;
    v_g_user_id   text;
    v_g_old_score numeric;
    v_g_new_score numeric;
    v_g_score_after numeric;
BEGIN
    EXECUTE format('SELECT root_post_id, root_favorite_count, root_reply_count
                     FROM analytics_md_fix.%I WHERE root_post_id IS NOT NULL LIMIT 1', v_table)
      INTO v_post_id, v_old_fav, v_old_reply;
    EXECUTE format('SELECT m.engaged_user_id, m.engaged_user_score FROM analytics_md_fix.%I m
                     JOIN mindshare.mindshare_user u ON u.x_id = m.engaged_user_id
                     WHERE m.engaged_user_id IS NOT NULL LIMIT 1', v_table)
      INTO v_user_id, v_old_score;

    v_new_fav := coalesce(v_old_fav,0)+1000;
    v_new_reply := coalesce(v_old_reply,0)+1000;
    v_new_score := coalesce(v_old_score,0)+12345;

    UPDATE mindshare.mindshare_post SET favorite_count=v_new_fav, reply_count=v_new_reply, updated_at=clock_timestamp() WHERE post_id=v_post_id;
    UPDATE mindshare.mindshare_user SET score=v_new_score, updated_at=clock_timestamp() WHERE x_id=v_user_id;

    SELECT root_post_id, root_favorite_count, root_reply_count INTO v_g_post_id, v_g_old_fav, v_g_old_reply
      FROM analytics_md_fix.mv_user_posts_engagement WHERE root_post_id IS NOT NULL LIMIT 1;
    SELECT m.engaged_user_id, m.engaged_user_score INTO v_g_user_id, v_g_old_score
      FROM analytics_md_fix.mv_user_posts_engagement m JOIN mindshare.mindshare_user u ON u.x_id = m.engaged_user_id
      WHERE m.engaged_user_id IS NOT NULL LIMIT 1;

    v_g_new_fav := coalesce(v_g_old_fav,0)+1000;
    v_g_new_reply := coalesce(v_g_old_reply,0)+1000;
    v_g_new_score := coalesce(v_g_old_score,0)+54321;

    UPDATE mindshare.user_post SET favorite_count=v_g_new_fav, reply_count=v_g_new_reply, updated_at=clock_timestamp() WHERE post_id=v_g_post_id;
    UPDATE mindshare.mindshare_user SET score=v_g_new_score, updated_at=clock_timestamp() WHERE x_id=v_g_user_id;

    DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);
    DROP TABLE IF EXISTS pg_temp.tmp_changed_up, pg_temp.tmp_dirty_users_up;
    CALL analytics_md_fix.refresh_user_posts_engagement_incremental();

    EXECUTE format('SELECT root_favorite_count, root_reply_count FROM analytics_md_fix.%I WHERE root_post_id = %L', v_table, v_post_id)
      INTO v_fav_after, v_reply_after;
    EXECUTE format('SELECT engaged_user_score FROM analytics_md_fix.%I WHERE engaged_user_id = %L LIMIT 1', v_table, v_user_id)
      INTO v_score_after;
    SELECT root_favorite_count, root_reply_count INTO v_g_fav_after, v_g_reply_after
      FROM analytics_md_fix.mv_user_posts_engagement WHERE root_post_id = v_g_post_id LIMIT 1;
    SELECT engaged_user_score INTO v_g_score_after
      FROM analytics_md_fix.mv_user_posts_engagement WHERE engaged_user_id = v_g_user_id LIMIT 1;

    PERFORM pg_temp.assert_eq('TC01a_project_post_favorite_change', v_fav_after, v_new_fav,
        'mindshare_post favorite_count change -> mv_engagement root_favorite_count');
    PERFORM pg_temp.assert_eq('TC01b_project_post_reply_change', v_reply_after, v_new_reply,
        'mindshare_post reply_count change -> mv_engagement root_reply_count');
    PERFORM pg_temp.assert_eq('TC02_project_user_score_change', v_score_after, v_new_score,
        'mindshare_user score change -> mv_engagement engaged_user_score');
    PERFORM pg_temp.assert_eq('TC03a_global_post_favorite_change', v_g_fav_after, v_g_new_fav,
        'user_post favorite_count change -> mv_user_posts_engagement root_favorite_count');
    PERFORM pg_temp.assert_eq('TC03b_global_post_reply_change', v_g_reply_after, v_g_new_reply,
        'user_post reply_count change -> mv_user_posts_engagement root_reply_count');
    PERFORM pg_temp.assert_eq('TC04_global_user_score_change', v_g_score_after, v_g_new_score,
        'mindshare_user score change -> mv_user_posts_engagement engaged_user_score');
END $$;

------------------------------------------------------------------------------
-- SECTION 2 (batch 1): project-scope synthetic setup -- new root+reply,
-- placeholder root, all in ONE incremental batch
------------------------------------------------------------------------------
DO $$
DECLARE
    v_project text := 'Acurast';
BEGIN
    -- created_at/updated_at set explicitly via clock_timestamp() everywhere below --
    -- the column DEFAULT is now()-based, and now() is frozen at transaction start,
    -- not per-statement, so relying on the default inside this long-running test
    -- transaction stamps every synthetic row BEFORE the watermark already advanced
    -- moments earlier via clock_timestamp() -- the dirty-scan would silently skip
    -- them all. Not an issue in production (each real ingest is its own transaction).
    INSERT INTO mindshare.mindshare_user (x_id, x_username, display_name, score, avatar_url, adjustment_config, followers_count, created_at, updated_at) VALUES
        ('ZT_P_USERA', 'zt_p_usera_v1', 'Test User A', 10.00, 'http://test', '{}'::jsonb, 0, clock_timestamp(), clock_timestamp()),
        ('ZT_P_USERB', 'zt_p_userb',    'Test User B', 20.00, 'http://test', '{}'::jsonb, 0, clock_timestamp(), clock_timestamp()),
        ('ZT_P_USERD', 'zt_p_userd',    'Test User D', 40.00, 'http://test', '{}'::jsonb, 0, clock_timestamp(), clock_timestamp());

    -- root R1 (poster A) + reply E1 (from B) landing in the SAME batch
    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_ROOT1', v_project, 'ZT_P_USERA', 'root1', 5, 0, 0, 0, 0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, replied_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_REPLY1', v_project, 'ZT_P_USERB', 'reply1', 'ZT_P_ROOT1', 1, 0, 0, 0, 0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    -- root R2 (poster D), zero engagement this batch -> should become a placeholder
    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_ROOT2', v_project, 'ZT_P_USERD', 'root2', 0, 0, 0, 0, 0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);

    PERFORM pg_temp.assert_eq('TC05a_new_root_and_reply_same_batch',
        (SELECT count(*) FROM analytics_md_fix.mv_engagement_acurast WHERE engaged_tweet_id='ZT_P_REPLY1' AND root_post_id='ZT_P_ROOT1')::int, 1,
        'brand-new root + brand-new reply in the same incremental batch must create exactly one engagement row');

    PERFORM pg_temp.assert_eq('TC05b_engaged_user_score_via_live_join',
        (SELECT engaged_user_score FROM analytics_md_fix.mv_engagement_acurast WHERE engaged_tweet_id='ZT_P_REPLY1'), 20.00::numeric,
        'engaged_user_score on a brand-new row must reflect the engager''s score at insert time');

    PERFORM pg_temp.assert_eq('TC08a_placeholder_created_for_zero_engagement_root',
        (SELECT count(*) FROM analytics_md_fix.mv_engagement_acurast WHERE root_post_id='ZT_P_ROOT2' AND engaged_tweet_id IS NULL)::int, 1,
        'a brand-new root with zero engagement this batch must get a placeholder row');
END $$;

------------------------------------------------------------------------------
-- SECTION 2 (batch 2): next "ingest batch" -- username rename, new engager on
-- an already-engaged root, first engagement on the placeholder root, a batch
-- of 3 simultaneous replies, and setup for the orphan-user case
------------------------------------------------------------------------------
DO $$
DECLARE
    v_project text := 'Acurast';
BEGIN
    -- TC06: poster A renames
    UPDATE mindshare.mindshare_user SET x_username='zt_p_usera_v2', updated_at=clock_timestamp() WHERE x_id='ZT_P_USERA';

    -- TC07: brand-new user C engages the already-engaged root R1
    INSERT INTO mindshare.mindshare_user (x_id, x_username, display_name, score, avatar_url, adjustment_config, followers_count, created_at, updated_at)
    VALUES ('ZT_P_USERC', 'zt_p_userc', 'Test User C', 30.00, 'http://test', '{}'::jsonb, 0, clock_timestamp(), clock_timestamp());
    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, replied_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_REPLY2', v_project, 'ZT_P_USERC', 'reply2', 'ZT_P_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    -- TC08b: first-ever reply lands on the placeholder root R2, in a LATER batch
    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, replied_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_REPLY3', v_project, 'ZT_P_USERB', 'reply3', 'ZT_P_ROOT2', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    -- TC09: batch of 3 simultaneous new replies to R1
    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, replied_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES
        ('ZT_P_REPLY4', v_project, 'ZT_P_USERB', 'reply4', 'ZT_P_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp()),
        ('ZT_P_REPLY5', v_project, 'ZT_P_USERC', 'reply5', 'ZT_P_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp()),
        ('ZT_P_REPLY6', v_project, 'ZT_P_USERD', 'reply6', 'ZT_P_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    -- TC15: orphan engaging user -- never inserted into mindshare_user at all
    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, replied_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_REPLY8', v_project, 'ZT_P_USER_ORPHAN', 'reply8', 'ZT_P_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);

    PERFORM pg_temp.assert_eq('TC06_root_username_after_rename',
        (SELECT root_username FROM analytics_md_fix.mv_engagement_acurast WHERE root_post_id='ZT_P_ROOT1' LIMIT 1), 'zt_p_usera_v2',
        'root_username on existing rows must reflect the poster''s new username');

    PERFORM pg_temp.assert_eq('TC07_new_engager_score_on_existing_root',
        (SELECT engaged_user_score FROM analytics_md_fix.mv_engagement_acurast WHERE engaged_tweet_id='ZT_P_REPLY2'), 30.00::numeric,
        'a brand-new engaging user replying to an already-engaged root must get the correct score');

    PERFORM pg_temp.assert_eq('TC08b_placeholder_removed_on_first_engagement',
        (SELECT count(*) FROM analytics_md_fix.mv_engagement_acurast WHERE root_post_id='ZT_P_ROOT2' AND engaged_tweet_id IS NULL)::int, 0,
        'the placeholder row must be gone once its root gets its first real engagement');

    PERFORM pg_temp.assert_eq('TC08c_real_row_for_former_placeholder_root',
        (SELECT count(*) FROM analytics_md_fix.mv_engagement_acurast WHERE root_post_id='ZT_P_ROOT2' AND engaged_tweet_id='ZT_P_REPLY3')::int, 1,
        'a real engagement row must now exist for the former placeholder root');

    PERFORM pg_temp.assert_eq('TC09_batch_of_3_all_landed',
        (SELECT count(*) FROM analytics_md_fix.mv_engagement_acurast WHERE engaged_tweet_id IN ('ZT_P_REPLY4','ZT_P_REPLY5','ZT_P_REPLY6'))::int, 3,
        'all 3 simultaneous replies in one batch must land -- none dropped by ON CONFLICT DO NOTHING');

    PERFORM pg_temp.assert_eq('TC15a_orphan_user_score_is_null_project_scope',
        (SELECT engaged_user_score FROM analytics_md_fix.mv_engagement_acurast WHERE engaged_tweet_id='ZT_P_REPLY8'), NULL::numeric,
        'an engaging user with no mindshare_user row -> project-scope engaged_user_score is NULL (LEFT JOIN, no COALESCE)');
END $$;

------------------------------------------------------------------------------
-- SECTION 2 (batch 3): cross-project isolation, idempotent re-run
------------------------------------------------------------------------------
DO $$
DECLARE
    v_project text := 'Acurast';
    v_watermark_before      timestamptz;
    v_user_watermark_before timestamptz;
    v_watermark_after       timestamptz;
    v_user_watermark_after  timestamptz;
    v_rows_inserted_after   bigint;
    v_rows_updated_after    bigint;
BEGIN
    -- TC14 setup: touch a DIFFERENT project's post -- must never leak into Acurast's dirty scan
    UPDATE mindshare.mindshare_post SET favorite_count = favorite_count + 777, updated_at = clock_timestamp()
     WHERE project_keyword = 'IronAllies_' AND post_id = '2029684768015618498';

    DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);

    PERFORM pg_temp.assert_eq('TC14_cross_project_isolation',
        (SELECT count(*) FROM analytics_md_fix.mv_engagement_acurast WHERE root_post_id = '2029684768015618498')::int, 0,
        'a change to a different project''s post must never appear in Acurast''s engagement table');

    -- TC16: idempotent re-run -- call again with zero further source changes
    SELECT last_ingest_ts, last_user_ts INTO v_watermark_before, v_user_watermark_before
      FROM analytics_md_fix.engagement_refresh_state WHERE scope_key='project:acurast';

    DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);

    SELECT last_ingest_ts, last_user_ts, rows_inserted, rows_updated
      INTO v_watermark_after, v_user_watermark_after, v_rows_inserted_after, v_rows_updated_after
      FROM analytics_md_fix.engagement_refresh_state WHERE scope_key='project:acurast';

    PERFORM pg_temp.assert_eq('TC16a_idempotent_rerun_zero_inserts', v_rows_inserted_after, 0::bigint,
        'calling incremental again with zero new source changes must insert 0 rows');
    PERFORM pg_temp.assert_eq('TC16b_idempotent_rerun_zero_updates', v_rows_updated_after, 0::bigint,
        'calling incremental again with zero new source changes must update 0 rows');
    PERFORM pg_temp.assert_eq('TC16c_idempotent_rerun_watermark_unchanged', v_watermark_after, v_watermark_before,
        'post watermark must not move on a true no-op run');
    PERFORM pg_temp.assert_eq('TC16d_idempotent_rerun_user_watermark_unchanged', v_user_watermark_after, v_user_watermark_before,
        'user watermark must not move on a true no-op run');
END $$;

------------------------------------------------------------------------------
-- SECTION 2 (batch 4): forced real failure inside the inner EXCEPTION block --
-- regression test for the PG_EXCEPTION_DETAIL bare-identifier bug found
-- while building this suite (see git history / conversation for detail): all
-- 4 procedures referenced PG_EXCEPTION_DETAIL/PG_EXCEPTION_CONTEXT as bare
-- identifiers, which is only valid via GET STACKED DIAGNOSTICS -- so ANY real
-- error, ever, crashed with a masking "column does not exist" instead of
-- logging the true failure. Fixed live; this proves the fix.
------------------------------------------------------------------------------
DO $$
DECLARE
    v_project      text := 'Acurast';
    v_error_caught boolean := false;
    v_log_status   text;
    v_log_detail   text;
BEGIN
    CREATE OR REPLACE FUNCTION pg_temp.boom() RETURNS trigger LANGUAGE plpgsql AS $f$
    BEGIN
        IF NEW.engaged_tweet_id = 'ZT_P_FORCE_ERROR' THEN
            RAISE EXCEPTION 'synthetic forced failure for TC18 test coverage';
        END IF;
        RETURN NEW;
    END;
    $f$;

    CREATE TRIGGER trg_pg_temp_boom BEFORE INSERT ON analytics_md_fix.mv_engagement_acurast
    FOR EACH ROW EXECUTE FUNCTION pg_temp.boom();

    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, replied_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_FORCE_ERROR', v_project, 'ZT_P_USERB', 'force error', 'ZT_P_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    BEGIN
        DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);
    EXCEPTION WHEN OTHERS THEN
        v_error_caught := true;
    END;

    DROP TRIGGER trg_pg_temp_boom ON analytics_md_fix.mv_engagement_acurast;

    SELECT status, error_detail INTO v_log_status, v_log_detail
      FROM analytics_md_fix.engagement_run_log
      WHERE project_keyword = v_project AND mode = 'incremental' AND status = 'failed'
      ORDER BY run_id DESC LIMIT 1;

    PERFORM pg_temp.assert_eq('TC18a_forced_failure_propagates_to_caller', v_error_caught, true,
        'a real error inside the incremental proc must propagate (RAISE) back to the caller, not be swallowed');
    PERFORM pg_temp.assert_eq('TC18b_forced_failure_logged_as_failed', v_log_status, 'failed',
        'engagement_run_log must record status=failed for a real error');
    PERFORM pg_temp.assert_eq('TC18c_forced_failure_has_error_detail', (v_log_detail IS NOT NULL), true,
        'error_detail must be captured -- regression test for the PG_EXCEPTION_DETAIL bare-identifier bug');
END $$;

------------------------------------------------------------------------------
-- SECTION 3: global-scope synthetic lifecycle (backed by user_post)
------------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO mindshare.mindshare_user (x_id, x_username, display_name, score, avatar_url, adjustment_config, followers_count, created_at, updated_at) VALUES
        ('ZT_G_USERA', 'zt_g_usera', 'G User A', 11.00, 'http://test', '{}'::jsonb, 0, clock_timestamp(), clock_timestamp()),
        ('ZT_G_USERB', 'zt_g_userb', 'G User B', 22.00, 'http://test', '{}'::jsonb, 0, clock_timestamp(), clock_timestamp()),
        ('ZT_G_USERC', 'zt_g_userc', 'G User C', 33.00, 'http://test', '{}'::jsonb, 0, clock_timestamp(), clock_timestamp()),
        ('ZT_G_USERD', 'zt_g_userd', 'G User D', 44.00, 'http://test', '{}'::jsonb, 0, clock_timestamp(), clock_timestamp());

    INSERT INTO mindshare.user_post (post_id, user_x_id, full_text, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_G_ROOT1', 'ZT_G_USERA', 'g root1', 5, 0, 0, 0, 0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    INSERT INTO mindshare.user_post (post_id, user_x_id, full_text, replied_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_G_REPLY1', 'ZT_G_USERB', 'g reply1', 'ZT_G_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    INSERT INTO mindshare.user_post (post_id, user_x_id, full_text, retweeted_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_G_RT1', 'ZT_G_USERC', '', 'ZT_G_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    INSERT INTO mindshare.user_post (post_id, user_x_id, full_text, quoted_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_G_QUOTE1', 'ZT_G_USERD', 'g quote1', 'ZT_G_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    DROP TABLE IF EXISTS pg_temp.tmp_changed_up, pg_temp.tmp_dirty_users_up;
    CALL analytics_md_fix.refresh_user_posts_engagement_incremental();

    PERFORM pg_temp.assert_eq('TC11_global_new_root_and_reply_same_batch',
        (SELECT count(*) FROM analytics_md_fix.mv_user_posts_engagement WHERE engaged_tweet_id='ZT_G_REPLY1' AND root_post_id='ZT_G_ROOT1')::int, 1,
        'global scope: brand-new root + brand-new reply in the same batch must create a row');

    PERFORM pg_temp.assert_eq('TC12_global_retweet_engagement_type',
        (SELECT is_engaged_repost FROM analytics_md_fix.mv_user_posts_engagement WHERE engaged_tweet_id='ZT_G_RT1'), true,
        'a retweet must be modeled as is_engaged_repost=true at global scope');

    PERFORM pg_temp.assert_eq('TC13_global_quote_engagement_type',
        (SELECT is_engaged_quote FROM analytics_md_fix.mv_user_posts_engagement WHERE engaged_tweet_id='ZT_G_QUOTE1'), true,
        'a quote (no reply) must be modeled as is_engaged_quote=true at global scope');
END $$;

------------------------------------------------------------------------------
-- SECTION 4: orphan engaged-user asymmetry at global scope (project scope
-- covered by TC15a above) -- documents a real design asymmetry, not
-- necessarily a bug: project-scope uses a raw LEFT JOIN (-> NULL), global
-- scope uses COALESCE(score, 0) (-> 0), for the same "user unknown" case.
------------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO mindshare.user_post (post_id, user_x_id, full_text, replied_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_G_REPLY_ORPHAN', 'ZT_G_USER_ORPHAN', 'g orphan reply', 'ZT_G_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    DROP TABLE IF EXISTS pg_temp.tmp_changed_up, pg_temp.tmp_dirty_users_up;
    CALL analytics_md_fix.refresh_user_posts_engagement_incremental();

    PERFORM pg_temp.assert_eq('TC15b_orphan_user_score_is_zero_global_scope',
        (SELECT engaged_user_score FROM analytics_md_fix.mv_user_posts_engagement WHERE engaged_tweet_id='ZT_G_REPLY_ORPHAN'), 0::numeric,
        'an engaging user with no mindshare_user row -> global-scope engaged_user_score is 0 (COALESCE) -- ASYMMETRIC with project scope''s NULL, confirm intentional');
END $$;

------------------------------------------------------------------------------
-- SECTION 5: stale-checkpoint self-heal (table dropped, checkpoint survives)
------------------------------------------------------------------------------
DO $$
DECLARE
    v_project        text := 'test11';
    v_existed_before boolean;
    v_exists_after   boolean;
    v_rows_after     bigint;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='analytics_md_fix' AND tablename='mv_engagement_test11') INTO v_existed_before;

    DROP TABLE IF EXISTS analytics_md_fix.mv_engagement_test11 CASCADE;

    DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);

    SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname='analytics_md_fix' AND tablename='mv_engagement_test11') INTO v_exists_after;
    SELECT rows_inserted INTO v_rows_after FROM analytics_md_fix.engagement_refresh_state WHERE scope_key='project:test11';

    PERFORM pg_temp.assert_eq('TC17a_stale_checkpoint_table_existed_before', v_existed_before, true,
        'sanity check: table existed before we dropped it');
    PERFORM pg_temp.assert_eq('TC17b_stale_checkpoint_selfheal_table_rebuilt', v_exists_after, true,
        'refresh_engagement_incremental must self-heal via full build when checkpoint exists but table is gone');
    PERFORM pg_temp.assert_eq('TC17c_stale_checkpoint_selfheal_checkpoint_refreshed', v_rows_after IS NOT NULL, true,
        'checkpoint row must be refreshed by the self-heal full build');
END $$;

------------------------------------------------------------------------------
-- SECTION 6: project-scope edge cases -- quote engagement, retweet exclusion,
-- cross-project isolation at the LINK level, late-arriving (backfilled) post,
-- multi-row root-metric + user-score updates, row-level idempotency,
-- watermark advance.
------------------------------------------------------------------------------
DO $$
DECLARE
    v_project text := 'Acurast';
BEGIN
    -- TC19: a QUOTE (quoted_post_id set, no reply) of R1 -- project scope includes
    -- quotes as engagers, is_engaged_quote must be true.
    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, quoted_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_QUOTE1', v_project, 'ZT_P_USERC', 'quote1', 'ZT_P_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    -- TC20: a RETWEET of R1 -- project scope excludes retweets entirely
    -- (dirty-scan has `AND NOT is_retweet`), so NO engagement row and NO placeholder.
    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, retweeted_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_RT1', v_project, 'ZT_P_USERD', '', 'ZT_P_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    -- TC21: a reply in Acurast whose root lives in a DIFFERENT project (IronAllies_).
    -- The root-resolution join is `r.project_keyword = 'Acurast'`, so it must NOT
    -- resolve -> no engagement row links this reply to the foreign root.
    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, replied_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_XPROJ_REPLY', v_project, 'ZT_P_USERB', 'xproj reply', '2029684768015618498', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    -- TC26: a LATE-ARRIVING reply -- post_created_at is 400 days old (backfilled),
    -- but created_at/updated_at (ingest time) is now. The dirty-scan keys on ingest
    -- time via GREATEST(created_at,updated_at), so it must still be picked up.
    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, replied_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_LATE', v_project, 'ZT_P_USERC', 'late reply', 'ZT_P_ROOT1', 0,0,0,0,0, clock_timestamp() - interval '400 days', clock_timestamp(), clock_timestamp());

    DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);

    PERFORM pg_temp.assert_eq('TC19_project_quote_engagement_type',
        (SELECT is_engaged_quote FROM analytics_md_fix.mv_engagement_acurast WHERE engaged_tweet_id='ZT_P_QUOTE1'), true,
        'a quote (no reply) must create a project-scope engagement row with is_engaged_quote=true');

    PERFORM pg_temp.assert_eq('TC20a_retweet_no_engagement_row',
        (SELECT count(*) FROM analytics_md_fix.mv_engagement_acurast WHERE engaged_tweet_id='ZT_P_RT1')::int, 0,
        'a retweet must NOT create a project-scope engagement row (excluded by NOT is_retweet)');
    PERFORM pg_temp.assert_eq('TC20b_retweet_no_placeholder',
        (SELECT count(*) FROM analytics_md_fix.mv_engagement_acurast WHERE root_post_id='ZT_P_RT1')::int, 0,
        'a retweet must NOT create a project-scope placeholder row either');

    PERFORM pg_temp.assert_eq('TC21_cross_project_reply_not_linked',
        (SELECT count(*) FROM analytics_md_fix.mv_engagement_acurast WHERE engaged_tweet_id='ZT_P_XPROJ_REPLY')::int, 0,
        'a reply whose root is in another project must NOT be linked as an engager in this project''s table');

    PERFORM pg_temp.assert_eq('TC26_late_arriving_post_picked_up',
        (SELECT count(*) FROM analytics_md_fix.mv_engagement_acurast WHERE engaged_tweet_id='ZT_P_LATE' AND root_post_id='ZT_P_ROOT1')::int, 1,
        'a backfilled post (old post_created_at, new ingest time) must still be picked up by the ingest-time watermark');
END $$;

DO $$
DECLARE
    v_project    text := 'Acurast';
    v_n_engagers int;
    v_n_updated  int;
BEGIN
    -- TC22: root R1 has many engagers by now. Bump R1's OWN favorite_count and confirm
    -- EVERY engagement row for that root gets root_favorite_count refreshed (multi-row).
    SELECT count(*) INTO v_n_engagers FROM analytics_md_fix.mv_engagement_acurast
     WHERE root_post_id='ZT_P_ROOT1' AND engaged_tweet_id IS NOT NULL;

    UPDATE mindshare.mindshare_post SET favorite_count = 987654, updated_at = clock_timestamp()
     WHERE project_keyword=v_project AND post_id='ZT_P_ROOT1';

    DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);

    SELECT count(*) INTO v_n_updated FROM analytics_md_fix.mv_engagement_acurast
     WHERE root_post_id='ZT_P_ROOT1' AND root_favorite_count = 987654;

    PERFORM pg_temp.assert_eq('TC22_root_metric_change_updates_all_engager_rows',
        v_n_updated >= v_n_engagers AND v_n_engagers > 1, true,
        format('bumping a root''s favorite_count must refresh ALL %s of its engagement rows, not just one (got %s updated)', v_n_engagers, v_n_updated));
END $$;

DO $$
DECLARE
    v_project    text := 'Acurast';
    v_n_asuser   int;
    v_n_updated  int;
BEGIN
    -- TC23: USERB engages several roots. Bump USERB's score and confirm EVERY row where
    -- USERB is the engager gets engaged_user_score refreshed (multi-row user-dirty path).
    SELECT count(*) INTO v_n_asuser FROM analytics_md_fix.mv_engagement_acurast
     WHERE engaged_user_id='ZT_P_USERB';

    UPDATE mindshare.mindshare_user SET score = 424242, updated_at = clock_timestamp() WHERE x_id='ZT_P_USERB';

    DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);

    SELECT count(*) INTO v_n_updated FROM analytics_md_fix.mv_engagement_acurast
     WHERE engaged_user_id='ZT_P_USERB' AND engaged_user_score = 424242;

    PERFORM pg_temp.assert_eq('TC23_user_score_change_updates_all_engager_rows',
        v_n_updated = v_n_asuser AND v_n_asuser > 1, true,
        format('bumping a user''s score must refresh ALL %s rows where they engaged (got %s updated)', v_n_asuser, v_n_updated));
END $$;

DO $$
DECLARE
    v_project     text := 'Acurast';
    v_count_before int;
    v_count_after  int;
BEGIN
    -- TC24: re-ingest an already-stored engaged tweet (same PK, updated_at bumped) --
    -- ON CONFLICT (engaged_tweet_id) DO NOTHING must keep it at exactly one row, no dup.
    SELECT count(*) INTO v_count_before FROM analytics_md_fix.mv_engagement_acurast WHERE engaged_tweet_id='ZT_P_REPLY1';

    UPDATE mindshare.mindshare_post SET updated_at = clock_timestamp()
     WHERE project_keyword=v_project AND post_id='ZT_P_REPLY1';

    DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);

    SELECT count(*) INTO v_count_after FROM analytics_md_fix.mv_engagement_acurast WHERE engaged_tweet_id='ZT_P_REPLY1';

    PERFORM pg_temp.assert_eq('TC24_reingest_same_tweet_no_duplicate', (v_count_before, v_count_after), (1, 1),
        're-ingesting an existing engaged tweet must not create a duplicate row (ON CONFLICT DO NOTHING)');
END $$;

DO $$
DECLARE
    v_project   text := 'Acurast';
    v_sentinel  timestamptz;
    v_watermark timestamptz;
BEGIN
    -- TC27: the post watermark must advance to the MAX ingest-time of the batch. Insert a
    -- sentinel reply stamped with a captured timestamp, then assert the checkpoint lands on it.
    v_sentinel := clock_timestamp();
    INSERT INTO mindshare.mindshare_post (post_id, project_keyword, user_x_id, full_text, replied_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_P_SENTINEL', v_project, 'ZT_P_USERC', 'sentinel', 'ZT_P_ROOT1', 0,0,0,0,0, clock_timestamp(), v_sentinel, v_sentinel);

    DROP TABLE IF EXISTS pg_temp.tmp_changed, pg_temp.tmp_dirty_users, pg_temp.tmp_new_engagements;
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);

    SELECT last_ingest_ts INTO v_watermark FROM analytics_md_fix.engagement_refresh_state WHERE scope_key='project:acurast';

    PERFORM pg_temp.assert_eq('TC27_watermark_advances_to_batch_max', v_watermark, v_sentinel,
        'the post watermark must advance to exactly the max ingest-time in the processed batch');
END $$;

------------------------------------------------------------------------------
-- SECTION 7: global-scope edge case -- reply+quote precedence
------------------------------------------------------------------------------
DO $$
BEGIN
    -- TC28: a post that is BOTH a reply AND a quote (replied_post_id AND quoted_post_id
    -- both set). Root resolution is COALESCE(replied, quoted, retweeted) -> replied wins,
    -- and it must produce exactly ONE row (no double-count across the reply/quote branches).
    INSERT INTO mindshare.user_post (post_id, user_x_id, full_text, replied_post_id, quoted_post_id, favorite_count, reply_count, retweet_count, quote_count, view_count, post_created_at, created_at, updated_at)
    VALUES ('ZT_G_REPLYQUOTE', 'ZT_G_USERC', 'reply+quote', 'ZT_G_ROOT1', 'ZT_G_ROOT1', 0,0,0,0,0, clock_timestamp(), clock_timestamp(), clock_timestamp());

    DROP TABLE IF EXISTS pg_temp.tmp_changed_up, pg_temp.tmp_dirty_users_up;
    CALL analytics_md_fix.refresh_user_posts_engagement_incremental();

    PERFORM pg_temp.assert_eq('TC28a_reply_quote_exactly_one_row',
        (SELECT count(*) FROM analytics_md_fix.mv_user_posts_engagement WHERE engaged_tweet_id='ZT_G_REPLYQUOTE')::int, 1,
        'a reply+quote must resolve to exactly one root (COALESCE precedence), not one row per branch');
    PERFORM pg_temp.assert_eq('TC28b_reply_quote_classified_as_reply',
        (SELECT is_engaged_reply FROM analytics_md_fix.mv_user_posts_engagement WHERE engaged_tweet_id='ZT_G_REPLYQUOTE'), true,
        'reply takes precedence over quote in root resolution -- is_engaged_reply must be true');
END $$;

------------------------------------------------------------------------------
-- SECTION 8: PARITY CAPSTONE -- the incrementally-maintained project table must
-- be byte-for-byte identical to a from-scratch full rebuild over the SAME final
-- source state. Snapshot the incremental result, run the real full-build proc
-- (it reads the same uncommitted synthetic rows in this txn), and EXCEPT ALL in
-- BOTH directions. Any non-zero row here is a real incremental/full divergence
-- (stale value, missing placeholder, extra row) that every targeted test above
-- might individually miss. This must be the LAST project-scope step -- the full
-- build DROPs and recreates mv_engagement_acurast.
------------------------------------------------------------------------------
DO $$
DECLARE
    v_missing int;
    v_extra   int;
BEGIN
    DROP TABLE IF EXISTS pg_temp.snap_acurast;
    CREATE TEMP TABLE snap_acurast AS TABLE analytics_md_fix.mv_engagement_acurast;

    CALL analytics_md_fix.create_engagement_table_full('Acurast');

    -- rows the full build produced that the incremental didn't (incremental too sparse)
    SELECT count(*) INTO v_missing FROM (
        TABLE analytics_md_fix.mv_engagement_acurast EXCEPT ALL TABLE pg_temp.snap_acurast
    ) d;
    -- rows the incremental has that the full build doesn't (incremental left stale/extra)
    SELECT count(*) INTO v_extra FROM (
        TABLE pg_temp.snap_acurast EXCEPT ALL TABLE analytics_md_fix.mv_engagement_acurast
    ) d;

    PERFORM pg_temp.assert_eq('TC29a_parity_full_has_nothing_incremental_missing', v_missing, 0,
        'full build must produce no row the incremental-maintained table lacks (EXCEPT ALL = 0)');
    PERFORM pg_temp.assert_eq('TC29b_parity_incremental_has_nothing_extra', v_extra, 0,
        'incremental-maintained table must hold no row the full build doesn''t (EXCEPT ALL = 0)');
END $$;

------------------------------------------------------------------------------
-- REPORT
------------------------------------------------------------------------------
SELECT status, count(*) FROM results GROUP BY status ORDER BY status;
SELECT test_id, status, detail FROM results ORDER BY test_id;

ROLLBACK;
