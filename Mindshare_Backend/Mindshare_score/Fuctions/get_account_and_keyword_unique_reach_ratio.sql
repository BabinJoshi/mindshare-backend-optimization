-- DROP FUNCTION mindshare_score.get_account_and_keyword_unique_reach_ratio(int8, int8, text);

CREATE OR REPLACE FUNCTION mindshare_score.get_account_and_keyword_unique_reach_ratio(startdate bigint, enddate bigint, projectname text)
 RETURNS TABLE(handle text, username character varying, keyword_unique_reach numeric, account_unique_reach numeric, account_keyword_unique_reach_ratio numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query TEXT;

    view_name TEXT := 'mv_engagement_' || LOWER(REPLACE(projectname,' ','_'));

BEGIN

sql_query := FORMAT($q$

WITH unique_engagements AS (
    SELECT DISTINCT ON (root_user_id, engaged_user_id)
        root_post_id,
        root_username,
        root_user_id,
        engaged_user_score
    FROM analytics.%I
    WHERE is_root_reply = FALSE
      AND root_tweet_created_at   BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND engaged_tweet_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND engaged_user_id != root_user_id
),

keyword_unique_reach_cte AS (
    SELECT
        root_user_id,
        root_username,
        SUM(engaged_user_score)::NUMERIC AS keyword_unique_reach
    FROM unique_engagements
    GROUP BY root_user_id, root_username
),

user_posts AS (
    SELECT
        post_id         AS root_post_id,
        user_x_id       AS root_user_id,
        post_created_at AS root_post_created_at
    FROM mindshare.user_post
    WHERE post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND (is_post = TRUE OR (is_quote = TRUE AND is_reply = FALSE))
),

engagements AS (
    SELECT
        up.root_post_id,
        up.root_user_id,
        e.user_x_id    AS engaged_user_id,
        e.user_x_score AS engaged_user_score
    FROM user_posts up
    LEFT JOIN mindshare.user_post e
           ON e.replied_post_id = up.root_post_id
    WHERE e.post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND e.user_x_id != up.root_user_id
),

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
)

SELECT
    k.root_user_id                                AS handle,
    k.root_username                               AS username,
    COALESCE(k.keyword_unique_reach, 0)           AS keyword_unique_reach,
    COALESCE(a.account_unique_reach, 0)           AS account_unique_reach,

    CASE
        WHEN COALESCE(k.keyword_unique_reach,0) = 0
            THEN NULL
        ELSE
			ROUND(
            	COALESCE(a.account_unique_reach, 0)
            	/ k.keyword_unique_reach,
            	2
        	)
    END AS account_keyword_unique_reach_ratio

FROM keyword_unique_reach_cte k
LEFT JOIN account_unique_reach_cte a
       ON a.root_user_id = k.root_user_id

ORDER BY account_unique_reach DESC NULLS LAST

$q$, view_name);


RETURN QUERY EXECUTE sql_query USING startdate, enddate;

END;
$function$
;