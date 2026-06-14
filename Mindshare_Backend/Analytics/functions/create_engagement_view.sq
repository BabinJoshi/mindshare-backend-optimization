-- DROP PROCEDURE analytics.create_engagement_view(text);

CREATE OR REPLACE PROCEDURE analytics.create_engagement_view(IN project_keyword text)
 LANGUAGE plpgsql
AS $procedure$
declare
    view_name TEXT := 'mv_engagement_' || LOWER(replace(project_keyword, ' ', '_'));

begin

    execute format('DROP MATERIALIZED VIEW IF EXISTS analytics.%I CASCADE', view_name);

    execute format($sql$
        create materialized view analytics.%I as
        with roots as (
            select
				*,
				mu.x_username as root_username
            from mindshare.mindshare_post
			left join mindshare.mindshare_user mu
				on mu.x_id = user_x_id
            where project_keyword = %L
            and (
                is_post = true
                or is_reply = true
                or is_quote = true
            )
        ),
        engaged_tweets as (
            select
                post_id,
                user_x_id,
                is_reply,
                is_quote,
                is_retweet,
                post_created_at,
                replied_post_id,
                quoted_post_id,
                retweeted_post_id
            from mindshare.mindshare_post
            where project_keyword = %L
            and (
                replied_post_id is not null
                or quoted_post_id is not null
            )
        ),
        engagements AS (
            -- 1. Matches Replies to the Root
            SELECT
                r.post_id               AS root_post_id,
                r.user_x_id             AS root_user_id,
                r.root_username         as root_username,
                r.post_created_at       AS root_tweet_created_at,
                r.is_post               AS is_root_post,
                r.is_quote              AS is_root_quote,
                r.is_reply              AS is_root_reply,
                r.favorite_count        AS root_favorite_count,
                r.reply_count           AS root_reply_count,
                e.post_id               AS engaged_tweet_id,
                e.user_x_id             AS engaged_user_id,
                e.is_reply              AS is_engaged_reply,
                e.is_quote              AS is_engaged_quote,
                e.is_retweet            AS is_engaged_repost,
                e.post_created_at       AS engaged_tweet_created_at
            from roots r
            JOIN engaged_tweets e ON e.replied_post_id = r.post_id

            union all

            -- 2. Matches Quotes of the Root
            SELECT
                r.post_id               AS root_post_id,
                r.user_x_id             AS root_user_id,
                r.root_username         as root_username,
                r.post_created_at       AS root_tweet_created_at,
                r.is_post               AS is_root_post,
                r.is_quote              AS is_root_quote,
                r.is_reply              AS is_root_reply,
                r.favorite_count        AS root_favorite_count,
                r.reply_count           AS root_reply_count,
                e.post_id               AS engaged_tweet_id,
                e.user_x_id             AS engaged_user_id,
                e.is_reply              AS is_engaged_reply,
                e.is_quote              AS is_engaged_quote,
                e.is_retweet            AS is_engaged_repost,
                e.post_created_at       AS engaged_tweet_created_at
            from roots r
            JOIN engaged_tweets e on e.quoted_post_id = r.post_id and e.replied_post_id is null
        ),

        engagements_with_scores as (
            select
                e.*,
                eu.score as engaged_user_score
            from engagements e
            left join mindshare.mindshare_user eu
	            on eu.x_id = e.engaged_user_id
        ),

		posts_with_no_engagement AS (
            SELECT
                r.post_id  AS root_post_id,
                r.user_x_id AS root_user_id,
                r.root_username  as root_username,
                r.post_created_at       AS root_tweet_created_at,
                r.is_post               AS is_root_post,
                r.is_quote              AS is_root_quote,
                r.is_reply              AS is_root_reply,
                r.favorite_count        AS root_favorite_count,
                r.reply_count           AS root_reply_count,
                NULL::text AS engaged_tweet_id,
                NULL::text AS engaged_user_id,
                NULL::boolean AS is_engaged_reply,
                NULL::boolean AS is_engaged_quote,
                NULL::boolean AS is_engaged_repost,
                NULL::timestamptz AS engaged_tweet_created_at,
                NULL::numeric as engaged_user_score
            FROM roots r
            WHERE NOT EXISTS (
                SELECT 1
                FROM engagements_with_scores e
                WHERE e.root_post_id = r.post_id
            )
        )

	    SELECT * FROM engagements_with_scores
        UNION ALL
        SELECT * FROM posts_with_no_engagement
    $sql$, view_name, project_keyword, project_keyword);

    -- Create Unique Index to allow concurrent refreshes and speed up joins
    execute format('CREATE UNIQUE INDEX IF NOT EXISTS %I ON analytics.%I (engaged_tweet_id)', 'ix_' || view_name || '_tweet', view_name);

    -- Create indexes on frequently aggregated columns
    execute format('CREATE INDEX IF NOT EXISTS %I ON analytics.%I (root_post_id)', 'ix_' || view_name || '_root', view_name);
    execute format('CREATE INDEX IF NOT EXISTS %I ON analytics.%I (engaged_user_id)', 'ix_' || view_name || '_user', view_name);

raise notice 'Materialized View % created with indexes.', view_name;
end;

$procedure$
;
