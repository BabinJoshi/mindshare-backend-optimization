-- DROP PROCEDURE mindshare_score.test_create_engagement_clustering_features_view(text);

CREATE OR REPLACE PROCEDURE mindshare_score.test_create_engagement_clustering_features_view(IN project_keyword text)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    base_view_name   TEXT := 'mv_engagement_' || LOWER(REPLACE(project_keyword, ' ', '_'));
    features_view_name TEXT := 'mv_engagement_features_' || LOWER(REPLACE(project_keyword, ' ', '_'));
    index_name       TEXT := 'ix_mv_engagement_features_' || LOWER(REPLACE(project_keyword, ' ', '_')) || '_root';
BEGIN
    EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS mindshare_score.%I CASCADE', features_view_name);

    EXECUTE format($sql$
        CREATE MATERIALIZED VIEW mindshare_score.%I AS
        WITH base AS (
            SELECT
                root_post_id,
                root_user_id,
                root_username,
                root_tweet_created_at,
                engaged_user_id,
                engaged_tweet_created_at,
                EXTRACT(EPOCH FROM engaged_tweet_created_at) AS engaged_epoch
            FROM analytics.%I
        ),

        -- 1. Root-level stats
        root_stats AS (
            SELECT
                root_post_id,
                root_user_id,
                root_username,
                root_tweet_created_at,
                COUNT(*)                                                            AS total_engagements,
                MIN(engaged_tweet_created_at)                                       AS first_engagement,
                MAX(engaged_tweet_created_at)                                       AS last_engagement,
                TO_TIMESTAMP(PERCENTILE_CONT(0.90) WITHIN GROUP (
                    ORDER BY EXTRACT(EPOCH FROM engaged_tweet_created_at)
                ))                                                                  AS p90_engagement
            FROM base
            GROUP BY 1, 2, 3, 4
        ),

        -- 2. Burst concentration — O(N log N) window function
        burst_windows AS (
            SELECT
                root_post_id,
                engaged_tweet_created_at AS window_start,
                COUNT(*) OVER (
                    PARTITION BY root_post_id
                    ORDER BY engaged_epoch
                    RANGE BETWEEN CURRENT ROW AND 3600 FOLLOWING
                ) AS window_count
            FROM base
        ),

        max_burst_info AS (
            SELECT DISTINCT ON (root_post_id)
                root_post_id,
                window_start        AS peak_window_start,
                window_count        AS peak_window_count
            FROM burst_windows
            ORDER BY root_post_id, window_count DESC, window_start ASC
        ),

        -- 3. Participant tracking
        burst_participants AS (
            SELECT b.root_user_id, b.root_post_id, b.engaged_user_id
            FROM base b
            JOIN max_burst_info m ON b.root_post_id = m.root_post_id
            WHERE b.engaged_tweet_created_at >= m.peak_window_start
              AND b.engaged_tweet_created_at <  m.peak_window_start + INTERVAL '60 minutes'
        ),

        author_burst_recurrence AS (
            SELECT
                root_user_id,
                engaged_user_id,
                COUNT(DISTINCT root_post_id) AS burst_posts_count
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
             AND bp.root_user_id   = abr.root_user_id
            GROUP BY 1
        ),

        -- 4. Metrics pre-aggregation
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

        -- 5. Post ordering
        post_order AS (
            SELECT DISTINCT
                root_post_id,
                root_user_id,
                root_tweet_created_at,
                ROW_NUMBER() OVER (
                    PARTITION BY root_user_id
                    ORDER BY root_tweet_created_at
                ) AS post_rank
            FROM base
        ),

        -- Deduplicate base once — reused by all overlap CTEs
        unique_engagers AS (
            SELECT DISTINCT root_post_id, engaged_user_id
            FROM base
        ),

        -- (user, post_rank, post_id, engager) — total rows = E_total (unique engagements)
        -- Hash join on (root_user_id, engaged_user_id) is highly selective
        user_engager_activity AS (
            SELECT
                po.root_user_id,
                po.root_post_id,
                po.post_rank,
                ue.engaged_user_id
            FROM post_order po
            JOIN unique_engagers ue ON ue.root_post_id = po.root_post_id
        ),

        -- 6. Cross-post overlap
        -- Semi-join: mark each (post, engager) pair where that engager
        -- also appeared in any of the author's previous 100 posts.
        -- DISTINCT output is bounded at E_total rows (not 50B as in the original).
        engager_has_prior AS (
            SELECT DISTINCT a.root_post_id, a.engaged_user_id
            FROM user_engager_activity a
            JOIN user_engager_activity b
                ON  b.root_user_id    = a.root_user_id
                AND b.engaged_user_id = a.engaged_user_id
                AND b.post_rank       <  a.post_rank
                AND b.post_rank       >= GREATEST(a.post_rank - 100, 1)
        ),

        cross_post_overlap AS (
            SELECT
                ue.root_post_id,
                ROUND(
                    COUNT(DISTINCT ehp.engaged_user_id)::numeric
                    / NULLIF(COUNT(DISTINCT ue.engaged_user_id), 0) * 100, 2
                ) AS avg_cross_post_overlap
            FROM unique_engagers ue
            LEFT JOIN engager_has_prior ehp
                ON  ehp.root_post_id    = ue.root_post_id
                AND ehp.engaged_user_id = ue.engaged_user_id
            GROUP BY ue.root_post_id
        ),

        -- 7. Previous post overlap (immediately preceding post only)
        -- LAG replaces the post_order self-join entirely.
        post_with_prev AS (
            SELECT
                root_post_id,
                root_user_id,
                post_rank,
                LAG(root_post_id) OVER (
                    PARTITION BY root_user_id
                    ORDER BY post_rank
                ) AS prev_post_id
            FROM post_order
        ),

        prev_post_overlap AS (
            SELECT
                ue.root_post_id,
                ROUND(
                    COUNT(DISTINCT prev_ue.engaged_user_id)::numeric
                    / NULLIF(COUNT(DISTINCT ue.engaged_user_id), 0) * 100, 2
                ) AS prev_post_overlap_pct
            FROM unique_engagers ue
            LEFT JOIN post_with_prev pp
                   ON  pp.root_post_id = ue.root_post_id
            LEFT JOIN unique_engagers prev_ue
                   ON  prev_ue.root_post_id    = pp.prev_post_id
                   AND prev_ue.engaged_user_id = ue.engaged_user_id
            GROUP BY ue.root_post_id
        )

        SELECT
            m.root_post_id,
            m.root_user_id,
            m.root_username,
            m.root_tweet_created_at,
            m.total_engagements,
            m.burst_concentration,
            m.duration_days_p90,
            COALESCE(c.avg_cross_post_overlap, 0)  AS cross_post_overlap,
            COALESCE(ppo.prev_post_overlap_pct, 0) AS prev_post_overlap,
            (m.burst_concentration * LEAST(COALESCE(pc.avg_burst_recurrence, 0) / 3, 1)) AS coordinated_burst,
            (
                0.25 * LEAST(m.burst_concentration * 1.25, 1) +
                0.20 * (1 - LEAST(m.duration_days_p90, 1)) +
                0.25 * LEAST(COALESCE(c.avg_cross_post_overlap, 0) / 100, 1) +
                0.30 * (m.burst_concentration * LEAST(COALESCE(pc.avg_burst_recurrence, 0) / 3, 1))
            ) * 100 AS farming_score
        FROM metrics_pre m
        LEFT JOIN cross_post_overlap c   ON c.root_post_id   = m.root_post_id
        LEFT JOIN prev_post_overlap  ppo ON ppo.root_post_id = m.root_post_id
        LEFT JOIN post_coordination  pc  ON pc.root_post_id  = m.root_post_id;
    $sql$, features_view_name, base_view_name);

    EXECUTE format(
        'CREATE UNIQUE INDEX IF NOT EXISTS %I ON mindshare_score.%I (root_post_id)',
        index_name, features_view_name
    );
END;
$procedure$
;