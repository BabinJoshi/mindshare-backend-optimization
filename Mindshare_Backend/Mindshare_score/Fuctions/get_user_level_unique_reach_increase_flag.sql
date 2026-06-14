-- DROP FUNCTION mindshare_score.get_user_level_unique_reach_increase_flag(int8, int8, text);

CREATE OR REPLACE FUNCTION mindshare_score.get_user_level_unique_reach_increase_flag(startdate bigint, enddate bigint, projectname text)
 RETURNS TABLE(handle text, username character varying, total_posts bigint, final_cumulative_reach numeric, early_spike_ratio numeric, growth_slope double precision, avg_expansion numeric, growth_variability numeric, max_spike_ratio numeric, esr_flag integer, gs_flag integer, gv_flag integer, msr_flag integer, farming_score integer, farming_flag text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query TEXT;
BEGIN

sql_query := $q$
WITH user_post_growth AS (
    select
		*
	from mindshare_score.get_unique_reach_increase($1, $2, $3)
),

post_level_growth AS (
    SELECT
        handle,
        username,
        root_post_id,
        post_sequence_number,
        expansion_unique_reach,
        cumulative_expansion_unique_reach,
        COUNT(*) OVER (PARTITION BY handle) AS total_posts_per_user
    FROM user_post_growth
),

user_metrics AS (
    SELECT
        handle,
        username,

        COUNT(*) AS total_posts,

        MAX(cumulative_expansion_unique_reach) AS final_cumulative_reach,

        -- Early Spike Ratio (first 2 posts)
        SUM(
            CASE
                WHEN post_sequence_number <= 2
                THEN expansion_unique_reach
                ELSE 0
            END
        )
        /
        NULLIF(MAX(cumulative_expansion_unique_reach), 0)
        AS early_spike_ratio,

        -- Growth Slope (linear regression)
        REGR_SLOPE(
            cumulative_expansion_unique_reach,
            post_sequence_number
        ) AS growth_slope,

        -- Avg expansion per post
        AVG(expansion_unique_reach) AS avg_expansion,

        -- Growth Variability (stddev of expansion)
        STDDEV(expansion_unique_reach) AS growth_variability,

        -- Max Spike Ratio
        MAX(expansion_unique_reach)
        /
        NULLIF(AVG(expansion_unique_reach), 0)
        AS max_spike_ratio

    FROM post_level_growth
    GROUP BY handle, username
),

scored_users AS (
    SELECT
        *,

        -- ESR flag (> 50%)
        CASE
            WHEN early_spike_ratio > 0.5 THEN 1
            ELSE 0
        END AS esr_flag,

        -- GS flag (slope too small relative to avg expansion)
        CASE
            WHEN growth_slope < (0.1 * avg_expansion)
            THEN 1
            ELSE 0
        END AS gs_flag,

        -- GV flag (stddev > 2x average expansion)
        CASE
            WHEN growth_variability > (2 * avg_expansion)
            THEN 1
            ELSE 0
        END AS gv_flag,

        -- MSR flag (>5x average)
        CASE
            WHEN max_spike_ratio > 5
            THEN 1
            ELSE 0
        END AS msr_flag

    FROM user_metrics
    WHERE total_posts >= 5   -- minimum activity threshold
)

SELECT
    *,
    (esr_flag + gs_flag + gv_flag + msr_flag) AS farming_score,

    CASE
        WHEN (esr_flag + gs_flag + gv_flag + msr_flag) >= 2
        THEN 'potential_engagement_farming'
        ELSE 'organic'
    END AS farming_flag

FROM scored_users
ORDER BY farming_score DESC
$q$;

RETURN QUERY EXECUTE sql_query USING startdate, enddate, projectName;

END;
$function$
;