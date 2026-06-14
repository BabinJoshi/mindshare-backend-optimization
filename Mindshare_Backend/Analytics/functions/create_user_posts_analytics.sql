-- DROP FUNCTION analytics.get_user_posts_analytics(text, int8, int8);

CREATE OR REPLACE FUNCTION analytics.get_user_posts_analytics(p_user_id text, startdate bigint, enddate bigint)
 RETURNS TABLE(post_id text, handle text, username character varying, content text, likes_count integer, replies_count bigint, quotes_count integer, retweets_count integer, impressions bigint, burst_concentration numeric, duration_days_p90 numeric, cross_post_overlap numeric, coordinated_burst numeric, reach numeric, unique_reach numeric, engagements bigint, self_replies_count bigint, like_reply_ratio numeric, impression_to_unique_reach_ratio numeric, post_type text, smart_reach numeric, unique_engagers bigint, unique_engager_scores_to_count_ratio numeric, like_reply_engagement_farming_flag boolean, like_reply_botting_flag boolean, impression_unique_reach_engagement_farming_flag boolean, impression_unique_reach_botting_flag boolean)
 LANGUAGE sql
 STABLE
AS $function$
WITH base_posts AS (
    SELECT
        up.post_id,
        up.user_x_id AS handle,
        u.x_username AS username,
        u.score AS author_score,
        up.full_text,
        up.view_count,
        up.favorite_count AS likes_count,
        up.retweet_count AS retweets_count,
        up.quote_count AS quotes_count,
        CASE
            WHEN up.retweeted_post_id IS NOT NULL THEN 'retweet'
            WHEN up.replied_post_id IS NOT NULL AND up.quoted_post_id IS NOT NULL THEN 'quoted_reply'
            WHEN up.replied_post_id IS NOT NULL THEN 'reply'
            WHEN up.quoted_post_id IS NOT NULL THEN 'quote'
            ELSE 'post'
        END AS post_type
    FROM mindshare.user_post up
    LEFT JOIN mindshare.mindshare_user u ON u.x_id = up.user_x_id
    WHERE up.user_x_id = p_user_id
      AND (up.post_id = up.root_post_id OR up.root_post_id IS NULL)
      AND (up.is_post OR up.is_quote)
      AND NOT up.is_reply
      AND NOT up.is_retweet
      AND up.post_created_at >= (to_timestamp(startDate))
      AND up.post_created_at <  (to_timestamp(endDate))
),

reply_counts AS (
    SELECT
        r.replied_post_id AS post_id,
        COUNT(*) AS total_replies,
        COUNT(*) FILTER (WHERE r.user_x_id = bp.handle) AS self_replies_count,
        COUNT(*) FILTER (WHERE r.user_x_id <> bp.handle) AS external_replies_count
    FROM mindshare.user_post r
    JOIN base_posts bp
      ON bp.post_id = r.replied_post_id
    WHERE r.post_created_at >= (to_timestamp(startDate))
      AND r.post_created_at <  (to_timestamp(endDate))
    GROUP BY r.replied_post_id
),

engagements AS (
    SELECT
        e.replied_post_id AS post_id,
        e.user_x_id,
        COALESCE(u.score, 0) as user_x_score
    FROM mindshare.user_post e
    JOIN base_posts bp
      ON bp.post_id = e.replied_post_id
    LEFT JOIN mindshare.mindshare_user u ON e.user_x_id = u.x_id
    WHERE e.user_x_id <> bp.handle
      AND e.post_created_at >= to_timestamp(startDate)
      AND e.post_created_at <  to_timestamp(endDate)
),

aggregated AS (
    SELECT
        post_id,
        COUNT(*) FILTER (WHERE row_number = 1)::bigint AS unique_engagers,
        SUM(user_x_score)::numeric AS reach,
        SUM(user_x_score) FILTER (WHERE row_number = 1)::numeric AS unique_reach
    FROM (
        SELECT
            *,
            ROW_NUMBER() OVER (PARTITION BY post_id, user_x_id ORDER BY post_id) AS row_number
        FROM engagements
    ) t
    GROUP BY post_id
),

ratio_data AS (
    SELECT
        bp.post_id,
        bp.handle,
        bp.username,
        bp.full_text as content,
        bp.likes_count,
        COALESCE(rc.external_replies_count, 0) AS replies_count,
        bp.quotes_count,
        bp.retweets_count,
        bp.view_count::bigint AS impressions,
        COALESCE(a.reach, 0) AS reach,
        COALESCE(a.unique_reach, 0) AS unique_reach,
        COALESCE(a.unique_engagers, 0) AS unique_engagers,
        (
            bp.likes_count
            + COALESCE(rc.external_replies_count,0)
            + bp.retweets_count
        ) AS engagements,
        COALESCE(rc.self_replies_count, 0) AS self_replies_count,
        CASE
            WHEN COALESCE(rc.external_replies_count,0) = 0 THEN NULL
            ELSE ROUND(
                bp.likes_count::numeric / rc.external_replies_count,
                2
            )
        END AS like_reply_ratio,
        CASE
            WHEN COALESCE(a.unique_reach,0) = 0 THEN NULL
            ELSE ROUND(
                bp.view_count::numeric / COALESCE(a.unique_reach,0)::numeric,
                4
            )
        END AS impression_to_unique_reach_ratio,
        CASE
            WHEN COALESCE(a.unique_engagers, 0) = 0 THEN NULL
            ELSE ROUND(COALESCE(a.unique_reach, 0)::numeric / a.unique_engagers, 2)
        END AS unique_engager_scores_to_count_ratio,
        bp.post_type,
        bp.author_score
    FROM base_posts bp
    LEFT JOIN reply_counts rc
           ON rc.post_id = bp.post_id
    LEFT JOIN aggregated a
           ON a.post_id = bp.post_id
),

unique_engager_cte AS (
    SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id)
        cs.original_post_id,
        cs.contribution_score
    FROM mindshare_score.global_contribution_scores cs
    WHERE cs.original_author_x_id = p_user_id
      AND cs.post_created_at >= to_timestamp(startDate)
      AND cs.post_created_at <  to_timestamp(endDate)
      AND cs.replier_x_id <> cs.original_author_x_id
    ORDER BY
        cs.original_post_id,
        cs.replier_x_id,
        cs.post_created_at ASC
),

smart_reach_cte AS (
    SELECT
        original_post_id,
        SUM(contribution_score) AS smart_reach
    FROM unique_engager_cte
    GROUP BY original_post_id
)

SELECT
    r.post_id,
    r.handle,
    r.username,
    r.content,
    r.likes_count,
    r.replies_count,
    r.quotes_count,
    r.retweets_count,
    r.impressions,

    -- Engagement Clustering Metrics
    ec.burst_concentration,
    ec.duration_days_p90,
    ec.cross_post_overlap,
    ec.coordinated_burst,

    r.reach,
    r.unique_reach,
    r.engagements,
    r.self_replies_count,
    r.like_reply_ratio,
    r.impression_to_unique_reach_ratio,
    r.post_type,

    COALESCE(sr.smart_reach, 0)::numeric AS smart_reach,
    r.unique_engagers,
    r.unique_engager_scores_to_count_ratio,

    -- LIKE / REPLY FLAGS
    CASE
        WHEN r.replies_count >= 10 AND r.like_reply_ratio < 1.7 THEN TRUE
        ELSE FALSE
    END AS like_reply_engagement_farming_flag,

    CASE
        WHEN r.replies_count >= 10 AND r.like_reply_ratio > 20 THEN TRUE
        ELSE FALSE
    END AS like_reply_botting_flag,

    -- UNIQUE REACH / IMPRESSION FLAGS
    CASE
        WHEN r.impression_to_unique_reach_ratio is not null AND r.impression_to_unique_reach_ratio < 1 THEN TRUE
        ELSE FALSE
    END AS impression_unique_reach_engagement_farming_flag,

    CASE
        WHEN r.impression_to_unique_reach_ratio is not null
             AND r.impression_to_unique_reach_ratio >
                 CASE WHEN r.author_score > 2000 THEN 15 ELSE 5 END
        THEN TRUE
        ELSE FALSE
    END AS impression_unique_reach_botting_flag

FROM ratio_data r
LEFT JOIN mindshare_score.mv_user_posts_engagement_features ec
    ON ec.root_post_id = r.post_id
LEFT JOIN smart_reach_cte sr
    ON sr.original_post_id = r.post_id
ORDER BY r.unique_reach DESC NULLS LAST;
$function$
;