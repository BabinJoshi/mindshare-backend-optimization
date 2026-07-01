-- ============================================================================
-- 01_partitions.sql  —  Partitioning for test_mindshare base tables
-- ----------------------------------------------------------------------------
-- Strategy: KEEP the existing LIST(project_keyword) partitioning on
--   mindshare_post / nucleus_post / post_content_signal (project-scoped queries
--   prune to a single partition; decay's per-replier ordered scan stays inside
--   one partition). Do NOT add time sub-partitioning (it would fragment decay's
--   ordered index scan and prune nothing for full-history reads).
--   user_post stays unpartitioned.
--
-- The only structural fix needed: nucleus_post has NO default partition, so an
-- insert for an unlisted project_keyword would fail. Add one.
-- ============================================================================

CREATE TABLE IF NOT EXISTS test_mindshare.nucleus_post_default
    PARTITION OF test_mindshare.nucleus_post DEFAULT;
