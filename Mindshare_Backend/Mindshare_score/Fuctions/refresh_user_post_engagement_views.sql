-- DROP PROCEDURE mindshare_score.refresh_user_post_engagement_views();

CREATE OR REPLACE PROCEDURE mindshare_score.refresh_user_post_engagement_views()
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    RAISE NOTICE 'Refreshing global user post engagement view...';
    REFRESH MATERIALIZED VIEW analytics.mv_user_posts_engagement;

    RAISE NOTICE 'Refreshing global user post features view...';
    REFRESH MATERIALIZED VIEW mindshare_score.mv_user_posts_engagement_features;

    RAISE NOTICE 'Successfully refreshed all global user post engagement views.';
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed refreshing user post views: %', SQLERRM;
END;
$procedure$
;