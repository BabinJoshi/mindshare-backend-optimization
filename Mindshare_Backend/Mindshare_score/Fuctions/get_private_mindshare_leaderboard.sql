-- DROP FUNCTION mindshare_score.get_private_mindshare_leaderboard(int8, int8, text, _text, _text);

CREATE OR REPLACE FUNCTION mindshare_score.get_private_mindshare_leaderboard(startdate bigint, enddate bigint, projectname text, p_exclude_list text[] DEFAULT NULL::text[], p_private_user_list text[] DEFAULT NULL::text[])
 RETURNS TABLE(x_user_id text, x_username character varying, x_display_name character varying, x_avatar_url character varying, mindshare_score numeric, mindshare_percent numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query TEXT;
    view_name TEXT := 'mv_engagement_' || LOWER(REPLACE(projectname, ' ', '_'));

    -- ┌─ CHANGED ──────────────────────────────────────────────────────────────┐
    -- │ These three variables are new — not present in the original private    │
    -- │ function at all.                                                        │
    -- │                                                                         │
    -- │ v_post_cap   default 5   — max posts per user per bucket               │
    -- │ v_cap_period default 'week' — bucket size                              │
    -- │ v_week_anchor            — project start timestamp; drives all bucket  │
    -- │                            boundary calculations in ranked_posts        │
    -- └────────────────────────────────────────────────────────────────────────┘
    v_post_cap    INT         := 5;
    v_cap_period  TEXT        := 'week';
    v_week_anchor TIMESTAMPTZ := NULL;
BEGIN

    -- ┌─ CHANGED ──────────────────────────────────────────────────────────────┐
    -- │ Cap lookup is new — not present in the original private function.      │
    -- │                                                                         │
    -- │ leaderboard_type = 'private' so this reads the private row from        │
    -- │ project_post_cap, independent of the global row for the same project.  │
    -- │                                                                         │
    -- │ COALESCE(cap_start_date, project_start_date): cap_start_date takes     │
    -- │ priority when an admin has set a campaign-level override; otherwise     │
    -- │ falls back to the project start anchor.                                 │
    -- │                                                                         │
    -- │ Double-COALESCE: the SELECT INTO leaves variables at their DECLARE      │
    -- │ defaults if no row exists for this project, but if the row exists with  │
    -- │ NULL columns the post-lookup COALESCE catches those too.               │
    -- └────────────────────────────────────────────────────────────────────────┘
    SELECT
        COALESCE(post_cap,    5),
        COALESCE(cap_period,  'week'),
        COALESCE(cap_start_date, project_start_date)
    INTO
        v_post_cap,
        v_cap_period,
        v_week_anchor
    FROM mindshare.project_post_cap
    WHERE project_keyword  = projectname
      AND leaderboard_type = 'private';

    v_post_cap   := COALESCE(v_post_cap,   5);
    v_cap_period := COALESCE(v_cap_period, 'week');
    -- v_week_anchor stays NULL when project_start_date is NULL.

    -- Dynamic SQL parameter map:
    --   $1 = startdate          (BIGINT epoch — user-supplied window start)
    --   $2 = enddate            (BIGINT epoch — user-supplied window end)
    --   $3 = projectname        (TEXT)
    --   $4 = p_private_user_list (TEXT[] — allowlist, nullable)  ← UNCHANGED
    --   $5 = p_exclude_list      (TEXT[] — exclusion, nullable)  ← UNCHANGED
    --   $6 = v_post_cap         (INT,  default 5)                ← NEW
    --   $7 = v_cap_period       (TEXT, 'day'|'week'|'month'|'none') ← NEW
    --   $8 = v_week_anchor      (TIMESTAMPTZ, nullable)          ← NEW
    --
    -- NOTE: $4/$5 shift from the original function's $4/$5 remains the same
    -- because the array params are still passed as $4 and $5 — the new cap
    -- params are appended as $6/$7/$8 to avoid renumbering.

    sql_query := FORMAT($q$

WITH

 --============================================================
-- STEP 1: FILTERED DATA
--
-- CHANGED: added root_tweet_created_at, is_root_post,
--          is_root_quote — required by user_posts CTE and
--          the bucket CASE in ranked_posts.
-- UNCHANGED: all other columns and filter conditions.
 --============================================================
filtered_data AS (
    SELECT
        root_post_id,
        root_user_id,
        root_username,
        root_tweet_created_at,  -- ADDED
        is_root_post,           -- ADDED
        is_root_quote,          -- ADDED
        is_root_reply,
        engaged_user_id,
        engaged_user_score,
        engaged_tweet_created_at,
        is_engaged_reply
    FROM analytics.%I
    WHERE root_tweet_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND root_user_id != ''
),

 --============================================================
-- STEP 2: BASE USER   ← UNCHANGED
 --============================================================
base_user AS (
    SELECT
        root_user_id,
        root_username,
        COUNT(DISTINCT root_post_id) FILTER (WHERE NOT is_root_reply) AS post_count,
        COUNT(DISTINCT root_post_id) FILTER (WHERE     is_root_reply) AS reply_count
    FROM filtered_data
    GROUP BY root_user_id, root_username
),

 --============================================================
-- STEP 3: USER POSTS
--
-- CHANGED: new CTE — was not in original private function.
--          Required to feed ranked_posts for cap bucketing.
 --============================================================
user_posts AS (
    SELECT DISTINCT
        root_post_id,
        root_user_id,
        root_tweet_created_at,
        is_root_post,
        is_root_quote,
        is_root_reply
    FROM filtered_data
),

 --============================================================
-- STEP 4: UNIQUE CONTRIBUTIONS
--
-- CHANGED: original joined post_metrics to resolve handle;
--          now queries contribution_scores directly with a
--          project_keyword filter, matching v2 global exactly.
--          post_engagements and post_metrics CTEs removed as
--          a result — they are no longer needed.
 --============================================================
unique_contributions AS (
    SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id)
        cs.original_post_id     AS post_id,
        cs.original_author_x_id,
        cs.contribution_score
    FROM mindshare_score.contribution_scores cs
    WHERE cs.post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND cs.replier_x_id <> cs.original_author_x_id
      AND cs.project_keyword = $3
    ORDER BY
        cs.original_post_id,
        cs.replier_x_id,
        cs.post_created_at ASC
),

 --============================================================
-- STEP 5: POST SMART REACH
--
-- CHANGED: new CTE — derived from unique_contributions.
--          Provides per-post smart reach score used to rank
--          posts within each cap bucket (best posts survive).
 --============================================================
post_sr_preview AS (
    SELECT
        uc.post_id              AS original_post_id,
        SUM(uc.contribution_score)::NUMERIC AS post_smart_reach
    FROM unique_contributions uc
    GROUP BY uc.post_id
),

 --============================================================
-- STEP 6: POST CAP
--
-- CHANGED: ranked_posts and capped_posts are new — not present
--          in the original private function.
--
-- HOW THE CAP WORKS (end-to-end):
--
--   v_post_cap ($6)   — max posts counted per user per bucket.
--                       Default 5. 0 = no cap (pass-through).
--
--   v_cap_period ($7) — bucket size: 'day', 'week', 'month',
--                       or 'none' (no bucketing). Default 'week'.
--
--   v_week_anchor ($8) — project start TIMESTAMPTZ. All bucket
--                        boundaries are computed relative to
--                        this exact timestamp, so bucket 0 starts
--                        at the project start (e.g. Feb 3 03:00
--                        UTC), not at midnight or the user-supplied
--                        startdate. NULL → calendar defaults.
--
--   Posts are ranked by smart_reach DESC within each
--   (user, bucket) partition. Only post_rank <= v_post_cap
--   pass through to capped_posts and contribute to scoring.
 --============================================================
ranked_posts AS (
    SELECT
        up.root_post_id,
        up.root_user_id,
        COALESCE(psr.post_smart_reach, 0)
            * (COALESCE(mp.content_score, 50) / 100) AS post_score,
        ROW_NUMBER() OVER (
            PARTITION BY
                up.root_user_id,
                CASE $7
                    WHEN 'day' THEN
                        CASE
                            WHEN $8 IS NOT NULL THEN
                                -- Anchor-based day bucket (starts at project_start_date)
                                $8 + (
                                    FLOOR(
                                        EXTRACT(EPOCH FROM (up.root_tweet_created_at - $8))
                                        / 86400
                                    ) * INTERVAL '1 day'
                                )
                            ELSE
                                DATE_TRUNC('day', up.root_tweet_created_at)
                        END
                    WHEN 'week' THEN
                        CASE
                            WHEN $8 IS NOT NULL THEN
                                -- Anchor-based 7-day bucket
                                $8 + (
                                    FLOOR(
                                        EXTRACT(EPOCH FROM (up.root_tweet_created_at - $8))
                                        / (7 * 86400)
                                    ) * INTERVAL '7 days'
                                )
                            ELSE
                                -- No anchor: floor to last Sunday
                                DATE_TRUNC('week', up.root_tweet_created_at + INTERVAL '1 day')
                                - INTERVAL '1 day'
                        END
                    WHEN 'month' THEN
                        CASE
                            WHEN $8 IS NOT NULL THEN
                                -- Anchor-based 30-day bucket
                                $8 + (
                                    FLOOR(
                                        EXTRACT(EPOCH FROM (up.root_tweet_created_at - $8))
                                        / (30 * 86400)
                                    ) * INTERVAL '30 days'
                                )
                            ELSE
                                DATE_TRUNC('month', up.root_tweet_created_at)
                        END
                    ELSE NULL  -- 'none': single partition, no bucketing
                END
            ORDER BY COALESCE(psr.post_smart_reach, 0) * (COALESCE(mp.content_score, 50) / 100) DESC
        ) AS post_rank
    FROM user_posts up
    LEFT JOIN post_sr_preview psr
        ON psr.original_post_id = up.root_post_id
    LEFT JOIN mindshare.mindshare_post mp
        ON  mp.post_id         = up.root_post_id
        AND mp.project_keyword = $3
    WHERE NOT up.is_root_reply
),

capped_posts AS (
    -- $6 = 0 means no cap: all posts pass through
    SELECT root_post_id, root_user_id, post_score
    FROM ranked_posts
    WHERE $6 = 0
       OR post_rank <= $6
),

 --============================================================
-- STEP 7: USER POST SCORES
--
-- CHANGED: now sourced from capped_posts (not post_scores).
--          post_count reflects capped post count, matching
--          the score formula below.
-- UNCHANGED: grouping and aggregation logic.
 --============================================================
user_post_scores AS (
    SELECT
        root_user_id            AS handle,
        SUM(post_score)::NUMERIC AS user_post_score,
        COUNT(root_post_id)      AS post_count
    FROM capped_posts
    GROUP BY root_user_id
),

 --============================================================
-- STEP 8: SCORES
--
-- CHANGED: post_count term now uses ups.post_count (capped)
--          instead of pc.post_count (raw). This ensures the
--          presence bonus only applies to posts that survived
--          the cap, consistent with how smart reach is counted.
-- UNCHANGED: formula structure, reply bonus, NULLIF guard.
 --============================================================
scores AS (
    SELECT
        bu.root_user_id              AS x_user_id,
        bu.root_username             AS x_username,
        COALESCE(u.display_name, '') AS x_display_name,
        u.avatar_url                 AS x_avatar_url,
        ROUND(
            COALESCE(ups.user_post_score, 0)
            + (COALESCE(ups.post_count, 0) * COALESCE(NULLIF(u.score, 0), 0.01))
            + (COALESCE(bu.reply_count, 0) * COALESCE(NULLIF(u.score, 0), 0.01) / 100),
            3
        ) AS mindshare_score
    FROM base_user bu
    LEFT JOIN user_post_scores ups
        ON  ups.handle = bu.root_user_id
    LEFT JOIN mindshare.mindshare_user u
        ON  u.x_id    = bu.root_user_id
),

 --============================================================
-- STEP 9: FILTERED SCORES   ← UNCHANGED
--
-- Private-only CTE. Applies allowlist ($4) and exclusion
-- list ($5) passed in by the caller. Logic and parameter
-- positions are identical to the original private function.
 --============================================================
filtered_scores AS (
    SELECT *
    FROM scores
    WHERE
        -- Allowlist: only include users in the list (if provided)
        (
            $4 IS NULL
            OR array_length($4, 1) IS NULL
            OR x_user_id = ANY($4)
        )
        -- Exclusion list: drop users in the list (if provided)
        AND (
            $5 IS NULL
            OR array_length($5, 1) IS NULL
            OR x_user_id != ALL($5)
        )
)

 --============================================================
-- FINAL OUTPUT   ← UNCHANGED
 --============================================================
SELECT
    s.x_user_id,
    s.x_username,
    s.x_display_name,
    s.x_avatar_url,
    s.mindshare_score,
    CASE
        WHEN SUM(s.mindshare_score) OVER () = 0 THEN 0
        ELSE ROUND(
            s.mindshare_score * 100.0
            / SUM(s.mindshare_score) OVER (),
            2
        )
    END AS mindshare_percent
FROM filtered_scores s
WHERE s.x_username != $3
ORDER BY s.mindshare_score DESC NULLS LAST
LIMIT 1100

$q$, view_name);

    RETURN QUERY EXECUTE sql_query
        USING startdate, enddate, projectname,
              p_private_user_list, p_exclude_list,   -- $4, $5 — UNCHANGED
              v_post_cap, v_cap_period, v_week_anchor; -- $6, $7, $8 — NEW

END;
$function$
;