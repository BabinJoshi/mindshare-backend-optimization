-- Incremental refresh test — SYNTHETIC (SIM_) row approach.
-- Covers BOTH scopes: per-project (acurast) and global (mv_user_posts_engagement).
-- See docs/testing_sim_approach.md for the full write-up (when to use this vs the
-- time-travel approach in test_timetravel_incremental.sql).
--
-- What this does: insert a handful of clearly-fake SIM_-prefixed posts, call the
-- incremental proc for real, check the exact row count it reports, then ROLLBACK so
-- none of it touches real data. Deterministic row counts (you chose how many rows you
-- inserted) — use this when you need to verify exact algorithm behavior (e.g. the
-- placeholder-swap logic), not just "did something get picked up."
--
-- REQUIRED: turn auto-commit OFF first (DBeaver: Database menu -> Transaction Mode ->
-- Manual Commit, or the toolbar toggle). Run each BEGIN...ROLLBACK block as ONE script
-- (Alt+X / Execute SQL Script) — not statement-by-statement, or DBeaver commits each
-- statement individually and ROLLBACK won't undo anything.
--
-- Gotcha already fixed here: mindshare_post.project_keyword is case-sensitive
-- ('Acurast', not 'acurast'). The DO block below resolves the canonical name once into
-- v_project before using it in any INSERT — safe regardless of the case you type into
-- the one literal at the top. See docs/analytics_incremental_engagement.md §3.6 for the
-- live bug this was found from.
--
-- Note: engagement_run_log rows for these test runs are NOT undone by ROLLBACK —
-- _log_engagement_run commits via an autonomous dblink connection independent of this
-- transaction (see §7). That's by design (so a real failure's log survives a real
-- rollback) — expect to see these test runs show up permanently in engagement_run_log.

-- ============================================================
-- PART 1 — per-project scope (acurast)
-- ============================================================
BEGIN;

DO $$
DECLARE v_project text;
BEGIN
    SELECT project_name INTO v_project FROM mindshare.mindshare_project
    WHERE lower(project_name) = lower('acurast') LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No project found matching acurast (case-insensitive)';
    END IF;

    -- one brand-new root post, zero engagement so far
    INSERT INTO mindshare.mindshare_post (
        post_id, project_keyword, user_x_id, full_text, post_created_at,
        view_count, reply_count, retweet_count, quote_count, favorite_count
    )
    SELECT 'SIM_root_acurast', v_project,
           (SELECT user_x_id FROM mindshare.mindshare_post WHERE project_keyword = v_project LIMIT 1),
           'test root', now(), 0,0,0,0,0;

    -- 5 replies to that new post (post_created_at = now(), stable within this
    -- transaction, so "most recent post" lookups after this point resolve to SIM_root
    -- itself — this is why the row count below works out the way it does)
    INSERT INTO mindshare.mindshare_post (
        post_id, project_keyword, user_x_id, full_text, replied_post_id, post_created_at,
        view_count, reply_count, retweet_count, quote_count, favorite_count
    )
    SELECT 'SIM_reply_acurast_' || gs, v_project,
           (SELECT user_x_id FROM mindshare.mindshare_post WHERE project_keyword = v_project LIMIT 1),
           'test reply ' || gs,
           'SIM_root_acurast',
           now(), 0,0,0,0,0
    FROM generate_series(1,5) gs;
END $$;

CALL analytics_md_fix.refresh_engagement_incremental('acurast');

SELECT rows_inserted, placeholders_removed, placeholders_inserted
FROM analytics_md_fix.engagement_refresh_state WHERE scope_key = 'project:acurast';
-- expect: rows_inserted = 5 (the 5 replies as engagement rows; SIM_root gets no
-- placeholder because it already has engagement from those same 5 replies, same batch)

ROLLBACK; -- undoes the simulated posts AND the delta this refresh just wrote

-- ============================================================
-- PART 2 — global scope (mv_user_posts_engagement)
-- ============================================================
BEGIN;

INSERT INTO mindshare.user_post (
    post_id, user_x_id, full_text, replied_post_id, post_created_at,
    view_count, reply_count, retweet_count, quote_count, favorite_count
)
SELECT 'SIM_reply_up_' || gs,
       (SELECT user_x_id FROM mindshare.user_post LIMIT 1),
       'test reply ' || gs,
       (SELECT post_id FROM mindshare.user_post
        WHERE (is_post OR is_quote) AND NOT is_reply AND NOT is_retweet
        ORDER BY post_created_at DESC LIMIT 1),
       now(), 0,0,0,0,0
FROM generate_series(1,15) gs;

CALL analytics_md_fix.refresh_user_posts_engagement_incremental();

SELECT rows_inserted FROM analytics_md_fix.engagement_refresh_state WHERE scope_key = 'user_posts_engagement';
-- expect: rows_inserted = 15 (exactly the 15 replies — no placeholder logic in this
-- scope, see §3.4)

ROLLBACK;
