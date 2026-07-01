-- DROP PROCEDURE analytics.refresh_engagement_views_all();

CREATE OR REPLACE PROCEDURE analytics.refresh_engagement_views_all()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    handle TEXT;
BEGIN
    FOR handle IN
        SELECT LOWER(REPLACE(project_name, ' ', '_'))
        FROM mindshare.mindshare_project
        WHERE project_name IS NOT NULL AND project_name != ''
    LOOP
        RAISE NOTICE 'Refreshing view for: %', handle;
        EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.%I', 'mv_engagement_' || handle);
    END LOOP;
END;
$procedure$
;