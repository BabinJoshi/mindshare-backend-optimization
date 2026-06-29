-- ============================================================================
-- decay_13_tail_cores.sql  —  TAIL-from-T_min replay cores for incremental decay
-- ----------------------------------------------------------------------------
-- The full-per-replier replay (decay_02/03 cores) recomputes a dirty replier's
-- ENTIRE history. For a recent append that is wasteful: only the tail (from the
-- earliest CHANGED reply, t_min) actually changes. These cores recompute only
-- rows with post_created_at >= t_min per replier, SEEDING the 30-day penalty
-- window from the already-stored rows.
--
-- Window reconstruction: each stored contribution row's
--   active_multipliers[array_upper(active_multipliers,1)]
-- is THAT reply's own penalty multiplier (the value appended when it was scored);
-- together with its post_created_at + original_author_x_id this rebuilds the
-- (mult,time,author) penalty log as of t_min. reply_seq is seeded from the count
-- of stored rows before t_min.
--
-- Input: a TEMP TABLE tmp_dirty(replier_x_id text, t_min timestamptz) populated
-- by the caller (decay_11/decay_12). The caller also deletes the tail
-- (post_created_at >= t_min) for those repliers before invoking the core.
-- t_min = '-infinity' forces a full replay of that replier (used for base-score drift).
-- ============================================================================

CREATE OR REPLACE FUNCTION test_mindshare_score._decay_apply_project_tail(
    p_project_keyword text,
    p_reset_interval  interval,
    p_run_id          bigint,
    p_log_every       integer
) RETURNS bigint
LANGUAGE plpgsql
SET random_page_cost = 1.1
SET work_mem = '256MB'
SET search_path = test_mindshare, test_mindshare_score, public
AS $func$
DECLARE
    v_count          bigint := 0;
    rec              RECORD;
    prev_replier     TEXT          := NULL;
    base_score       NUMERIC; min_floor NUMERIC; calc_score NUMERIC; effective_score NUMERIC;
    reply_seq        INT; local_seq INT; dtype TEXT; new_mult NUMERIC;
    penalty_mults    NUMERIC[]; penalty_times TIMESTAMPTZ[]; penalty_authors TEXT[];
    i INT; n INT; active_product NUMERIC; cutoff_time TIMESTAMPTZ;
    new_mults NUMERIC[]; new_times TIMESTAMPTZ[]; new_authors TEXT[];
    v_seed_from TIMESTAMPTZ;
BEGIN
    FOR rec IN
        SELECT p.project_keyword, p.post_id, op.post_id AS original_post_id,
               p.user_x_id AS replier_x_id, p.post_created_at,
               op.user_x_id AS original_author_x_id, u.score AS replier_base_score, d.t_min
        FROM tmp_dirty d
        JOIN test_mindshare.mindshare_post p
          ON p.project_keyword = p_project_keyword AND p.user_x_id = d.replier_x_id
         AND p.replied_post_id IS NOT NULL AND p.post_created_at >= d.t_min
        JOIN test_mindshare.mindshare_post op
          ON p.replied_post_id = op.post_id AND op.project_keyword = p_project_keyword
        JOIN test_mindshare.mindshare_user u ON u.x_id = p.user_x_id
        ORDER BY p.user_x_id, p.post_created_at, p.post_id
    LOOP
        IF rec.replier_x_id IS DISTINCT FROM prev_replier THEN
            prev_replier := rec.replier_x_id;
            base_score   := rec.replier_base_score;
            min_floor    := ROUND(base_score * 0.01, 2);
            v_seed_from  := rec.t_min - p_reset_interval;
            -- (a) window arrays: ONLY the 30-day window before t_min (bounded range scan)
            SELECT
                COALESCE(array_agg(own_mult ORDER BY post_created_at), ARRAY[]::numeric[]),
                COALESCE(array_agg(post_created_at ORDER BY post_created_at), ARRAY[]::timestamptz[]),
                COALESCE(array_agg(original_author_x_id ORDER BY post_created_at), ARRAY[]::text[])
            INTO penalty_mults, penalty_times, penalty_authors
            FROM (
                SELECT post_created_at, original_author_x_id,
                       active_multipliers[array_upper(active_multipliers,1)] AS own_mult
                FROM test_mindshare_score.contribution_scores
                WHERE project_keyword = p_project_keyword AND replier_x_id = rec.replier_x_id
                  AND post_created_at > v_seed_from AND post_created_at < rec.t_min
            ) s;
            -- (b) reply_seq seed = reply_number of the LAST row before t_min (single indexed row;
            --     reply_number increases with (post_created_at, post_id), so the last one is the max)
            SELECT COALESCE(reply_number, 0) INTO reply_seq
            FROM test_mindshare_score.contribution_scores
            WHERE project_keyword = p_project_keyword AND replier_x_id = rec.replier_x_id
              AND post_created_at < rec.t_min
            ORDER BY post_created_at DESC, reply_post_id DESC
            LIMIT 1;
            reply_seq := COALESCE(reply_seq, 0);
        END IF;

        reply_seq := reply_seq + 1;

        cutoff_time := rec.post_created_at - p_reset_interval;
        new_mults := ARRAY[]::numeric[]; new_times := ARRAY[]::timestamptz[]; new_authors := ARRAY[]::text[];
        n := COALESCE(array_length(penalty_mults,1),0);
        FOR i IN 1..n LOOP
            IF penalty_times[i] > cutoff_time THEN
                new_mults := array_append(new_mults, penalty_mults[i]);
                new_times := array_append(new_times, penalty_times[i]);
                new_authors := array_append(new_authors, penalty_authors[i]);
            END IF;
        END LOOP;
        penalty_mults := new_mults; penalty_times := new_times; penalty_authors := new_authors;

        local_seq := 0;
        n := COALESCE(array_length(penalty_authors,1),0);
        FOR i IN 1..n LOOP IF penalty_authors[i] = rec.original_author_x_id THEN local_seq := local_seq + 1; END IF; END LOOP;
        local_seq := local_seq + 1;

        active_product := 1.0;
        n := COALESCE(array_length(penalty_mults,1),0);
        FOR i IN 1..n LOOP active_product := active_product * penalty_mults[i]; END LOOP;
        effective_score := GREATEST(ROUND(base_score * active_product, 2), min_floor);
        calc_score := effective_score;

        IF n = 0 THEN dtype := 'FIRST_REPLY'; new_mult := 1.0;
        ELSIF local_seq > 1 THEN new_mult := 0.50; calc_score := GREATEST(ROUND(calc_score*0.50,2),min_floor); dtype := 'LOCAL_DECAY';
        ELSE new_mult := 0.90; calc_score := GREATEST(ROUND(calc_score*0.90,2),min_floor); dtype := 'GLOBAL_DECAY';
        END IF;

        penalty_mults := array_append(penalty_mults, new_mult);
        penalty_times := array_append(penalty_times, rec.post_created_at);
        penalty_authors := array_append(penalty_authors, rec.original_author_x_id);

        INSERT INTO test_mindshare_score.contribution_scores (
            project_keyword, reply_post_id, original_post_id, replier_x_id, original_author_x_id,
            post_created_at, replier_base_score, effective_score, contribution_score,
            active_multipliers, reply_number, local_reply_count, decay_type
        ) VALUES (
            rec.project_keyword, rec.post_id, rec.original_post_id, rec.replier_x_id, rec.original_author_x_id,
            rec.post_created_at, rec.replier_base_score, effective_score, ROUND(calc_score,2),
            penalty_mults, reply_seq, local_seq, dtype
        );

        v_count := v_count + 1;
        IF p_log_every > 0 AND v_count % p_log_every = 0 THEN
            PERFORM test_mindshare_score._decay_log(p_run_id,'project',p_project_keyword,'running','writing',
                format('%s tail rows written...', v_count), v_count);
        END IF;
    END LOOP;
    RETURN v_count;
END;
$func$;


CREATE OR REPLACE FUNCTION test_mindshare_score._decay_apply_global_tail(
    p_reset_interval interval,
    p_run_id         bigint,
    p_log_every      integer
) RETURNS bigint
LANGUAGE plpgsql
SET random_page_cost = 1.1
SET work_mem = '256MB'
SET search_path = test_mindshare, test_mindshare_score, public
AS $func$
DECLARE
    v_count bigint := 0;
    rec RECORD;
    prev_replier TEXT := NULL;
    base_score NUMERIC; min_floor NUMERIC; calc_score NUMERIC; effective_score NUMERIC;
    reply_seq INT; local_seq INT; dtype TEXT; new_mult NUMERIC;
    penalty_mults NUMERIC[]; penalty_times TIMESTAMPTZ[]; penalty_authors TEXT[];
    i INT; n INT; active_product NUMERIC; cutoff_time TIMESTAMPTZ;
    new_mults NUMERIC[]; new_times TIMESTAMPTZ[]; new_authors TEXT[];
    v_seed_from TIMESTAMPTZ;
BEGIN
    FOR rec IN
        SELECT p.post_id AS reply_post_id, op.post_id AS original_post_id,
               p.user_x_id AS replier_x_id, p.post_created_at,
               op.user_x_id AS original_author_x_id, u.score AS replier_base_score, d.t_min
        FROM tmp_dirty d
        JOIN test_mindshare.user_post p
          ON p.user_x_id = d.replier_x_id AND p.replied_post_id IS NOT NULL AND p.post_created_at >= d.t_min
        JOIN test_mindshare.user_post op ON p.replied_post_id = op.post_id
        JOIN test_mindshare.mindshare_user u ON u.x_id = p.user_x_id
        ORDER BY p.user_x_id, p.post_created_at, p.post_id
    LOOP
        IF rec.replier_x_id IS DISTINCT FROM prev_replier THEN
            prev_replier := rec.replier_x_id;
            base_score   := rec.replier_base_score;
            min_floor    := ROUND(base_score * 0.01, 2);
            v_seed_from  := rec.t_min - p_reset_interval;
            -- (a) window arrays: ONLY the 30-day window before t_min (bounded range scan)
            SELECT
                COALESCE(array_agg(own_mult ORDER BY post_created_at), ARRAY[]::numeric[]),
                COALESCE(array_agg(post_created_at ORDER BY post_created_at), ARRAY[]::timestamptz[]),
                COALESCE(array_agg(original_author_x_id ORDER BY post_created_at), ARRAY[]::text[])
            INTO penalty_mults, penalty_times, penalty_authors
            FROM (
                SELECT post_created_at, original_author_x_id,
                       active_multipliers[array_upper(active_multipliers,1)] AS own_mult
                FROM test_mindshare_score.global_contribution_scores
                WHERE replier_x_id = rec.replier_x_id
                  AND post_created_at > v_seed_from AND post_created_at < rec.t_min
            ) s;
            -- (b) reply_seq seed = reply_number of the LAST row before t_min (single indexed row)
            SELECT COALESCE(reply_number, 0) INTO reply_seq
            FROM test_mindshare_score.global_contribution_scores
            WHERE replier_x_id = rec.replier_x_id AND post_created_at < rec.t_min
            ORDER BY post_created_at DESC, reply_post_id DESC
            LIMIT 1;
            reply_seq := COALESCE(reply_seq, 0);
        END IF;

        reply_seq := reply_seq + 1;

        cutoff_time := rec.post_created_at - p_reset_interval;
        new_mults := ARRAY[]::numeric[]; new_times := ARRAY[]::timestamptz[]; new_authors := ARRAY[]::text[];
        n := COALESCE(array_length(penalty_mults,1),0);
        FOR i IN 1..n LOOP
            IF penalty_times[i] > cutoff_time THEN
                new_mults := array_append(new_mults, penalty_mults[i]);
                new_times := array_append(new_times, penalty_times[i]);
                new_authors := array_append(new_authors, penalty_authors[i]);
            END IF;
        END LOOP;
        penalty_mults := new_mults; penalty_times := new_times; penalty_authors := new_authors;

        local_seq := 0;
        n := COALESCE(array_length(penalty_authors,1),0);
        FOR i IN 1..n LOOP IF penalty_authors[i] = rec.original_author_x_id THEN local_seq := local_seq + 1; END IF; END LOOP;
        local_seq := local_seq + 1;

        active_product := 1.0;
        n := COALESCE(array_length(penalty_mults,1),0);
        FOR i IN 1..n LOOP active_product := active_product * penalty_mults[i]; END LOOP;
        effective_score := GREATEST(ROUND(base_score * active_product, 2), min_floor);
        calc_score := effective_score;

        IF n = 0 THEN dtype := 'FIRST_REPLY'; new_mult := 1.0;
        ELSIF local_seq > 1 THEN new_mult := 0.50; calc_score := GREATEST(ROUND(calc_score*0.50,2),min_floor); dtype := 'LOCAL_DECAY';
        ELSE new_mult := 0.90; calc_score := GREATEST(ROUND(calc_score*0.90,2),min_floor); dtype := 'GLOBAL_DECAY';
        END IF;

        penalty_mults := array_append(penalty_mults, new_mult);
        penalty_times := array_append(penalty_times, rec.post_created_at);
        penalty_authors := array_append(penalty_authors, rec.original_author_x_id);

        INSERT INTO test_mindshare_score.global_contribution_scores (
            reply_post_id, original_post_id, replier_x_id, original_author_x_id,
            post_created_at, replier_base_score, effective_score, contribution_score,
            active_multipliers, reply_number, local_reply_count, decay_type
        ) VALUES (
            rec.reply_post_id, rec.original_post_id, rec.replier_x_id, rec.original_author_x_id,
            rec.post_created_at, rec.replier_base_score, effective_score, ROUND(calc_score,2),
            penalty_mults, reply_seq, local_seq, dtype
        );

        v_count := v_count + 1;
        IF p_log_every > 0 AND v_count % p_log_every = 0 THEN
            PERFORM test_mindshare_score._decay_log(p_run_id,'global',NULL,'running','writing',
                format('%s tail rows written...', v_count), v_count);
        END IF;
    END LOOP;
    RETURN v_count;
END;
$func$;
