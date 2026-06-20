-- Indexes for the Polars decay source reads.
--
-- The decay pipeline reads only reply rows, joins each reply to its original
-- post, and must receive rows ordered by replier and time:
--
--   WHERE p.project_keyword = ?
--     AND p.replied_post_id IS NOT NULL
--   JOIN original ON original.project_keyword = p.project_keyword
--                AND original.post_id = p.replied_post_id
--   ORDER BY p.user_x_id, p.post_created_at
--
-- Run these in PostgreSQL during a maintenance window. The mindshare_post table
-- is partitioned by project_keyword, so index creation can take time on large
-- partitions.

CREATE INDEX IF NOT EXISTS ix_mindshare_post_decay_source_order ON mindshare.mindshare_post (
    project_keyword,
    user_x_id,
    post_created_at
) INCLUDE (post_id, replied_post_id)
WHERE
    replied_post_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_mindshare_post_decay_original_lookup ON mindshare.mindshare_post (project_keyword, post_id) INCLUDE (user_x_id);

-- Global decay reads from mindshare.user_post.

CREATE INDEX IF NOT EXISTS ix_user_post_decay_source_order ON mindshare.user_post (user_x_id, post_created_at) INCLUDE (post_id, replied_post_id)
WHERE
    replied_post_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_user_post_decay_original_lookup ON mindshare.user_post (post_id) INCLUDE (user_x_id);

CREATE INDEX IF NOT EXISTS ix_user_post_retweeted_post_id ON mindshare.user_post (retweeted_post_id);

ANALYZE mindshare.mindshare_post;

ANALYZE mindshare.user_post;

ANALYZE mindshare.mindshare_user;