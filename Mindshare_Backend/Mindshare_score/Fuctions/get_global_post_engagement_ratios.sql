-- DROP FUNCTION mindshare_score.get_global_post_engagement_ratios(int8, int8);

CREATE OR REPLACE FUNCTION mindshare_score.get_global_post_engagement_ratios(startdate bigint, enddate bigint)
 RETURNS TABLE(post_id text, handle text, username character varying, post_unique_reach numeric, total_impressions bigint, reach_to_impression_ratio numeric, total_likes integer, total_replies bigint, like_reply_ratio numeric, unique_engagers bigint, unique_engager_scores_to_count_ratio numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
	sql_query TEXT;
BEGIN
sql_query := format($q$
WITH user_posts AS (
    SELECT
        post_id         AS root_post_id,
        user_x_id       AS root_user_id,
		u.x_username       AS root_username,
		favorite_count,
		view_count,
        post_created_at
    FROM mindshare.user_post
	left join mindshare.mindshare_user u on u.x_id = user_x_id
    WHERE post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND (is_post = TRUE OR (is_quote = TRUE AND is_reply = FALSE))
),

engagements AS (
    SELECT
		up.root_post_id,
        up.root_user_id,
		up.root_username,
		e.user_x_id as engaged_user_id,
        u.score AS engaged_user_score,
		up.favorite_count AS root_favorite_count,
		up.view_count
   	FROM user_posts up
    JOIN mindshare.user_post e
           ON e.replied_post_id = up.root_post_id
	left join mindshare.mindshare_user u on u.x_id = e.user_x_id
    WHERE e.post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND e.user_x_id != up.root_user_id
),

unique_engagements AS (
    select DISTINCT ON (root_post_id, engaged_user_id)
        root_post_id,
        root_user_id,
		root_username,
        engaged_user_score,
        root_favorite_count,
		view_count
    FROM engagements
),

replies AS (
     SELECT
     	root_post_id,
        COUNT(*) replies_on_post
     FROM engagements
     GROUP BY root_post_id
),

post_metrics AS (
    SELECT ue.root_post_id,
           ue.root_user_id,
           ue.root_username,
		   COUNT(*) AS unique_engagers,
           SUM(ue.engaged_user_score)::NUMERIC AS post_unique_reach,
           MAX(ue.root_favorite_count)::INT AS total_likes,
		   MAX(ue.view_count)::INT AS view_count
    FROM unique_engagements ue
    GROUP BY ue.root_post_id, ue.root_user_id, ue.root_username
)
SELECT
    pm.root_post_id AS post_id,
    pm.root_user_id AS handle,
	pm.root_username as username,
    pm.post_unique_reach,
    pm.view_count::BIGINT AS total_impressions,
    CASE
        WHEN pm.view_count = 0 THEN NULL
        ELSE ROUND(pm.post_unique_reach / pm.view_count::NUMERIC, 4)
    END AS reach_to_impression_ratio,
    pm.total_likes,
    coalesce(r.replies_on_post,0) as total_replies,
    CASE
        WHEN coalesce(r.replies_on_post,0)  = 0 THEN NULL
        ELSE ROUND(pm.total_likes::NUMERIC / r.replies_on_post , 2)
    END AS like_reply_ratio,
	unique_engagers,
	CASE
        WHEN coalesce(unique_engagers,0)  = 0 THEN NULL
        ELSE ROUND(post_unique_reach / unique_engagers , 2)
	END as unique_engager_scores_to_count_ratio
FROM post_metrics pm
JOIN replies r on r.root_post_id = pm.root_post_id
ORDER BY pm.post_unique_reach DESC
$q$
);

return query execute sql_query using startDate, endDate;

end;
$function$
;