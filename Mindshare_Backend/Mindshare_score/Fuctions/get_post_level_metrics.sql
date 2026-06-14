-- DROP FUNCTION mindshare_score.get_post_level_metrics(int8, int8, text);

CREATE OR REPLACE FUNCTION mindshare_score.get_post_level_metrics(startdate bigint, enddate bigint, projectname text)
 RETURNS TABLE(post_id text, handle text, username character varying, post_unique_reach numeric, total_impressions bigint, total_likes integer, total_replies bigint, unique_engagers bigint, smart_reach numeric, like_reply_ratio numeric, impression_to_unique_reach_ratio numeric, unique_engager_scores_to_count_ratio numeric, like_reply_engagement_farming_flag boolean, like_reply_botting_flag boolean, impression_unique_reach_engagement_farming_flag boolean, impression_unique_reach_botting_flag boolean)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query TEXT;
    view_name text := 'mv_engagement_' || lower(replace(projectname, ' ', '_'));
BEGIN

sql_query := format($q$

WITH engagements AS (
    SELECT
        root_post_id,
        root_user_id,
        root_username,
        engaged_user_id,
        engaged_user_score,
        is_engaged_reply,
        root_favorite_count,
        root_reply_count
    FROM analytics.%I
    WHERE engaged_tweet_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND root_tweet_created_at    BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND is_root_reply   = FALSE
      AND is_engaged_reply = TRUE
      AND root_user_id   != engaged_user_id
),

unique_engagements AS (
    SELECT DISTINCT ON (root_post_id, engaged_user_id)
        root_post_id,
        root_user_id,
        root_username,
        engaged_user_score,
        root_favorite_count,
        root_reply_count
    FROM engagements
),

replies AS (
    SELECT
        root_post_id,
        COUNT(*) FILTER (WHERE is_engaged_reply) AS replies_on_post
    FROM engagements
    GROUP BY root_post_id
),

post_metrics AS (
    SELECT
        ue.root_post_id,
        ue.root_user_id,
        ue.root_username,
        COUNT(*)                            AS unique_engagers,
        SUM(ue.engaged_user_score)::NUMERIC AS post_unique_reach,
        MAX(ue.root_favorite_count)::INT    AS total_likes
    FROM unique_engagements ue
    GROUP BY ue.root_post_id, ue.root_user_id, ue.root_username
),

ratio_data AS (
    SELECT
        pm.root_post_id                                             AS post_id,
        pm.root_user_id                                             AS handle,
        pm.root_username                                            AS username,
        pm.post_unique_reach,
        p.view_count::BIGINT                                        AS total_impressions,
        CASE
            WHEN pm.post_unique_reach = 0 THEN NULL
            ELSE ROUND(p.view_count::NUMERIC / pm.post_unique_reach, 2)
        END                                                         AS impression_to_unique_reach_ratio,
        pm.total_likes,
        COALESCE(r.replies_on_post, 0)                              AS total_replies,
        CASE
            WHEN COALESCE(r.replies_on_post, 0) = 0 THEN NULL
            ELSE ROUND(pm.total_likes::NUMERIC / r.replies_on_post, 2)
        END                                                         AS like_reply_ratio,
        pm.unique_engagers,
        CASE
            WHEN COALESCE(pm.unique_engagers, 0) = 0 THEN NULL
            ELSE ROUND(pm.post_unique_reach / pm.unique_engagers, 2)
        END                                                         AS unique_engager_scores_to_count_ratio
    FROM post_metrics pm
    JOIN replies r
        ON r.root_post_id = pm.root_post_id
    JOIN mindshare.mindshare_post p
        ON p.post_id        = pm.root_post_id
       AND p.project_keyword = $3
),

unique_engager AS (
    SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id)
        cs.original_post_id,
        cs.contribution_score
    FROM mindshare_score.contribution_scores cs
    WHERE EXISTS (SELECT 1 FROM ratio_data rd WHERE rd.post_id = cs.original_post_id)
      AND cs.post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
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
    FROM unique_engager
    GROUP BY original_post_id
)

SELECT
    r.post_id,
    r.handle,
    r.username,
    r.post_unique_reach,
    r.total_impressions,
    r.total_likes,
    r.total_replies,
    r.unique_engagers,
    sr.smart_reach,
    r.like_reply_ratio,
    r.impression_to_unique_reach_ratio,
    r.unique_engager_scores_to_count_ratio,

    -- LIKE / REPLY FLAGS
    CASE
        WHEN r.total_replies >= 10 AND r.like_reply_ratio < 1.7 THEN TRUE
        ELSE FALSE
    END AS like_reply_engagement_farming_flag,

    CASE
        WHEN r.total_replies >= 10 AND r.like_reply_ratio > 20  THEN TRUE
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
                 CASE WHEN u.score > 2000 THEN 15 ELSE 5 END
        THEN TRUE
        ELSE FALSE
    END AS impression_unique_reach_botting_flag

FROM ratio_data r
LEFT JOIN mindshare.mindshare_user u
    ON r.handle = u.x_id
LEFT JOIN smart_reach_cte sr
    ON sr.original_post_id = r.post_id
ORDER BY r.post_unique_reach DESC

$q$, view_name);

RETURN QUERY EXECUTE sql_query USING startdate, enddate, projectname;

END;
$function$
;