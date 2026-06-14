-- DROP PROCEDURE mindshare_score.create_user_posts_engagement_features_view();

CREATE OR REPLACE PROCEDURE mindshare_score.create_user_posts_engagement_features_view()
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    -- Drop if exists
    DROP MATERIALIZED VIEW IF EXISTS mindshare_score.mv_user_posts_engagement_features;

    -- Create Materialized View
    CREATE MATERIALIZED VIEW mindshare_score.mv_user_posts_engagement_features AS
    WITH base AS (
        SELECT
            root_post_id,
            root_user_id,
            root_username,
            root_tweet_created_at,
            engaged_user_id,
            engaged_tweet_created_at
        FROM analytics.mv_user_posts_engagement
    ),

    -- 1️⃣ Root-level stats
    root_stats AS (
        SELECT
            root_post_id,
            root_user_id,
            root_username,
            root_tweet_created_at,
            COUNT(*) AS total_engagements,
            MIN(engaged_tweet_created_at) AS first_engagement,
            MAX(engaged_tweet_created_at) AS last_engagement,
            TO_TIMESTAMP(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM engaged_tweet_created_at))) AS p90_engagement
        FROM base
        GROUP BY 1, 2, 3, 4
    ),

    -- 2️⃣ Burst concentration (60 min window) - OPTIMIZED: Window Range instead of Self-Join
    burst_windows AS (
        SELECT
            root_post_id,
            engaged_tweet_created_at AS window_start,
            COUNT(*) OVER (
                PARTITION BY root_post_id
                ORDER BY engaged_tweet_created_at
                RANGE BETWEEN CURRENT ROW AND '59 minutes 59 seconds'::interval FOLLOWING
            ) AS window_count
        FROM base
    ),

    -- Identify the peak window for each post
    max_burst_info AS (
        SELECT DISTINCT ON (root_post_id)
            root_post_id,
            window_start AS peak_window_start,
            window_count AS peak_window_count
        FROM burst_windows
        ORDER BY root_post_id, window_count DESC, window_start ASC
    ),

    -- 3️⃣ Participant Tracking
    burst_participants AS (
        SELECT DISTINCT
            b.root_user_id,
            b.root_post_id,
            b.engaged_user_id
        FROM base b
        JOIN max_burst_info m ON b.root_post_id = m.root_post_id
        WHERE b.engaged_tweet_created_at >= m.peak_window_start
          AND b.engaged_tweet_created_at < m.peak_window_start + INTERVAL '60 minutes'
    ),

    author_burst_recurrence AS (
        SELECT
            root_user_id,
            engaged_user_id,
            COUNT(root_post_id) AS burst_posts_count
        FROM burst_participants
        GROUP BY 1, 2
    ),

    post_coordination AS (
        SELECT
            bp.root_post_id,
            AVG(abr.burst_posts_count - 1)::numeric AS avg_burst_recurrence
        FROM burst_participants bp
        JOIN author_burst_recurrence abr
          ON bp.engaged_user_id = abr.engaged_user_id
          AND bp.root_user_id = abr.root_user_id
        GROUP BY 1
    ),

    -- 4️⃣ Metrics calculation
    metrics_pre AS (
        SELECT
            r.*,
            CASE
                WHEN r.total_engagements = 0 THEN 0
                ELSE COALESCE(mb.peak_window_count, 0)::numeric / r.total_engagements
            END AS burst_concentration,
            EXTRACT(EPOCH FROM (r.p90_engagement - r.first_engagement)) / 86400 AS duration_days_p90
        FROM root_stats r
        LEFT JOIN max_burst_info mb ON r.root_post_id = mb.root_post_id
    ),

    -- 5 & 6️⃣ Cross-post overlap and Prev-post overlap (OPTIMIZED: Window functions instead of massive cross-joins)
    -- Rank each author's posts chronologically
    post_order AS (
        SELECT DISTINCT
            root_post_id,
            root_user_id,
            root_tweet_created_at
        FROM base
    ),

    ranked_post_order AS (
        SELECT
            root_post_id,
            root_user_id,
            root_tweet_created_at,
            ROW_NUMBER() OVER (
                PARTITION BY root_user_id
                ORDER BY root_tweet_created_at, root_post_id
            ) AS post_rank
        FROM post_order
    ),

    -- Find the most recent post (by rank) an engager interacted with before their current engagement
    user_engagement_history AS (
        SELECT
            b.root_post_id,
            b.engaged_user_id,
            p.root_user_id,
            p.post_rank,
            LAG(p.post_rank) OVER (
                PARTITION BY p.root_user_id, b.engaged_user_id
                ORDER BY p.post_rank
            ) AS prev_engaged_post_rank
        FROM (SELECT DISTINCT root_post_id, engaged_user_id FROM base) b
        JOIN ranked_post_order p ON p.root_post_id = b.root_post_id
    ),

    post_overlap_metrics AS (
        SELECT
            root_post_id,
            CASE WHEN COUNT(*) = 0 THEN 0
                 ELSE ROUND(
                     SUM(CASE WHEN prev_engaged_post_rank >= post_rank - 100 THEN 1 ELSE 0 END)::numeric
                     / COUNT(*) * 100, 2
                 )
            END AS cross_post_overlap,
            CASE WHEN COUNT(*) = 0 THEN 0
                 ELSE ROUND(
                     SUM(CASE WHEN prev_engaged_post_rank = post_rank - 1 THEN 1 ELSE 0 END)::numeric
                     / COUNT(*) * 100, 2
                 )
            END AS prev_post_overlap_pct
        FROM user_engagement_history
        GROUP BY root_post_id
    )

    SELECT
        m.root_post_id,
        m.root_user_id,
        m.root_username,
        m.root_tweet_created_at,
        m.total_engagements,
        m.burst_concentration,
        m.duration_days_p90,
        COALESCE(pom.cross_post_overlap, 0) AS cross_post_overlap,
        COALESCE(pom.prev_post_overlap_pct, 0) AS prev_post_overlap,
        (m.burst_concentration * LEAST(COALESCE(pc.avg_burst_recurrence, 0) / 3, 1)) AS coordinated_burst,
        (
            0.25 * LEAST(m.burst_concentration * 1.25, 1) +
            0.20 * (1 - LEAST(m.duration_days_p90, 1)) +
            0.25 * LEAST(COALESCE(pom.cross_post_overlap, 0) / 100, 1) +
            0.30 * (m.burst_concentration * LEAST(COALESCE(pc.avg_burst_recurrence, 0) / 3, 1))
        ) * 100 AS farming_score
    FROM metrics_pre m
    LEFT JOIN post_overlap_metrics pom ON m.root_post_id = pom.root_post_id
    LEFT JOIN post_coordination pc ON m.root_post_id = pc.root_post_id;

    CREATE UNIQUE INDEX IF NOT EXISTS ix_mv_user_posts_engagement_features_root ON mindshare_score.mv_user_posts_engagement_features (root_post_id);
END;
$procedure$
;