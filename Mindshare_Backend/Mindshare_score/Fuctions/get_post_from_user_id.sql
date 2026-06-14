-- DROP FUNCTION mindshare_score.get_post_from_user_id(_text, text, text);

CREATE OR REPLACE FUNCTION mindshare_score.get_post_from_user_id(p_user_x_id text[], project_name text DEFAULT NULL::text, table_name text DEFAULT NULL::text)
 RETURNS TABLE(post_id text, user_x_id text, project_keyword text, source_table text, favorite_count integer, view_count integer, post_created_at timestamp with time zone, is_post boolean, is_quote boolean, is_reply boolean, updated_at timestamp with time zone, post_type text, status text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_start_date timestamptz;
    v_end_date   timestamptz;
BEGIN
    -- Fetch project date range when project_name is provided
    IF project_name IS NOT NULL THEN
        SELECT
            CASE WHEN p.start_ts > 0 THEN to_timestamp(p.start_ts) ELSE NULL END,
            CASE WHEN p.end_ts   > 0 THEN to_timestamp(p.end_ts)   ELSE NULL END
        INTO v_start_date, v_end_date
        FROM mindshare.mindshare_project p
        WHERE p.project_name = get_post_from_user_id.project_name  -- avoid ambiguity
        LIMIT 1;
    END IF;

    IF table_name IS NULL OR table_name = 'mindshare_post' THEN
        RETURN QUERY
        SELECT
            m.post_id::text,
            m.user_x_id::text,
            m.project_keyword::text,
            'mindshare_post' AS source_table,
            m.favorite_count,
            m.view_count,
            m.post_created_at,
            m.is_post,
            m.is_quote,
            m.is_reply,
            m.updated_at,
            CASE
                WHEN m.is_post THEN 'post'
                WHEN m.is_quote AND NOT m.is_reply THEN 'quote'
                WHEN m.is_reply THEN 'reply'
            END,
            CASE
                WHEN current_date - date(m.created_at) >= 2 THEN 'tracked'
                ELSE 'Under Review'
            END
        FROM mindshare.mindshare_post m
        WHERE m.user_x_id = ANY(p_user_x_id)
          AND (project_name IS NULL OR m.project_keyword = project_name)
          AND (v_start_date IS NULL OR m.post_created_at >= v_start_date)
          AND (v_end_date   IS NULL OR m.post_created_at <= v_end_date)
          AND NOT m.is_reply
          AND NOT m.is_retweet
        ORDER BY post_created_at DESC;

    ELSIF table_name = 'user_post' THEN
        RETURN QUERY
        SELECT
            u.post_id::text,
            u.user_x_id::text,
            NULL::text,
            'user_post' AS source_table,
            u.favorite_count,
            u.view_count,
            u.post_created_at,
            u.is_post,
            u.is_quote,
            u.is_reply,
            u.updated_at,
            CASE
                WHEN u.is_post THEN 'post'
                WHEN u.is_quote AND NOT u.is_reply THEN 'quote'
                WHEN u.is_reply THEN 'reply'
            END,
            NULL::text
        FROM mindshare.user_post u
        WHERE u.user_x_id = ANY(p_user_x_id)
          AND (v_start_date IS NULL OR u.post_created_at >= v_start_date)
          AND (v_end_date   IS NULL OR u.post_created_at <= v_end_date)
          AND NOT u.is_reply
          AND NOT u.is_retweet
        ORDER BY post_created_at DESC;

    ELSIF table_name = 'nucleus_post' THEN
        RETURN QUERY
        SELECT
            n.post_id::text,
            n.user_x_id::text,
            n.project_keyword::text,
            'nucleus_post' AS source_table,
            n.favorite_count,
            n.view_count,
            n.post_created_at,
            n.is_post,
            n.is_quote,
            n.is_reply,
            n.updated_at,
            CASE
                WHEN n.is_post THEN 'post'
                WHEN n.is_quote AND NOT n.is_reply THEN 'quote'
                WHEN n.is_reply THEN 'reply'
            END,
            NULL::text
        FROM mindshare.nucleus_post n
        WHERE n.user_x_id = ANY(p_user_x_id)
          AND (project_name IS NULL OR n.project_keyword = project_name)
          AND (v_start_date IS NULL OR n.post_created_at >= v_start_date)
          AND (v_end_date   IS NULL OR n.post_created_at <= v_end_date)
          AND NOT n.is_reply
          AND NOT n.is_retweet
        ORDER BY post_created_at DESC;

    END IF;
END;
$function$
;