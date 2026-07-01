-- ============================================================================
-- 03_indexes_tier2.sql  —  Tier-2 indexes for test_mindshare base tables
-- ----------------------------------------------------------------------------
-- Add if EXPLAIN shows the corresponding query is hot / picks a nested loop.
-- These serve secondary reader paths (timelines, OR-joins, matview builds).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- user_post (unpartitioned)
-- ---------------------------------------------------------------------------
-- non-reply user timeline (get_post_from_user_id, user_post branch)
CREATE INDEX IF NOT EXISTS ix_tmp_up_user_time
    ON test_mindshare.user_post (user_x_id, post_created_at);

-- quoted / retweeted lookups: get_all_users_analytics OR-join + engagement matview builds
CREATE INDEX IF NOT EXISTS ix_tmp_up_quoted_post_id
    ON test_mindshare.user_post (quoted_post_id)    WHERE quoted_post_id    IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_tmp_up_retweeted_post_id
    ON test_mindshare.user_post (retweeted_post_id) WHERE retweeted_post_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- nucleus_post (partitioned)
-- ---------------------------------------------------------------------------
-- get_user_engagement_quality second scan: WHERE replied_post_id IN (...)
CREATE INDEX IF NOT EXISTS ix_tmp_np_replied_post_id
    ON test_mindshare.nucleus_post (replied_post_id) WHERE replied_post_id IS NOT NULL;
