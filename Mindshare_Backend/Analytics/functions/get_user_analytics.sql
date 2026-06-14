-- DROP FUNCTION analytics.get_user_analytics(text, int4);

CREATE OR REPLACE FUNCTION analytics.get_user_analytics(target_user_id text, limit_cnt integer DEFAULT NULL::integer)
 RETURNS TABLE(total_unique_engaged_users bigint, total_post_count bigint, total_quote_post_count bigint, total_post_view_count bigint, total_quote_post_view_count bigint, total_view_count bigint, x_id text, x_username text, x_score numeric, engagements bigint, likes bigint, replies bigint, retweets bigint, like_to_reply_ratio numeric, reach numeric, unique_reach numeric, first_post_date timestamp with time zone, last_post_date timestamp with time zone, self_replies bigint, average_p90 numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query TEXT;
BEGIN
    sql_query := format($q$
    WITH target_posts AS (
        SELECT post_id
        FROM mindshare.user_post
        WHERE user_x_id = %L
          AND (is_post OR (is_quote AND NOT is_reply))
        ORDER BY post_created_at DESC
        LIMIT %s
    ),
    filtered AS (
        SELECT mp.*
        FROM mindshare.user_post mp
        JOIN target_posts tp ON mp.post_id = tp.post_id
    ),
    project_totals AS (
        SELECT
            COALESCE(COUNT(*) FILTER (WHERE is_post), 0) AS total_post_count,
            COALESCE(COUNT(*) FILTER (WHERE is_quote AND NOT is_reply), 0) AS total_quote_post_count,
            COALESCE(SUM(CASE WHEN is_post THEN COALESCE(view_count,0) ELSE 0 END), 0) AS total_post_view_count,
            COALESCE(SUM(CASE WHEN is_quote AND NOT is_reply THEN COALESCE(view_count,0) ELSE 0 END), 0) AS total_quote_post_view_count,
            MIN(post_created_at) as first_post_date,
            MAX(post_created_at) as last_post_date
        FROM filtered
    ),
    user_p90_stats AS (
        SELECT
            tp.user_x_id AS x_id,
            ROUND(AVG(fe.duration_days_p90)::numeric, 2) AS average_p90
        FROM filtered tp
        JOIN mindshare_score.mv_user_posts_engagement_features fe
            ON fe.root_post_id = tp.post_id
        GROUP BY tp.user_x_id
    ),
    user_stats AS (
        SELECT
            user_x_id as x_id,
            SUM(case when is_post or (is_quote and not is_reply)
                 then coalesce(favorite_count, 0)
                 else 0 end) as likes,
            SUM(case when is_post or (is_quote and not is_reply)
                 then coalesce(retweet_count, 0)
                 else 0 end) as retweets,
            SUM(case when is_post or (is_quote and not is_reply)
                 then coalesce(favorite_count, 0) + coalesce(retweet_count, 0)
                 else 0 end) as internal_engagements,
            COUNT(*) filter (where is_post) as post_count,
            COUNT(*) filter (where is_quote and not is_reply) as quote_post_count,
            COUNT(*) filter (where is_reply) as replies_count,
            SUM(case when is_post then coalesce(view_count, 0) else 0 end) as post_view_count,
            SUM(case when (is_quote and not is_reply) then coalesce(view_count, 0) else 0 end) as quote_view_count,
            SUM(case when is_reply then coalesce(view_count, 0) else 0 end) as replies_view_count
        FROM
            filtered
        GROUP BY
            user_x_id
    ),
    incoming_engagements AS (
        SELECT
            mp.user_x_id as engaged_user_id,
            COALESCE(mu.score, 0) as engaged_user_score,
            mp.post_id as engaged_tweet_id,
            mp.is_reply as is_engaged_reply,
            COALESCE(mp.replied_post_id, mp.quoted_post_id) as target_post_id
        FROM mindshare.user_post mp
        LEFT JOIN mindshare.mindshare_user mu ON mp.user_x_id = mu.x_id
        WHERE
            (mp.replied_post_id IN (SELECT post_id FROM target_posts)
             OR mp.quoted_post_id IN (SELECT post_id FROM target_posts))
    ),
    unique_engager_scores AS (
        SELECT
            engaged_user_id,
            MAX(COALESCE(engaged_user_score, 0)) as unique_score
        FROM incoming_engagements
        WHERE engaged_user_id != %L
        GROUP BY engaged_user_id
    ),
    final_unique_reach AS (
        SELECT SUM(unique_score) as total_unique_reach
        FROM unique_engager_scores
    ),
    post_unique_reach AS (
        SELECT
            target_post_id,
            SUM(max_engager_score) as p_unique_reach
        FROM (
            SELECT
                target_post_id,
                engaged_user_id,
                MAX(engaged_user_score) as max_engager_score
            FROM incoming_engagements
            WHERE engaged_user_id != %L
            GROUP BY target_post_id, engaged_user_id
        ) sub
        GROUP BY target_post_id
    ),
    engagement_totals AS (
        SELECT
            COUNT(*) FILTER (WHERE engaged_user_id != %L) as replies_received,
            COUNT(*) FILTER (WHERE engaged_user_id = %L) as self_replies_count,
            COUNT(DISTINCT engaged_user_id) FILTER (WHERE engaged_user_id != %L) as total_unique_engaged_users,
            COALESCE((SELECT SUM(p_unique_reach) FROM post_unique_reach), 0) as total_reach
        FROM incoming_engagements
    ),
    with_users AS (
        SELECT
            us.*,
            COALESCE(mu.score, 0) as x_score,
            COALESCE(mu.x_username, '') as combined_username,
            ups.average_p90 as average_p90
        FROM
            user_stats us
        LEFT JOIN mindshare.mindshare_user mu ON us.x_id = mu.x_id
        LEFT JOIN user_p90_stats ups ON us.x_id = ups.x_id
    )
    SELECT
        coalesce(et.total_unique_engaged_users, 0) as total_unique_engaged_users,
        pt.total_post_count,
        pt.total_quote_post_count,
        pt.total_post_view_count,
        pt.total_quote_post_view_count,
        (pt.total_post_view_count + pt.total_quote_post_view_count) as total_view_count,
        wu.x_id::text,
        wu.combined_username::text as x_username,
        wu.x_score::numeric,
        (wu.internal_engagements + coalesce(et.replies_received, 0))::bigint as engagements,
        wu.likes::bigint,
        coalesce(et.replies_received, 0)::bigint as replies,
        wu.retweets::bigint,
        case
            when coalesce(et.replies_received, 0) = 0 then 0
            else round(wu.likes::numeric / et.replies_received, 2)
        end::numeric as like_to_reply_ratio,
        COALESCE(et.total_reach, 0)::numeric as reach,
        COALESCE(fur.total_unique_reach, 0)::numeric as unique_reach,
        pt.first_post_date,
        pt.last_post_date,
        coalesce(et.self_replies_count, 0)::bigint as self_replies,
        wu.average_p90
    FROM project_totals pt
    LEFT JOIN engagement_totals et ON true
    CROSS JOIN final_unique_reach fur
    JOIN with_users wu ON true
    $q$,
    target_user_id,
    COALESCE(limit_cnt::text, 'NULL'),
    target_user_id,
    target_user_id,
    target_user_id,
    target_user_id,
    target_user_id,
    target_user_id
    );

    RETURN QUERY EXECUTE sql_query;
END;
$function$
;