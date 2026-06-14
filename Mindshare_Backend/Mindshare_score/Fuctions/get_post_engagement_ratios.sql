-- DROP FUNCTION mindshare_score.get_post_engagement_ratios(int8, int8, text);

CREATE OR REPLACE FUNCTION mindshare_score.get_post_engagement_ratios(startdate bigint, enddate bigint, projectname text)
 RETURNS TABLE(post_id text, handle text, username character varying, post_unique_reach numeric, total_impressions bigint, reach_to_impression_ratio numeric, total_likes integer, total_replies bigint, like_reply_ratio numeric, unique_engagers bigint, unique_engager_scores_to_count_ratio numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
	sql_query TEXT;
	view_name text := 'mv_engagement_' || lower(replace(projectName, ' ', '_'));
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
		AND root_tweet_created_at   BETWEEN to_timestamp($1) AND to_timestamp($2)
		AND is_root_reply = FALSE
		and root_user_id != engaged_user_id
),
unique_engagements as (
	select DISTINCT ON (root_post_id, engaged_user_id)
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
    SELECT ue.root_post_id,
           ue.root_user_id,
           ue.root_username,
		   COUNT(*) AS unique_engagers,
           SUM(ue.engaged_user_score)::NUMERIC AS post_unique_reach,
           MAX(ue.root_favorite_count)::INT AS total_likes
    FROM unique_engagements ue
    GROUP BY ue.root_post_id, ue.root_user_id, ue.root_username
)
SELECT
    pm.root_post_id AS post_id,
    pm.root_user_id AS handle,
	pm.root_username as username,
    pm.post_unique_reach,
    p.view_count::BIGINT AS total_impressions,
    CASE
        WHEN p.view_count = 0 THEN NULL
        ELSE ROUND(pm.post_unique_reach / p.view_count::NUMERIC, 4)
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
JOIN mindshare.mindshare_post p
    ON p.post_id = pm.root_post_id
   AND p.project_keyword = $3 
ORDER BY pm.post_unique_reach DESC
$q$,
view_name);

return query execute sql_query using startDate, endDate, projectName;

end;
$function$
;