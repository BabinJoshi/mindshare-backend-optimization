-- DROP FUNCTION mindshare_score.calculate_global_decay_scores(interval);

CREATE OR REPLACE FUNCTION mindshare_score.calculate_global_decay_scores(p_reset_interval interval DEFAULT '30 days'::interval)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
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

    -- Rolling penalty log (three parallel arrays, pruned each iteration)
    penalty_mults    NUMERIC[]     := ARRAY[]::NUMERIC[];
    penalty_times    TIMESTAMPTZ[] := ARRAY[]::TIMESTAMPTZ[];
    penalty_authors  TEXT[]        := ARRAY[]::TEXT[];

    -- Scratch variables
    i                INT;
    n                INT;
    active_product   NUMERIC;
    cutoff_time      TIMESTAMPTZ;
    new_mults        NUMERIC[];
    new_times        TIMESTAMPTZ[];
    new_authors      TEXT[];
BEGIN
    FOR rec IN
        SELECT
            p.post_id                AS reply_post_id,
            op.post_id               AS original_post_id,
            p.user_x_id              AS replier_x_id,
            p.post_created_at,
            op.user_x_id             AS original_author_x_id,
            u.score                  AS replier_base_score
        FROM mindshare.user_post p
        INNER JOIN mindshare.user_post op
            ON p.replied_post_id = op.post_id
        INNER JOIN mindshare.mindshare_user u
            ON p.user_x_id = u.x_id
        WHERE p.is_reply = true
          AND p.replied_post_id IS NOT NULL
        ORDER BY p.user_x_id, p.post_created_at
    LOOP
        -- New replier: reset ALL state
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

        -- ROLLING WINDOW PRUNING
        -- Drop any penalty entries older than p_reset_interval.
        -- Each penalty expires individually (paintbrush model).
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

        -- LOCAL reply count: how many times has this replier already
        -- replied to rec.original_author_x_id within the active window?
        local_seq := 0;
        n := COALESCE(array_length(penalty_authors, 1), 0);
        FOR i IN 1 .. n LOOP
            IF penalty_authors[i] = rec.original_author_x_id THEN
                local_seq := local_seq + 1;
            END IF;
        END LOOP;
        local_seq := local_seq + 1;

        -- Recompute effective score from base * product of active penalties.
        -- This is the score BEFORE applying the new decay.
        -- Note: only LOCAL_DECAY entries (0.50) affect the product.
        -- NEW_AUTHOR entries use mult=1.0 so they do not reduce the product.
        active_product := 1.0;
        n := COALESCE(array_length(penalty_mults, 1), 0);
        FOR i IN 1 .. n LOOP
            active_product := active_product * penalty_mults[i];
        END LOOP;
        effective_score := GREATEST(ROUND(base_score * active_product, 2), min_floor);
        calc_score      := effective_score;

        -- Apply decay for THIS reply
        IF n = 0 THEN
            -- No active penalties: fresh start
            dtype    := 'FIRST_REPLY';
            new_mult := 1.0;

        ELSIF local_seq > 1 THEN
            -- Repeated reply to same author within window: LOCAL DECAY (50%)
            new_mult   := 0.50;
            calc_score := GREATEST(ROUND(calc_score * 0.50, 2), min_floor);
            dtype      := 'LOCAL_DECAY';

        ELSE
            -- New author within window: no penalty, score carries through as-is
            new_mult := 1.0;
            dtype    := 'NEW_AUTHOR';
        END IF;

        -- Append this reply's entry to the rolling log.
        -- NEW_AUTHOR and FIRST_REPLY both use mult=1.0 so they do not
        -- reduce the effective score but still track the author for
        -- local_seq counting in future replies.
        penalty_mults   := array_append(penalty_mults,   new_mult);
        penalty_times   := array_append(penalty_times,   rec.post_created_at);
        penalty_authors := array_append(penalty_authors, rec.original_author_x_id);

        -- Persist
        INSERT INTO mindshare_score.global_contribution_scores (
            reply_post_id,
            original_post_id,
            replier_x_id,
            original_author_x_id,
            post_created_at,
            replier_base_score,
            effective_score,
            contribution_score,
            active_multipliers,
            reply_number,
            local_reply_count,
            decay_type
        ) VALUES (
            rec.reply_post_id,
            rec.original_post_id,
            rec.replier_x_id,
            rec.original_author_x_id,
            rec.post_created_at,
            rec.replier_base_score,
            effective_score,
            ROUND(calc_score, 2),
            penalty_mults,
            reply_seq,
            local_seq,
            dtype
        );
    END LOOP;
END;
$function$
;