-- ============================================================================
-- decay_00_tables_and_log.sql
--   Destination score tables + the observability (run-log) table for the
--   replicated decay pipeline in test_mindshare_score.
-- ----------------------------------------------------------------------------
-- Mirrors mindshare_score.contribution_scores / global_contribution_scores and
-- applies the indexes from the strategy doc's "Deferred" section.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS test_mindshare_score;

-- ---------------------------------------------------------------------------
-- Project-scoped contribution scores
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS test_mindshare_score.contribution_scores (
    project_keyword       text        NOT NULL,
    reply_post_id         text        NOT NULL,
    replier_x_id          text        NOT NULL,
    original_post_id      text        NOT NULL,
    original_author_x_id  text        NOT NULL,
    post_created_at       timestamptz NOT NULL,
    replier_base_score    numeric     NOT NULL,
    effective_score       numeric     NOT NULL,
    contribution_score    numeric     NOT NULL,
    active_multipliers    numeric[]   NOT NULL,
    reply_number          integer     NOT NULL,
    local_reply_count     integer     NOT NULL,
    decay_type            text        NOT NULL,
    CONSTRAINT pk_tcs PRIMARY KEY (project_keyword, reply_post_id)
);

CREATE INDEX IF NOT EXISTS ix_tcs_keyword_orig_replier_time
    ON test_mindshare_score.contribution_scores
       (project_keyword, original_post_id, replier_x_id, post_created_at)
    INCLUDE (original_author_x_id, contribution_score);

CREATE INDEX IF NOT EXISTS ix_tcs_keyword_replier_time
    ON test_mindshare_score.contribution_scores (project_keyword, replier_x_id, post_created_at);

-- ---------------------------------------------------------------------------
-- Global contribution scores (no project_keyword)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS test_mindshare_score.global_contribution_scores (
    reply_post_id         text        NOT NULL,
    original_post_id      text        NOT NULL,
    replier_x_id          text        NOT NULL,
    original_author_x_id  text        NOT NULL,
    post_created_at       timestamptz NOT NULL,
    replier_base_score    numeric     NOT NULL,
    effective_score       numeric     NOT NULL,
    contribution_score    numeric     NOT NULL,
    active_multipliers    numeric[]   NOT NULL,
    reply_number          integer     NOT NULL,
    local_reply_count     integer     NOT NULL,
    decay_type            text        NOT NULL,
    CONSTRAINT pk_tgcs PRIMARY KEY (reply_post_id)
);

CREATE INDEX IF NOT EXISTS ix_tgcs_orig_replier_time
    ON test_mindshare_score.global_contribution_scores
       (original_post_id, replier_x_id, post_created_at)
    INCLUDE (original_author_x_id, contribution_score);

CREATE INDEX IF NOT EXISTS ix_tgcs_replier_time
    ON test_mindshare_score.global_contribution_scores (replier_x_id, post_created_at);

-- ---------------------------------------------------------------------------
-- Run log  —  the table the BACKEND/FRONT-END reads to see progress & failures
-- ---------------------------------------------------------------------------
-- One row per decay run, keyed by run_id. It is written via AUTONOMOUS
-- transactions (see decay_01_logging.sql) so the row SURVIVES even when the
-- decay function itself fails and its main transaction rolls back.
CREATE SEQUENCE IF NOT EXISTS test_mindshare_score.decay_run_id_seq;

CREATE TABLE IF NOT EXISTS test_mindshare_score.decay_run_log (
    run_id          bigint      NOT NULL PRIMARY KEY,
    scope           text        NOT NULL,            -- 'project' | 'global'
    project_keyword text,                            -- NULL for global
    status          text        NOT NULL,            -- 'running' | 'success' | 'failed'
    phase           text,                            -- 'init'|'clearing'|'computing'|'writing'|'done'|'error'
    message         text,
    rows_processed  bigint      NOT NULL DEFAULT 0,
    error_sqlstate  text,
    error_message   text,
    error_detail    text,
    error_context   text,
    started_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz
);

-- list recent runs (e.g. an admin screen) efficiently
CREATE INDEX IF NOT EXISTS ix_decay_run_log_recent
    ON test_mindshare_score.decay_run_log (started_at DESC);
