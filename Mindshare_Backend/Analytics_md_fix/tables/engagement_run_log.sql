-- analytics_md_fix.engagement_run_log
-- Append-only run history — separate concern from engagement_refresh_state (the
-- watermark/checkpoint table, which intentionally overwrites one row per scope; see
-- docs/analytics_incremental_engagement.md §3.1/§7 for why that's correct and shouldn't
-- become append-only itself). This table answers "what happened, when, and why did it
-- fail" — decay_run_log in backend_optimization/decay_00_tables_and_log.sql is the exact
-- same pattern, one row per run, keyed by run_id, written via autonomous commit so a
-- failed run's error details SURVIVE even though the run's own transaction rolls back.

CREATE SEQUENCE IF NOT EXISTS analytics_md_fix.engagement_run_id_seq;

CREATE TABLE IF NOT EXISTS analytics_md_fix.engagement_run_log (
    run_id                  bigint      NOT NULL PRIMARY KEY,
    scope                   text        NOT NULL,   -- 'project' | 'global'
    project_keyword         text,                   -- NULL for global; the resolved canonical casing when known
    mode                    text        NOT NULL,   -- 'full' | 'incremental'
    status                  text        NOT NULL,   -- 'running' | 'success' | 'failed'
    phase                   text,                   -- 'resolving_project'|'building'|'scanning_dirty'|'writing'|'done'|'error'
    message                 text,
    rows_processed          bigint      NOT NULL DEFAULT 0,
    placeholders_removed    bigint      NOT NULL DEFAULT 0,
    placeholders_inserted   bigint      NOT NULL DEFAULT 0,
    error_sqlstate          text,
    error_message           text,
    error_detail            text,
    error_context           text,
    started_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    finished_at             timestamptz
);

-- list recent runs (e.g. "what failed today") efficiently
CREATE INDEX IF NOT EXISTS ix_engagement_run_log_recent
    ON analytics_md_fix.engagement_run_log (started_at DESC);

-- fast "show me every failure for this project" lookup
CREATE INDEX IF NOT EXISTS ix_engagement_run_log_project_status
    ON analytics_md_fix.engagement_run_log (project_keyword, status, started_at DESC);
