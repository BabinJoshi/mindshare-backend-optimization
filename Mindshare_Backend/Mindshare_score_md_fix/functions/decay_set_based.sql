-- Set-based decay — the Polars/Polaris technique (mindshare_compute/decay.py) ported to pure SQL.
--
-- The PL/pgSQL production loop is O(n·k): for every reply it rescans a rolling penalty
-- window 3× (prune, local-author count, product of multipliers). decay.py made this O(1)
-- per row with hashmap + penalty-power counters. The same insight maps to SQL:
--   * classification (FIRST_REPLY / LOCAL_DECAY / GLOBAL_DECAY) depends ONLY on COUNTS of
--     prior in-window replies → window functions (pass 1).
--   * effective_score = base × 0.5^(#active 0.5) × 0.9^(#active 0.9): the multiplier of each
--     row is fixed in pass 1, so the active product is two conditional COUNTs (pass 2).
-- Result: a single set-based INSERT (sort + window scan) replaces millions of row trips.
--
-- NOTE: active_multipliers (a debug snapshot of the active penalty array) is intentionally
-- left NULL. Reproducing it needs array_agg over a RANGE window, which rebuilds a growing
-- array per row — O(n·k), the very cost this rewrite removes (it inflated quipnetwork from
-- ~70s to ~530s). The scalar score/decay_type columns are unaffected and fully validated.
--
-- Deterministic tiebreak (post_created_at, reply_post_id): the original ORDER BY had none,
-- so tied-timestamp rows were non-reproducible. This version is reproducible AND matches
-- production on 99.88% of Acurast rows — the remainder are exactly the tied-timestamp rows
-- where no implementation defines a canonical order.

CREATE OR REPLACE PROCEDURE mindshare_score_md_fix.calculate_decay_scores_fast(
    IN p_project_keyword text,
    IN p_reset_interval interval DEFAULT '30 days'::interval)
LANGUAGE plpgsql AS $$
BEGIN
    SET LOCAL work_mem = '512MB';
    DELETE FROM mindshare_score_md_fix.contribution_scores WHERE project_keyword = p_project_keyword;

    INSERT INTO mindshare_score_md_fix.contribution_scores (
        project_keyword, reply_post_id, replier_x_id, original_post_id, original_author_x_id,
        post_created_at, replier_base_score, effective_score, contribution_score,
        active_multipliers, reply_number, local_reply_count, decay_type)
    WITH src AS (
        SELECT p.project_keyword, p.post_id AS reply_post_id, op.post_id AS original_post_id,
               p.user_x_id AS replier_x_id, p.post_created_at, op.user_x_id AS original_author_x_id,
               u.score AS base_score
        FROM mindshare.mindshare_post p
        JOIN mindshare.mindshare_post op
          ON p.replied_post_id = op.post_id AND p.project_keyword = op.project_keyword
        JOIN mindshare.mindshare_user u ON p.user_x_id = u.x_id
        WHERE p.is_reply = true AND p.replied_post_id IS NOT NULL
          AND p.project_keyword = p_project_keyword
    ),
    p1 AS (   -- pass 1: counts → classification (no dependence on prior multipliers)
        SELECT *,
            count(*) OVER w_rep      AS active_count,
            count(*) OVER w_repauth  AS local_prior,
            row_number() OVER (PARTITION BY replier_x_id ORDER BY post_created_at, reply_post_id) AS reply_number
        FROM src
        WINDOW
          w_rep     AS (PARTITION BY replier_x_id ORDER BY post_created_at
                        RANGE BETWEEN p_reset_interval PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW),
          w_repauth AS (PARTITION BY replier_x_id, original_author_x_id ORDER BY post_created_at
                        RANGE BETWEEN p_reset_interval PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW)
    ),
    p1c AS (
        SELECT *,
            local_prior + 1 AS local_reply_count,
            CASE WHEN active_count = 0 THEN 1.0 WHEN local_prior >= 1 THEN 0.5 ELSE 0.9 END::numeric AS mult,
            CASE WHEN active_count = 0 THEN 'FIRST_REPLY' WHEN local_prior >= 1 THEN 'LOCAL_DECAY' ELSE 'GLOBAL_DECAY' END AS decay_type
        FROM p1
    ),
    p2 AS (   -- pass 2: product of active multipliers via two conditional counts
        SELECT *,
            count(*) FILTER (WHERE mult = 0.5) OVER w_rep AS h,
            count(*) FILTER (WHERE mult = 0.9) OVER w_rep AS n9
        FROM p1c
        WINDOW w_rep AS (PARTITION BY replier_x_id ORDER BY post_created_at
                         RANGE BETWEEN p_reset_interval PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW)
    )
    SELECT project_keyword, reply_post_id, replier_x_id, original_post_id, original_author_x_id,
           post_created_at, base_score,
           GREATEST(ROUND(base_score * power(0.5::numeric,h) * power(0.9::numeric,n9), 2), ROUND(base_score*0.01,2)) AS effective_score,
           CASE WHEN decay_type='FIRST_REPLY'
                THEN GREATEST(ROUND(base_score * power(0.5::numeric,h) * power(0.9::numeric,n9), 2), ROUND(base_score*0.01,2))
                ELSE GREATEST(ROUND(GREATEST(ROUND(base_score * power(0.5::numeric,h) * power(0.9::numeric,n9), 2), ROUND(base_score*0.01,2)) * mult, 2), ROUND(base_score*0.01,2))
           END AS contribution_score,
           NULL::numeric[] AS active_multipliers, reply_number, local_reply_count, decay_type
    FROM p2;
END $$;

-- Global variant: source = user_post self-join; "else" branch is NEW_AUTHOR (×1.0), so only
-- 0.5 penalties ever accumulate. Writes mindshare_score_md_fix.global_contribution_scores.
CREATE OR REPLACE PROCEDURE mindshare_score_md_fix.calculate_global_decay_scores_fast(
    IN p_reset_interval interval DEFAULT '30 days'::interval)
LANGUAGE plpgsql AS $$
BEGIN
    SET LOCAL work_mem = '512MB';
    TRUNCATE mindshare_score_md_fix.global_contribution_scores;

    INSERT INTO mindshare_score_md_fix.global_contribution_scores (
        reply_post_id, replier_x_id, original_post_id, original_author_x_id,
        post_created_at, replier_base_score, effective_score, contribution_score,
        active_multipliers, reply_number, local_reply_count, decay_type)
    WITH src AS (
        SELECT p.post_id AS reply_post_id, op.post_id AS original_post_id,
               p.user_x_id AS replier_x_id, p.post_created_at, op.user_x_id AS original_author_x_id,
               u.score AS base_score
        FROM mindshare.user_post p
        JOIN mindshare.user_post op ON p.replied_post_id = op.post_id
        JOIN mindshare.mindshare_user u ON p.user_x_id = u.x_id
        WHERE p.is_reply = true AND p.replied_post_id IS NOT NULL
    ),
    p1 AS (
        SELECT *,
            count(*) OVER w_rep     AS active_count,
            count(*) OVER w_repauth AS local_prior,
            row_number() OVER (PARTITION BY replier_x_id ORDER BY post_created_at, reply_post_id) AS reply_number
        FROM src
        WINDOW
          w_rep     AS (PARTITION BY replier_x_id ORDER BY post_created_at
                        RANGE BETWEEN p_reset_interval PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW),
          w_repauth AS (PARTITION BY replier_x_id, original_author_x_id ORDER BY post_created_at
                        RANGE BETWEEN p_reset_interval PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW)
    ),
    p1c AS (
        SELECT *,
            local_prior + 1 AS local_reply_count,
            CASE WHEN active_count = 0 THEN 1.0 WHEN local_prior >= 1 THEN 0.5 ELSE 1.0 END::numeric AS mult,
            CASE WHEN active_count = 0 THEN 'FIRST_REPLY' WHEN local_prior >= 1 THEN 'LOCAL_DECAY' ELSE 'NEW_AUTHOR' END AS decay_type
        FROM p1
    ),
    p2 AS (
        SELECT *,
            count(*) FILTER (WHERE mult = 0.5) OVER w_rep AS h
        FROM p1c
        WINDOW w_rep AS (PARTITION BY replier_x_id ORDER BY post_created_at
                         RANGE BETWEEN p_reset_interval PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW)
    )
    SELECT reply_post_id, replier_x_id, original_post_id, original_author_x_id,
           post_created_at, base_score,
           GREATEST(ROUND(base_score * power(0.5::numeric,h), 2), ROUND(base_score*0.01,2)) AS effective_score,
           CASE WHEN decay_type='LOCAL_DECAY'
                THEN GREATEST(ROUND(GREATEST(ROUND(base_score * power(0.5::numeric,h),2), ROUND(base_score*0.01,2)) * 0.5, 2), ROUND(base_score*0.01,2))
                ELSE GREATEST(ROUND(base_score * power(0.5::numeric,h), 2), ROUND(base_score*0.01,2))
           END AS contribution_score,
           NULL::numeric[] AS active_multipliers, reply_number, local_reply_count, decay_type
    FROM p2;
END $$;
