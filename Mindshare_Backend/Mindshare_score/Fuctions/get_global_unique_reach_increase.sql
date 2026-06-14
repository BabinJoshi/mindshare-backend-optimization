-- DROP FUNCTION mindshare_score.get_global_unique_reach_increase(int8, int8);

CREATE OR REPLACE FUNCTION mindshare_score.get_global_unique_reach_increase(startdate bigint, enddate bigint)
 RETURNS TABLE(handle text, username character varying, root_post_id text, root_tweet_created_at timestamp with time zone, post_sequence_number bigint, total_engagements bigint, post_unique_reach numeric, expansion_unique_reach numeric, new_audience_count bigint, cumulative_new_audience_count numeric, cumulative_expansion_unique_reach numeric)
 LANGUAGE plpgsql
AS $function$
DECLARE
    sql_query  TEXT;
BEGIN
    sql_query := FORMAT(
$q$
WITH user_posts AS (
	SELECT
        post_id         AS root_post_id,
        user_x_id       AS root_user_id,
		u.x_username    AS root_username,
        post_created_at
    FROM mindshare.user_post
	left join mindshare.mindshare_user u on u.x_id = user_x_id
    WHERE post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND (is_post = TRUE OR (is_quote = TRUE AND is_reply = FALSE))
),

unique_engagements AS (
    SELECT DISTINCT ON (up.root_post_id, e.user_x_id)
        up.root_post_id,
        up.root_user_id,
		up.root_username,
		up.post_created_at as root_tweet_created_at,
        e.user_x_id    AS engaged_user_id,
		u.score AS engaged_user_score
    FROM user_posts up
    LEFT JOIN mindshare.user_post e
           ON e.replied_post_id = up.root_post_id
		  AND e.post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
	      AND e.user_x_id != up.root_user_id
	LEFT join mindshare.mindshare_user u on u.x_id = e.user_x_id
),

post_sequence AS (
    SELECT
        root_user_id,
        root_post_id,
        root_tweet_created_at,
        ROW_NUMBER() OVER (
            PARTITION BY root_user_id
            ORDER BY root_tweet_created_at, root_post_id
        ) AS post_seq
    FROM unique_engagements
    GROUP BY
        root_user_id,
        root_post_id,
        root_tweet_created_at
),

sequenced_engagements AS (
    SELECT
        ue.*,
        ps.post_seq
    FROM unique_engagements ue
    JOIN post_sequence ps
      ON ue.root_user_id = ps.root_user_id
     AND ue.root_post_id = ps.root_post_id
),

first_audience_touch AS (
    SELECT
        root_user_id,
        engaged_user_id,
        MIN(post_seq) AS first_post_seq
    FROM sequenced_engagements
    GROUP BY
        root_user_id,
        engaged_user_id
),

audience_marked AS (
    SELECT
        se.*,
        CASE
            WHEN se.post_seq = fat.first_post_seq THEN TRUE
            ELSE FALSE
        END AS is_new_audience
    FROM sequenced_engagements se
    LEFT JOIN first_audience_touch fat
      ON se.root_user_id = fat.root_user_id
     AND se.engaged_user_id = fat.engaged_user_id
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
$q$
);

    RETURN QUERY EXECUTE sql_query USING startdate, enddate;

END;
$function$
;