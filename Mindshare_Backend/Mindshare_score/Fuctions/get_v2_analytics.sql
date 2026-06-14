-- DROP FUNCTION mindshare_score.get_v2_analytics(text, int8, int8, text, _text);

CREATE OR REPLACE FUNCTION mindshare_score.get_v2_analytics(projectname text, startdate bigint, enddate bigint, sort_key text, private_user_ids text[] DEFAULT NULL::text[])
 RETURNS TABLE(total_unique_engaged_users bigint, total_post_count bigint, total_quote_post_count bigint, total_replies_count bigint, total_post_view_count bigint, total_quote_post_view_count bigint, total_replies_view_count bigint, total_view_count bigint, community_score numeric, project_analytics jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query TEXT;
    view_name TEXT := 'mv_engagement_' || LOWER(REPLACE(projectname, ' ', '_'));
    features_view_name TEXT := 'mv_engagement_features_' || LOWER(REPLACE(projectname, ' ', '_'));

	filter_by_user text:='';

	order_clause TEXT;
BEGIN

order_clause :=
        CASE sort_key
            WHEN 'MOST_POSTS'
                THEN 'post_count + quote_post_count'

            WHEN 'MOST_VIEWS'
                THEN 'post_view_count + quote_view_count'

            WHEN 'UNIQUE_ENGAGERS'
                THEN 'unique_engager'

            WHEN 'UNIQUE_REACH'
                THEN 'unique_reach'

            WHEN 'REACH'
                THEN 'reach'

            WHEN 'ENGAGEMENTS'
                THEN 'engagements + replies'

			WHEN 'MINDSHARE_SCORE'
                THEN 'mindshare_score'

            WHEN 'SMART_REACH'
                THEN 'smart_reach'

            ELSE 'post_count + quote_post_count'
        END;

if private_user_ids is not null and cardinality(private_user_ids) > 0 then
	filter_by_user :=' and user_x_id = any($4)';
end if;

sql_query := FORMAT($q$

WITH filtered AS (
    SELECT *
    FROM mindshare.mindshare_post
    WHERE project_keyword = $1
      AND post_created_at BETWEEN to_timestamp($2) AND to_timestamp($3)
	  %s
),

project_totals AS (
    SELECT
        COALESCE(COUNT(DISTINCT user_x_id), 0) AS total_unique_engaged_users,

        COALESCE(COUNT(*) FILTER (WHERE is_post), 0) AS total_post_count,
        COALESCE(COUNT(*) FILTER (WHERE is_quote AND NOT is_reply), 0) AS total_quote_post_count,
        COALESCE(COUNT(*) FILTER (WHERE is_reply), 0) AS total_replies_count,

        COALESCE(SUM(CASE WHEN is_post THEN COALESCE(view_count, 0) ELSE 0 END), 0) AS total_post_view_count,
        COALESCE(SUM(CASE WHEN is_quote AND NOT is_reply THEN COALESCE(view_count, 0) ELSE 0 END), 0) AS total_quote_post_view_count,
        COALESCE(SUM(CASE WHEN is_reply THEN COALESCE(view_count, 0) ELSE 0 END), 0) AS total_replies_view_count
    FROM filtered
),

user_stats AS (
    SELECT
        user_x_id AS x_id,

        SUM(
            CASE
                WHEN is_post OR (is_quote AND NOT is_reply)
                THEN COALESCE(favorite_count, 0) + COALESCE(retweet_count, 0)
                ELSE 0
            END
        ) AS engagements,

        SUM(
            CASE
                WHEN is_post OR (is_quote AND NOT is_reply)
                THEN COALESCE(favorite_count, 0)
                ELSE 0
            END
        ) AS likes,

        SUM(
            CASE
                WHEN is_post OR (is_quote AND NOT is_reply)
                THEN COALESCE(retweet_count, 0)
                ELSE 0
            END
        ) AS retweets,

        COUNT(*) FILTER (WHERE is_post) AS post_count,
        COUNT(*) FILTER (WHERE is_quote AND NOT is_reply) AS quote_post_count,
        COUNT(*) FILTER (WHERE is_reply) AS replies_count,

        SUM(CASE WHEN is_post THEN COALESCE(view_count, 0) ELSE 0 END) AS post_view_count,
        SUM(CASE WHEN is_quote AND NOT is_reply THEN COALESCE(view_count, 0) ELSE 0 END) AS quote_view_count,
        SUM(CASE WHEN is_reply THEN COALESCE(view_count, 0) ELSE 0 END) AS replies_view_count

    FROM filtered
    GROUP BY user_x_id
),

user_content_scores AS (
    SELECT
        user_x_id AS x_id,
        AVG(content_score) AS avg_content_score
    FROM filtered
    WHERE (is_post OR (is_quote AND NOT is_reply))
    GROUP BY user_x_id
),

user_duration_p90 AS (
    SELECT
        f.user_x_id AS x_id,
        AVG(fe.duration_days_p90)::numeric AS average_p90
    FROM filtered f
    JOIN mindshare_score.%I fe
        ON fe.root_post_id = f.post_id
    WHERE f.is_post OR (f.is_quote AND NOT f.is_reply)
    GROUP BY f.user_x_id
),

community_score_total AS (
    SELECT
        COALESCE(SUM(COALESCE(mu.score, 0)), 0) AS community_score
    FROM (
        SELECT DISTINCT user_x_id
        FROM filtered
    ) fp
    LEFT JOIN mindshare.mindshare_user mu
        ON mu.x_id = fp.user_x_id
),

with_scores AS (
    SELECT
        us.*,
        COALESCE(u.score, 0) AS x_score,
        COALESCE(u.x_username, '') AS x_username,
        ucs.avg_content_score,
        udp.average_p90
    FROM user_stats us
    LEFT JOIN mindshare.mindshare_user u
        ON u.x_id = us.x_id
    LEFT JOIN user_content_scores ucs
        ON ucs.x_id = us.x_id
    LEFT JOIN user_duration_p90 udp
        ON udp.x_id = us.x_id
),

engagement_stream AS (
    SELECT
        ws.x_id AS root_user_id,
        root_post_id,
        mve.engaged_user_id,
        mve.engaged_user_score,
        mve.is_engaged_reply
    FROM with_scores ws
    LEFT JOIN analytics.%I mve
        ON mve.root_user_id = ws.x_id
       AND mve.is_root_reply = false
       AND mve.is_engaged_reply = true
       AND mve.engaged_tweet_id IS NOT NULL
       AND mve.root_tweet_created_at BETWEEN to_timestamp($2) AND to_timestamp($3)
       AND mve.engaged_tweet_created_at BETWEEN to_timestamp($2) AND to_timestamp($3)
       AND mve.engaged_user_id != ws.x_id
),

unique_engagers AS (
    SELECT
        root_user_id,
        engaged_user_id,
        MAX(engaged_user_score) AS unique_engager_score
    FROM engagement_stream
    WHERE engaged_user_id IS NOT NULL
    GROUP BY root_user_id, engaged_user_id
),

post_level_unique_engager AS (
    SELECT DISTINCT ON (root_post_id, engaged_user_id)
        root_post_id,
        root_user_id,
        engaged_user_score
    FROM engagement_stream
),

reach_cte AS (
    SELECT
        root_user_id,
        SUM(engaged_user_score) AS reach
    FROM post_level_unique_engager
    GROUP BY root_user_id
),

engagement_totals AS (
    SELECT
        root_user_id,
        COUNT(*) FILTER (WHERE is_engaged_reply) AS replies_on_users_posts
    FROM engagement_stream
    GROUP BY root_user_id
),

unique_totals AS (
    SELECT
        root_user_id,

        COUNT(engaged_user_id) AS unique_engager_count,
        SUM(unique_engager_score) AS unique_reach,

        percentile_cont(0.5)
            WITHIN GROUP (ORDER BY unique_engager_score)
            AS median_unique_engagers_score,

        AVG(unique_engager_score) AS average_unique_engagers_score

    FROM unique_engagers
    GROUP BY root_user_id
),

valid_posts AS (
    SELECT
        root_post_id AS post_id,
        root_user_id AS handle
    FROM post_level_unique_engager
    GROUP BY root_post_id, root_user_id
),

unique_contributions AS (
    SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id)
        cs.original_post_id as post_id,
        vp.handle,
        cs.contribution_score
    FROM mindshare_score.contribution_scores cs
    JOIN valid_posts vp
        ON vp.post_id = cs.original_post_id
    WHERE cs.post_created_at BETWEEN to_timestamp($2) AND to_timestamp($3)
      AND cs.replier_x_id <> cs.original_author_x_id
      AND cs.project_keyword = $1
    ORDER BY
        cs.original_post_id,
        cs.replier_x_id,
        cs.post_created_at ASC
),

post_scores AS (
    SELECT
    	uc.post_id,
        uc.handle,
        SUM(uc.contribution_score)::NUMERIC AS post_smart_reach,
        SUM(uc.contribution_score)::NUMERIC * (COALESCE(mp.content_score , 100) / 100) AS post_score
    FROM unique_contributions uc
    JOIN mindshare.mindshare_post mp
       ON mp.post_id = uc.post_id
       AND mp.project_keyword = $1
    GROUP BY uc.post_id, uc.handle, mp.content_score
),

user_post_scores AS (
    SELECT
        handle,
        SUM(post_smart_reach)::NUMERIC AS smart_reach,
        SUM(post_score)::NUMERIC AS user_post_score
    FROM post_scores
    GROUP BY handle
),

user_analytics AS (
    SELECT
        ws.x_id,
        ws.x_username,
        ws.x_score,
        ws.engagements + COALESCE(et.replies_on_users_posts, 0) AS engagements,
        ws.likes,
        COALESCE(et.replies_on_users_posts, 0) AS replies,
        ws.retweets,
        CASE
            WHEN COALESCE(et.replies_on_users_posts, 0) = 0 THEN 0
            ELSE ROUND(ws.likes::numeric / et.replies_on_users_posts, 2)
        END AS like_reply_ratio,
        ws.post_count,
        ws.quote_post_count,
        ws.replies_count,
        ws.post_view_count,
        ws.quote_view_count,
        ws.replies_view_count,
        COALESCE(ut.unique_engager_count, 0) AS unique_engager,
        ROUND(ut.median_unique_engagers_score::numeric, 2) AS median_unique_engager_score,
        ROUND(ut.average_unique_engagers_score::numeric, 2) AS avg_unique_engager_score,
        ut.unique_reach,
        rc.reach,
        COALESCE(ups.smart_reach, 0) AS smart_reach,
        ROUND(ws.avg_content_score, 2) AS avg_content_score,
        ROUND(ws.average_p90, 2) AS average_p90,
        ROUND(
            COALESCE(ups.user_post_score, 0)
            + ((COALESCE(ws.post_count, 0) + COALESCE(ws.quote_post_count, 0)) * COALESCE(NULLIF(ws.x_score, 0), 0.01))
            + (COALESCE(ws.replies_count, 0) * COALESCE(NULLIF(ws.x_score, 0), 0.01) / 100),
            3
        ) AS mindshare_score
    FROM with_scores ws
    LEFT JOIN unique_totals ut
        ON ut.root_user_id = ws.x_id
    LEFT JOIN engagement_totals et
        ON et.root_user_id = ws.x_id
    LEFT JOIN reach_cte rc
        ON rc.root_user_id = ws.x_id
    LEFT JOIN user_post_scores ups
        ON  ups.handle  = ws.x_id
),

user_analytics_with_rank AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY mindshare_score DESC) AS user_rank
    FROM user_analytics
)

SELECT
    pt.total_unique_engaged_users,
    pt.total_post_count,
    pt.total_quote_post_count,
    pt.total_replies_count,
    pt.total_post_view_count,
    pt.total_quote_post_view_count,
    pt.total_replies_view_count,
    (pt.total_post_view_count + pt.total_quote_post_view_count + pt.total_replies_view_count) AS total_view_count,
    cst.community_score,
    ua.project_analytics
FROM project_totals pt
CROSS JOIN community_score_total cst
CROSS JOIN LATERAL (
    SELECT COALESCE(jsonb_agg(project_analytics), '[]'::jsonb) AS project_analytics
    FROM (
        SELECT
            jsonb_build_object(
                'x_id', x_id,
                'x_username', x_username,
                'x_score', x_score,
                'engagements', engagements,
                'likes', likes,
                'replies', replies,
                'retweets', retweets,
                'like_to_reply_ratio', like_reply_ratio,
                'contributions', jsonb_build_object(
                    'post_count', post_count,
                    'quote_post_count', quote_post_count,
                    'replies_count', replies_count
                ),
                'views', jsonb_build_object(
                    'post_view_count', post_view_count,
                    'quote_post_view_count', quote_view_count,
                    'replies_view_count', replies_view_count
                ),
                'unique_engagers_count', unique_engager,
                'median_unique_engagers_score', median_unique_engager_score,
                'average_unique_engagers_score', avg_unique_engager_score,
                'average_content_score', avg_content_score,
                'average_p90', average_p90,
                'unique_reach', unique_reach,
                'reach', reach,
                'smart_reach', smart_reach,
                'mindshare_score', mindshare_score,
				'rank', user_rank
            ) AS project_analytics
        FROM user_analytics_with_rank
		ORDER BY %s DESC NULLS LAST
		LIMIT 1100
    )
) ua
$q$, filter_by_user, features_view_name, view_name, order_clause);

RETURN QUERY EXECUTE sql_query USING projectname, startdate, enddate, private_user_ids;

END;
$function$
;