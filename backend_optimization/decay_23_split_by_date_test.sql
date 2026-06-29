-- Date-window carve test: full-load everything ingested up to (max_ingest - N days),
-- then incrementally absorb the last N days of ingest. Split by INGEST time
-- (GREATEST(created_at,updated_at)) to match the watermark. Reusable: change PROJ / DAYS.
\set ON_ERROR_STOP on
\timing on
\set PROJ TheARCTERMINAL
\set DAYS 3

\echo '===== CLEAN SLATE ====='
TRUNCATE test_mindshare_score.contribution_scores;
TRUNCATE test_mindshare_score.global_contribution_scores;
TRUNCATE test_mindshare_score.decay_run_log;
DELETE FROM test_mindshare_score.decay_run_state;
DROP TABLE IF EXISTS test_mindshare_score.sim_hold;
UPDATE test_mindshare.mindshare_user t SET score=s.score
  FROM mindshare.mindshare_user s WHERE t.x_id=s.x_id AND t.score IS DISTINCT FROM s.score;

\echo '===== cutoff = max_ingest - N days ====='
SELECT (max(GREATEST(created_at,updated_at)) - (:'DAYS'||' days')::interval) AS cutoff
FROM test_mindshare.mindshare_post WHERE project_keyword=:'PROJ' \gset
\echo 'cutoff =' :'cutoff'

\echo '===== carve the last N days (by ingest) into holding table; remove from partition ====='
CREATE TABLE test_mindshare_score.sim_hold AS
SELECT post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id,
       view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at,
       sentiment_score, sentiment_label, entities, content_score, latest_reply_at
FROM test_mindshare.mindshare_post
WHERE project_keyword=:'PROJ' AND GREATEST(created_at,updated_at) > :'cutoff';
SELECT count(*) AS carved_last_n_days FROM test_mindshare_score.sim_hold;
DELETE FROM test_mindshare.mindshare_post WHERE project_keyword=:'PROJ' AND GREATEST(created_at,updated_at) > :'cutoff';
SELECT count(*) AS remaining_full_load FROM test_mindshare.mindshare_post WHERE project_keyword=:'PROJ';

\echo '===== [PHASE 1: FULL] build decay on everything up to cutoff ====='
SELECT test_mindshare_score.calculate_decay_scores_incremental(:'PROJ') AS full_run_id;
SELECT dirty_repliers AS full_dirty, rows_written AS full_rows FROM test_mindshare_score.decay_run_state WHERE scope='project:'||:'PROJ';

\echo '===== re-insert the last N days (simulate fresh ingestion) ====='
INSERT INTO test_mindshare.mindshare_post
  (post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id,
   view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at,
   sentiment_score, sentiment_label, entities, content_score, latest_reply_at)
SELECT post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id,
   view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at,
   sentiment_score, sentiment_label, entities, content_score, latest_reply_at
FROM test_mindshare_score.sim_hold;

\echo '===== [PHASE 2: INCREMENTAL] absorb the last N days ====='
SELECT test_mindshare_score.calculate_decay_scores_incremental(:'PROJ') AS incr_run_id;
SELECT dirty_repliers AS incr_dirty, rows_written AS incr_rows FROM test_mindshare_score.decay_run_state WHERE scope='project:'||:'PROJ';
SELECT count(*) AS final_rows FROM test_mindshare_score.contribution_scores WHERE project_keyword=:'PROJ';
DROP TABLE IF EXISTS test_mindshare_score.sim_hold;
