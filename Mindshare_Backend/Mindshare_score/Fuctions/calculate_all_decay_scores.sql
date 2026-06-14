-- DROP FUNCTION mindshare_score.calculate_all_decay_scores(interval);

CREATE OR REPLACE FUNCTION mindshare_score.calculate_all_decay_scores(p_reset_interval interval DEFAULT '30 days'::interval)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    proj    RECORD;
    t_start TIMESTAMP;
    t_end   TIMESTAMP;
    cnt     BIGINT;
BEGIN
    TRUNCATE mindshare_score.contribution_scores;

    FOR proj IN
        SELECT DISTINCT project_keyword
        FROM mindshare.mindshare_post
        WHERE is_reply = true
        ORDER BY project_keyword
    LOOP
        t_start := clock_timestamp();
        RAISE NOTICE 'Processing: %', proj.project_keyword;

        PERFORM mindshare_score.calculate_decay_scores(proj.project_keyword, p_reset_interval);

        t_end := clock_timestamp();
        SELECT count(*) INTO cnt
        FROM mindshare_score.contribution_scores
        WHERE project_keyword = proj.project_keyword;

        RAISE NOTICE '  → % done — % rows in % sec',
            proj.project_keyword, cnt,
            ROUND(EXTRACT(EPOCH FROM (t_end - t_start))::NUMERIC, 2);
    END LOOP;

    RAISE NOTICE 'Creating indexes...';
    CREATE INDEX IF NOT EXISTS idx_cs_keyword_author
        ON mindshare_score.contribution_scores (project_keyword, original_author_x_id);
    CREATE INDEX IF NOT EXISTS idx_cs_keyword_replier
        ON mindshare_score.contribution_scores (project_keyword, replier_x_id);
    CREATE INDEX IF NOT EXISTS idx_cs_post_created
        ON mindshare_score.contribution_scores (post_created_at);
    CREATE INDEX IF NOT EXISTS idx_cs_reply_post_id
        ON mindshare_score.contribution_scores (reply_post_id);
    CREATE INDEX IF NOT EXISTS idx_cs_original_post_id
        ON mindshare_score.contribution_scores (original_post_id);

    RAISE NOTICE 'All projects processed!';
END;
$function$
;