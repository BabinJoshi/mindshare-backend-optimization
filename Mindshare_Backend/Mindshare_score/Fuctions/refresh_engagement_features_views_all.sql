-- DROP PROCEDURE mindshare_score.refresh_engagement_features_views_all();

CREATE OR REPLACE PROCEDURE mindshare_score.refresh_engagement_features_views_all()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    handle TEXT;
    base_view_name TEXT;
    features_view_name TEXT;
    features_exists BOOLEAN;
    start_time TIMESTAMP;
    end_time TIMESTAMP;
BEGIN
    FOR handle IN
        SELECT DISTINCT LOWER(REPLACE(project_name, ' ', '_'))
        FROM mindshare.mindshare_project
        WHERE project_name IS NOT NULL AND project_name != ''
    LOOP
        base_view_name := 'mv_engagement_' || handle;
        features_view_name := 'mv_engagement_features_' || handle;

        -- Check if features view exists
        SELECT EXISTS (
            SELECT 1 FROM pg_matviews WHERE schemaname = 'mindshare_score' AND matviewname = features_view_name
        ) INTO features_exists;

        -- Handle Features View
        BEGIN
            -- Set a local timeout for this specific project's refresh
            EXECUTE 'SET LOCAL statement_timeout = ''10min''';
            
            start_time := clock_timestamp();
            
            IF features_exists THEN
                RAISE NOTICE 'Refreshing features view concurrently: %', features_view_name;
                EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY mindshare_score.%I', features_view_name);
            ELSE
                RAISE NOTICE 'Provisioning missing features view for: %', handle;
                CALL mindshare_score.create_engagement_clustering_features_view(handle);
            END IF;
            
            end_time := clock_timestamp();
            RAISE NOTICE 'Finished processing % in %', features_view_name, (end_time - start_time);
            
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Failed refreshing/provisioning features view %: %', features_view_name, SQLERRM;
        END;

        -- Commit the current project's work (or rollback if exception occurred)
        -- Must be outside the EXCEPTION block!
        COMMIT;

    END LOOP;
END;
$procedure$
;