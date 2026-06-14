-- DROP FUNCTION analytics.get_all_users_analytics(int4);

CREATE OR REPLACE FUNCTION analytics.get_all_users_analytics(limit_per_user integer DEFAULT NULL::integer)
 RETURNS TABLE(x_id text, x_username text, x_score numeric, total_unique_engaged_users bigint, total_post_count bigint, total_quote_post_count bigint, total_post_view_count bigint, total_quote_post_view_count bigint, total_view_count bigint, engagements bigint, likes bigint, replies bigint, retweets bigint, like_to_reply_ratio numeric, reach numeric, unique_reach numeric, average_p90 numeric, first_post_date timestamp with time zone, last_post_date timestamp with time zone, self_replies bigint, smart_reach numeric, unique_engagers_count bigint, median_unique_engagers_score numeric, average_unique_engagers_score numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query TEXT;
BEGIN
    -- Optimization: Bypass window function if no per-user limit is requested
    IF limit_per_user IS NULL THEN
        sql_query := format($q$
        WITH target_posts AS (
            SELECT *
            FROM mindshare.user_post
            WHERE (is_post OR is_quote)
              AND NOT is_reply
              AND NOT is_retweet
        ),
        user_stats AS (
            SELECT
                user_x_id as x_id,
                COALESCE(SUM(CASE WHEN is_post THEN COALESCE(view_count,0) ELSE 0 END), 0) AS total_post_view_count,
                COALESCE(SUM(CASE WHEN is_quote THEN COALESCE(view_count,0) ELSE 0 END), 0) AS total_quote_post_view_count,
                COALESCE(COUNT(*) FILTER (WHERE is_post), 0) AS post_count,
                COALESCE(COUNT(*) FILTER (WHERE is_quote), 0) AS quote_post_count,
                SUM(coalesce(favorite_count, 0)) as total_likes,
                SUM(coalesce(retweet_count, 0)) as total_retweets,
                MIN(post_created_at) as user_first_post_date,
                MAX(post_created_at) as user_last_post_date
            FROM
                target_posts
            GROUP BY
                user_x_id
        ),
        user_p90_stats AS (
            SELECT
                tp.user_x_id AS x_id,
                ROUND(AVG(fe.duration_days_p90)::numeric, 2) AS average_p90
            FROM target_posts tp
            JOIN mindshare_score.mv_user_posts_engagement_features fe
                ON fe.root_post_id = tp.post_id
            GROUP BY tp.user_x_id
        ),
        incoming_engagements AS (
            SELECT
                tp.user_x_id as author_id,
                mp.user_x_id as engaged_user_id,
                mp.user_x_id = tp.user_x_id as is_self_reply,
                COALESCE(u.score, 0) as engaged_user_score,
                tp.post_id as target_post_id
            FROM mindshare.user_post mp
            JOIN target_posts tp ON (mp.replied_post_id = tp.post_id OR mp.quoted_post_id = tp.post_id)
            LEFT JOIN mindshare.mindshare_user u ON mp.user_x_id = u.x_id
        ),
        post_reach_agg AS (
            SELECT
                author_id,
                target_post_id,
                SUM(max_engager_score) as p_unique_reach
            FROM (
                SELECT author_id, target_post_id, engaged_user_id, MAX(COALESCE(engaged_user_score, 0)) as max_engager_score
                FROM incoming_engagements
                WHERE NOT is_self_reply
                GROUP BY author_id, target_post_id, engaged_user_id
            ) sub
            GROUP BY author_id, target_post_id
        ),
        engagement_agg_base AS (
            SELECT
                author_id,
                COUNT(*) FILTER (WHERE NOT is_self_reply) as replies_received,
                COUNT(*) FILTER (WHERE is_self_reply) as self_replies_count,
                COUNT(DISTINCT engaged_user_id) FILTER (WHERE NOT is_self_reply) as total_unique_engaged_users
            FROM incoming_engagements
            GROUP BY author_id
        ),
        account_reach_agg AS (
            SELECT
                author_id,
                SUM(p_unique_reach) as total_reach
            FROM post_reach_agg
            GROUP BY author_id
        ),
        engagement_agg AS (
            SELECT
                eab.*,
                COALESCE(ara.total_reach, 0) as total_reach
            FROM engagement_agg_base eab
            LEFT JOIN account_reach_agg ara ON eab.author_id = ara.author_id
        ),
        unique_reach_agg AS (
            SELECT
                author_id,
                SUM(max_engager_score) as total_unique_reach
            FROM (
                SELECT author_id, engaged_user_id, MAX(COALESCE(engaged_user_score, 0)) as max_engager_score
                FROM incoming_engagements
                WHERE NOT is_self_reply
                GROUP BY author_id, engaged_user_id
            ) sub
            GROUP BY author_id
        ),
        unique_engager_stats AS (
            SELECT
                author_id,
                COUNT(engaged_user_id) AS unique_engagers_count,
                percentile_cont(0.5)
                    WITHIN GROUP (ORDER BY max_engager_score)
                    AS median_unique_engagers_score,
                AVG(max_engager_score) AS average_unique_engagers_score
            FROM (
                SELECT author_id, engaged_user_id, MAX(COALESCE(engaged_user_score, 0)) as max_engager_score
                FROM incoming_engagements
                WHERE NOT is_self_reply
                GROUP BY author_id, engaged_user_id
            ) sub
            GROUP BY author_id
        ),
        valid_posts AS (
            SELECT
                target_post_id AS post_id,
                author_id AS handle
            FROM post_reach_agg
            GROUP BY target_post_id, author_id
        ),
        unique_contributions AS (
            SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id)
                vp.handle,
                cs.contribution_score
            FROM mindshare_score.global_contribution_scores cs
            JOIN valid_posts vp
                ON vp.post_id = cs.original_post_id
            WHERE cs.replier_x_id <> cs.original_author_x_id
            ORDER BY
                cs.original_post_id,
                cs.replier_x_id,
                cs.post_created_at ASC
        ),
        smart_reach_cte AS (
            SELECT
                handle,
                SUM(contribution_score)::NUMERIC AS smart_reach
            FROM unique_contributions
            GROUP BY handle
        ),
        with_users AS (
            SELECT
                us.*,
                COALESCE(u.score, 0) as x_score,
                COALESCE(u.x_username, '') as combined_username
            FROM
                user_stats us
            LEFT JOIN mindshare.mindshare_user u ON us.x_id = u.x_id
        )
        SELECT
            wu.x_id::text,
            wu.combined_username::text as x_username,
            wu.x_score::numeric,
            coalesce(ea.total_unique_engaged_users, 0)::bigint as total_unique_engaged_users,
            wu.post_count::bigint,
            wu.quote_post_count::bigint,
            wu.total_post_view_count::bigint,
            wu.total_quote_post_view_count::bigint,
            (wu.total_post_view_count + wu.total_quote_post_view_count)::bigint as total_view_count,
            (wu.total_likes + wu.total_retweets + coalesce(ea.replies_received, 0))::bigint as engagements,
            wu.total_likes::bigint as likes,
            coalesce(ea.replies_received, 0)::bigint as replies,
            wu.total_retweets::bigint as retweets,
            case
                when coalesce(ea.replies_received, 0) = 0 then 0
                else round(wu.total_likes::numeric / ea.replies_received, 2)
            end::numeric as like_to_reply_ratio,
            COALESCE(ea.total_reach, 0)::numeric as reach,
            COALESCE(ura.total_unique_reach, 0)::numeric as unique_reach,
            ups.average_p90 as average_p90,
            wu.user_first_post_date as first_post_date,
            wu.user_last_post_date as user_last_post_date,
            coalesce(ea.self_replies_count, 0)::bigint as self_replies,
            COALESCE(sr.smart_reach, 0)::numeric as smart_reach,
            COALESCE(ues.unique_engagers_count, 0)::bigint as unique_engagers_count,
            ROUND(COALESCE(ues.median_unique_engagers_score, 0)::numeric, 2) as median_unique_engagers_score,
            ROUND(COALESCE(ues.average_unique_engagers_score, 0)::numeric, 2) as average_unique_engagers_score
        FROM with_users wu
        LEFT JOIN engagement_agg ea ON wu.x_id = ea.author_id
        LEFT JOIN unique_reach_agg ura ON wu.x_id = ura.author_id
        LEFT JOIN smart_reach_cte sr ON wu.x_id = sr.handle
        LEFT JOIN unique_engager_stats ues ON wu.x_id = ues.author_id
        LEFT JOIN user_p90_stats ups ON wu.x_id = ups.x_id
        $q$
        );
    ELSE
        sql_query := format($q$
        WITH filtered_posts AS (
            SELECT *,
                   ROW_NUMBER() OVER (PARTITION BY user_x_id ORDER BY post_created_at DESC) as rank
            FROM mindshare.user_post
            WHERE (is_post OR is_quote)
              AND NOT is_reply
              AND NOT is_retweet
        ),
        target_posts AS (
            SELECT *
            FROM filtered_posts
            WHERE rank <= %L
        ),
        user_stats AS (
            SELECT
                user_x_id as x_id,
                COALESCE(SUM(CASE WHEN is_post THEN COALESCE(view_count,0) ELSE 0 END), 0) AS total_post_view_count,
                COALESCE(SUM(CASE WHEN is_quote THEN COALESCE(view_count,0) ELSE 0 END), 0) AS total_quote_post_view_count,
                COALESCE(COUNT(*) FILTER (WHERE is_post), 0) AS post_count,
                COALESCE(COUNT(*) FILTER (WHERE is_quote), 0) AS quote_post_count,
                SUM(coalesce(favorite_count, 0)) as total_likes,
                SUM(coalesce(retweet_count, 0)) as total_retweets,
                MIN(post_created_at) as user_first_post_date,
                MAX(post_created_at) as user_last_post_date
            FROM
                target_posts
            GROUP BY
                user_x_id
        ),
        user_p90_stats AS (
            SELECT
                tp.user_x_id AS x_id,
                ROUND(AVG(fe.duration_days_p90)::numeric, 2) AS average_p90
            FROM target_posts tp
            JOIN mindshare_score.mv_user_posts_engagement_features fe
                ON fe.root_post_id = tp.post_id
            GROUP BY tp.user_x_id
        ),
        incoming_engagements AS (
            SELECT
                tp.user_x_id as author_id,
                mp.user_x_id as engaged_user_id,
                mp.user_x_id = tp.user_x_id as is_self_reply,
                COALESCE(u.score, 0) as engaged_user_score,
                tp.post_id as target_post_id
            FROM mindshare.user_post mp
            JOIN target_posts tp ON (mp.replied_post_id = tp.post_id OR mp.quoted_post_id = tp.post_id)
            LEFT JOIN mindshare.mindshare_user u ON mp.user_x_id = u.x_id
        ),
        post_reach_agg AS (
            SELECT
                author_id,
                target_post_id,
                SUM(max_engager_score) as p_unique_reach
            FROM (
                SELECT author_id, target_post_id, engaged_user_id, MAX(COALESCE(engaged_user_score, 0)) as max_engager_score
                FROM incoming_engagements
                WHERE NOT is_self_reply
                GROUP BY author_id, target_post_id, engaged_user_id
            ) sub
            GROUP BY author_id, target_post_id
        ),
        engagement_agg_base AS (
            SELECT
                author_id,
                COUNT(*) FILTER (WHERE NOT is_self_reply) as replies_received,
                COUNT(*) FILTER (WHERE is_self_reply) as self_replies_count,
                COUNT(DISTINCT engaged_user_id) FILTER (WHERE NOT is_self_reply) as total_unique_engaged_users
            FROM incoming_engagements
            GROUP BY author_id
        ),
        account_reach_agg AS (
            SELECT
                author_id,
                SUM(p_unique_reach) as total_reach
            FROM post_reach_agg
            GROUP BY author_id
        ),
        engagement_agg AS (
            SELECT
                eab.*,
                COALESCE(ara.total_reach, 0) as total_reach
            FROM engagement_agg_base eab
            LEFT JOIN account_reach_agg ara ON eab.author_id = ara.author_id
        ),
        unique_reach_agg AS (
            SELECT
                author_id,
                SUM(max_engager_score) as total_unique_reach
            FROM (
                SELECT author_id, engaged_user_id, MAX(COALESCE(engaged_user_score, 0)) as max_engager_score
                FROM incoming_engagements
                WHERE NOT is_self_reply
                GROUP BY author_id, engaged_user_id
            ) sub
            GROUP BY author_id
        ),
        unique_engager_stats AS (
            SELECT
                author_id,
                COUNT(engaged_user_id) AS unique_engagers_count,
                percentile_cont(0.5)
                    WITHIN GROUP (ORDER BY max_engager_score)
                    AS median_unique_engagers_score,
                AVG(max_engager_score) AS average_unique_engagers_score
            FROM (
                SELECT author_id, engaged_user_id, MAX(COALESCE(engaged_user_score, 0)) as max_engager_score
                FROM incoming_engagements
                WHERE NOT is_self_reply
                GROUP BY author_id, engaged_user_id
            ) sub
            GROUP BY author_id
        ),
        valid_posts AS (
            SELECT
                target_post_id AS post_id,
                author_id AS handle
            FROM post_reach_agg
            GROUP BY target_post_id, author_id
        ),
        unique_contributions AS (
            SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id)
                vp.handle,
                cs.contribution_score
            FROM mindshare_score.global_contribution_scores cs
            JOIN valid_posts vp
                ON vp.post_id = cs.original_post_id
            WHERE cs.replier_x_id <> cs.original_author_x_id
            ORDER BY
                cs.original_post_id,
                cs.replier_x_id,
                cs.post_created_at ASC
        ),
        smart_reach_cte AS (
            SELECT
                handle,
                SUM(contribution_score)::NUMERIC AS smart_reach
            FROM unique_contributions
            GROUP BY handle
        ),
        with_users AS (
            SELECT
                us.*,
                COALESCE(u.score, 0) as x_score,
                COALESCE(u.x_username, '') as combined_username
            FROM
                user_stats us
            LEFT JOIN mindshare.mindshare_user u ON us.x_id = u.x_id
        )
        SELECT
            wu.x_id::text,
            wu.combined_username::text as x_username,
            wu.x_score::numeric,
            coalesce(ea.total_unique_engaged_users, 0)::bigint as total_unique_engaged_users,
            wu.post_count::bigint,
            wu.quote_post_count::bigint,
            wu.total_post_view_count::bigint,
            wu.total_quote_post_view_count::bigint,
            (wu.total_post_view_count + wu.total_quote_post_view_count)::bigint as total_view_count,
            (wu.total_likes + wu.total_retweets + coalesce(ea.replies_received, 0))::bigint as engagements,
            wu.total_likes::bigint as likes,
            coalesce(ea.replies_received, 0)::bigint as replies,
            wu.total_retweets::bigint as retweets,
            case
                when coalesce(ea.replies_received, 0) = 0 then 0
                else round(wu.total_likes::numeric / ea.replies_received, 2)
            end::numeric as like_to_reply_ratio,
            COALESCE(ea.total_reach, 0)::numeric as reach,
            COALESCE(ura.total_unique_reach, 0)::numeric as unique_reach,
            ups.average_p90 as average_p90,
            wu.user_first_post_date as first_post_date,
            wu.user_last_post_date as user_last_post_date,
            coalesce(ea.self_replies_count, 0)::bigint as self_replies,
            COALESCE(sr.smart_reach, 0)::numeric as smart_reach,
            COALESCE(ues.unique_engagers_count, 0)::bigint as unique_engagers_count,
            ROUND(COALESCE(ues.median_unique_engagers_score, 0)::numeric, 2) as median_unique_engagers_score,
            ROUND(COALESCE(ues.average_unique_engagers_score, 0)::numeric, 2) as average_unique_engagers_score
        FROM with_users wu
        LEFT JOIN engagement_agg ea ON wu.x_id = ea.author_id
        LEFT JOIN unique_reach_agg ura ON wu.x_id = ura.author_id
        LEFT JOIN smart_reach_cte sr ON wu.x_id = sr.handle
        LEFT JOIN unique_engager_stats ues ON wu.x_id = ues.author_id
        LEFT JOIN user_p90_stats ups ON wu.x_id = ups.x_id
        $q$,
        limit_per_user
        );
    END IF;

    RETURN QUERY EXECUTE sql_query;
END;
$function$
;