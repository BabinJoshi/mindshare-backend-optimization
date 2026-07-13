-- ============================================================================
-- 02_create_indexes_and_state.sql
-- Phase 3: Create indexes for dirty detection + state management tuning
--
-- This script creates:
--   - Expression indexes on GREATEST(created_at, updated_at) for all source tables
--   - Tuning for autovacuum on score tables (more aggressive due to incremental churn)
--   - ANALYZE to populate statistics
--
-- Duration: ~3-5 minutes
-- Risk: Low (non-breaking, additive indexes only)
-- ============================================================================

-- ============================================================================
-- Expression Indexes for Dirty Detection
-- 
-- The incremental decay path detects "changed" rows via these indexes.
-- The detection queries MUST use the identical expression for the optimizer
-- to choose these indexes (via ix_*_ingest).
-- ============================================================================

-- Changed posts in mindshare.mindshare_post
-- Serves: branch (1) "changed replies" AND branch (2) "changed parents"
-- Cannot be partial because parents may not be replies themselves
-- Backward scan gives max() cheaply
CREATE INDEX IF NOT EXISTS ix_tmp_mp_ingest
    ON mindshare.mindshare_post (GREATEST(created_at, updated_at) DESC);

-- Changed posts in mindshare.user_post (global scope)
CREATE INDEX IF NOT EXISTS ix_tmp_up_ingest
    ON mindshare.user_post (GREATEST(created_at, updated_at) DESC);

-- Base-score changes: mindshare_user table (small, updated rarely)
CREATE INDEX IF NOT EXISTS ix_tmp_mu_ingest
    ON mindshare.mindshare_user (GREATEST(created_at, updated_at) DESC);

-- Branch (2) optimization: reach replies via parent post_id
-- (Join on replied_post_id when parent is a changed post)
-- Only index the replies (replied_post_id IS NOT NULL)
CREATE INDEX IF NOT EXISTS ix_tmp_mp_replied_post_id
    ON mindshare.mindshare_post (replied_post_id)
    WHERE replied_post_id IS NOT NULL;

-- ============================================================================
-- MVCC Tuning: Score Tables
-- 
-- The incremental decay path does lots of DELETE + INSERT (churn).
-- This generates dead tuples. Make autovacuum more aggressive so they don't
-- accumulate between weekly full rebuilds.
-- 
-- Default scale_factor: 0.2 (20%)
-- Tuned scale_factor: 0.02 (2%)  → vacuum more often, sooner
-- This trades vacuum overhead for fresher statistics and less bloat
-- ============================================================================

ALTER TABLE mindshare_score.contribution_scores
    SET (
        autovacuum_vacuum_scale_factor = 0.02,
        autovacuum_analyze_scale_factor = 0.02
    );

ALTER TABLE mindshare_score.global_contribution_scores
    SET (
        autovacuum_vacuum_scale_factor = 0.02,
        autovacuum_analyze_scale_factor = 0.02
    );

-- ============================================================================
-- Statistics Update
--
-- CRITICAL: Populate statistics for the GREATEST(created_at, updated_at)
-- expression indexes. Without this, the planner cannot estimate the
-- watermark predicate's selectivity and falls back to Seq Scan.
--
-- After ANALYZE, dirty detection becomes an Index Scan on ix_tmp_*_ingest
-- that scales with the watermark window, not the table size.
-- ============================================================================

ANALYZE mindshare.mindshare_post;
ANALYZE mindshare.user_post;
ANALYZE mindshare.mindshare_user;

-- Also analyze the score tables for accurate plan estimation in decay functions
ANALYZE mindshare_score.contribution_scores;
ANALYZE mindshare_score.global_contribution_scores;

-- ============================================================================
-- Verification: Check index creation
-- ============================================================================
SELECT 'Index creation complete.'::text as status,
       COUNT(*) as indexes_created
FROM (
    SELECT 1 WHERE EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'ix_tmp_mp_ingest')
    UNION ALL
    SELECT 1 WHERE EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'ix_tmp_up_ingest')
    UNION ALL
    SELECT 1 WHERE EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'ix_tmp_mu_ingest')
    UNION ALL
    SELECT 1 WHERE EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'ix_tmp_mp_replied_post_id')
) t;

