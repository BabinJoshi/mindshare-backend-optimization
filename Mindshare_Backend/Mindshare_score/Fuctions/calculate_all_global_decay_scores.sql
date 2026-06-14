-- DROP FUNCTION mindshare_score.calculate_all_global_decay_scores(interval);

CREATE OR REPLACE FUNCTION mindshare_score.calculate_all_global_decay_scores(p_reset_interval interval DEFAULT '30 days'::interval)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    t_start TIMESTAMP;
    t_end   TIMESTAMP;
    cnt     BIGINT;
BEGIN
    TRUNCATE mindshare_score.global_contribution_scores;

    t_start := clock_timestamp();
    RAISE NOTICE 'Processing user contribution scores...';

    PERFORM mindshare_score.calculate_global_decay_scores(p_reset_interval);

    t_end := clock_timestamp();
    SELECT count(*) INTO cnt
    FROM mindshare_score.global_contribution_scores;

    RAISE NOTICE 'Done - % rows in % sec',
        cnt,
        ROUND(EXTRACT(EPOCH FROM (t_end - t_start))::NUMERIC, 2);

    RAISE NOTICE 'Creating indexes...';
    CREATE INDEX IF NOT EXISTS idx_ucs_replier
        ON mindshare_score.global_contribution_scores (replier_x_id);
    CREATE INDEX IF NOT EXISTS idx_ucs_original_author
        ON mindshare_score.global_contribution_scores (original_author_x_id);
    CREATE INDEX IF NOT EXISTS idx_ucs_post_created
        ON mindshare_score.global_contribution_scores (post_created_at);
    CREATE INDEX IF NOT EXISTS idx_ucs_reply_post_id
        ON mindshare_score.global_contribution_scores (reply_post_id);
    CREATE INDEX IF NOT EXISTS idx_ucs_original_post_id
        ON mindshare_score.global_contribution_scores (original_post_id);

    RAISE NOTICE 'User contribution scores processed!';
END;
$function$
;