-- Easy full-vs-incremental latency test for the analytics_md_fix engagement tables.
-- Plain SQL — works in DBeaver (or any SQL client), no psql required.
--
-- Change 'acurast' in the 3 places below to whichever project you want to test. Pick a
-- small one first (fast iteration) — the doc-recorded full-build baseline for pact_swap
-- (~1M rows) was 5,768ms best-case / 15,025ms original, so a big project's full phase
-- can legitimately take tens of seconds to minutes; that's expected, not a bug.
--
-- Before running step 3: turn OFF auto-commit in DBeaver (bottom status bar of the SQL
-- editor, or the toolbar auto-commit toggle). Step 3 relies on BEGIN...ROLLBACK being one
-- transaction — with auto-commit on, DBeaver may commit each statement individually and
-- the rollback won't undo the simulated rows.

-- ============================================================
-- 1. FULL BUILD (bootstrap: no checkpoint row yet -> full rebuild + seed watermark)
-- ============================================================
-- DROP first: TEMP tables live for the whole DBeaver session, not just this script run.
-- Re-running this file in the same session without the DROP hits "relation already exists".
DROP TABLE IF EXISTS _bench_full;
CREATE TEMP TABLE _bench_full (ms numeric);
DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    CALL analytics_md_fix.create_engagement_table_full('acurast');
    INSERT INTO _bench_full VALUES (extract(epoch FROM (clock_timestamp()-t0))*1000);
END $$;
SELECT ms AS full_build_ms FROM _bench_full;

-- ============================================================
-- 2. INCREMENTAL NO-OP (checkpoint now exists, nothing changed since it was seeded)
-- ============================================================
DROP TABLE IF EXISTS _bench_noop;
CREATE TEMP TABLE _bench_noop (ms numeric);
DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    CALL analytics_md_fix.refresh_engagement_incremental('acurast');
    INSERT INTO _bench_noop VALUES (extract(epoch FROM (clock_timestamp()-t0))*1000);
END $$;
SELECT ms AS incremental_noop_ms FROM _bench_noop;

-- ============================================================
-- 3. SIMULATED NEW INGEST -> INCREMENTAL DELTA
--    Wrapped in a transaction, rolled back at the end — never touches real data.
--    Run this whole block together (BEGIN through ROLLBACK), auto-commit OFF.
-- ============================================================
BEGIN;

-- One brand-new root post + 20 brand-new replies to an EXISTING root, all timestamped
-- "now" so they land after the current watermark. SIM_ prefix makes cleanup trivial.
--
-- project_keyword on mindshare_post is CASE-SENSITIVE ('Acurast', not 'acurast') — the
-- procs resolve case for you, but a raw INSERT against mindshare_post does not. This DO
-- block resolves the canonical name ONCE so typing 'acurast' below still works instead of
-- silently inserting user_x_id = NULL (see docs/analytics_incremental_engagement.md §3.6).
DO $$
DECLARE v_project text;
BEGIN
    SELECT project_name INTO v_project FROM mindshare.mindshare_project
    WHERE lower(project_name) = lower('acurast') LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No project found matching acurast (case-insensitive)';
    END IF;

    INSERT INTO mindshare.mindshare_post (
        post_id, project_keyword, user_x_id, full_text, post_created_at,
        view_count, reply_count, retweet_count, quote_count, favorite_count
    )
    SELECT
        'SIM_root_acurast',
        v_project,
        (SELECT user_x_id FROM mindshare.mindshare_post WHERE project_keyword = v_project LIMIT 1),
        'bench sim root post',
        now(), 0, 0, 0, 0, 0;

    INSERT INTO mindshare.mindshare_post (
        post_id, project_keyword, user_x_id, full_text, replied_post_id, post_created_at,
        view_count, reply_count, retweet_count, quote_count, favorite_count
    )
    SELECT
        'SIM_reply_acurast_' || gs,
        v_project,
        (SELECT user_x_id FROM mindshare.mindshare_post WHERE project_keyword = v_project LIMIT 1),
        'bench sim reply ' || gs,
        (SELECT post_id FROM mindshare.mindshare_post
          WHERE project_keyword = v_project AND NOT is_retweet
          ORDER BY post_created_at DESC LIMIT 1),
        now(), 0, 0, 0, 0, 0
    FROM generate_series(1, 20) gs;
END $$;

DROP TABLE IF EXISTS _bench_delta;
CREATE TEMP TABLE _bench_delta (ms numeric);
DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    CALL analytics_md_fix.refresh_engagement_incremental('acurast');
    INSERT INTO _bench_delta VALUES (extract(epoch FROM (clock_timestamp()-t0))*1000);
END $$;

-- Should show ~21 rows written (not the whole project) — see docs/analytics_incremental_engagement.md
-- §3.3/§5.4 for why it can land on a slightly different number depending on which existing
-- post the replies happen to resolve to.
SELECT ms AS incremental_delta_ms FROM _bench_delta;
SELECT scope_key, last_ingest_ts, rows_inserted, placeholders_removed, placeholders_inserted
FROM analytics_md_fix.engagement_refresh_state
WHERE scope_key = 'project:acurast';

ROLLBACK; -- undoes the simulated source rows AND the delta this incremental run wrote

-- ============================================================
-- Done. Compare full_build_ms (step 1) against incremental_delta_ms (step 3) — that gap is
-- the number that matters. Sanity-check step 1 against the existing baseline in
-- docs/db-analysis/performance-comparison.md #2 (analytics_md_fix single-pass: 5,768ms on
-- pact_swap/~1M rows) to confirm this run is representative.
-- ============================================================
