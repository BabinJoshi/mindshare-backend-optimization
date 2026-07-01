-- ============================================================================
-- decay_20_incremental_simulation.sql
--   Simulates "new data ingestion" on the STATIC test replica (which has no live
--   pipeline) and verifies the incremental decay pipeline against the gold
--   standard: a full rebuild. For every scenario it asserts
--       incremental result == full-rebuild result   (0 differing rows).
--
--   Run (fails loudly on any mismatch):
--     psql "$URL" -v ON_ERROR_STOP=1 -f backend_optimization/decay_20_incremental_simulation.sql
--
--   Project under test: Acurast (small/fast). All synthetic posts use the post_id
--   prefix 'SIM_' and are removed at the end; drifted base scores are restored from
--   the source `mindshare` schema, leaving the replica pristine.
--
--   Method per scenario:
--     1. synthesize an ingestion event (INSERT/UPDATE with created_at/updated_at = now())
--     2. run calculate_decay_scores_incremental('Acurast')  -> snapshot result (sim_inc)
--     3. run calculate_decay_scores('Acurast')  (full rebuild = gold standard)
--     4. assert symmetric difference(sim_inc, full) = 0
--   Because incremental detects "new" by INGEST time (GREATEST(created_at,updated_at)),
--   each synthetic event uses now() so it is always newer than the watermark.
-- ============================================================================
\set ON_ERROR_STOP on
\timing on
\set PROJ Acurast

-- ---------------------------------------------------------------------------
-- helpers: result collector + parity check (symmetric EXCEPT vs sim_inc snapshot)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS sim_results;
CREATE TEMP TABLE sim_results(step text, dirty bigint, parity_diff bigint, expectation text);

-- plpgsql + EXECUTE: defers name resolution to runtime and re-plans each call, so
-- it tolerates sim_inc being (re)created per scenario.
CREATE OR REPLACE FUNCTION pg_temp.sim_parity(p_proj text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
    EXECUTE format($q$
        SELECT count(*) FROM (
            (SELECT * FROM sim_inc
             EXCEPT SELECT * FROM test_mindshare_score.contribution_scores WHERE project_keyword = %L)
            UNION ALL
            (SELECT * FROM test_mindshare_score.contribution_scores WHERE project_keyword = %L
             EXCEPT SELECT * FROM sim_inc)
        ) d $q$, p_proj, p_proj) INTO v;
    RETURN v;
END $$;

-- ---------------------------------------------------------------------------
-- CLEAN BASELINE: restore source scores, drop leftover synthetic rows,
-- reset watermark, full build, capture canonical baseline.
-- ---------------------------------------------------------------------------
\echo '########## SETUP: clean baseline ##########'
UPDATE test_mindshare.mindshare_user t SET score = s.score
  FROM mindshare.mindshare_user s WHERE t.x_id = s.x_id AND t.score IS DISTINCT FROM s.score;
DELETE FROM test_mindshare.mindshare_post WHERE post_id LIKE 'SIM\_%';
DELETE FROM test_mindshare_score.decay_run_state WHERE scope = 'project:' || :'PROJ';

SELECT test_mindshare_score.calculate_decay_scores_incremental(:'PROJ') AS baseline_run_id;  -- first run => full + watermark
DROP TABLE IF EXISTS sim_baseline;
CREATE TEMP TABLE sim_baseline AS SELECT * FROM test_mindshare_score.contribution_scores WHERE project_keyword = :'PROJ';
SELECT count(*) AS baseline_rows FROM sim_baseline;

-- fixtures: busiest replier + an existing parent post + time bounds
DROP TABLE IF EXISTS sim_fix;
CREATE TEMP TABLE sim_fix AS
WITH busy AS (
    SELECT user_x_id AS replier, count(*) AS n,
           min(post_created_at) AS min_t, max(post_created_at) AS max_t
    FROM test_mindshare.mindshare_post
    WHERE project_keyword = :'PROJ' AND replied_post_id IS NOT NULL
    GROUP BY user_x_id ORDER BY count(*) DESC LIMIT 1
)
SELECT b.replier, b.n, b.min_t, b.max_t,
       (SELECT post_id FROM test_mindshare.mindshare_post
          WHERE project_keyword = :'PROJ' AND replied_post_id IS NULL LIMIT 1) AS parent_post,
       (SELECT max(post_created_at) FROM test_mindshare.mindshare_post WHERE project_keyword = :'PROJ') AS proj_max_t
FROM busy b;
SELECT replier, n AS replier_reply_count, parent_post FROM sim_fix;

-- ===========================================================================
-- SCENARIO 1 — new RECENT reply (branch 1: reply ingested since watermark)
-- ===========================================================================
\echo '########## S1: new recent reply ##########'
INSERT INTO test_mindshare.mindshare_post
    (post_id, project_keyword, user_x_id, full_text, replied_post_id,
     view_count, reply_count, retweet_count, quote_count, favorite_count,
     post_created_at, created_at, updated_at)
SELECT 'SIM_recent', :'PROJ', f.replier, 'sim recent reply', f.parent_post,
       0,0,0,0,0, f.proj_max_t + interval '1 hour', now(), now()
FROM sim_fix f;

SELECT test_mindshare_score.calculate_decay_scores_incremental(:'PROJ') AS s1_run;
DROP TABLE IF EXISTS sim_inc; CREATE TEMP TABLE sim_inc AS
    SELECT * FROM test_mindshare_score.contribution_scores WHERE project_keyword = :'PROJ';
SELECT test_mindshare_score.calculate_decay_scores(:'PROJ') AS s1_full;   -- gold standard
INSERT INTO sim_results
SELECT 'S1 new recent reply', d.dirty_repliers, pg_temp.sim_parity(:'PROJ'), 'dirty=1, parity_diff=0'
FROM test_mindshare_score.decay_run_state d WHERE scope = 'project:' || :'PROJ';

-- ===========================================================================
-- SCENARIO 2 — LATE-arriving reply (old post_created_at, ingested now)
--   Lands in the MIDDLE of the replier's tweet-time history => must recompute
--   the replier's later replies too. Tests ingest-watermark + whole-replier replay.
-- ===========================================================================
\echo '########## S2: late-arriving reply ##########'
INSERT INTO test_mindshare.mindshare_post
    (post_id, project_keyword, user_x_id, full_text, replied_post_id,
     view_count, reply_count, retweet_count, quote_count, favorite_count,
     post_created_at, created_at, updated_at)
SELECT 'SIM_late', :'PROJ', f.replier, 'sim late reply', f.parent_post,
       0,0,0,0,0, f.min_t + interval '5 days', now(), now()    -- OLD tweet time, NEW ingest
FROM sim_fix f;

SELECT test_mindshare_score.calculate_decay_scores_incremental(:'PROJ') AS s2_run;
DROP TABLE IF EXISTS sim_inc; CREATE TEMP TABLE sim_inc AS
    SELECT * FROM test_mindshare_score.contribution_scores WHERE project_keyword = :'PROJ';
SELECT test_mindshare_score.calculate_decay_scores(:'PROJ') AS s2_full;
INSERT INTO sim_results
SELECT 'S2 late-arriving reply', d.dirty_repliers, pg_temp.sim_parity(:'PROJ'), 'dirty>=1, parity_diff=0'
FROM test_mindshare_score.decay_run_state d WHERE scope = 'project:' || :'PROJ';

-- ===========================================================================
-- SCENARIO 3 — PARENT-late (branch 2): an EXISTING reply's parent is re-ingested.
--   The reply's own ingest is old (< watermark); only the PARENT changed.
-- ===========================================================================
\echo '########## S3: parent-late ##########'
DROP TABLE IF EXISTS sim_pl;
-- pick a reply whose PARENT actually exists in the Acurast partition (INNER JOIN op),
-- otherwise the reply produced no contribution row and bumping a phantom parent tests nothing.
CREATE TEMP TABLE sim_pl AS
SELECT r.post_id AS reply_id, r.user_x_id AS replier, op.post_id AS parent_id
FROM test_mindshare.mindshare_post r
JOIN test_mindshare.mindshare_post op
  ON op.post_id = r.replied_post_id AND op.project_keyword = r.project_keyword
WHERE r.project_keyword = :'PROJ' AND r.replied_post_id IS NOT NULL AND r.post_id NOT LIKE 'SIM\_%'
LIMIT 1;
-- bump ONLY the parent's ingest timestamp
UPDATE test_mindshare.mindshare_post p SET updated_at = now()
FROM sim_pl WHERE p.post_id = sim_pl.parent_id AND p.project_keyword = :'PROJ';

SELECT test_mindshare_score.calculate_decay_scores_incremental(:'PROJ') AS s3_run;
DROP TABLE IF EXISTS sim_inc; CREATE TEMP TABLE sim_inc AS
    SELECT * FROM test_mindshare_score.contribution_scores WHERE project_keyword = :'PROJ';
SELECT test_mindshare_score.calculate_decay_scores(:'PROJ') AS s3_full;
INSERT INTO sim_results
SELECT 'S3 parent-late (branch 2)', d.dirty_repliers, pg_temp.sim_parity(:'PROJ'),
       'dirty>=1 (replier of the reply to the bumped parent), parity_diff=0'
FROM test_mindshare_score.decay_run_state d WHERE scope = 'project:' || :'PROJ';

-- ===========================================================================
-- SCENARIO 4 — BASE-SCORE change (branch 3 / Option B): drift detected by
--   comparing current mindshare_user.score vs stored replier_base_score.
-- ===========================================================================
\echo '########## S4: base-score change ##########'
UPDATE test_mindshare.mindshare_user u SET score = score + 50, updated_at = now()
FROM sim_fix f WHERE u.x_id = f.replier;

SELECT test_mindshare_score.calculate_decay_scores_incremental(:'PROJ') AS s4_run;
DROP TABLE IF EXISTS sim_inc; CREATE TEMP TABLE sim_inc AS
    SELECT * FROM test_mindshare_score.contribution_scores WHERE project_keyword = :'PROJ';
SELECT test_mindshare_score.calculate_decay_scores(:'PROJ') AS s4_full;
INSERT INTO sim_results
SELECT 'S4 base-score change', d.dirty_repliers, pg_temp.sim_parity(:'PROJ'), 'dirty=1, parity_diff=0'
FROM test_mindshare_score.decay_run_state d WHERE scope = 'project:' || :'PROJ';

-- ===========================================================================
-- SCENARIO 5 — NO-OP: nothing changed since the last run.
-- ===========================================================================
\echo '########## S5: no-op ##########'
SELECT test_mindshare_score.calculate_decay_scores_incremental(:'PROJ') AS s5_run;
DROP TABLE IF EXISTS sim_inc; CREATE TEMP TABLE sim_inc AS
    SELECT * FROM test_mindshare_score.contribution_scores WHERE project_keyword = :'PROJ';
INSERT INTO sim_results
SELECT 'S5 no-op', d.dirty_repliers, 0, 'dirty=0 (no work)'
FROM test_mindshare_score.decay_run_state d WHERE scope = 'project:' || :'PROJ';

-- ===========================================================================
-- RESULTS + ASSERTIONS
-- ===========================================================================
\echo '########## RESULTS ##########'
SELECT * FROM sim_results ORDER BY step;

DO $$
DECLARE bad int;
BEGIN
    -- parity: every scenario's incremental result must equal the full rebuild
    SELECT count(*) INTO bad FROM sim_results WHERE parity_diff IS DISTINCT FROM 0;
    IF bad > 0 THEN RAISE EXCEPTION 'SIMULATION FAILED: % scenario(s) with non-zero parity diff', bad; END IF;

    -- dirty-count expectations: each change-detection branch must actually fire,
    -- and the no-op must do zero work.
    IF (SELECT dirty FROM sim_results WHERE step='S1 new recent reply')      <> 1 THEN RAISE EXCEPTION 'S1 expected dirty=1';  END IF;
    IF (SELECT dirty FROM sim_results WHERE step='S2 late-arriving reply')    < 1 THEN RAISE EXCEPTION 'S2 expected dirty>=1'; END IF;
    IF (SELECT dirty FROM sim_results WHERE step='S3 parent-late (branch 2)') < 1 THEN RAISE EXCEPTION 'S3 (branch 2) did not fire: dirty=0'; END IF;
    IF (SELECT dirty FROM sim_results WHERE step='S4 base-score change')      <> 1 THEN RAISE EXCEPTION 'S4 expected dirty=1';  END IF;
    IF (SELECT dirty FROM sim_results WHERE step='S5 no-op')                  <> 0 THEN RAISE EXCEPTION 'S5 expected dirty=0';  END IF;

    RAISE NOTICE 'ALL SIMULATION SCENARIOS PASSED (incremental == full rebuild; every branch fired; no-op did 0 work)';
END $$;

-- ===========================================================================
-- CLEANUP: remove synthetic rows, restore source scores, reset to clean baseline.
-- ===========================================================================
\echo '########## CLEANUP ##########'
DELETE FROM test_mindshare.mindshare_post WHERE post_id LIKE 'SIM\_%';
UPDATE test_mindshare.mindshare_user t SET score = s.score
  FROM mindshare.mindshare_user s WHERE t.x_id = s.x_id AND t.score IS DISTINCT FROM s.score;
DELETE FROM test_mindshare_score.decay_run_state WHERE scope = 'project:' || :'PROJ';
SELECT test_mindshare_score.calculate_decay_scores_incremental(:'PROJ') AS final_clean_run;  -- clean full rebuild + fresh watermark
SELECT 'cleanup_parity_vs_baseline' AS check,
  (SELECT count(*) FROM (
     (TABLE sim_baseline EXCEPT SELECT * FROM test_mindshare_score.contribution_scores WHERE project_keyword = :'PROJ')
     UNION ALL
     (SELECT * FROM test_mindshare_score.contribution_scores WHERE project_keyword = :'PROJ' EXCEPT TABLE sim_baseline)
   ) d) AS rows_differing_from_baseline;
