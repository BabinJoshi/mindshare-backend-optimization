-- ============================================================================
-- 02_indexes_tier1.sql  —  Tier-1 indexes for test_mindshare base tables
-- ----------------------------------------------------------------------------
-- Create now. Covers the decay drivers (primary concern) + the hot reader paths.
-- Conventions:
--   * Partitioned-table indexes are created on the PARENT (propagate to all
--     current/future partitions) and OMIT project_keyword (constant per
--     partition; pruning already isolates the project).
--   * Partial indexes use "WHERE <col> IS NOT NULL" so they remain usable
--     whether or not the redundant generated-column filter (is_reply) is present.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- mindshare_post (partitioned)
-- ---------------------------------------------------------------------------
-- PROJECT DECAY driving scan: ordered + partial + covering -> no Sort, INDEX-ONLY for p.
-- project_keyword is INCLUDEd (even though it is the partition key / constant per partition)
-- because the decay SELECT returns p.project_keyword; without it the scan cannot go index-only.
-- Verified: Index Only Scan, Heap Fetches: 0, driving scan ~11.2s -> ~0.88s on 'quipnetwork'.
CREATE INDEX IF NOT EXISTS ix_tmp_mp_replier_time
    ON test_mindshare.mindshare_post (user_x_id, post_created_at)
    INCLUDE (post_id, replied_post_id, project_keyword)
    WHERE replied_post_id IS NOT NULL;

-- post_id lookup: decay self-join (op) + every "JOIN mindshare_post ON post_id = ..." reader
CREATE INDEX IF NOT EXISTS ix_tmp_mp_post_lookup
    ON test_mindshare.mindshare_post (post_id) INCLUDE (user_x_id);

-- general user timeline (NON-reply rows the partial index above does not cover):
-- get_v2_user_posts_analytics, get_unique_reach_increase, get_post_from_user_id
CREATE INDEX IF NOT EXISTS ix_tmp_mp_user_time
    ON test_mindshare.mindshare_post (user_x_id, post_created_at);

-- ---------------------------------------------------------------------------
-- user_post (unpartitioned)
-- ---------------------------------------------------------------------------
-- GLOBAL DECAY driving scan: ordered + partial + covering -> no Sort, index-only for p
CREATE INDEX IF NOT EXISTS ix_tmp_up_replier_time
    ON test_mindshare.user_post (user_x_id, post_created_at)
    INCLUDE (post_id, replied_post_id)
    WHERE replied_post_id IS NOT NULL;

-- post_id lookup: global decay self-join + root_up.post_id = reply_up.root_post_id joins
CREATE INDEX IF NOT EXISTS ix_tmp_up_post_lookup
    ON test_mindshare.user_post (post_id) INCLUDE (user_x_id);

-- replied_post_id (+time): account/global metrics engagement join
-- JOIN user_post e ON e.replied_post_id = root WHERE e.post_created_at BETWEEN ...
CREATE INDEX IF NOT EXISTS ix_tmp_up_replied_time
    ON test_mindshare.user_post (replied_post_id, post_created_at)
    WHERE replied_post_id IS NOT NULL;

-- root_post_id: get_post_metrics_from_user_post + replies/post_metrics joins
CREATE INDEX IF NOT EXISTS ix_tmp_up_root_post_id
    ON test_mindshare.user_post (root_post_id);

-- ---------------------------------------------------------------------------
-- nucleus_post (partitioned)
-- ---------------------------------------------------------------------------
-- get_post_from_user_id (nucleus) + get_top_nucleus_posts_per_user + get_user_engagement_quality
CREATE INDEX IF NOT EXISTS ix_tmp_np_user_time
    ON test_mindshare.nucleus_post (user_x_id, post_created_at);

-- ---------------------------------------------------------------------------
-- mindshare_user (unpartitioned)
-- ---------------------------------------------------------------------------
-- Covering (x_id) INCLUDE (score): makes the replier-base-score join INDEX-ONLY in BOTH decay
-- functions and the engagement matview builds (u.score / eu.score is read in 60+ call sites).
-- Verified: global decay score join 607ms/155k reads -> 55ms/~1.9k buffers; decay 12.4s -> 8.1s.
CREATE INDEX IF NOT EXISTS ix_tmp_mu_xid_score
    ON test_mindshare.mindshare_user (x_id) INCLUDE (score);
