-- ============================================================================
-- decay_01_logging.sql
--   Autonomous run-logging for the decay pipeline + a status accessor for the API.
-- ----------------------------------------------------------------------------
-- WHY dblink: a plain INSERT into decay_run_log from inside the decay function
-- would roll back together with the function when it fails -> the front-end
-- would see nothing. dblink opens a SEPARATE loopback session, so each log
-- write COMMITS INDEPENDENTLY and therefore:
--   * progress heartbeats are visible to a polling front-end WHILE the run is
--     still in flight (the main transaction hasn't committed yet), and
--   * the 'failed' row with the error details PERSISTS after the run rolls back.
--
-- SECURITY NOTE (test schema): the loopback connection string below embeds
-- credentials. For production, replace it with a dblink FOREIGN SERVER + USER
-- MAPPING (or a Vault-sourced secret) so no password sits in the function body.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS dblink;

-- Convenience: mint a run_id the BACKEND can grab BEFORE starting the run, so it
-- can poll decay_run_log for that id while the (synchronous) function executes.
CREATE OR REPLACE FUNCTION test_mindshare_score.next_decay_run_id()
RETURNS bigint LANGUAGE sql AS
$$ SELECT nextval('test_mindshare_score.decay_run_id_seq') $$;

-- Autonomous upsert of a run-log row. Never raises (logging must not break the job).
CREATE OR REPLACE FUNCTION test_mindshare_score._decay_log(
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
SET search_path = test_mindshare_score, public
AS $$
DECLARE
    -- loopback connection -> autonomous commit (see SECURITY NOTE above)
    v_conn text := 'host=127.0.0.1 port=5432 dbname=mindshare_db user=postgres_user password=postgres_pass';
    v_sql  text;
BEGIN
    v_sql := format($f$
        INSERT INTO test_mindshare_score.decay_run_log
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

-- Status accessor for the API/front-end (returns the run-log row as JSON).
CREATE OR REPLACE FUNCTION test_mindshare_score.get_decay_run_status(p_run_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = test_mindshare_score, public
AS $$
    SELECT to_jsonb(l) FROM test_mindshare_score.decay_run_log l WHERE l.run_id = p_run_id
$$;
