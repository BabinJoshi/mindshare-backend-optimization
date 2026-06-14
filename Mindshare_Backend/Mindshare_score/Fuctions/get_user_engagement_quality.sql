-- DROP FUNCTION mindshare_score.get_user_engagement_quality(_text);

CREATE OR REPLACE FUNCTION mindshare_score.get_user_engagement_quality(p_user_ids text[])
 RETURNS TABLE(handle text, username character varying, score numeric, unique_reach numeric, engagement_flag_count bigint, botting_flag_count bigint, total_posts bigint)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query TEXT;
BEGIN

sql_query := format($q$
WITH user_all_posts AS (
    SELECT DISTINCT ON (post_id, user_x_id)
        post_id, user_x_id, favorite_count, view_count,
        post_created_at, updated_at, is_post, is_quote, is_reply
    FROM mindshare.nucleus_post
    WHERE user_x_id = ANY($1)
        AND (is_post OR (is_quote AND NOT is_reply))
        AND is_reply_fetched
    ORDER BY post_id, user_x_id, updated_at DESC
),

user_posts AS (
    SELECT
        up.post_id AS root_post_id,
        up.user_x_id AS root_user_id,
        up.favorite_count AS root_favorite_count,
        up.view_count AS root_post_view_count,
        up.post_created_at,
        up.is_post,
        up.is_quote,
        up.is_reply
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY user_x_id
                ORDER BY post_created_at DESC
            ) AS rn
        FROM user_all_posts
    ) up
    WHERE rn <= 50
),

base_users AS (
    SELECT
        x_id  AS user_id,
        COALESCE(x_username, '') AS username,
        COALESCE(score, 0::NUMERIC) AS score
    FROM mindshare.mindshare_user
    WHERE x_id = ANY($1)
),

post_counts AS (
    SELECT
        root_user_id,
        COUNT(root_post_id) AS total_posts
    FROM user_posts
    GROUP BY root_user_id
),

all_engagement_posts AS (
    SELECT post_id, user_x_id, replied_post_id, is_reply, updated_at
    FROM mindshare.nucleus_post
    WHERE replied_post_id IN (SELECT root_post_id FROM user_posts)
),

deduplicated_engagement_posts AS (
    SELECT DISTINCT ON (post_id)
        post_id, user_x_id, replied_post_id, is_reply
    FROM all_engagement_posts
    ORDER BY post_id, updated_at DESC
),

engagements AS (
    SELECT
        up.root_post_id,
        up.root_user_id,
        up.root_favorite_count,
        up.root_post_view_count,
        e.user_x_id AS engaged_user_id,
        e.is_reply,
        eu.score AS engaged_user_score
    FROM user_posts up
    LEFT JOIN deduplicated_engagement_posts e
        ON e.replied_post_id = up.root_post_id
        AND e.user_x_id <> up.root_user_id
    LEFT JOIN mindshare.mindshare_user eu
        ON e.user_x_id = eu.x_id
),

unique_engagers_to_user AS (
    SELECT
        root_user_id,
        engaged_user_id,
        MAX(engaged_user_score) AS engager_score
    FROM engagements
    GROUP BY root_user_id, engaged_user_id
),

unique_reach_cte AS (
    SELECT
        root_user_id,
        SUM(engager_score)::NUMERIC AS unique_reach
    FROM unique_engagers_to_user
    GROUP BY root_user_id
),

unique_engagements_to_posts AS (
    SELECT DISTINCT ON (root_post_id, engaged_user_id)
        root_post_id,
        root_user_id,
        engaged_user_id,
        engaged_user_score,
        root_favorite_count,
        root_post_view_count
    FROM engagements
),

replies AS (
    SELECT
        root_post_id,
        COUNT(*) FILTER (WHERE is_reply) AS replies_on_post
    FROM engagements
    GROUP BY root_post_id
),

post_metrics AS (
    SELECT
        ue.root_post_id,
        ue.root_user_id,
        COUNT(engaged_user_id) AS unique_engagers,
        COALESCE(SUM(ue.engaged_user_score),0)::NUMERIC AS post_unique_reach,
        MAX(ue.root_favorite_count)::INT AS total_likes,
        MAX(ue.root_post_view_count)::INT AS total_views
    FROM unique_engagements_to_posts ue
    GROUP BY
        ue.root_post_id,
        ue.root_user_id
),

ratios AS (
    SELECT
        pm.root_post_id AS post_id,
        pm.root_user_id AS handle,
        pm.post_unique_reach,
        pm.total_views::BIGINT AS total_impressions,

        CASE
            WHEN pm.post_unique_reach = 0 THEN NULL
            ELSE ROUND(pm.total_views::NUMERIC / pm.post_unique_reach, 2)
        END AS impression_to_unique_reach_ratio,

        pm.total_likes,
        COALESCE(r.replies_on_post, 0) AS total_replies,

        CASE
            WHEN COALESCE(r.replies_on_post, 0) = 0 THEN NULL
            ELSE ROUND(pm.total_likes::NUMERIC / r.replies_on_post, 2)
        END AS like_reply_ratio,

        pm.unique_engagers,

        CASE
            WHEN COALESCE(pm.unique_engagers, 0) = 0 THEN NULL
            ELSE ROUND(pm.post_unique_reach / pm.unique_engagers, 2)
        END AS unique_engager_scores_to_count_ratio

    FROM post_metrics pm
    JOIN replies r
        ON r.root_post_id = pm.root_post_id
),

flags AS (
    SELECT
        r.post_id,
        r.handle,

        -- LIKE / REPLY FLAGS
        CASE
            WHEN r.total_replies >= 10
                 AND r.like_reply_ratio < 1.7
            THEN TRUE ELSE FALSE
        END AS like_reply_engagement_farming_flag,

        CASE
            WHEN r.total_replies >= 10
                 AND r.like_reply_ratio > 20
            THEN TRUE ELSE FALSE
        END AS like_reply_botting_flag,

        -- UNIQUE REACH / IMPRESSION FLAGS
        CASE
            WHEN r.impression_to_unique_reach_ratio IS NOT NULL
                 AND r.impression_to_unique_reach_ratio < 1
            THEN TRUE ELSE FALSE
        END AS impression_unique_reach_engagement_farming_flag,

        CASE
            WHEN r.impression_to_unique_reach_ratio IS NOT NULL
                 AND r.impression_to_unique_reach_ratio >
                     CASE
                         WHEN COALESCE(mu.score, 0) > 2000 THEN 15
                         ELSE 5
                     END
            THEN TRUE ELSE FALSE
        END AS impression_unique_reach_botting_flag

    FROM ratios r
    LEFT JOIN mindshare.mindshare_user mu
        ON mu.x_id = r.handle
),

count_flags AS (
    SELECT
        f.handle,
        u.unique_reach,

        SUM(
            CASE
                WHEN f.like_reply_engagement_farming_flag
                  OR f.impression_unique_reach_engagement_farming_flag
                THEN 1 ELSE 0
            END
        ) AS engagement_flag_count,

        SUM(
            CASE
                WHEN f.like_reply_botting_flag
                  OR f.impression_unique_reach_botting_flag
                THEN 1 ELSE 0
            END
        ) AS botting_flag_count,

        pc.total_posts

    FROM flags f
    LEFT JOIN unique_reach_cte u
        ON u.root_user_id = f.handle
    LEFT JOIN post_counts pc
        ON pc.root_user_id = f.handle
    GROUP BY f.handle, u.unique_reach, pc.total_posts
)

-- Final: LEFT JOIN count_flags onto base_users
-- so reply-only users still appear with zeroed-out metrics
SELECT
    bu.user_id::TEXT AS handle,
    bu.username::VARCHAR AS username,
    bu.score::NUMERIC AS score,
    COALESCE(cf.unique_reach, 0)::NUMERIC AS unique_reach,
    COALESCE(cf.engagement_flag_count, 0)::BIGINT AS engagement_flag_count,
    COALESCE(cf.botting_flag_count, 0)::BIGINT AS botting_flag_count,
    COALESCE(cf.total_posts, 0)::BIGINT AS total_posts
FROM base_users bu
LEFT JOIN count_flags cf
    ON cf.handle = bu.user_id
$q$);

RETURN QUERY EXECUTE sql_query USING p_user_ids;

END;
$function$
;