-- analytics_md_fix.engagement_refresh_state
-- Watermark/checkpoint table driving incremental refresh for BOTH engagement scopes:
--   scope_key = 'project:<lower_project_keyword>'  -> per-project analytics_md_fix.engagement_<project>
--   scope_key = 'user_posts_engagement'            -> global analytics_md_fix.user_posts_engagement
--
-- No row for a scope = never built -> incremental procs fall back to a full build and seed it.
--
-- TWO independent watermarks, because two different source tables drive dirtiness:
--   last_ingest_ts -> mindshare_post/user_post (new/edited posts -> new engagement rows)
--   last_user_ts   -> mindshare_user (score/username changes -> UPDATE existing rows)
-- See functions/refresh_engagement_incremental.sql for how each is used.

CREATE TABLE IF NOT EXISTS analytics_md_fix.engagement_refresh_state (
    scope_key              text PRIMARY KEY,
    last_ingest_ts         timestamptz NOT NULL,
    last_user_ts           timestamptz NOT NULL DEFAULT '-infinity',
    last_run_at            timestamptz NOT NULL DEFAULT now(),
    rows_inserted          bigint NOT NULL DEFAULT 0,
    placeholders_removed   bigint NOT NULL DEFAULT 0,
    placeholders_inserted  bigint NOT NULL DEFAULT 0,
    rows_updated           bigint NOT NULL DEFAULT 0
);

-- idempotent add for an already-deployed table (this DB already has the table from before
-- this column existed)
ALTER TABLE analytics_md_fix.engagement_refresh_state ADD COLUMN IF NOT EXISTS last_user_ts timestamptz NOT NULL DEFAULT '-infinity';
ALTER TABLE analytics_md_fix.engagement_refresh_state ADD COLUMN IF NOT EXISTS rows_updated bigint NOT NULL DEFAULT 0;
