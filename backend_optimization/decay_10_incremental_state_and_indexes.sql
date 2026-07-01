-- ============================================================================
-- decay_10_incremental_state_and_indexes.sql
--   State + indexes that the INCREMENTAL decay path needs.
-- ----------------------------------------------------------------------------
-- The incremental path recomputes only the repliers whose data changed since the
-- last successful run. "Changed" is measured on the INGEST timestamp
-- GREATEST(created_at, updated_at) -- NOT post_created_at, because ~85% of
-- replies are ingested >1 day after the tweet and up to ~9.5% over 30 days late.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Watermark / bookkeeping (one row per scope). Advances only on a successful run.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS test_mindshare_score.decay_run_state (
    scope               text        PRIMARY KEY,        -- 'project:<kw>' | 'global'
    last_ingest_ts      timestamptz NOT NULL,           -- max post ingest GREATEST(created_at,updated_at) processed
    last_user_ingest_ts timestamptz,                    -- max mindshare_user ingest processed (base-score watermark)
    last_run_at         timestamptz NOT NULL DEFAULT now(),
    last_run_id         bigint,
    dirty_repliers      bigint,
    rows_written        bigint
);
-- decouple base-score-change detection from the post-ingest watermark: a score change
-- bumps mindshare_user.updated_at but not any post's ingest, so without its own watermark
-- it would be re-detected on every run until a new post advances last_ingest_ts.
ALTER TABLE test_mindshare_score.decay_run_state
    ADD COLUMN IF NOT EXISTS last_user_ingest_ts timestamptz;

-- ---------------------------------------------------------------------------
-- Source-side indexes for dirty detection (on the READ-ONLY base tables).
-- Expression indexes on GREATEST(created_at, updated_at): the detection queries
-- MUST use the identical expression for these to be chosen by the planner.
-- ---------------------------------------------------------------------------

-- Changed posts: serves branch (1) "changed replies" (with residual replied_post_id
-- filter + partition prune) AND branch (2) "changed parents" (any post). Cannot be
-- partial because parents are not necessarily replies. Backward scan gives max() cheaply.
CREATE INDEX IF NOT EXISTS ix_tmp_mp_ingest
    ON test_mindshare.mindshare_post (GREATEST(created_at, updated_at));

CREATE INDEX IF NOT EXISTS ix_tmp_up_ingest
    ON test_mindshare.user_post (GREATEST(created_at, updated_at));

-- Base-score change detection (small table; index keeps it tidy).
CREATE INDEX IF NOT EXISTS ix_tmp_mu_ingest
    ON test_mindshare.mindshare_user (GREATEST(created_at, updated_at));

-- Branch (2): reach the replies of a changed parent via replied_post_id.
-- (user_post already has ix_tmp_up_replied_time for this.)
CREATE INDEX IF NOT EXISTS ix_tmp_mp_replied_post_id
    ON test_mindshare.mindshare_post (replied_post_id)
    WHERE replied_post_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- MVCC: incremental DELETE+INSERT churns the score tables -> make autovacuum
-- more aggressive so dead tuples don't accumulate between weekly full rebuilds.
-- ---------------------------------------------------------------------------
ALTER TABLE test_mindshare_score.contribution_scores
    SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.02);
ALTER TABLE test_mindshare_score.global_contribution_scores
    SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.02);

-- ---------------------------------------------------------------------------
-- REQUIRED: populate statistics for the GREATEST(created_at, updated_at)
-- EXPRESSION indexes. Without this the planner cannot estimate the watermark
-- predicate's selectivity and falls back to a Seq Scan for dirty detection.
-- After ANALYZE, detection is an Index Scan on ix_tmp_*_ingest that scales with
-- the watermark window, not the table size.
-- ---------------------------------------------------------------------------
ANALYZE test_mindshare.mindshare_post;
ANALYZE test_mindshare.user_post;
ANALYZE test_mindshare.mindshare_user;
