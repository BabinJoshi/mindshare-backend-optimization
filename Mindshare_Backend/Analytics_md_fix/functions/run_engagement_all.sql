-- analytics_md_fix.run_engagement_all
-- Sequential orchestrator, ALL projects + the global scope, no dblink/concurrency —
-- the always-works fallback if you don't want the parallel path's dblink dependency.
--
-- p_mode = 'full'        -> unconditional rebuild of every scope (hard resync).
-- p_mode = 'incremental' -> smart refresh: bootstraps a scope on its first-ever call,
--                           incremental after (this is what you'd put on a schedule).
--
-- Replaces the earlier separate build_all_engagement_tables_full() — same thing, plus
-- the incremental mode, in one proc instead of two.

CREATE OR REPLACE PROCEDURE analytics_md_fix.run_engagement_all(IN p_mode text DEFAULT 'incremental')
LANGUAGE plpgsql AS $proc$
DECLARE
    v_name text;
BEGIN
    IF p_mode NOT IN ('full', 'incremental') THEN
        RAISE EXCEPTION 'p_mode must be ''full'' or ''incremental'', got %', p_mode;
    END IF;

    FOR v_name IN
        SELECT project_name FROM mindshare.mindshare_project
        WHERE project_name IS NOT NULL AND project_name != ''
    LOOP
        IF p_mode = 'full' THEN
            CALL analytics_md_fix.create_engagement_table_full(v_name);
        ELSE
            CALL analytics_md_fix.refresh_engagement_incremental(v_name);
        END IF;
    END LOOP;

    IF p_mode = 'full' THEN
        CALL analytics_md_fix.create_user_posts_engagement_table_full();
    ELSE
        CALL analytics_md_fix.refresh_user_posts_engagement_incremental();
    END IF;
END;
$proc$;
