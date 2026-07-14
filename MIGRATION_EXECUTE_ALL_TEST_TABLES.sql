-- ============================================================================
-- MIGRATION_EXECUTE_ALL_TEST_TABLES.sql
-- Master script to replicate incremental decay from test to prod schemas
-- BUT writes to _test versions of score tables for validation before going live
--
-- Differences from MIGRATION_EXECUTE_ALL.sql:
--   - Writes to: contribution_scores_test, global_contribution_scores_test
--   - Reads from: mindshare, mindshare_user, user_post (production source tables)
--   - Logging: Uses same decay_run_log and decay_run_state
--   - Purpose: Validate incremental logic before writing to live tables
--
-- This allows you to:
--   1. Run incremental decay on prod data
--   2. Validate results in _test tables
--   3. Compare with production tables
--   4. Switch to live tables once validated
--
-- Connection: postgresql://postgres_user:postgres_pass@195.35.23.78:5432/mindshare_db
-- ============================================================================

-- ============================================================================
-- PHASE 1-2: INFRASTRUCTURE SETUP
-- Logging infrastructure and sequences
-- (Score tables created in Phase 3 below)
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS dblink;

CREATE SEQUENCE IF NOT EXISTS mindshare_score.decay_run_id_seq
    START WITH 1 INCREMENT BY 1;

CREATE TABLE IF NOT EXISTS mindshare_score.decay_run_state (
    scope               text        PRIMARY KEY,
    last_ingest_ts      timestamptz NOT NULL,
    last_user_ingest_ts timestamptz,
    last_run_at         timestamptz NOT NULL DEFAULT now(),
    last_run_id         bigint,
    dirty_repliers      bigint,
    rows_written        bigint
);

CREATE TABLE IF NOT EXISTS mindshare_score.decay_run_log (
    run_id          bigint      NOT NULL PRIMARY KEY,
    scope           text        NOT NULL,
    project_keyword text,
    status          text        NOT NULL,
    phase           text,
    message         text,
    rows_processed  bigint      NOT NULL DEFAULT 0,
    error_sqlstate  text,
    error_message   text,
    error_detail    text,
    error_context   text,
    started_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz
);

CREATE INDEX IF NOT EXISTS ix_decay_run_log_recent
    ON mindshare_score.decay_run_log (started_at DESC);

-- Autonomous logging function
CREATE OR REPLACE FUNCTION mindshare_score._decay_log(
    p_run_id    bigint,
    p_scope     text,
    p_project   text,
    p_status    text,
    p_phase     text,
    p_message   text,
    p_rows      bigint  DEFAULT 0,
    p_sqlstate  text    DEFAULT NULL,
    p_errmsg    text    DEFAULT NULL,
    p_detail    text    DEFAULT NULL,
    p_context   text    DEFAULT NULL,
    p_finished  boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql
SET search_path = mindshare_score, public
AS $$
DECLARE
    v_conn text := 'host=127.0.0.1 port=5432 dbname=mindshare_db user=postgres_user password=postgres_pass';
    v_sql  text;
BEGIN
    v_sql := format($f$
        INSERT INTO mindshare_score.decay_run_log
            (run_id, scope, project_keyword, status, phase, message, rows_processed,
             error_sqlstate, error_message, error_detail, error_context,
             started_at, updated_at, finished_at)
        VALUES (%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L, now(), now(), %s)
        ON CONFLICT (run_id) DO UPDATE SET
            status         = EXCLUDED.status,
            phase          = EXCLUDED.phase,
            message        = EXCLUDED.message,
            rows_processed = EXCLUDED.rows_processed,
            error_sqlstate = COALESCE(EXCLUDED.error_sqlstate, decay_run_log.error_sqlstate),
            error_message  = COALESCE(EXCLUDED.error_message,  decay_run_log.error_message),
            error_detail   = COALESCE(EXCLUDED.error_detail,   decay_run_log.error_detail),
            error_context  = COALESCE(EXCLUDED.error_context,  decay_run_log.error_context),
            updated_at     = now(),
            finished_at    = COALESCE(EXCLUDED.finished_at, decay_run_log.finished_at)
    $f$,
        p_run_id, p_scope, p_project, p_status, p_phase, p_message, p_rows,
        p_sqlstate, p_errmsg, p_detail, p_context,
        CASE WHEN p_finished THEN 'now()' ELSE 'NULL' END);
    PERFORM public.dblink(v_conn, v_sql);
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION mindshare_score.next_decay_run_id()
RETURNS bigint LANGUAGE sql
AS $$ SELECT nextval('mindshare_score.decay_run_id_seq') $$;

-- ============================================================================
-- CREATE TEST SCORE TABLES (if they don't exist)
-- ============================================================================

CREATE TABLE IF NOT EXISTS mindshare_score.contribution_scores_test (
    project_keyword       text        NOT NULL,
    reply_post_id         text        NOT NULL,
    replier_x_id          text        NOT NULL,
    original_post_id      text        NOT NULL,
    original_author_x_id  text        NOT NULL,
    post_created_at       timestamptz NOT NULL,
    replier_base_score    numeric     NOT NULL,
    effective_score       numeric     NOT NULL,
    contribution_score    numeric     NOT NULL,
    active_multipliers    numeric[]   NOT NULL,
    reply_number          integer     NOT NULL,
    local_reply_count     integer     NOT NULL,
    decay_type            text        NOT NULL,
    CONSTRAINT pk_tcs_test PRIMARY KEY (project_keyword, reply_post_id)
);

CREATE TABLE IF NOT EXISTS mindshare_score.global_contribution_scores_test (
    reply_post_id         text        NOT NULL,
    original_post_id      text        NOT NULL,
    replier_x_id          text        NOT NULL,
    original_author_x_id  text        NOT NULL,
    post_created_at       timestamptz NOT NULL,
    replier_base_score    numeric     NOT NULL,
    effective_score       numeric     NOT NULL,
    contribution_score    numeric     NOT NULL,
    active_multipliers    numeric[]   NOT NULL,
    reply_number          integer     NOT NULL,
    local_reply_count     integer     NOT NULL,
    decay_type            text        NOT NULL,
    CONSTRAINT pk_tgcs_test PRIMARY KEY (reply_post_id)
);

-- Create indexes on test tables
CREATE INDEX IF NOT EXISTS ix_tcs_test_keyword_orig_replier_time
    ON mindshare_score.contribution_scores_test
       (project_keyword, original_post_id, replier_x_id, post_created_at)
    INCLUDE (original_author_x_id, contribution_score);

CREATE INDEX IF NOT EXISTS ix_tcs_test_keyword_replier_time
    ON mindshare_score.contribution_scores_test (project_keyword, replier_x_id, post_created_at);

CREATE INDEX IF NOT EXISTS ix_tgcs_test_orig_replier_time
    ON mindshare_score.global_contribution_scores_test
       (original_post_id, replier_x_id, post_created_at)
    INCLUDE (original_author_x_id, contribution_score);

CREATE INDEX IF NOT EXISTS ix_tgcs_test_replier_time
    ON mindshare_score.global_contribution_scores_test (replier_x_id, post_created_at);

-- ============================================================================
-- PHASE 3: INDEXES AND STATE MANAGEMENT
-- ============================================================================

CREATE INDEX IF NOT EXISTS ix_tmp_mp_ingest
    ON mindshare.mindshare_post (GREATEST(created_at, updated_at) DESC);

CREATE INDEX IF NOT EXISTS ix_tmp_up_ingest
    ON mindshare.user_post (GREATEST(created_at, updated_at) DESC);

CREATE INDEX IF NOT EXISTS ix_tmp_mu_ingest
    ON mindshare.mindshare_user (GREATEST(created_at, updated_at) DESC);

CREATE INDEX IF NOT EXISTS ix_tmp_mp_replied_post_id
    ON mindshare.mindshare_post (replied_post_id)
    WHERE replied_post_id IS NOT NULL;

-- Autovacuum tuning for test score tables
ALTER TABLE mindshare_score.contribution_scores_test
    SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.02);

ALTER TABLE mindshare_score.global_contribution_scores_test
    SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_analyze_scale_factor = 0.02);

-- Analyze tables for statistics
ANALYZE mindshare.mindshare_post;
ANALYZE mindshare.user_post;
ANALYZE mindshare.mindshare_user;
ANALYZE mindshare_score.contribution_scores_test;
ANALYZE mindshare_score.global_contribution_scores_test;

-- ============================================================================
-- PHASE 4: CORE DECAY FUNCTIONS (WRITES TO _TEST TABLES)
-- ============================================================================

CREATE OR REPLACE FUNCTION mindshare_score._decay_apply_project_test(
    p_project_keyword text,
    p_reset_interval  interval,
    p_run_id          bigint,
    p_only_dirty      boolean,
    p_log_every       integer
) RETURNS bigint
LANGUAGE plpgsql
SET random_page_cost = 1.1
SET work_mem = '256MB'
SET search_path = mindshare, mindshare_score, public
AS $func$
DECLARE
    v_count  bigint := 0;
    v_query  text;
    rec              RECORD;
    prev_replier     TEXT          := '';
    base_score       NUMERIC       := 0;
    min_floor        NUMERIC       := 0;
    calc_score       NUMERIC       := 0;
    effective_score  NUMERIC       := 0;
    reply_seq        INT           := 0;
    local_seq        INT           := 0;
    dtype            TEXT          := '';
    new_mult         NUMERIC       := 1.0;
    penalty_mults    NUMERIC[]     := ARRAY[]::NUMERIC[];
    penalty_times    TIMESTAMPTZ[] := ARRAY[]::TIMESTAMPTZ[];
    penalty_authors  TEXT[]        := ARRAY[]::TEXT[];
    i                INT;
    n                INT;
    active_product   NUMERIC;
    cutoff_time      TIMESTAMPTZ;
    new_mults        NUMERIC[];
    new_times        TIMESTAMPTZ[];
    new_authors      TEXT[];
BEGIN
    v_query :=
        'SELECT p.project_keyword, p.post_id, op.post_id AS original_post_id, '
        '       p.user_x_id AS replier_x_id, p.post_created_at, '
        '       op.user_x_id AS original_author_x_id, u.score AS replier_base_score '
        'FROM mindshare.mindshare_post p '
        'INNER JOIN mindshare.mindshare_post op '
        '    ON p.replied_post_id = op.post_id AND p.project_keyword = op.project_keyword '
        'INNER JOIN mindshare.mindshare_user u ON p.user_x_id = u.x_id '
        'WHERE p.replied_post_id IS NOT NULL AND p.project_keyword = $1 ';
    IF p_only_dirty THEN
        v_query := v_query || 'AND p.user_x_id IN (SELECT replier_x_id FROM tmp_dirty_repliers) ';
    END IF;
    v_query := v_query || 'ORDER BY p.user_x_id, p.post_created_at, p.post_id';

    FOR rec IN EXECUTE v_query USING p_project_keyword LOOP
        IF rec.replier_x_id IS DISTINCT FROM prev_replier THEN
            prev_replier    := rec.replier_x_id;
            base_score      := rec.replier_base_score;
            min_floor       := ROUND(base_score * 0.01, 2);
            reply_seq       := 0;
            penalty_mults   := ARRAY[]::NUMERIC[];
            penalty_times   := ARRAY[]::TIMESTAMPTZ[];
            penalty_authors := ARRAY[]::TEXT[];
        END IF;

        reply_seq := reply_seq + 1;
        cutoff_time := rec.post_created_at - p_reset_interval;
        new_mults   := ARRAY[]::NUMERIC[];
        new_times   := ARRAY[]::TIMESTAMPTZ[];
        new_authors := ARRAY[]::TEXT[];
        n := COALESCE(array_length(penalty_mults, 1), 0);
        FOR i IN 1 .. n LOOP
            IF penalty_times[i] > cutoff_time THEN
                new_mults   := array_append(new_mults,   penalty_mults[i]);
                new_times   := array_append(new_times,   penalty_times[i]);
                new_authors := array_append(new_authors, penalty_authors[i]);
            END IF;
        END LOOP;
        penalty_mults   := new_mults;
        penalty_times   := new_times;
        penalty_authors := new_authors;

        local_seq := 0;
        n := COALESCE(array_length(penalty_authors, 1), 0);
        FOR i IN 1 .. n LOOP
            IF penalty_authors[i] = rec.original_author_x_id THEN
                local_seq := local_seq + 1;
            END IF;
        END LOOP;
        local_seq := local_seq + 1;

        active_product := 1.0;
        n := COALESCE(array_length(penalty_mults, 1), 0);
        FOR i IN 1 .. n LOOP
            active_product := active_product * penalty_mults[i];
        END LOOP;
        effective_score := GREATEST(ROUND(base_score * active_product, 2), min_floor);
        calc_score      := effective_score;

        IF n = 0 THEN
            dtype := 'FIRST_REPLY'; new_mult := 1.0;
        ELSIF local_seq > 1 THEN
            new_mult := 0.50; calc_score := GREATEST(ROUND(calc_score * 0.50, 2), min_floor); dtype := 'LOCAL_DECAY';
        ELSE
            new_mult := 0.90; calc_score := GREATEST(ROUND(calc_score * 0.90, 2), min_floor); dtype := 'GLOBAL_DECAY';
        END IF;

        penalty_mults   := array_append(penalty_mults,   new_mult);
        penalty_times   := array_append(penalty_times,   rec.post_created_at);
        penalty_authors := array_append(penalty_authors, rec.original_author_x_id);

        -- WRITE TO _test TABLE
        INSERT INTO mindshare_score.contribution_scores_test (
            project_keyword, reply_post_id, original_post_id, replier_x_id, original_author_x_id,
            post_created_at, replier_base_score, effective_score, contribution_score,
            active_multipliers, reply_number, local_reply_count, decay_type
        ) VALUES (
            rec.project_keyword, rec.post_id, rec.original_post_id, rec.replier_x_id, rec.original_author_x_id,
            rec.post_created_at, rec.replier_base_score, effective_score, ROUND(calc_score, 2),
            penalty_mults, reply_seq, local_seq, dtype
        );

        v_count := v_count + 1;
        IF p_log_every > 0 AND v_count % p_log_every = 0 THEN
            PERFORM mindshare_score._decay_log(p_run_id,'project',p_project_keyword,'running','writing',
                format('%s rows written...', v_count), v_count);
        END IF;
    END LOOP;
    RETURN v_count;
END;
$func$;

CREATE OR REPLACE FUNCTION mindshare_score._decay_apply_global_test(
    p_reset_interval interval,
    p_run_id         bigint,
    p_only_dirty     boolean,
    p_log_every      integer
) RETURNS bigint
LANGUAGE plpgsql
SET random_page_cost = 1.1
SET work_mem = '256MB'
SET search_path = mindshare, mindshare_score, public
AS $func$
DECLARE
    v_count  bigint := 0;
    v_query  text;
    rec              RECORD;
    prev_replier     TEXT          := '';
    base_score       NUMERIC       := 0;
    min_floor        NUMERIC       := 0;
    calc_score       NUMERIC       := 0;
    effective_score  NUMERIC       := 0;
    reply_seq        INT           := 0;
    local_seq        INT           := 0;
    dtype            TEXT          := '';
    new_mult         NUMERIC       := 1.0;
    penalty_mults    NUMERIC[]     := ARRAY[]::NUMERIC[];
    penalty_times    TIMESTAMPTZ[] := ARRAY[]::TIMESTAMPTZ[];
    penalty_authors  TEXT[]        := ARRAY[]::TEXT[];
    i                INT;
    n                INT;
    active_product   NUMERIC;
    cutoff_time      TIMESTAMPTZ;
    new_mults        NUMERIC[];
    new_times        TIMESTAMPTZ[];
    new_authors      TEXT[];
BEGIN
    v_query :=
        'SELECT p.post_id AS reply_post_id, op.post_id AS original_post_id, '
        '       p.user_x_id AS replier_x_id, p.post_created_at, '
        '       op.user_x_id AS original_author_x_id, u.score AS replier_base_score '
        'FROM mindshare.user_post p '
        'INNER JOIN mindshare.user_post op ON p.replied_post_id = op.post_id '
        'INNER JOIN mindshare.mindshare_user u ON p.user_x_id = u.x_id '
        'WHERE p.replied_post_id IS NOT NULL ';
    IF p_only_dirty THEN
        v_query := v_query || 'AND p.user_x_id IN (SELECT replier_x_id FROM tmp_dirty_repliers) ';
    END IF;
    v_query := v_query || 'ORDER BY p.user_x_id, p.post_created_at, p.post_id';

    FOR rec IN EXECUTE v_query LOOP
        IF rec.replier_x_id IS DISTINCT FROM prev_replier THEN
            prev_replier    := rec.replier_x_id;
            base_score      := rec.replier_base_score;
            min_floor       := ROUND(base_score * 0.01, 2);
            reply_seq       := 0;
            penalty_mults   := ARRAY[]::NUMERIC[];
            penalty_times   := ARRAY[]::TIMESTAMPTZ[];
            penalty_authors := ARRAY[]::TEXT[];
        END IF;

        reply_seq := reply_seq + 1;
        cutoff_time := rec.post_created_at - p_reset_interval;
        new_mults   := ARRAY[]::NUMERIC[];
        new_times   := ARRAY[]::TIMESTAMPTZ[];
        new_authors := ARRAY[]::TEXT[];
        n := COALESCE(array_length(penalty_mults, 1), 0);
        FOR i IN 1 .. n LOOP
            IF penalty_times[i] > cutoff_time THEN
                new_mults   := array_append(new_mults,   penalty_mults[i]);
                new_times   := array_append(new_times,   penalty_times[i]);
                new_authors := array_append(new_authors, penalty_authors[i]);
            END IF;
        END LOOP;
        penalty_mults   := new_mults;
        penalty_times   := new_times;
        penalty_authors := new_authors;

        local_seq := 0;
        n := COALESCE(array_length(penalty_authors, 1), 0);
        FOR i IN 1 .. n LOOP
            IF penalty_authors[i] = rec.original_author_x_id THEN
                local_seq := local_seq + 1;
            END IF;
        END LOOP;
        local_seq := local_seq + 1;

        active_product := 1.0;
        n := COALESCE(array_length(penalty_mults, 1), 0);
        FOR i IN 1 .. n LOOP
            active_product := active_product * penalty_mults[i];
        END LOOP;
        effective_score := GREATEST(ROUND(base_score * active_product, 2), min_floor);
        calc_score      := effective_score;

        IF n = 0 THEN
            dtype := 'FIRST_REPLY'; new_mult := 1.0;
        ELSIF local_seq > 1 THEN
            new_mult := 0.50; calc_score := GREATEST(ROUND(calc_score * 0.50, 2), min_floor); dtype := 'LOCAL_DECAY';
        ELSE
            new_mult := 0.90; calc_score := GREATEST(ROUND(calc_score * 0.90, 2), min_floor); dtype := 'GLOBAL_DECAY';
        END IF;

        penalty_mults   := array_append(penalty_mults,   new_mult);
        penalty_times   := array_append(penalty_times,   rec.post_created_at);
        penalty_authors := array_append(penalty_authors, rec.original_author_x_id);

        -- WRITE TO _test TABLE
        INSERT INTO mindshare_score.global_contribution_scores_test (
            reply_post_id, original_post_id, replier_x_id, original_author_x_id,
            post_created_at, replier_base_score, effective_score, contribution_score,
            active_multipliers, reply_number, local_reply_count, decay_type
        ) VALUES (
            rec.reply_post_id, rec.original_post_id, rec.replier_x_id, rec.original_author_x_id,
            rec.post_created_at, rec.replier_base_score, effective_score, ROUND(calc_score, 2),
            penalty_mults, reply_seq, local_seq, dtype
        );

        v_count := v_count + 1;
        IF p_log_every > 0 AND v_count % p_log_every = 0 THEN
            PERFORM mindshare_score._decay_log(p_run_id,'global',NULL,'running','writing',
                format('%s global rows written...', v_count), v_count);
        END IF;
    END LOOP;
    RETURN v_count;
END;
$func$;

-- ============================================================================
-- PHASE 5: TAIL CORE FUNCTIONS (WRITES TO _TEST TABLES)
-- ============================================================================

CREATE OR REPLACE FUNCTION mindshare_score._decay_apply_project_tail_test(
    p_project_keyword text,
    p_reset_interval  interval,
    p_run_id          bigint,
    p_log_every       integer
) RETURNS bigint
LANGUAGE plpgsql
SET random_page_cost = 1.1
SET work_mem = '256MB'
SET search_path = mindshare, mindshare_score, public
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
        JOIN mindshare.mindshare_post p
          ON p.project_keyword = p_project_keyword AND p.user_x_id = d.replier_x_id
         AND p.replied_post_id IS NOT NULL AND p.post_created_at >= d.t_min
        JOIN mindshare.mindshare_post op
          ON p.replied_post_id = op.post_id AND op.project_keyword = p_project_keyword
        JOIN mindshare.mindshare_user u ON u.x_id = p.user_x_id
        ORDER BY p.user_x_id, p.post_created_at, p.post_id
    LOOP
        IF rec.replier_x_id IS DISTINCT FROM prev_replier THEN
            prev_replier := rec.replier_x_id;
            base_score   := rec.replier_base_score;
            min_floor    := ROUND(base_score * 0.01, 2);
            v_seed_from  := rec.t_min - p_reset_interval;
            SELECT
                COALESCE(array_agg(own_mult ORDER BY post_created_at), ARRAY[]::numeric[]),
                COALESCE(array_agg(post_created_at ORDER BY post_created_at), ARRAY[]::timestamptz[]),
                COALESCE(array_agg(original_author_x_id ORDER BY post_created_at), ARRAY[]::text[])
            INTO penalty_mults, penalty_times, penalty_authors
            FROM (
                SELECT post_created_at, original_author_x_id,
                       active_multipliers[array_upper(active_multipliers,1)] AS own_mult
                FROM mindshare_score.contribution_scores_test
                WHERE project_keyword = p_project_keyword AND replier_x_id = rec.replier_x_id
                  AND post_created_at > v_seed_from AND post_created_at < rec.t_min
            ) s;
            SELECT COALESCE(reply_number, 0) INTO reply_seq
            FROM mindshare_score.contribution_scores_test
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

        INSERT INTO mindshare_score.contribution_scores_test (
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
            PERFORM mindshare_score._decay_log(p_run_id,'project',p_project_keyword,'running','writing',
                format('%s tail rows written...', v_count), v_count);
        END IF;
    END LOOP;
    RETURN v_count;
END;
$func$;

CREATE OR REPLACE FUNCTION mindshare_score._decay_apply_global_tail_test(
    p_reset_interval interval,
    p_run_id         bigint,
    p_log_every      integer
) RETURNS bigint
LANGUAGE plpgsql
SET random_page_cost = 1.1
SET work_mem = '256MB'
SET search_path = mindshare, mindshare_score, public
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
        JOIN mindshare.user_post p
          ON p.user_x_id = d.replier_x_id AND p.replied_post_id IS NOT NULL AND p.post_created_at >= d.t_min
        JOIN mindshare.user_post op ON p.replied_post_id = op.post_id
        JOIN mindshare.mindshare_user u ON u.x_id = p.user_x_id
        ORDER BY p.user_x_id, p.post_created_at, p.post_id
    LOOP
        IF rec.replier_x_id IS DISTINCT FROM prev_replier THEN
            prev_replier := rec.replier_x_id;
            base_score   := rec.replier_base_score;
            min_floor    := ROUND(base_score * 0.01, 2);
            v_seed_from  := rec.t_min - p_reset_interval;
            SELECT
                COALESCE(array_agg(own_mult ORDER BY post_created_at), ARRAY[]::numeric[]),
                COALESCE(array_agg(post_created_at ORDER BY post_created_at), ARRAY[]::timestamptz[]),
                COALESCE(array_agg(original_author_x_id ORDER BY post_created_at), ARRAY[]::text[])
            INTO penalty_mults, penalty_times, penalty_authors
            FROM (
                SELECT post_created_at, original_author_x_id,
                       active_multipliers[array_upper(active_multipliers,1)] AS own_mult
                FROM mindshare_score.global_contribution_scores_test
                WHERE replier_x_id = rec.replier_x_id
                  AND post_created_at > v_seed_from AND post_created_at < rec.t_min
            ) s;
            SELECT COALESCE(reply_number, 0) INTO reply_seq
            FROM mindshare_score.global_contribution_scores_test
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

        INSERT INTO mindshare_score.global_contribution_scores_test (
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
            PERFORM mindshare_score._decay_log(p_run_id,'global',NULL,'running','writing',
                format('%s global tail rows written...', v_count), v_count);
        END IF;
    END LOOP;
    RETURN v_count;
END;
$func$;

-- ============================================================================
-- PHASE 6: INCREMENTAL ENTRY POINTS (WRITES TO _TEST TABLES)
-- ============================================================================

CREATE OR REPLACE FUNCTION mindshare_score.calculate_decay_scores_incremental_test(
    p_project_keyword text,
    p_reset_interval  interval DEFAULT '30 days',
    p_run_id          bigint   DEFAULT NULL,
    p_log_every       integer  DEFAULT 50000
) RETURNS bigint
LANGUAGE plpgsql
SET random_page_cost = 1.1
SET work_mem = '256MB'
SET search_path = mindshare, mindshare_score, public
AS $func$
DECLARE
    v_run_id  bigint := COALESCE(p_run_id, nextval('mindshare_score.decay_run_id_seq'));
    v_scope   text   := 'project:' || p_project_keyword || ':TEST';
    v_since      timestamptz;
    v_new        timestamptz;
    v_user_since timestamptz;
    v_user_new   timestamptz;
    v_dirty   bigint := 0;
    v_count   bigint := 0;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('decay:' || v_scope));

    PERFORM mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'running','init',
        format('INCREMENTAL decay run started (project=%s, TEST TABLE, reset_interval=%s)', p_project_keyword, p_reset_interval), 0);

    SELECT last_ingest_ts, last_user_ingest_ts INTO v_since, v_user_since
    FROM mindshare_score.decay_run_state WHERE scope = v_scope;

    SELECT max(GREATEST(created_at, updated_at)) INTO v_new
    FROM mindshare.mindshare_post WHERE project_keyword = p_project_keyword;
    SELECT max(GREATEST(created_at, updated_at)) INTO v_user_new
    FROM mindshare.mindshare_user;

    IF v_since IS NULL THEN
        PERFORM mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'running','computing',
            'First run: full rebuild for project (TEST TABLE)', 0);
        DELETE FROM mindshare_score.contribution_scores_test WHERE project_keyword = p_project_keyword;
        v_count := mindshare_score._decay_apply_project_test(p_project_keyword, p_reset_interval, v_run_id, false, p_log_every);
        v_dirty := NULL;
    ELSE
        DROP TABLE IF EXISTS tmp_changed;
        CREATE TEMP TABLE tmp_changed ON COMMIT DROP AS
        SELECT post_id, user_x_id, replied_post_id, post_created_at
        FROM mindshare.mindshare_post
        WHERE project_keyword = p_project_keyword
          AND GREATEST(created_at, updated_at) >  v_since
          AND GREATEST(created_at, updated_at) <= v_new;
        CREATE INDEX ON tmp_changed (post_id);
        ANALYZE tmp_changed;

        DROP TABLE IF EXISTS tmp_dirty;
        CREATE TEMP TABLE tmp_dirty (replier_x_id text PRIMARY KEY, t_min timestamptz) ON COMMIT DROP;

        INSERT INTO tmp_dirty (replier_x_id, t_min)
        SELECT replier_x_id, min(t_min) AS t_min FROM (
            SELECT c.user_x_id AS replier_x_id, c.post_created_at AS t_min
            FROM tmp_changed c
            WHERE c.replied_post_id IS NOT NULL
            UNION ALL
            SELECT r.user_x_id, r.post_created_at
            FROM tmp_changed c
            JOIN mindshare.mindshare_post r
              ON r.replied_post_id = c.post_id AND r.project_keyword = p_project_keyword
            WHERE r.replied_post_id IS NOT NULL
            UNION ALL
            SELECT p.user_x_id, p.post_created_at
            FROM mindshare.mindshare_user u
            JOIN mindshare.mindshare_post p
              ON p.user_x_id = u.x_id
             AND p.project_keyword = p_project_keyword
             AND p.replied_post_id IS NOT NULL
            WHERE GREATEST(u.created_at, u.updated_at) >  COALESCE(v_user_since, '-infinity'::timestamptz)
              AND GREATEST(u.created_at, u.updated_at) <= v_user_new
        ) d
        GROUP BY replier_x_id;

        GET DIAGNOSTICS v_dirty = ROW_COUNT;
        ANALYZE tmp_dirty;

        PERFORM mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'running','computing',
            format('%s dirty repliers to recompute (tail-from-t_min) - TEST TABLE', v_dirty), 0);

        IF v_dirty > 0 THEN
            DELETE FROM mindshare_score.contribution_scores_test cs
            USING tmp_dirty d
            WHERE cs.project_keyword = p_project_keyword
              AND cs.replier_x_id = d.replier_x_id
              AND cs.post_created_at >= d.t_min;

            v_count := mindshare_score._decay_apply_project_tail_test(
                           p_project_keyword, p_reset_interval, v_run_id, p_log_every);
        END IF;
    END IF;

    INSERT INTO mindshare_score.decay_run_state (scope, last_ingest_ts, last_user_ingest_ts, last_run_at, last_run_id, dirty_repliers, rows_written)
    VALUES (v_scope, COALESCE(v_new, now()), v_user_new, now(), v_run_id, v_dirty, v_count)
    ON CONFLICT (scope) DO UPDATE SET
        last_ingest_ts      = EXCLUDED.last_ingest_ts,
        last_user_ingest_ts = EXCLUDED.last_user_ingest_ts,
        last_run_at         = EXCLUDED.last_run_at,
        last_run_id         = EXCLUDED.last_run_id,
        dirty_repliers      = EXCLUDED.dirty_repliers,
        rows_written        = EXCLUDED.rows_written;

    PERFORM mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'success','done',
        format('Completed (%s): %s repliers recomputed, %s rows written (TEST TABLE)',
               CASE WHEN v_dirty IS NULL THEN 'full rebuild (first run)' ELSE 'incremental' END,
               COALESCE(v_dirty::text,'ALL'), v_count), v_count, NULL,NULL,NULL,NULL, true);
    RETURN v_run_id;

EXCEPTION WHEN OTHERS THEN
    DECLARE
        v_state text := SQLSTATE; v_msg text := SQLERRM; v_detail text; v_context text;
    BEGIN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL, v_context = PG_EXCEPTION_CONTEXT;
        PERFORM mindshare_score._decay_log(v_run_id,'project',p_project_keyword,'failed','error',
            format('FAILED (incremental, TEST TABLE): %s', v_msg), v_count, v_state, v_msg, v_detail, v_context, true);
    END;
    RAISE;
END;
$func$;

CREATE OR REPLACE FUNCTION mindshare_score.calculate_global_decay_scores_incremental_test(
    p_reset_interval interval DEFAULT '30 days',
    p_run_id         bigint   DEFAULT NULL,
    p_log_every      integer  DEFAULT 50000
) RETURNS bigint
LANGUAGE plpgsql
SET random_page_cost = 1.1
SET work_mem = '256MB'
SET search_path = mindshare, mindshare_score, public
AS $func$
DECLARE
    v_run_id bigint := COALESCE(p_run_id, nextval('mindshare_score.decay_run_id_seq'));
    v_scope  text   := 'global:TEST';
    v_since  timestamptz;
    v_new    timestamptz;
    v_user_since timestamptz;
    v_user_new   timestamptz;
    v_dirty  bigint := 0;
    v_count  bigint := 0;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('decay:' || v_scope));

    PERFORM mindshare_score._decay_log(v_run_id,'global',NULL,'running','init',
        format('INCREMENTAL global decay run started (TEST TABLE, reset_interval=%s)', p_reset_interval), 0);

    SELECT last_ingest_ts, last_user_ingest_ts INTO v_since, v_user_since
    FROM mindshare_score.decay_run_state WHERE scope = v_scope;

    SELECT max(GREATEST(created_at, updated_at)) INTO v_new
    FROM mindshare.user_post;
    SELECT max(GREATEST(created_at, updated_at)) INTO v_user_new
    FROM mindshare.mindshare_user;

    IF v_since IS NULL THEN
        PERFORM mindshare_score._decay_log(v_run_id,'global',NULL,'running','computing',
            'First run: full global rebuild (TEST TABLE)', 0);
        TRUNCATE TABLE mindshare_score.global_contribution_scores_test;
        v_count := mindshare_score._decay_apply_global_test(p_reset_interval, v_run_id, false, p_log_every);
        v_dirty := NULL;
    ELSE
        DROP TABLE IF EXISTS tmp_changed;
        CREATE TEMP TABLE tmp_changed ON COMMIT DROP AS
        SELECT post_id, user_x_id, replied_post_id, post_created_at
        FROM mindshare.user_post
        WHERE GREATEST(created_at, updated_at) >  v_since
          AND GREATEST(created_at, updated_at) <= v_new;
        CREATE INDEX ON tmp_changed (post_id);
        ANALYZE tmp_changed;

        DROP TABLE IF EXISTS tmp_dirty;
        CREATE TEMP TABLE tmp_dirty (replier_x_id text PRIMARY KEY, t_min timestamptz) ON COMMIT DROP;

        INSERT INTO tmp_dirty (replier_x_id, t_min)
        SELECT replier_x_id, min(t_min) AS t_min FROM (
            SELECT c.user_x_id AS replier_x_id, c.post_created_at AS t_min
            FROM tmp_changed c
            WHERE c.replied_post_id IS NOT NULL
            UNION ALL
            SELECT r.user_x_id, r.post_created_at
            FROM tmp_changed c
            JOIN mindshare.user_post r ON r.replied_post_id = c.post_id
            WHERE r.replied_post_id IS NOT NULL
            UNION ALL
            SELECT p.user_x_id, p.post_created_at
            FROM mindshare.mindshare_user u
            JOIN mindshare.user_post p
              ON p.user_x_id = u.x_id AND p.replied_post_id IS NOT NULL
            WHERE GREATEST(u.created_at, u.updated_at) >  COALESCE(v_user_since, '-infinity'::timestamptz)
              AND GREATEST(u.created_at, u.updated_at) <= v_user_new
        ) d
        GROUP BY replier_x_id;

        GET DIAGNOSTICS v_dirty = ROW_COUNT;
        ANALYZE tmp_dirty;

        PERFORM mindshare_score._decay_log(v_run_id,'global',NULL,'running','computing',
            format('%s dirty repliers to recompute (tail-from-t_min) - TEST TABLE', v_dirty), 0);

        IF v_dirty > 0 THEN
            DELETE FROM mindshare_score.global_contribution_scores_test cs
            USING tmp_dirty d
            WHERE cs.replier_x_id = d.replier_x_id
              AND cs.post_created_at >= d.t_min;

            v_count := mindshare_score._decay_apply_global_tail_test(p_reset_interval, v_run_id, p_log_every);
        END IF;
    END IF;

    INSERT INTO mindshare_score.decay_run_state (scope, last_ingest_ts, last_user_ingest_ts, last_run_at, last_run_id, dirty_repliers, rows_written)
    VALUES (v_scope, COALESCE(v_new, now()), v_user_new, now(), v_run_id, v_dirty, v_count)
    ON CONFLICT (scope) DO UPDATE SET
        last_ingest_ts      = EXCLUDED.last_ingest_ts,
        last_user_ingest_ts = EXCLUDED.last_user_ingest_ts,
        last_run_at         = EXCLUDED.last_run_at,
        last_run_id         = EXCLUDED.last_run_id,
        dirty_repliers      = EXCLUDED.dirty_repliers,
        rows_written        = EXCLUDED.rows_written;

    PERFORM mindshare_score._decay_log(v_run_id,'global',NULL,'success','done',
        format('Completed (%s): %s repliers recomputed, %s rows written (TEST TABLE)',
               CASE WHEN v_dirty IS NULL THEN 'full rebuild (first run)' ELSE 'incremental' END,
               COALESCE(v_dirty::text,'ALL'), v_count), v_count, NULL,NULL,NULL,NULL, true);
    RETURN v_run_id;

EXCEPTION WHEN OTHERS THEN
    DECLARE
        v_state text := SQLSTATE; v_msg text := SQLERRM; v_detail text; v_context text;
    BEGIN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL, v_context = PG_EXCEPTION_CONTEXT;
        PERFORM mindshare_score._decay_log(v_run_id,'global',NULL,'failed','error',
            format('FAILED (incremental, TEST TABLE): %s', v_msg), v_count, v_state, v_msg, v_detail, v_context, true);
    END;
    RAISE;
END;
$func$;

-- ============================================================================
-- Phase 7: Wrapper function to run incremental decay for ALL projects at once (TEST TABLES)
-- ============================================================================

CREATE OR REPLACE FUNCTION mindshare_score.calculate_all_decay_scores_incremental_test(
    p_reset_interval interval DEFAULT '30 days'::interval,
    p_log_every      integer  DEFAULT 50000
) RETURNS void
LANGUAGE plpgsql
AS $func$
DECLARE
    proj    RECORD;
    t_start TIMESTAMP;
    t_end   TIMESTAMP;
    v_run_id BIGINT;
    v_count  BIGINT;
BEGIN
    RAISE NOTICE '════════════════════════════════════════════════════';
    RAISE NOTICE 'Starting INCREMENTAL decay run for ALL projects (TEST TABLES)';
    RAISE NOTICE '════════════════════════════════════════════════════';

    -- Process each project
    FOR proj IN
        SELECT DISTINCT project_keyword
        FROM mindshare.mindshare_post
        WHERE is_reply = true
        ORDER BY project_keyword
    LOOP
        t_start := clock_timestamp();
        RAISE NOTICE '';
        RAISE NOTICE '→ Project: %', proj.project_keyword;

        -- Run incremental decay for this project (TEST TABLES)
        v_run_id := mindshare_score.calculate_decay_scores_incremental_test(
            p_project_keyword  := proj.project_keyword,
            p_reset_interval   := p_reset_interval,
            p_log_every        := p_log_every
        );

        t_end := clock_timestamp();

        -- Count rows for this project
        SELECT count(*) INTO v_count
        FROM mindshare_score.contribution_scores_test
        WHERE project_keyword = proj.project_keyword;

        RAISE NOTICE '  ✓ Completed in % sec | Total rows: % | Run ID: %',
            ROUND(EXTRACT(EPOCH FROM (t_end - t_start))::NUMERIC, 2),
            v_count,
            v_run_id;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '════════════════════════════════════════════════════';
    RAISE NOTICE 'All projects processed successfully (TEST TABLES)!';
    RAISE NOTICE 'Run calculate_all_global_decay_scores_incremental_test() separately for global decay';
    RAISE NOTICE '════════════════════════════════════════════════════';
END;
$func$;

-- ============================================================================
-- Phase 7b: Separate wrapper function for ONLY global decay (TEST TABLES)
-- ============================================================================

CREATE OR REPLACE FUNCTION mindshare_score.calculate_all_global_decay_scores_incremental_test(
    p_reset_interval interval DEFAULT '30 days'::interval,
    p_log_every      integer  DEFAULT 50000
) RETURNS void
LANGUAGE plpgsql
AS $func$
DECLARE
    t_start TIMESTAMP;
    t_end   TIMESTAMP;
    v_run_id BIGINT;
    v_count  BIGINT;
BEGIN
    RAISE NOTICE '════════════════════════════════════════════════════';
    RAISE NOTICE 'Starting INCREMENTAL global decay calculation (TEST TABLES)';
    RAISE NOTICE '════════════════════════════════════════════════════';

    t_start := clock_timestamp();

    -- Run global incremental decay (TEST TABLES)
    v_run_id := mindshare_score.calculate_global_decay_scores_incremental_test(
        p_reset_interval := p_reset_interval,
        p_log_every      := p_log_every
    );

    t_end := clock_timestamp();

    -- Count rows
    SELECT count(*) INTO v_count
    FROM mindshare_score.global_contribution_scores_test;

    RAISE NOTICE '✓ Global decay completed in % sec | Total rows: % | Run ID: %',
        ROUND(EXTRACT(EPOCH FROM (t_end - t_start))::NUMERIC, 2),
        v_count,
        v_run_id;

    RAISE NOTICE '';
    RAISE NOTICE '════════════════════════════════════════════════════';
    RAISE NOTICE 'Global decay processed successfully (TEST TABLES)!';
    RAISE NOTICE '════════════════════════════════════════════════════';
END;
$func$;

-- ============================================================================
-- VERIFICATION
-- ============================================================================

SELECT 'Migration to TEST tables complete!'::text as status,
       (SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema='mindshare_score' AND table_name IN ('contribution_scores_test','global_contribution_scores_test')) as test_tables_created,
       (SELECT COUNT(*) FROM information_schema.routines
        WHERE routine_schema='mindshare_score' AND routine_name LIKE '%test%') as test_functions_created;

-- ============================================================================
-- NEXT STEPS: Execute Phase 7 (First Run - TEST TABLES)
-- ============================================================================
-- To run incremental decay on production data but write to test tables:
--
-- -- Run for a specific project:
-- SELECT mindshare_score.calculate_decay_scores_incremental_test('default', '30 days'::interval);
--
-- -- Run global:
-- SELECT mindshare_score.calculate_global_decay_scores_incremental_test('30 days'::interval);
--
-- -- Check progress:
-- SELECT run_id, scope, project_keyword, status, dirty_repliers, rows_written, updated_at
-- FROM mindshare_score.decay_run_log
-- WHERE scope LIKE '%TEST%'
-- ORDER BY run_id DESC LIMIT 5;
--
-- -- Compare test vs production results:
-- SELECT COUNT(*) as test_count FROM mindshare_score.contribution_scores_test WHERE project_keyword='default';
-- SELECT COUNT(*) as prod_count FROM mindshare_score.contribution_scores WHERE project_keyword='default';
--
-- -- Once validated, switch to production tables by using the original functions
-- SELECT mindshare_score.calculate_decay_scores_incremental('default', '30 days'::interval);
-- ============================================================================
