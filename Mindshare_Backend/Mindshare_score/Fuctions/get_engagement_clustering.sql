-- DROP FUNCTION mindshare_score.get_engagement_clustering(int8, int8, text);

CREATE OR REPLACE FUNCTION mindshare_score.get_engagement_clustering(start_ts bigint, end_ts bigint, project_keyword text)
 RETURNS TABLE(root_post_id text, root_user_id text, root_username text, root_tweet_created_at timestamp with time zone, total_engagements bigint, burst_concentration numeric, duration_days_p90 numeric, cross_post_overlap numeric, coordinated_burst numeric, farming_score numeric)
 LANGUAGE plpgsql
AS $function$
DECLARE
    view_name text := format('mindshare_score.mv_engagement_features_%s', lower(replace(project_keyword, ' ', '_')));
BEGIN
    RETURN QUERY EXECUTE format($query$
        SELECT
            root_post_id::text,
            root_user_id::text,
            root_username::text,
            root_tweet_created_at::timestamptz,
            total_engagements::bigint,
            burst_concentration::numeric,
            duration_days_p90::numeric,
            cross_post_overlap::numeric,
            coordinated_burst::numeric,
            farming_score::numeric
        FROM %s
        WHERE root_tweet_created_at >= to_timestamp(%L)
          AND root_tweet_created_at <= to_timestamp(%L)
        ORDER BY farming_score DESC
    $query$, view_name, start_ts, end_ts);
END;
$function$
;