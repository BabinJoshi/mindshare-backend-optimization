-- 95/5 carve test on one project: full-build 95% (oldest by ingest), then incrementally
-- absorb the newest 5%. Reusable: change \set PROJ. Run with -v ON_ERROR_STOP=1.
\set ON_ERROR_STOP on
\timing on
\set PROJ TheARCTERMINAL

\echo '===== CLEAN SLATE test_mindshare_score ====='
TRUNCATE test_mindshare_score.contribution_scores;
TRUNCATE test_mindshare_score.global_contribution_scores;
TRUNCATE test_mindshare_score.decay_run_log;
DELETE FROM test_mindshare_score.decay_run_state;
UPDATE test_mindshare.mindshare_user t SET score=s.score
  FROM mindshare.mindshare_user s WHERE t.x_id=s.x_id AND t.score IS DISTINCT FROM s.score;

\echo '===== T95 ingest cutoff over ALL posts of the project ====='
SELECT percentile_disc(0.95) WITHIN GROUP (ORDER BY GREATEST(created_at,updated_at)) AS t95
FROM test_mindshare.mindshare_post WHERE project_keyword=:'PROJ' \gset
\echo 'T95 cutoff =' :'t95'

\echo '===== carve newest 5% (by ingest) into holding table, remove from partition ====='
DROP TABLE IF EXISTS test_mindshare_score.sim_hold;
CREATE TABLE test_mindshare_score.sim_hold AS
SELECT post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id,
       view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at,
       sentiment_score, sentiment_label, entities, content_score, latest_reply_at
FROM test_mindshare.mindshare_post
WHERE project_keyword=:'PROJ' AND GREATEST(created_at,updated_at) > :'t95';
SELECT count(*) AS carved_5pct_posts FROM test_mindshare_score.sim_hold;
DELETE FROM test_mindshare.mindshare_post WHERE project_keyword=:'PROJ' AND GREATEST(created_at,updated_at) > :'t95';
SELECT count(*) AS remaining_95pct_posts FROM test_mindshare.mindshare_post WHERE project_keyword=:'PROJ';

\echo '===== [PHASE 1: FULL] build decay on the 95% ====='
SELECT test_mindshare_score.calculate_decay_scores_incremental(:'PROJ') AS full_run_id;
SELECT dirty_repliers AS full_dirty, rows_written AS full_rows, last_ingest_ts AS watermark
  FROM test_mindshare_score.decay_run_state WHERE scope='project:'||:'PROJ';

\echo '===== re-insert the 5% (simulate ingestion of the remaining data) ====='
INSERT INTO test_mindshare.mindshare_post
  (post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id,
   view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at,
   sentiment_score, sentiment_label, entities, content_score, latest_reply_at)
SELECT post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id,
   view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at,
   sentiment_score, sentiment_label, entities, content_score, latest_reply_at
FROM test_mindshare_score.sim_hold;
SELECT count(*) AS posts_after_reinsert FROM test_mindshare.mindshare_post WHERE project_keyword=:'PROJ';

\echo '===== [PHASE 2: INCREMENTAL] absorb the newest 5% ====='
SELECT test_mindshare_score.calculate_decay_scores_incremental(:'PROJ') AS incr_run_id;
SELECT dirty_repliers AS incr_dirty, rows_written AS incr_rows, last_ingest_ts AS watermark
  FROM test_mindshare_score.decay_run_state WHERE scope='project:'||:'PROJ';
SELECT count(*) AS final_contribution_rows FROM test_mindshare_score.contribution_scores WHERE project_keyword=:'PROJ';

\echo '===== cleanup holding table ====='
DROP TABLE IF EXISTS test_mindshare_score.sim_hold;
