-- analytics_md_fix.run_engagement_all_parallel
-- Concurrent orchestrator, ALL projects + the global scope, dispatched across
-- p_max_concurrency dblink loopback connections (see parallel_engine.sql). Returns one
-- row per scope with elapsed time and success/error, as soon as each finishes.
--
-- p_mode = 'full'        -> unconditional rebuild of every scope (hard resync).
-- p_mode = 'incremental' -> smart refresh: bootstraps a scope on its first-ever call,
--                           incremental after — this is the one to schedule routinely.
--
-- Replaces the earlier separate build_all_engagement_tables_full_parallel() and
-- refresh_engagement_all_parallel() — same two behaviors, one function, mode-selected,
-- so the dispatch/scheduling logic isn't duplicated across two near-identical functions.
--
-- p_max_concurrency default 4: ~13 projects today, max_connections=100 with room to
-- spare on this DB. Raise it if you have more headroom and want more overlap.

CREATE OR REPLACE FUNCTION analytics_md_fix.run_engagement_all_parallel(
    p_mode text DEFAULT 'incremental', p_max_concurrency int DEFAULT 4
)
RETURNS TABLE(label text, ms numeric, ok boolean, err text)
LANGUAGE plpgsql AS $fn$
DECLARE
    v_labels  text[];
    v_queries text[];
    v_wrapper text;
BEGIN
    IF p_mode NOT IN ('full', 'incremental') THEN
        RAISE EXCEPTION 'p_mode must be ''full'' or ''incremental'', got %', p_mode;
    END IF;

    v_wrapper := CASE WHEN p_mode = 'full' THEN '_run_build_full' ELSE '_run_refresh_incremental' END;

    SELECT array_agg(project_name ORDER BY project_name),
           array_agg(format('SELECT * FROM analytics_md_fix.%I(%L)', v_wrapper, project_name) ORDER BY project_name)
      INTO v_labels, v_queries
    FROM mindshare.mindshare_project
    WHERE project_name IS NOT NULL AND project_name != '';

    v_labels  := v_labels  || ARRAY['__global__'];
    v_queries := v_queries || ARRAY[format('SELECT * FROM analytics_md_fix.%I(NULL)', v_wrapper)];

    RETURN QUERY
    SELECT * FROM analytics_md_fix._run_queries_parallel(v_labels, v_queries, p_max_concurrency);
END;
$fn$;
