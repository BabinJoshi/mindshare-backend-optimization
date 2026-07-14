-- One-time cutover: drop the OLD matview-based engagement pipeline in analytics_md_fix
-- before switching to the incremental table version. Run this once, then bootstrap
-- (see benchmark/bench_full_vs_incremental.sql or just CALL refresh_engagement_all()).
--
-- Deliberately does NOT touch the read/query functions (get_all_users_analytics,
-- get_user_analytics, get_user_posts_analytics, get_v2_user_posts_analytics) — they are
-- consumers, not part of the build pipeline, and this repo doesn't have their live
-- analytics_md_fix-specific source to redeploy if dropped. get_v2_user_posts_analytics
-- in particular does `analytics_md_fix.%I` on 'mv_engagement_<project>' — which is
-- exactly why the new tables below keep that same name instead of renaming.

DO $$
DECLARE
    r record;
BEGIN
    -- All per-project engagement matviews (mv_engagement_*), whatever projects exist today.
    FOR r IN
        SELECT matviewname FROM pg_matviews
        WHERE schemaname = 'analytics_md_fix' AND matviewname LIKE 'mv_engagement_%'
    LOOP
        EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS analytics_md_fix.%I CASCADE', r.matviewname);
        RAISE NOTICE 'Dropped matview analytics_md_fix.%', r.matviewname;
    END LOOP;
END;
$$;

DROP MATERIALIZED VIEW IF EXISTS analytics_md_fix.mv_user_posts_engagement CASCADE;

-- Old build/refresh pipeline procedures, superseded by:
--   create_engagement_view(text)             -> create_engagement_table_full(text)
--   create_user_posts_engagement_view()       -> create_user_posts_engagement_table_full()
--   refresh_engagement_views_all()            -> refresh_engagement_all() [+ refresh_engagement_incremental(text)]
--   run_create_engagement_views()             -> refresh_engagement_all() (bootstraps on first call per project)
DROP PROCEDURE IF EXISTS analytics_md_fix.create_engagement_view(text);
DROP PROCEDURE IF EXISTS analytics_md_fix.create_user_posts_engagement_view();
DROP PROCEDURE IF EXISTS analytics_md_fix.refresh_engagement_views_all();
DROP PROCEDURE IF EXISTS analytics_md_fix.run_create_engagement_views();
