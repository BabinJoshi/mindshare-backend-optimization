-- DROP FUNCTION mindshare_score.get_user_post_engagement_clustering(text, int8, int8);

CREATE OR REPLACE FUNCTION mindshare_score.get_user_post_engagement_clustering(p_user_id text DEFAULT NULL::text, start_ts bigint DEFAULT NULL::bigint, end_ts bigint DEFAULT NULL::bigint)
 RETURNS TABLE(root_post_id text, root_user_id text, root_username text, root_tweet_created_at timestamp with time zone, total_engagements bigint, burst_concentration numeric, duration_days_p90 numeric, cross_post_overlap numeric, coordinated_burst numeric, farming_score numeric)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        f.root_post_id::text,
        f.root_user_id::text,
        f.root_username::text,
        f.root_tweet_created_at::timestamptz,
        f.total_engagements::bigint,
        f.burst_concentration::numeric,
        f.duration_days_p90::numeric,
        f.cross_post_overlap::numeric,
        f.coordinated_burst::numeric,
        f.farming_score::numeric
    FROM mindshare_score.mv_user_posts_engagement_features f
    WHERE (p_user_id IS NULL OR f.root_user_id = p_user_id)
      AND (start_ts IS NULL OR f.root_tweet_created_at >= to_timestamp(start_ts))
      AND (end_ts IS NULL OR f.root_tweet_created_at <= to_timestamp(end_ts))
    ORDER BY f.farming_score DESC;
END;
$function$
;