-- ============================================================================
-- decay_21_benchmark_full_vs_incremental.sql
--   Clean-slate test_mindshare_score, then time a FULL recompute vs an
--   INCREMENTAL recompute for every project (contribution_scores) and for
--   global (global_contribution_scores).
--
--   "FULL"        = first incremental run for a scope (no watermark -> full build + sets watermark)
--   "INCREMENTAL" = the immediately-following run (watermark set, no new data -> 0 dirty)
--
--   Per-call wall-clock is printed by \timing after each SELECT; the '@@@' marker
--   lines label each call so the durations can be paired up.
--
--   Run:  psql "$URL" -f backend_optimization/decay_21_benchmark_full_vs_incremental.sql
-- ============================================================================
\timing on

\echo '@@@ CLEAN SLATE test_mindshare_score'
TRUNCATE test_mindshare_score.contribution_scores;
TRUNCATE test_mindshare_score.global_contribution_scores;
TRUNCATE test_mindshare_score.decay_run_log;
DELETE FROM test_mindshare_score.decay_run_state;

-- =================== FULL (cold) ===================
\echo '@@@ FULL project quipnetwork'
SELECT test_mindshare_score.calculate_decay_scores_incremental('quipnetwork');
\echo '@@@ FULL project TheARCTERMINAL'
SELECT test_mindshare_score.calculate_decay_scores_incremental('TheARCTERMINAL');
\echo '@@@ FULL project sleepagotchi'
SELECT test_mindshare_score.calculate_decay_scores_incremental('sleepagotchi');
\echo '@@@ FULL project Pact_Swap'
SELECT test_mindshare_score.calculate_decay_scores_incremental('Pact_Swap');
\echo '@@@ FULL project YOM_Official'
SELECT test_mindshare_score.calculate_decay_scores_incremental('YOM_Official');
\echo '@@@ FULL project _technotainment'
SELECT test_mindshare_score.calculate_decay_scores_incremental('_technotainment');
\echo '@@@ FULL project CNPYNetwork'
SELECT test_mindshare_score.calculate_decay_scores_incremental('CNPYNetwork');
\echo '@@@ FULL project Acurast'
SELECT test_mindshare_score.calculate_decay_scores_incremental('Acurast');
\echo '@@@ FULL project D3lMundos'
SELECT test_mindshare_score.calculate_decay_scores_incremental('D3lMundos');
\echo '@@@ FULL project IronAllies_'
SELECT test_mindshare_score.calculate_decay_scores_incremental('IronAllies_');
\echo '@@@ FULL global'
SELECT test_mindshare_score.calculate_global_decay_scores_incremental();

-- =================== INCREMENTAL (warm, no new data) ===================
\echo '@@@ INCR project quipnetwork'
SELECT test_mindshare_score.calculate_decay_scores_incremental('quipnetwork');
\echo '@@@ INCR project TheARCTERMINAL'
SELECT test_mindshare_score.calculate_decay_scores_incremental('TheARCTERMINAL');
\echo '@@@ INCR project sleepagotchi'
SELECT test_mindshare_score.calculate_decay_scores_incremental('sleepagotchi');
\echo '@@@ INCR project Pact_Swap'
SELECT test_mindshare_score.calculate_decay_scores_incremental('Pact_Swap');
\echo '@@@ INCR project YOM_Official'
SELECT test_mindshare_score.calculate_decay_scores_incremental('YOM_Official');
\echo '@@@ INCR project _technotainment'
SELECT test_mindshare_score.calculate_decay_scores_incremental('_technotainment');
\echo '@@@ INCR project CNPYNetwork'
SELECT test_mindshare_score.calculate_decay_scores_incremental('CNPYNetwork');
\echo '@@@ INCR project Acurast'
SELECT test_mindshare_score.calculate_decay_scores_incremental('Acurast');
\echo '@@@ INCR project D3lMundos'
SELECT test_mindshare_score.calculate_decay_scores_incremental('D3lMundos');
\echo '@@@ INCR project IronAllies_'
SELECT test_mindshare_score.calculate_decay_scores_incremental('IronAllies_');
\echo '@@@ INCR global'
SELECT test_mindshare_score.calculate_global_decay_scores_incremental();

-- =================== SUMMARY ===================
\echo '@@@ SUMMARY rows + dirty per scope'
SELECT scope, dirty_repliers, rows_written FROM test_mindshare_score.decay_run_state ORDER BY scope;
SELECT 'contribution_scores total' AS t, count(*) FROM test_mindshare_score.contribution_scores
UNION ALL
SELECT 'global_contribution_scores total', count(*) FROM test_mindshare_score.global_contribution_scores;
