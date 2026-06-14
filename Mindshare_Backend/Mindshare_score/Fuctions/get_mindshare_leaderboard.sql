-- DROP FUNCTION mindshare_score.get_mindshare_leaderboard(int8, int8, text);

CREATE OR REPLACE FUNCTION mindshare_score.get_mindshare_leaderboard(startdate bigint, enddate bigint, projectname text)
 RETURNS TABLE(x_user_id text, x_username character varying, x_display_name character varying, x_avatar_url character varying, mindshare_score numeric, mindshare_percent numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query     TEXT;
    view_name     TEXT := 'mv_engagement_' || LOWER(REPLACE(projectname, ' ', '_'));

    -- ┌─ CHANGED ──────────────────────────────────────────────────────────────┐
    -- │ v_post_cap   default changed from 0 (no cap) → 5                      │
    -- │ v_cap_period default changed from 'none'     → 'week'                 │
    -- │ These are the hard-coded fallbacks used when no row exists in the      │
    -- │ project_post_cap table for this project + leaderboard_type.            │
    -- └────────────────────────────────────────────────────────────────────────┘
    v_post_cap    INT         := 5;
    v_cap_period  TEXT        := 'week';

    -- UNCHANGED: v_week_anchor carries the project start timestamp and drives
    --            all bucket boundary calculations in ranked_posts.
    v_week_anchor TIMESTAMPTZ := NULL;
BEGIN

    -- ┌─ CHANGED ──────────────────────────────────────────────────────────────┐
    -- │ Added AND leaderboard_type = 'global' so this function reads only the  │
    -- │ global row. get_private_mindshare_leaderboard uses 'private' instead.  │
    -- │                                                                         │
    -- │ CHANGED: COALESCE fallbacks for post_cap / cap_period now use the new  │
    -- │ defaults (5 / 'week') rather than (0 / 'none').                        │
    -- │                                                                         │
    -- │ UNCHANGED: v_week_anchor is still resolved as                          │
    -- │ COALESCE(cap_start_date, project_start_date), giving cap_start_date    │
    -- │ priority when an admin has set a campaign-level override.               │
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
      AND leaderboard_type = 'global';

    v_post_cap   := COALESCE(v_post_cap,   5);
    v_cap_period := COALESCE(v_cap_period, 'week');
    -- v_week_anchor stays NULL when project_start_date is NULL (see seed data).

    -- Dynamic SQL parameter map (UNCHANGED):
    --   $1 = startdate     (BIGINT epoch  — user-supplied window start)
    --   $2 = enddate       (BIGINT epoch  — user-supplied window end)
    --   $3 = projectname   (TEXT)
    --   $4 = v_post_cap    (INT,  default 5)
    --   $5 = v_cap_period  (TEXT, 'day' | 'week' | 'month' | 'none')
    --   $6 = v_week_anchor (TIMESTAMPTZ, nullable — project start)

    sql_query := FORMAT($q$

WITH

 --============================================================
-- STEP 1: FILTERED DATA   ← UNCHANGED
 --============================================================
filtered_data AS (
    SELECT
        root_post_id,
        root_user_id,
        root_username,
        root_tweet_created_at,
        is_root_post,
        is_root_quote,
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
-- STEP 3: USER POST
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
-- STEP 4:  UNIQUE CONTRIBUTIONS
 --============================================================
unique_contributions AS (
    SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id)
        cs.original_post_id AS post_id,
        cs.original_author_x_id,
        cs.contribution_score
    FROM mindshare_score.contribution_scores cs
    WHERE cs.post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND cs.replier_x_id <> cs.original_author_x_id
      and cs.project_keyword = $3
    ORDER BY
        cs.original_post_id,
        cs.replier_x_id,
        cs.post_created_at ASC
),

--============================================================
-- STEP 5:  POST SMART REACH
 --============================================================
post_sr_preview AS (
    SELECT
        uc.post_id as original_post_id,
        SUM(uc.contribution_score)::NUMERIC AS post_smart_reach
    FROM unique_contributions uc
    GROUP BY uc.post_id
),

 --============================================================
-- STEP 6: POST CAP
--
-- post_sr_preview   ← UNCHANGED
-- ranked_posts      ← CHANGED (see inline notes below)
-- capped_posts      ← UNCHANGED
--
-- HOW THE CAP WORKS (end-to-end):
--
--   v_post_cap ($4) — maximum posts counted per user per bucket.
--                     Default is now 5 (was 0 = unlimited).
--                     0 still means no cap (pass-through).
--
--   v_cap_period ($5) — the time bucket size: 'day', 'week',
--                       'month', or 'none' (no bucketing).
--                       Default is now 'week'.
--
--   v_week_anchor ($6) — the TIMESTAMPTZ of project_start_date.
--                        All bucket boundaries are computed
--                        relative to this exact timestamp, so
--                        bucket 0 starts at the project start
--                        (e.g. Feb 3 03:00 UTC), not at
--                        midnight or the user-supplied startdate.
--                        NULL → falls back to calendar defaults.
--
--   Within each (user, bucket) partition posts are ranked by
--   their smart_reach DESC so the highest-impact posts survive
--   the cap. Only posts with post_rank <= v_post_cap reach
--   capped_posts and then contribute to scoring.
 --============================================================

ranked_posts AS (
    SELECT
        up.root_post_id,
        up.root_user_id,
		COALESCE(psr.post_smart_reach, 0) * (COALESCE(mp.content_score, 50) / 100) AS post_score,
        ROW_NUMBER() OVER (
            PARTITION BY
                up.root_user_id,
                -- ┌─ CHANGED ───────────────────────────────────────────────────┐
                -- │ 'day' branch: now uses anchor-based exact bucketing when     │
                -- │ $6 IS NOT NULL. Bucket N starts at:                          │
                -- │   $6 + N * '1 day'                                           │
                -- │ so boundaries align to the project start time, not midnight. │
                -- │ When $6 IS NULL → falls back to DATE_TRUNC('day', ...).      │
                -- │                                                               │
                -- │ 'week' branch: UNCHANGED (anchor-based 7-day bucket or       │
                -- │ Sunday-floor fallback — identical to original function).      │
                -- │                                                               │
                -- │ 'month' branch: ADDED. Anchor-based 30-day bucket when       │
                -- │ $6 IS NOT NULL; DATE_TRUNC('month') fallback otherwise.       │
                -- │                                                               │
                -- │ 'none' / ELSE: UNCHANGED — NULL bucket collapses all posts   │
                -- │ into one partition (no effective time bucketing).             │
                -- └─────────────────────────────────────────────────────────────┘
                CASE $5
                    WHEN 'day' THEN
                        CASE
                            WHEN $6 IS NOT NULL THEN
                                -- Anchor-based day bucket (starts at project_start_date)
                                $6 + (
                                    FLOOR(
                                        EXTRACT(EPOCH FROM (up.root_tweet_created_at - $6))
                                        / 86400
                                    ) * INTERVAL '1 day'
                                )
                            ELSE
                                DATE_TRUNC('day', up.root_tweet_created_at)
                        END
                    WHEN 'week' THEN
                        CASE
                            WHEN $6 IS NOT NULL THEN
                                -- Anchor-based 7-day bucket (UNCHANGED)
                                $6 + (
                                    FLOOR(
                                        EXTRACT(EPOCH FROM (up.root_tweet_created_at - $6))
                                        / (7 * 86400)
                                    ) * INTERVAL '7 days'
                                )
                            ELSE
                                -- No anchor: floor to last Sunday (UNCHANGED)
                                DATE_TRUNC('week', up.root_tweet_created_at + INTERVAL '1 day')
                                - INTERVAL '1 day'
                        END
                    WHEN 'month' THEN
                        -- NEW: 30-day anchor bucket, or calendar-month fallback
                        CASE
                            WHEN $6 IS NOT NULL THEN
                                $6 + (
                                    FLOOR(
                                        EXTRACT(EPOCH FROM (up.root_tweet_created_at - $6))
                                        / (30 * 86400)
                                    ) * INTERVAL '30 days'
                                )
                            ELSE
                                DATE_TRUNC('month', up.root_tweet_created_at)
                        END
                    ELSE NULL  -- 'none': single partition, no bucketing (UNCHANGED)
                END
            ORDER BY COALESCE(psr.post_smart_reach, 0) * (COALESCE(mp.content_score, 50) / 100) DESC
        ) AS post_rank
    FROM user_posts up
    LEFT JOIN post_sr_preview psr
        ON psr.original_post_id = up.root_post_id
	LEFT JOIN mindshare.mindshare_post mp
    	ON mp.post_id = up.root_post_id
    	and mp.project_keyword = $3
    WHERE NOT up.is_root_reply  -- UNCHANGED
),

capped_posts AS (
    -- UNCHANGED: $4 = 0 still means no cap (all posts pass through)
    SELECT root_post_id, root_user_id, post_score
    FROM ranked_posts
    WHERE $4 = 0
       OR post_rank <= $4
),

 --============================================================
-- STEP 7: USER POST SCORES   ← UNCHANGED
 --============================================================
user_post_scores AS (
    SELECT
        root_user_id as handle,
        SUM(post_score)::NUMERIC AS user_post_score,
        COUNT(root_post_id)     AS post_count
    FROM capped_posts
    GROUP BY root_user_id
),

 --============================================================
-- STEP 8: SCORES   ← UNCHANGED
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
        ON  u.x_id     = bu.root_user_id
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
FROM scores s
WHERE s.x_username != $3
ORDER BY s.mindshare_score DESC NULLS LAST
LIMIT 1100

$q$, view_name);

    RETURN QUERY EXECUTE sql_query
        USING startdate, enddate, projectname, v_post_cap, v_cap_period, v_week_anchor;

END;
$function$
;