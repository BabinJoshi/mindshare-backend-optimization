-- Incremental feature pipeline (TABLE, not MATERIALIZED VIEW)
-- Replaces mindshare_score_md_fix.create_engagement_clustering_features_view (MV) with:
--   * a real table  features_<project>            (PK root_post_id, UPSERT target)
--   * watermark      feature_watermarks            (per-project last processed engagement ts)
--   * full build     build_features_full(project)  (TRUNCATE + INSERT whole pipeline)
--   * incremental    refresh_features_incremental(project) (recompute only hot authors' posts)
-- All read from analytics_md_fix.mv_engagement_<project>. Production untouched.

CREATE TABLE IF NOT EXISTS mindshare_score_md_fix.feature_watermarks (
    project          text PRIMARY KEY,
    last_engaged_at  timestamptz,   -- MAX(engaged_tweet_created_at) processed so far
    last_refresh_at  timestamptz,
    last_mode        text
);

-- Returns the 12-CTE farming-score pipeline SELECT for one project matview.
-- scope_predicate: a full WHERE clause applied to the base CTE ('' = whole project).
CREATE OR REPLACE FUNCTION mindshare_score_md_fix._features_pipeline_sql(
    mv_name text, scope_predicate text DEFAULT '')
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
SELECT format($q$
    WITH base AS (
        SELECT root_post_id, root_user_id, root_username, root_tweet_created_at,
               engaged_user_id, engaged_tweet_created_at,
               EXTRACT(EPOCH FROM engaged_tweet_created_at) AS engaged_epoch
        FROM analytics_md_fix.%I
        %s
    ),
    root_stats AS (
        SELECT root_post_id, root_user_id, root_username, root_tweet_created_at,
               COUNT(*) AS total_engagements,
               MIN(engaged_tweet_created_at) AS first_engagement,
               MAX(engaged_tweet_created_at) AS last_engagement,
               TO_TIMESTAMP(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM engaged_tweet_created_at))) AS p90_engagement
        FROM base GROUP BY 1,2,3,4
    ),
    burst_windows AS (
        SELECT root_post_id, date_trunc('hour', engaged_tweet_created_at) AS hour_bucket, COUNT(*) AS window_count
        FROM base WHERE engaged_tweet_created_at IS NOT NULL
        GROUP BY root_post_id, date_trunc('hour', engaged_tweet_created_at)
    ),
    max_burst_info AS (
        SELECT DISTINCT ON (root_post_id) root_post_id, hour_bucket AS peak_window_start, window_count AS peak_window_count
        FROM burst_windows ORDER BY root_post_id, window_count DESC, hour_bucket ASC
    ),
    burst_participants AS (
        SELECT b.root_user_id, b.root_post_id, b.engaged_user_id
        FROM base b JOIN max_burst_info m ON b.root_post_id = m.root_post_id
        WHERE date_trunc('hour', b.engaged_tweet_created_at) = m.peak_window_start
    ),
    author_burst_recurrence AS (
        SELECT root_user_id, engaged_user_id, COUNT(DISTINCT root_post_id) AS burst_posts_count
        FROM burst_participants GROUP BY 1,2
    ),
    post_coordination AS (
        SELECT bp.root_post_id, AVG(abr.burst_posts_count - 1)::numeric AS avg_burst_recurrence
        FROM burst_participants bp
        JOIN author_burst_recurrence abr ON bp.engaged_user_id = abr.engaged_user_id AND bp.root_user_id = abr.root_user_id
        GROUP BY 1
    ),
    metrics_pre AS (
        SELECT r.*,
               CASE WHEN r.total_engagements = 0 THEN 0
                    ELSE COALESCE(mb.peak_window_count,0)::numeric / r.total_engagements END AS burst_concentration,
               EXTRACT(EPOCH FROM (r.p90_engagement - r.first_engagement))/86400 AS duration_days_p90
        FROM root_stats r LEFT JOIN max_burst_info mb ON r.root_post_id = mb.root_post_id
    ),
    post_order AS (
        SELECT DISTINCT root_post_id, root_user_id, root_tweet_created_at FROM base
    ),
    ranked_post_order AS (
        SELECT root_post_id, root_user_id, root_tweet_created_at,
               ROW_NUMBER() OVER (PARTITION BY root_user_id ORDER BY root_tweet_created_at, root_post_id) AS post_rank
        FROM post_order
    ),
    user_engagement_history AS (
        SELECT b.root_post_id, b.engaged_user_id, p.root_user_id, p.post_rank,
               LAG(p.post_rank) OVER (PARTITION BY p.root_user_id, b.engaged_user_id ORDER BY p.post_rank) AS prev_engaged_post_rank
        FROM (SELECT DISTINCT root_post_id, engaged_user_id FROM base) b
        JOIN ranked_post_order p ON p.root_post_id = b.root_post_id
    ),
    post_overlap_metrics AS (
        SELECT root_post_id,
               CASE WHEN COUNT(*)=0 THEN 0
                    ELSE ROUND(SUM(CASE WHEN prev_engaged_post_rank >= post_rank-100 THEN 1 ELSE 0 END)::numeric / COUNT(*) * 100, 2) END AS cross_post_overlap
        FROM user_engagement_history GROUP BY root_post_id
    )
    SELECT m.root_post_id, m.root_user_id, m.root_username, m.root_tweet_created_at,
           m.total_engagements, m.burst_concentration, m.duration_days_p90,
           COALESCE(pom.cross_post_overlap,0) AS cross_post_overlap,
           0 AS prev_post_overlap,
           (m.burst_concentration * LEAST(COALESCE(pc.avg_burst_recurrence,0)/3,1)) AS coordinated_burst,
           ( 0.25*LEAST(m.burst_concentration*1.25,1)
           + 0.20*(1-LEAST(m.duration_days_p90,1))
           + 0.25*LEAST(COALESCE(pom.cross_post_overlap,0)/100,1)
           + 0.30*(m.burst_concentration*LEAST(COALESCE(pc.avg_burst_recurrence,0)/3,1)) )*100 AS farming_score
    FROM metrics_pre m
    LEFT JOIN post_overlap_metrics pom ON m.root_post_id = pom.root_post_id
    LEFT JOIN post_coordination   pc  ON m.root_post_id = pc.root_post_id
$q$, mv_name, scope_predicate);
$fn$;

-- Create the per-project features table if absent.
CREATE OR REPLACE PROCEDURE mindshare_score_md_fix._ensure_features_table(IN p_slug text)
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format($d$
        CREATE TABLE IF NOT EXISTS mindshare_score_md_fix.%I (
            root_post_id          text PRIMARY KEY,
            root_user_id          text,
            root_username         text,
            root_tweet_created_at timestamptz,
            total_engagements     bigint,
            burst_concentration   numeric,
            duration_days_p90     numeric,
            cross_post_overlap    numeric,
            prev_post_overlap     numeric DEFAULT 0,
            coordinated_burst     numeric,
            farming_score         numeric,
            computed_at           timestamptz DEFAULT now()
        )$d$, 'features_'||p_slug);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON mindshare_score_md_fix.%I (root_user_id)',
                   'ix_features_'||p_slug||'_author', 'features_'||p_slug);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON mindshare_score_md_fix.%I (farming_score)',
                   'ix_features_'||p_slug||'_score', 'features_'||p_slug);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON mindshare_score_md_fix.%I (root_tweet_created_at)',
                   'ix_features_'||p_slug||'_time', 'features_'||p_slug);
END $$;

-- Full build: TRUNCATE + INSERT entire pipeline. Equivalent output to the old MV.
CREATE OR REPLACE PROCEDURE mindshare_score_md_fix.build_features_full(IN project_keyword text)
LANGUAGE plpgsql AS $$
DECLARE
    slug    text := lower(replace(project_keyword,' ','_'));
    mv      text := 'mv_engagement_'||slug;
    tbl     text := 'features_'||slug;
    maxeng  timestamptz;
BEGIN
    SET LOCAL work_mem = '512MB';
    CALL mindshare_score_md_fix._ensure_features_table(slug);
    EXECUTE format('TRUNCATE mindshare_score_md_fix.%I', tbl);
    EXECUTE format('INSERT INTO mindshare_score_md_fix.%I
        (root_post_id,root_user_id,root_username,root_tweet_created_at,total_engagements,
         burst_concentration,duration_days_p90,cross_post_overlap,prev_post_overlap,coordinated_burst,farming_score) %s',
        tbl, mindshare_score_md_fix._features_pipeline_sql(mv, ''));
    EXECUTE format('SELECT max(engaged_tweet_created_at) FROM analytics_md_fix.%I', mv) INTO maxeng;
    INSERT INTO mindshare_score_md_fix.feature_watermarks(project,last_engaged_at,last_refresh_at,last_mode)
    VALUES (slug, maxeng, now(), 'full')
    ON CONFLICT (project) DO UPDATE SET last_engaged_at=EXCLUDED.last_engaged_at,
        last_refresh_at=EXCLUDED.last_refresh_at, last_mode='full';
END $$;

-- Incremental: recompute only posts by authors who got new engagements since watermark, then UPSERT.
CREATE OR REPLACE PROCEDURE mindshare_score_md_fix.refresh_features_incremental(IN project_keyword text)
LANGUAGE plpgsql AS $$
DECLARE
    slug    text := lower(replace(project_keyword,' ','_'));
    mv      text := 'mv_engagement_'||slug;
    tbl     text := 'features_'||slug;
    wm      timestamptz;
    maxeng  timestamptz;
    scope   text;
BEGIN
    SET LOCAL work_mem = '512MB';
    CALL mindshare_score_md_fix._ensure_features_table(slug);
    SELECT last_engaged_at INTO wm FROM mindshare_score_md_fix.feature_watermarks WHERE project=slug;
    IF wm IS NULL THEN
        -- never built: fall back to full
        CALL mindshare_score_md_fix.build_features_full(project_keyword);
        RETURN;
    END IF;
    -- scope base to ALL posts of hot authors (full history needed for cross_post_overlap)
    scope := format($s$WHERE root_user_id IN (
                 SELECT DISTINCT root_user_id FROM analytics_md_fix.%I
                 WHERE engaged_tweet_created_at > %L)$s$, mv, wm);
    EXECUTE format('INSERT INTO mindshare_score_md_fix.%I
        (root_post_id,root_user_id,root_username,root_tweet_created_at,total_engagements,
         burst_concentration,duration_days_p90,cross_post_overlap,prev_post_overlap,coordinated_burst,farming_score) %s
        ON CONFLICT (root_post_id) DO UPDATE SET
            root_user_id=EXCLUDED.root_user_id, root_username=EXCLUDED.root_username,
            root_tweet_created_at=EXCLUDED.root_tweet_created_at, total_engagements=EXCLUDED.total_engagements,
            burst_concentration=EXCLUDED.burst_concentration, duration_days_p90=EXCLUDED.duration_days_p90,
            cross_post_overlap=EXCLUDED.cross_post_overlap, prev_post_overlap=EXCLUDED.prev_post_overlap,
            coordinated_burst=EXCLUDED.coordinated_burst, farming_score=EXCLUDED.farming_score, computed_at=now()',
        tbl, mindshare_score_md_fix._features_pipeline_sql(mv, scope));
    EXECUTE format('SELECT max(engaged_tweet_created_at) FROM analytics_md_fix.%I', mv) INTO maxeng;
    UPDATE mindshare_score_md_fix.feature_watermarks
       SET last_engaged_at=GREATEST(last_engaged_at,maxeng), last_refresh_at=now(), last_mode='incremental'
     WHERE project=slug;
END $$;

-- Orchestrators: derive project slug from each analytics_md_fix engagement matview name.
-- NOTE: build_all uses per-loop COMMIT — run from psql/cron, NOT inside an explicit transaction.
CREATE OR REPLACE PROCEDURE mindshare_score_md_fix.build_all_features()
LANGUAGE plpgsql AS $$
DECLARE r record; slug text; t0 timestamptz; n bigint;
BEGIN
  FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname='analytics_md_fix'
           AND matviewname LIKE 'mv_engagement_%' AND matviewname <> 'mv_user_posts_engagement'
           ORDER BY pg_relation_size('analytics_md_fix.'||quote_ident(matviewname)) LOOP
    slug := substring(r.matviewname FROM length('mv_engagement_')+1);
    t0 := clock_timestamp();
    CALL mindshare_score_md_fix.build_features_full(slug);
    EXECUTE format('SELECT count(*) FROM mindshare_score_md_fix.%I','features_'||slug) INTO n;
    INSERT INTO mindshare_score_md_fix._bench_log(project,method,detail,rows_out,elapsed_ms)
    VALUES (slug,'rollout_full_build','build_features_full',n,EXTRACT(epoch FROM clock_timestamp()-t0)*1000);
    COMMIT;
  END LOOP;
END $$;

CREATE OR REPLACE PROCEDURE mindshare_score_md_fix.refresh_all_features_incremental()
LANGUAGE plpgsql AS $$
DECLARE r record; slug text;
BEGIN
  FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname='analytics_md_fix'
           AND matviewname LIKE 'mv_engagement_%' AND matviewname <> 'mv_user_posts_engagement' LOOP
    slug := substring(r.matviewname FROM length('mv_engagement_')+1);
    CALL mindshare_score_md_fix.refresh_features_incremental(slug);
    COMMIT;
  END LOOP;
END $$;

-- API: read the table instead of the MV (farming_score index makes top-N ~110× faster).
CREATE OR REPLACE FUNCTION mindshare_score_md_fix.get_engagement_clustering(start_ts bigint, end_ts bigint, project_keyword text)
 RETURNS TABLE(root_post_id text, root_user_id text, root_username text, root_tweet_created_at timestamptz, total_engagements bigint, burst_concentration numeric, duration_days_p90 numeric, cross_post_overlap numeric, coordinated_burst numeric, farming_score numeric)
 LANGUAGE plpgsql STABLE AS $function$
DECLARE tbl text := format('mindshare_score_md_fix.features_%s', lower(replace(project_keyword,' ','_')));
BEGIN
    RETURN QUERY EXECUTE format($q$
        SELECT root_post_id::text, root_user_id::text, root_username::text, root_tweet_created_at::timestamptz,
               total_engagements::bigint, burst_concentration::numeric, duration_days_p90::numeric,
               cross_post_overlap::numeric, coordinated_burst::numeric, farming_score::numeric
        FROM %s
        WHERE root_tweet_created_at >= to_timestamp(%L) AND root_tweet_created_at <= to_timestamp(%L)
        ORDER BY farming_score DESC
    $q$, tbl, start_ts, end_ts);
END;
$function$;
