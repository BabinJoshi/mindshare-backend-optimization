-- test_change_propagation.sql
-- Proves mindshare_post / mindshare_user / user_post changes propagate into
-- both engagement tables via the incremental procs, not just at first build.
--
-- Covers:
--   A. project scope: mindshare_post.favorite_count/reply_count change ->
--      mv_engagement_<project>.root_favorite_count/root_reply_count
--   B. project scope: mindshare_user.score change ->
--      mv_engagement_<project>.engaged_user_score
--   C. global scope:  user_post.favorite_count/reply_count change ->
--      mv_user_posts_engagement.root_favorite_count/root_reply_count
--   D. global scope:  mindshare_user.score change ->
--      mv_user_posts_engagement.engaged_user_score
--
-- Runs entirely inside one transaction and ROLLBACKs at the end -- source
-- tables and engagement tables are untouched once this script finishes.
-- (engagement_run_log rows from the two CALLs will still persist -- that
-- table is written via an autonomous dblink commit by design, see
-- engagement_logging.sql. Harmless log noise, not a real side effect.)
--
-- Change v_project below to any project that already has an engagement
-- table built (CALL analytics_md_fix.create_engagement_table_full(...) first
-- if not). Run in DBeaver with auto-commit OFF, or via psql -f.

BEGIN;

DO $$
DECLARE
    v_project        text := 'Acurast';
    v_table          text := 'mv_engagement_' || lower(replace(v_project, ' ', '_'));

    -- A/B: project scope
    v_post_id        text;
    v_old_fav        int;
    v_old_reply      int;
    v_new_fav        int;
    v_new_reply      int;
    v_fav_after      int;
    v_reply_after    int;

    v_user_id        text;
    v_old_score      numeric;
    v_new_score      numeric;
    v_score_after    numeric;

    -- C/D: global scope
    v_g_post_id      text;
    v_g_old_fav      int;
    v_g_old_reply    int;
    v_g_new_fav      int;
    v_g_new_reply    int;
    v_g_fav_after    int;
    v_g_reply_after  int;

    v_g_user_id      text;
    v_g_old_score    numeric;
    v_g_new_score    numeric;
    v_g_score_after  numeric;

    v_rows           int;
BEGIN
    ------------------------------------------------------------------
    -- A/B setup: pick a real root post + a real engaged user from the
    -- project's engagement table.
    ------------------------------------------------------------------
    EXECUTE format('SELECT root_post_id, root_favorite_count, root_reply_count
                     FROM analytics_md_fix.%I WHERE root_post_id IS NOT NULL LIMIT 1', v_table)
      INTO v_post_id, v_old_fav, v_old_reply;

    IF v_post_id IS NULL THEN
        RAISE EXCEPTION 'no rows in analytics_md_fix.% -- pick a project with data', v_table;
    END IF;

    -- engaged_user_id in the engagement table can be an orphan (no matching
    -- mindshare_user row -> COALESCE(score,0) at build time, LEFT JOIN). An
    -- UPDATE against an orphan silently affects 0 rows, so require existence
    -- here or the "before/after" comparison below is checking a mutation
    -- that never actually happened.
    EXECUTE format('SELECT m.engaged_user_id, m.engaged_user_score
                     FROM analytics_md_fix.%I m
                     JOIN mindshare.mindshare_user u ON u.x_id = m.engaged_user_id
                     WHERE m.engaged_user_id IS NOT NULL LIMIT 1', v_table)
      INTO v_user_id, v_old_score;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'no engaged_user_id in % has a matching mindshare.mindshare_user row -- cannot test user-score propagation', v_table;
    END IF;

    v_new_fav   := coalesce(v_old_fav, 0) + 1000;
    v_new_reply := coalesce(v_old_reply, 0) + 1000;
    v_new_score := coalesce(v_old_score, 0) + 12345;

    RAISE NOTICE '[A/B] project=% post=% fav % -> % reply % -> %  |  user=% score % -> %',
        v_project, v_post_id, v_old_fav, v_new_fav, v_old_reply, v_new_reply, v_user_id, v_old_score, v_new_score;

    UPDATE mindshare.mindshare_post
       SET favorite_count = v_new_fav, reply_count = v_new_reply, updated_at = clock_timestamp()
     WHERE post_id = v_post_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION '[A setup] FAIL: expected to update exactly 1 mindshare_post row for post_id=%, updated %', v_post_id, v_rows;
    END IF;

    UPDATE mindshare.mindshare_user
       SET score = v_new_score, updated_at = clock_timestamp()
     WHERE x_id = v_user_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION '[B setup] FAIL: expected to update exactly 1 mindshare_user row for x_id=%, updated %', v_user_id, v_rows;
    END IF;

    ------------------------------------------------------------------
    -- C/D setup: pick a real root post + engaged user from the global
    -- engagement table (backed by user_post, a different source table).
    ------------------------------------------------------------------
    SELECT root_post_id, root_favorite_count, root_reply_count
      INTO v_g_post_id, v_g_old_fav, v_g_old_reply
      FROM analytics_md_fix.mv_user_posts_engagement WHERE root_post_id IS NOT NULL LIMIT 1;

    IF v_g_post_id IS NULL THEN
        RAISE EXCEPTION 'no rows in analytics_md_fix.mv_user_posts_engagement';
    END IF;

    SELECT m.engaged_user_id, m.engaged_user_score
      INTO v_g_user_id, v_g_old_score
      FROM analytics_md_fix.mv_user_posts_engagement m
      JOIN mindshare.mindshare_user u ON u.x_id = m.engaged_user_id
      WHERE m.engaged_user_id IS NOT NULL LIMIT 1;

    IF v_g_user_id IS NULL THEN
        RAISE EXCEPTION 'no engaged_user_id in mv_user_posts_engagement has a matching mindshare.mindshare_user row -- cannot test user-score propagation';
    END IF;

    v_g_new_fav   := coalesce(v_g_old_fav, 0) + 1000;
    v_g_new_reply := coalesce(v_g_old_reply, 0) + 1000;
    v_g_new_score := coalesce(v_g_old_score, 0) + 54321;

    RAISE NOTICE '[C/D] global post=% fav % -> % reply % -> %  |  user=% score % -> %',
        v_g_post_id, v_g_old_fav, v_g_new_fav, v_g_old_reply, v_g_new_reply, v_g_user_id, v_g_old_score, v_g_new_score;

    UPDATE mindshare.user_post
       SET favorite_count = v_g_new_fav, reply_count = v_g_new_reply, updated_at = clock_timestamp()
     WHERE post_id = v_g_post_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION '[C setup] FAIL: expected to update exactly 1 user_post row for post_id=%, updated %', v_g_post_id, v_rows;
    END IF;

    UPDATE mindshare.mindshare_user
       SET score = v_g_new_score, updated_at = clock_timestamp()
     WHERE x_id = v_g_user_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION '[D setup] FAIL: expected to update exactly 1 mindshare_user row for x_id=%, updated %', v_g_user_id, v_rows;
    END IF;

    ------------------------------------------------------------------
    -- Run the incremental procs -- exactly what a scheduled job would call.
    ------------------------------------------------------------------
    CALL analytics_md_fix.refresh_engagement_incremental(v_project);
    CALL analytics_md_fix.refresh_user_posts_engagement_incremental();

    ------------------------------------------------------------------
    -- Verify A/B
    ------------------------------------------------------------------
    EXECUTE format('SELECT root_favorite_count, root_reply_count FROM analytics_md_fix.%I
                     WHERE root_post_id = %L LIMIT 1', v_table, v_post_id)
      INTO v_fav_after, v_reply_after;

    EXECUTE format('SELECT engaged_user_score FROM analytics_md_fix.%I
                     WHERE engaged_user_id = %L LIMIT 1', v_table, v_user_id)
      INTO v_score_after;

    IF v_fav_after IS DISTINCT FROM v_new_fav OR v_reply_after IS DISTINCT FROM v_new_reply THEN
        RAISE EXCEPTION '[A] FAIL: % root_favorite_count/root_reply_count not updated (got %, %, want %, %)',
            v_table, v_fav_after, v_reply_after, v_new_fav, v_new_reply;
    END IF;
    RAISE NOTICE '[A] PASS: mindshare_post change reflected in %', v_table;

    IF v_score_after IS DISTINCT FROM v_new_score THEN
        RAISE EXCEPTION '[B] FAIL: % engaged_user_score not updated (got %, want %)',
            v_table, v_score_after, v_new_score;
    END IF;
    RAISE NOTICE '[B] PASS: mindshare_user score change reflected in %', v_table;

    ------------------------------------------------------------------
    -- Verify C/D
    ------------------------------------------------------------------
    SELECT root_favorite_count, root_reply_count
      INTO v_g_fav_after, v_g_reply_after
      FROM analytics_md_fix.mv_user_posts_engagement WHERE root_post_id = v_g_post_id LIMIT 1;

    SELECT engaged_user_score INTO v_g_score_after
      FROM analytics_md_fix.mv_user_posts_engagement WHERE engaged_user_id = v_g_user_id LIMIT 1;

    IF v_g_fav_after IS DISTINCT FROM v_g_new_fav OR v_g_reply_after IS DISTINCT FROM v_g_new_reply THEN
        RAISE EXCEPTION '[C] FAIL: mv_user_posts_engagement root_favorite_count/root_reply_count not updated (got %, %, want %, %)',
            v_g_fav_after, v_g_reply_after, v_g_new_fav, v_g_new_reply;
    END IF;
    RAISE NOTICE '[C] PASS: user_post change reflected in mv_user_posts_engagement';

    IF v_g_score_after IS DISTINCT FROM v_g_new_score THEN
        RAISE EXCEPTION '[D] FAIL: mv_user_posts_engagement engaged_user_score not updated (got %, want %)',
            v_g_score_after, v_g_new_score;
    END IF;
    RAISE NOTICE '[D] PASS: mindshare_user score change reflected in mv_user_posts_engagement';

    RAISE NOTICE 'ALL PASS: post + user changes propagate correctly at both scopes.';
END $$;

ROLLBACK;
