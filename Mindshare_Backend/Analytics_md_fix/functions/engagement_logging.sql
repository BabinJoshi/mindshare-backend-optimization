-- Autonomous run-logging for the engagement pipeline, mirroring
-- backend_optimization/decay_01_logging.sql exactly (same rationale, same mechanism).
--
-- WHY dblink: a plain INSERT into engagement_run_log from inside
-- create_engagement_table_full/refresh_engagement_incremental would roll back together
-- with the procedure when it fails — you'd see NOTHING in the log for the run that most
-- needs debugging. dblink's one-shot `dblink(connstr, sql)` opens a separate loopback
-- connection that commits independently of the caller's transaction, so:
--   * the 'failed' row with full error details PERSISTS even though the run itself rolls back
--   * a 'running' row is visible to anyone polling while a long build is still in flight
--
-- SECURITY NOTE: same as parallel_engine.sql / decay_01_logging.sql — plaintext local
-- creds, acceptable for this test/dev DB, replace with FOREIGN SERVER + USER MAPPING
-- before any real production use.

CREATE OR REPLACE FUNCTION analytics_md_fix.next_engagement_run_id()
RETURNS bigint LANGUAGE sql AS
$$ SELECT nextval('analytics_md_fix.engagement_run_id_seq') $$;

-- Autonomous upsert of a run-log row. Never raises (logging must not break the job).
CREATE OR REPLACE FUNCTION analytics_md_fix._log_engagement_run(
    p_run_id                  bigint,
    p_scope                   text,
    p_project                 text,
    p_mode                    text,
    p_status                  text,
    p_phase                   text,
    p_message                 text,
    p_rows                    bigint  DEFAULT 0,
    p_placeholders_removed    bigint  DEFAULT 0,
    p_placeholders_inserted   bigint  DEFAULT 0,
    p_sqlstate                text    DEFAULT NULL,
    p_errmsg                  text    DEFAULT NULL,
    p_detail                  text    DEFAULT NULL,
    p_context                 text    DEFAULT NULL,
    p_finished                boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE
    v_conn text := 'host=127.0.0.1 port=5432 dbname=mindshare_db user=postgres_user password=postgres_pass';
    v_sql  text;
BEGIN
    v_sql := format($f$
        INSERT INTO analytics_md_fix.engagement_run_log
            (run_id, scope, project_keyword, mode, status, phase, message, rows_processed,
             placeholders_removed, placeholders_inserted,
             error_sqlstate, error_message, error_detail, error_context,
             started_at, updated_at, finished_at)
        VALUES (%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L, now(), now(), %s)
        ON CONFLICT (run_id) DO UPDATE SET
            status                 = EXCLUDED.status,
            phase                  = EXCLUDED.phase,
            message                = EXCLUDED.message,
            rows_processed         = EXCLUDED.rows_processed,
            placeholders_removed   = EXCLUDED.placeholders_removed,
            placeholders_inserted  = EXCLUDED.placeholders_inserted,
            error_sqlstate         = COALESCE(EXCLUDED.error_sqlstate, engagement_run_log.error_sqlstate),
            error_message          = COALESCE(EXCLUDED.error_message,  engagement_run_log.error_message),
            error_detail           = COALESCE(EXCLUDED.error_detail,   engagement_run_log.error_detail),
            error_context          = COALESCE(EXCLUDED.error_context,  engagement_run_log.error_context),
            updated_at             = now(),
            finished_at            = COALESCE(EXCLUDED.finished_at, engagement_run_log.finished_at)
    $f$,
        p_run_id, p_scope, p_project, p_mode, p_status, p_phase, p_message, p_rows,
        p_placeholders_removed, p_placeholders_inserted,
        p_sqlstate, p_errmsg, p_detail, p_context,
        CASE WHEN p_finished THEN 'now()' ELSE 'NULL' END);

    PERFORM dblink(v_conn, v_sql);
EXCEPTION WHEN OTHERS THEN
    -- swallow logging errors: the engagement job must never fail because logging failed
    NULL;
END;
$fn$;

-- Status accessor (e.g. for a script/API polling one run).
CREATE OR REPLACE FUNCTION analytics_md_fix.get_engagement_run_status(p_run_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS
$$ SELECT to_jsonb(l) FROM analytics_md_fix.engagement_run_log l WHERE l.run_id = p_run_id $$;

-- Convenience for "what failed recently" debugging.
CREATE OR REPLACE FUNCTION analytics_md_fix.get_recent_engagement_failures(p_limit int DEFAULT 20)
RETURNS SETOF analytics_md_fix.engagement_run_log LANGUAGE sql STABLE AS
$$
    SELECT * FROM analytics_md_fix.engagement_run_log
    WHERE status = 'failed'
    ORDER BY started_at DESC
    LIMIT p_limit
$$;
