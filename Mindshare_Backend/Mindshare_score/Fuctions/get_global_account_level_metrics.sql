-- DROP FUNCTION mindshare_score.get_global_account_level_metrics(int8, int8);

CREATE OR REPLACE FUNCTION mindshare_score.get_global_account_level_metrics(startdate bigint, enddate bigint)
 RETURNS TABLE(handle text, username character varying, score numeric, post_count bigint, smart_reach numeric, mindshare_score numeric, account_unique_reach numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN

RETURN QUERY

WITH

------------------------------------------------------
-- SHARED BASE: pure reply engagements from user_post
-- Excludes retweets, quotes, and self-replies.
-- Root posts must be original posts only.
------------------------------------------------------
engagements AS (
    SELECT
        root_up.post_id          AS root_post_id,
        root_up.user_x_id        AS root_user_id,
        root_u.x_username        AS root_username,
        reply_up.user_x_id       AS engaged_user_id,
        reply_u.score            AS engaged_user_score,
        reply_up.favorite_count  AS root_favorite_count,
        root_up.reply_count      AS root_reply_count
    FROM mindshare.user_post reply_up
    JOIN mindshare.user_post root_up
        ON root_up.post_id = reply_up.root_post_id
    JOIN mindshare.mindshare_user root_u
        ON root_u.x_id = root_up.user_x_id
    JOIN mindshare.mindshare_user reply_u
        ON reply_u.x_id = reply_up.user_x_id
    WHERE reply_up.post_created_at  BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND root_up.post_created_at   BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND reply_up.is_reply   = TRUE
      AND reply_up.is_retweet = FALSE
      AND reply_up.is_quote   = FALSE
      AND root_up.is_post     = TRUE
      AND root_up.is_retweet  = FALSE
      AND root_up.is_quote    = FALSE
      AND root_up.user_x_id  != reply_up.user_x_id
),

------------------------------------------------------
-- ACCOUNT UNIQUE REACH
------------------------------------------------------
unique_engagers AS (
    SELECT
        root_user_id,
        engaged_user_id,
        MAX(engaged_user_score) AS max_engager_score
    FROM engagements
    GROUP BY root_user_id, engaged_user_id
),

account_unique_reach_cte AS (
    SELECT
        root_user_id,
        SUM(max_engager_score)::NUMERIC AS account_unique_reach
    FROM unique_engagers
    GROUP BY root_user_id
),

------------------------------------------------------
-- POST COUNT + VALID POSTS
------------------------------------------------------
unique_engagements_per_post AS (
    SELECT DISTINCT ON (root_post_id, engaged_user_id)
        root_post_id,
        root_user_id,
        root_username,
        engaged_user_score,
        root_favorite_count,
        root_reply_count
    FROM engagements
),

post_metrics AS (
    SELECT
        ue.root_post_id,
        ue.root_user_id,
        ue.root_username,
        COUNT(*)                            AS unique_engagers,
        SUM(ue.engaged_user_score)::NUMERIC AS post_unique_reach,
        MAX(ue.root_favorite_count)::INT    AS total_likes
    FROM unique_engagements_per_post ue
    GROUP BY ue.root_post_id, ue.root_user_id, ue.root_username
),

valid_posts AS (
    SELECT
        pm.root_post_id  AS post_id,
        pm.root_user_id  AS user_x_id,
        pm.root_username AS root_username
    FROM post_metrics pm
),

post_count_cte AS (
    SELECT
        user_x_id,
        root_username,
        COUNT(*) AS post_count
    FROM valid_posts
    GROUP BY user_x_id, root_username
),

------------------------------------------------------
-- SMART REACH
------------------------------------------------------
unique_contributions AS (
    SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id)
        vp.user_x_id,
        cs.contribution_score
    FROM mindshare_score.contribution_scores cs
    JOIN valid_posts vp
        ON vp.post_id = cs.original_post_id
    WHERE cs.post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND cs.replier_x_id <> cs.original_author_x_id
    ORDER BY
        cs.original_post_id,
        cs.replier_x_id,
        cs.post_created_at ASC
),

smart_reach_cte AS (
    SELECT
        user_x_id,
        SUM(contribution_score)::NUMERIC AS smart_reach
    FROM unique_contributions
    GROUP BY user_x_id
)

------------------------------------------------------
-- FINAL JOIN
------------------------------------------------------
SELECT
    a.root_user_id                                          AS handle,
    u.x_username                                            AS username,
    u.score,
    COALESCE(pc.post_count,  0)                             AS post_count,
    COALESCE(sr.smart_reach, 0)                             AS smart_reach,
    ROUND(
        COALESCE(sr.smart_reach, 0)
        + (COALESCE(pc.post_count, 0) * COALESCE(u.score, 0)),
        3
    )                                                       AS mindshare_score,
    COALESCE(a.account_unique_reach, 0)                     AS account_unique_reach

FROM account_unique_reach_cte a
LEFT JOIN post_count_cte pc
    ON  pc.user_x_id    = a.root_user_id
LEFT JOIN smart_reach_cte sr
    ON  sr.user_x_id    = a.root_user_id
LEFT JOIN mindshare.mindshare_user u
    ON  u.x_id          = a.root_user_id

ORDER BY mindshare_score DESC NULLS LAST;

END;
$function$
;