-- ============================================================================
-- 01_setup_infrastructure.sql
-- Phase 2: Create support infrastructure for incremental decay
-- 
-- This script creates:
--   - dblink extension (for autonomous logging)
--   - decay_run_id_seq (sequence for unique run IDs)
--   - decay_run_state (watermark tracking)
--   - decay_run_log (execution log)
--   - _decay_log() function (autonomous logging)
--   - next_decay_run_id() helper
--
-- Duration: ~2-3 minutes
-- Risk: Low (non-breaking, additive only)
-- ============================================================================

-- ============================================================================
-- Enable dblink extension (needed for autonomous logging)
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS dblink;

-- ============================================================================
-- Sequence for unique run IDs (one per decay execution)
-- ============================================================================
CREATE SEQUENCE IF NOT EXISTS mindshare_score.decay_run_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    NO CYCLE;

-- ============================================================================
-- Watermark / State Tracking Table
-- One row per scope ('project:<keyword>' | 'global')
-- Advances only on a successful incremental run
-- ============================================================================
CREATE TABLE IF NOT EXISTS mindshare_score.decay_run_state (
    scope               text        PRIMARY KEY,        -- 'project:<kw>' | 'global'
    last_ingest_ts      timestamptz NOT NULL,           -- max post ingest GREATEST(created_at,updated_at) processed
    last_user_ingest_ts timestamptz,                    -- max mindshare_user ingest processed (base-score watermark)
    last_run_at         timestamptz NOT NULL DEFAULT now(),
    last_run_id         bigint,
    dirty_repliers      bigint,
    rows_written        bigint
);

-- Ensure last_user_ingest_ts column exists (in case table exists from earlier versions)
ALTER TABLE mindshare_score.decay_run_state
    ADD COLUMN IF NOT EXISTS last_user_ingest_ts timestamptz;

-- ============================================================================
-- Execution Log Table
-- One row per decay run, keyed by run_id
-- Written via AUTONOMOUS transactions so it survives even if the decay function fails
-- ============================================================================
CREATE TABLE IF NOT EXISTS mindshare_score.decay_run_log (
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

-- Index for efficient recent-run queries (admin screen, monitoring)
CREATE INDEX IF NOT EXISTS ix_decay_run_log_recent
    ON mindshare_score.decay_run_log (started_at DESC);

-- ============================================================================
-- Autonomous Logging Function
-- Uses dblink to open a separate connection, so logs COMMIT independently
-- even if the main decay function fails and rolls back.
--
-- SECURITY NOTE: For production, move credentials to a dblink FOREIGN SERVER
-- or fetch them from Vault instead of embedding in the function body.
-- ============================================================================
CREATE OR REPLACE FUNCTION mindshare_score._decay_log(
    p_run_id    bigint,
    p_scope     text,
    p_project   text,
    p_status    text,
    p_phase     text,
    p_message   text,
    p_rows      bigint  DEFAULT 0,
    p_sqlstate  text    DEFAULT NULL,
    p_errmsg    text    DEFAULT NULL,
    p_detail    text    DEFAULT NULL,
    p_context   text    DEFAULT NULL,
    p_finished  boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql
SET search_path = mindshare_score, public
AS $$
DECLARE
    -- loopback connection -> autonomous commit
    -- This allows logs to persist even if the main decay function fails
    v_conn text := 'host=127.0.0.1 port=5432 dbname=mindshare_db user=postgres_user password=postgres_pass';
    v_sql  text;
BEGIN
    v_sql := format($f$
        INSERT INTO mindshare_score.decay_run_log
            (run_id, scope, project_keyword, status, phase, message, rows_processed,
             error_sqlstate, error_message, error_detail, error_context,
             started_at, updated_at, finished_at)
        VALUES (%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L, now(), now(), %s)
        ON CONFLICT (run_id) DO UPDATE SET
            status         = EXCLUDED.status,
            phase          = EXCLUDED.phase,
            message        = EXCLUDED.message,
            rows_processed = EXCLUDED.rows_processed,
            error_sqlstate = COALESCE(EXCLUDED.error_sqlstate, decay_run_log.error_sqlstate),
            error_message  = COALESCE(EXCLUDED.error_message,  decay_run_log.error_message),
            error_detail   = COALESCE(EXCLUDED.error_detail,   decay_run_log.error_detail),
            error_context  = COALESCE(EXCLUDED.error_context,  decay_run_log.error_context),
            updated_at     = now(),
            finished_at    = COALESCE(EXCLUDED.finished_at, decay_run_log.finished_at)
    $f$,
        p_run_id, p_scope, p_project, p_status, p_phase, p_message, p_rows,
        p_sqlstate, p_errmsg, p_detail, p_context,
        CASE WHEN p_finished THEN 'now()' ELSE 'NULL' END);

    PERFORM public.dblink(v_conn, v_sql);
EXCEPTION WHEN OTHERS THEN
    -- swallow logging errors: the decay job must never fail because logging failed
    NULL;
END;
$$;

-- ============================================================================
-- Helper: Mint a run_id before starting the actual run
-- Allows the backend/front-end to poll decay_run_log for that id
-- while the (synchronous) decay function executes
-- ============================================================================
CREATE OR REPLACE FUNCTION mindshare_score.next_decay_run_id()
RETURNS bigint
LANGUAGE sql
AS $$
    SELECT nextval('mindshare_score.decay_run_id_seq')
$$;

-- ============================================================================
-- Confirmation
-- ============================================================================
SELECT 'Infrastructure setup complete.'::text as status,
       COUNT(*) as tables_and_functions_created
FROM (
    SELECT 1 WHERE EXISTS (SELECT 1 FROM information_schema.tables 
                          WHERE table_schema='mindshare_score' AND table_name='decay_run_log')
    UNION ALL
    SELECT 1 WHERE EXISTS (SELECT 1 FROM information_schema.tables 
                          WHERE table_schema='mindshare_score' AND table_name='decay_run_state')
    UNION ALL
    SELECT 1 WHERE EXISTS (SELECT 1 FROM information_schema.routines 
                          WHERE routine_schema='mindshare_score' AND routine_name='_decay_log')
    UNION ALL
    SELECT 1 WHERE EXISTS (SELECT 1 FROM information_schema.routines 
                          WHERE routine_schema='mindshare_score' AND routine_name='next_decay_run_id')
) t;

