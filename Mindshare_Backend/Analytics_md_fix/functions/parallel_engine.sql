-- Generic parallel-execution engine for the analytics_md_fix orchestrators, plus the
-- small per-task wrapper functions it dispatches.
--
-- WHY dblink, not a bare CALL loop: a plpgsql CALL loop runs everything in one backend,
-- one project after another — inherently sequential no matter how it's written. Real
-- concurrency in Postgres means multiple backend processes, i.e. multiple connections.
-- dblink (already used elsewhere in this repo — see backend_optimization/decay_01_logging.sql)
-- opens N loopback connections and fans work across them with an async sliding-window
-- scheduler: as soon as one project's build finishes, the next queued project is dispatched
-- to that same connection immediately, instead of waiting for a whole batch to finish.
--
-- SECURITY NOTE (same as decay_01_logging.sql, same tradeoff, same caveat): the connection
-- string below has plaintext local credentials. Fine for this test/dev DB; before any real
-- production use, replace with a FOREIGN SERVER + USER MAPPING so the password isn't sitting
-- in function source.
--
-- Why the wrapper functions exist: a bare `CALL some_procedure()` has ZERO output columns.
-- dblink's async reader (dblink_get_result) requires a column-shape declaration to parse a
-- SETOF RECORD result, and zero declared columns isn't valid SQL syntax — so a bare CALL
-- can't be read back over dblink at all ("function return row and query-specified return
-- row do not match"). Each wrapper below is a FUNCTION returning exactly one (ok, err) row,
-- catching any exception internally instead of letting it propagate — so one project's
-- failure shows up as a row in the results table, not a crash that kills the whole batch.
--
-- p_project = NULL routes to the global (mv_user_posts_engagement) scope instead of a
-- per-project one — one wrapper covers both cases instead of a separate _global variant.

CREATE OR REPLACE FUNCTION analytics_md_fix._run_build_full(p_project text DEFAULT NULL)
RETURNS TABLE(ok boolean, err text) LANGUAGE plpgsql AS $fn$
BEGIN
    BEGIN
        IF p_project IS NULL THEN
            CALL analytics_md_fix.create_user_posts_engagement_table_full();
        ELSE
            CALL analytics_md_fix.create_engagement_table_full(p_project);
        END IF;
        ok := true; err := NULL;
    EXCEPTION WHEN OTHERS THEN
        ok := false; err := SQLERRM;
    END;
    RETURN NEXT;
END;
$fn$;

CREATE OR REPLACE FUNCTION analytics_md_fix._run_refresh_incremental(p_project text DEFAULT NULL)
RETURNS TABLE(ok boolean, err text) LANGUAGE plpgsql AS $fn$
BEGIN
    BEGIN
        IF p_project IS NULL THEN
            CALL analytics_md_fix.refresh_user_posts_engagement_incremental();
        ELSE
            CALL analytics_md_fix.refresh_engagement_incremental(p_project);
        END IF;
        ok := true; err := NULL;
    EXCEPTION WHEN OTHERS THEN
        ok := false; err := SQLERRM;
    END;
    RETURN NEXT;
END;
$fn$;

-- The scheduler. p_queries[i] must be a `SELECT * FROM analytics_md_fix._run_*(...)` call
-- (i.e. something returning exactly one (ok boolean, err text) row) — that's what makes it
-- readable back over dblink_get_result. p_labels[i] is just what shows up in the report.
CREATE OR REPLACE FUNCTION analytics_md_fix._run_queries_parallel(
    p_labels text[], p_queries text[], p_max_concurrency int DEFAULT 4
)
RETURNS TABLE(label text, ms numeric, ok boolean, err text)
LANGUAGE plpgsql AS $fn$
DECLARE
    v_connstr text := 'host=127.0.0.1 port=5432 dbname=mindshare_db user=postgres_user password=postgres_pass';
    n           int := COALESCE(array_length(p_labels, 1), 0);
    conn_name   text[];
    slot_busy   boolean[];
    slot_label  text[];
    slot_start  timestamptz[];
    next_task   int := 1;
    done_count  int := 0;
    s           int;
    r           record;
BEGIN
    IF n = 0 THEN RETURN; END IF;

    conn_name  := ARRAY(SELECT 'pconn' || g FROM generate_series(1, p_max_concurrency) g);
    slot_busy  := array_fill(false, ARRAY[p_max_concurrency]);
    slot_label := array_fill(NULL::text, ARRAY[p_max_concurrency]);
    slot_start := array_fill(NULL::timestamptz, ARRAY[p_max_concurrency]);

    FOR s IN 1..p_max_concurrency LOOP
        PERFORM dblink_connect(conn_name[s], v_connstr);
    END LOOP;

    LOOP
        -- dispatch to every free slot, immediately, not just once per pass.
        -- dblink_send_query returns 0 if the connection wasn't actually ready to accept a
        -- new async query (e.g. previous result not fully drained yet) — checked explicitly
        -- here; a silently-ignored failed send is exactly what caused 3 of 14 "successful"
        -- builds to actually be no-ops in testing (see docs/analytics_incremental_engagement.md
        -- §7). On a failed send, reconnect that slot and retry the same task next pass rather
        -- than marking it busy for a query that was never actually queued.
        FOR s IN 1..p_max_concurrency LOOP
            IF NOT slot_busy[s] AND next_task <= n THEN
                IF dblink_send_query(conn_name[s], p_queries[next_task]) = 1 THEN
                    slot_busy[s]  := true;
                    slot_label[s] := p_labels[next_task];
                    slot_start[s] := clock_timestamp();
                    next_task := next_task + 1;
                ELSE
                    PERFORM dblink_disconnect(conn_name[s]);
                    PERFORM dblink_connect(conn_name[s], v_connstr);
                END IF;
            END IF;
        END LOOP;

        EXIT WHEN done_count >= n;

        FOR s IN 1..p_max_concurrency LOOP
            IF slot_busy[s] AND dblink_is_busy(conn_name[s]) = 0 THEN
                label := slot_label[s];
                ms    := extract(epoch FROM (clock_timestamp() - slot_start[s])) * 1000;
                -- Fail-loud default: only ok=true if a real (o,e) row actually came back.
                -- Previously this defaulted to ok:=true before checking, so a get_result
                -- that silently returned zero rows was misreported as success.
                ok := false; err := 'no result row returned from dblink_get_result';
                BEGIN
                    FOR r IN SELECT * FROM dblink_get_result(conn_name[s]) AS t(o boolean, e text) LOOP
                        ok := r.o; err := r.e;
                    END LOOP;
                EXCEPTION WHEN OTHERS THEN
                    ok := false; err := SQLERRM;
                END;
                RETURN NEXT;
                slot_busy[s] := false;
                done_count := done_count + 1;
            END IF;
        END LOOP;

        IF done_count < n THEN
            PERFORM pg_sleep(0.2);
        END IF;
    END LOOP;

    FOR s IN 1..p_max_concurrency LOOP
        PERFORM dblink_disconnect(conn_name[s]);
    END LOOP;
END;
$fn$;
