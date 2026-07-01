-- ============================================================================
-- 00_apply_all.sql  —  Apply the full test_mindshare optimization in order
-- ----------------------------------------------------------------------------
-- Usage:
--   psql "<conn string>" -v ON_ERROR_STOP=1 -f backend_optimization/00_apply_all.sql
-- Idempotent: all CREATE INDEX use IF NOT EXISTS; partition uses CREATE TABLE IF NOT EXISTS.
-- ============================================================================

\timing on

\echo '== 01: partitioning =='
\ir 01_partitions.sql

\echo '== 02: Tier-1 indexes =='
\ir 02_indexes_tier1.sql

\echo '== 03: Tier-2 indexes =='
\ir 03_indexes_tier2.sql

-- VACUUM (not just ANALYZE) is required after the bulk load so the visibility map
-- is set; otherwise the covering indexes cannot perform index-only scans (the decay
-- driving scan would heap-fetch every row instead of Heap Fetches: 0).
\echo '== VACUUM ANALYZE =='
VACUUM (ANALYZE) test_mindshare.mindshare_post;
VACUUM (ANALYZE) test_mindshare.user_post;
VACUUM (ANALYZE) test_mindshare.nucleus_post;

-- NOTE: realizing the index-only decay plan also needs SSD-appropriate planner config.
-- With stock random_page_cost = 4 the planner reverts to Seq Scan + on-disk Sort.
-- Recommended (scope as you prefer; the per-function form is safest as it is local):
--   ALTER DATABASE mindshare_db SET random_page_cost = 1.1;   -- instance-wide for this DB
--   -- or, per decay function once you create it in the test schema:
--   -- ALTER FUNCTION test_mindshare.calculate_decay_scores(text, interval)
--   --   SET random_page_cost = 1.1 SET work_mem = '256MB';

\echo '== done =='
