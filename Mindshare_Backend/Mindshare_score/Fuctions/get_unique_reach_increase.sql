-- DROP FUNCTION mindshare_score.get_unique_reach_increase(int8, int8, text);

CREATE OR REPLACE FUNCTION mindshare_score.get_unique_reach_increase(startdate bigint, enddate bigint, projectname text)
 RETURNS TABLE(handle text, username character varying, root_post_id text, root_tweet_created_at timestamp with time zone, post_sequence_number bigint, total_engagements bigint, post_unique_reach numeric, expansion_unique_reach numeric, new_audience_count bigint, cumulative_new_audience_count numeric, cumulative_expansion_unique_reach numeric)
 LANGUAGE plpgsql
AS $function$
DECLARE
    table_name TEXT;
    sql_query  TEXT;
BEGIN
    table_name := 'analytics.mv_engagement_' || LOWER(projectname);

    sql_query := FORMAT(
$q$
WITH user_posts as (
	select
		mp.post_id,
		mp.user_x_id,
		mu.x_username,
		mp.post_created_at,
		 ROW_NUMBER() OVER (
            PARTITION BY mp.user_x_id
            ORDER BY mp.post_created_at, mp.post_id
        ) AS post_seq
	from mindshare.mindshare_post mp
	LEFT JOIN mindshare.mindshare_user mu
		on mu.x_id = mp.user_x_id
	WHERE mp.post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
        AND	mp.project_keyword = $3
      	AND (mp.is_post = TRUE OR (mp.is_quote = TRUE AND mp.is_reply = FALSE))
      	AND mp.user_x_id != ''
),

unique_engagements AS (
    select DISTINCT ON (up.post_id, mve.engaged_user_id)
		up.post_id as root_post_id,
        up.user_x_id as root_user_id,
        up.x_username as root_username,
        up.post_created_at as root_tweet_created_at,
        up.post_seq,
        mve.engaged_user_id,
        mve.engaged_user_score
    FROM user_posts up
    LEFT JOIN %s mve
        ON mve.root_post_id = up.post_id
       AND mve.is_engaged_reply = true
       AND mve.engaged_tweet_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
       AND mve.engaged_user_id != up.user_x_id
),

audience_marked AS (
    SELECT
        ue.*,
        CASE
            WHEN ue.engaged_user_id IS NOT NULL
            	AND ue.post_seq =
                	MIN(ue.post_seq) OVER (
                    	PARTITION BY ue.root_user_id, ue.engaged_user_id
	                )
            THEN TRUE
            ELSE FALSE
        END AS is_new_audience
    FROM unique_engagements ue
),

post_metrics AS (
    SELECT
        am.root_user_id      AS handle,
        am.root_username     AS username,
        am.root_post_id,
        am.root_tweet_created_at,
        am.post_seq,

        COUNT(am.engaged_user_id) AS total_engagements,

        SUM(am.engaged_user_score) AS post_unique_reach,

        SUM(
            CASE
                WHEN am.is_new_audience = TRUE THEN am.engaged_user_score
                ELSE 0
            END
        ) AS expansion_unique_reach,

        COUNT(
            CASE
                WHEN am.is_new_audience = TRUE THEN 1
            END
        ) AS new_audience_count
    FROM audience_marked am
    GROUP BY
        am.root_post_id,
        am.root_user_id,
        am.root_username,
        am.root_tweet_created_at,
        am.post_seq
)

SELECT
    handle,
    username,
    root_post_id,
    root_tweet_created_at,
    post_seq,
    total_engagements,
    post_unique_reach,
    expansion_unique_reach,
    new_audience_count,
    SUM(new_audience_count) OVER (
        PARTITION BY handle
        ORDER BY post_seq
    ) AS cumulative_new_audience_count,
    SUM(expansion_unique_reach) OVER (
        PARTITION BY handle
        ORDER BY post_seq
    ) AS cumulative_expansion_unique_reach
FROM post_metrics
ORDER BY
    handle,
    root_tweet_created_at DESC
$q$,
        table_name
    );

    RETURN QUERY EXECUTE sql_query USING startdate, enddate, projectname;

END;
$function$
;