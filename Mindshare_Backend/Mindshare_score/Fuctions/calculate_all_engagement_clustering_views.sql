-- DROP PROCEDURE mindshare_score.create_all_engagement_clustering_views();

CREATE OR REPLACE PROCEDURE mindshare_score.create_all_engagement_clustering_views()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    keyword_record RECORD;
BEGIN
    -- Loop through all unique project keywords found in the posts table
    FOR keyword_record IN
        SELECT MIN(project_keyword) AS project_keyword
        FROM mindshare.mindshare_post
        WHERE project_keyword IS NOT NULL AND project_keyword != ''
        GROUP BY LOWER(REPLACE(project_keyword, ' ', '_'))
    LOOP
        -- Create/Recreate the engagement features view
        BEGIN
            CALL mindshare_score.create_engagement_clustering_features_view(keyword_record.project_keyword);
            RAISE NOTICE 'Features view created for: %', keyword_record.project_keyword;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Failed to create features view for %: %', keyword_record.project_keyword, SQLERRM;
        END;
    END LOOP;
END;
$procedure$
;