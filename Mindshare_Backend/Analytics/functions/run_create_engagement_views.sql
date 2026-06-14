-- DROP PROCEDURE analytics.run_create_engagement_views();

CREATE OR REPLACE PROCEDURE analytics.run_create_engagement_views()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    handle text;
BEGIN
    FOR handle IN
        SELECT project_name
        FROM mindshare.mindshare_project
        WHERE project_name IS NOT NULL AND project_name != ''
    LOOP
        CALL analytics.create_engagement_view(handle);
        RAISE NOTICE 'Processed view for: %', handle;
    END LOOP;
END;
$procedure$
;