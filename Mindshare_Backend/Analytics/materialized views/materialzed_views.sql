-- analytics.mv_engagement__technotainment source

CREATE MATERIALIZED VIEW analytics.mv_engagement__technotainment TABLESPACE pg_default AS
WITH
    roots AS (
        SELECT
            mindshare_post.post_id,
            mindshare_post.project_keyword,
            mindshare_post.user_x_id,
            mindshare_post.full_text,
            mindshare_post.retweeted_post_id,
            mindshare_post.replied_post_id,
            mindshare_post.quoted_post_id,
            mindshare_post.root_post_id,
            mindshare_post.is_retweet,
            mindshare_post.is_reply,
            mindshare_post.is_quote,
            mindshare_post.is_post,
            mindshare_post.view_count,
            mindshare_post.reply_count,
            mindshare_post.retweet_count,
            mindshare_post.quote_count,
            mindshare_post.favorite_count,
            mindshare_post.post_created_at,
            mindshare_post.created_at,
            mindshare_post.updated_at,
            mindshare_post.sentiment_score,
            mindshare_post.sentiment_label,
            mindshare_post.entities,
            mindshare_post.content_score,
            mu.x_id,
            mu.x_username,
            mu.display_name,
            mu.score,
            mu.avatar_url,
            mu.adjustment_config,
            mu.followers_count,
            mu.verified,
            mu.created_at,
            mu.updated_at,
            mu.x_username AS root_username
        FROM mindshare.mindshare_post
            LEFT JOIN mindshare.mindshare_user mu ON mu.x_id::text = mindshare_post.user_x_id
        WHERE
            mindshare_post.project_keyword = '_technotainment'::text
            AND (
                mindshare_post.is_post = true
                OR mindshare_post.is_reply = true
                OR mindshare_post.is_quote = true
            )
    ),
    engaged_tweets AS (
        SELECT mindshare_post.post_id, mindshare_post.user_x_id, mindshare_post.is_reply, mindshare_post.is_quote, mindshare_post.is_retweet, mindshare_post.post_created_at, mindshare_post.replied_post_id, mindshare_post.quoted_post_id, mindshare_post.retweeted_post_id
        FROM mindshare.mindshare_post
        WHERE
            mindshare_post.project_keyword = '_technotainment'::text
            AND (
                mindshare_post.replied_post_id IS NOT NULL
                OR mindshare_post.quoted_post_id IS NOT NULL
            )
    ),
    engagements AS (
        SELECT
            r.post_id AS root_post_id,
            r.user_x_id AS root_user_id,
            r.root_username,
            r.post_created_at AS root_tweet_created_at,
            r.is_post AS is_root_post,
            r.is_quote AS is_root_quote,
            r.is_reply AS is_root_reply,
            r.favorite_count AS root_favorite_count,
            r.reply_count AS root_reply_count,
            e.post_id AS engaged_tweet_id,
            e.user_x_id AS engaged_user_id,
            e.is_reply AS is_engaged_reply,
            e.is_quote AS is_engaged_quote,
            e.is_retweet AS is_engaged_repost,
            e.post_created_at AS engaged_tweet_created_at
        FROM roots r (
                post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id, is_retweet, is_reply, is_quote, is_post, view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at, sentiment_score, sentiment_label, entities, content_score, x_id, x_username, display_name, score, avatar_url, adjustment_config, followers_count, verified, created_at_1, updated_at_1, root_username
            )
            JOIN engaged_tweets e ON e.replied_post_id = r.post_id
        UNION ALL
        SELECT
            r.post_id AS root_post_id,
            r.user_x_id AS root_user_id,
            r.root_username,
            r.post_created_at AS root_tweet_created_at,
            r.is_post AS is_root_post,
            r.is_quote AS is_root_quote,
            r.is_reply AS is_root_reply,
            r.favorite_count AS root_favorite_count,
            r.reply_count AS root_reply_count,
            e.post_id AS engaged_tweet_id,
            e.user_x_id AS engaged_user_id,
            e.is_reply AS is_engaged_reply,
            e.is_quote AS is_engaged_quote,
            e.is_retweet AS is_engaged_repost,
            e.post_created_at AS engaged_tweet_created_at
        FROM
            roots r (
                post_id,
                project_keyword,
                user_x_id,
                full_text,
                retweeted_post_id,
                replied_post_id,
                quoted_post_id,
                root_post_id,
                is_retweet,
                is_reply,
                is_quote,
                is_post,
                view_count,
                reply_count,
                retweet_count,
                quote_count,
                favorite_count,
                post_created_at,
                created_at,
                updated_at,
                sentiment_score,
                sentiment_label,
                entities,
                content_score,
                x_id,
                x_username,
                display_name,
                score,
                avatar_url,
                adjustment_config,
                followers_count,
                verified,
                created_at_1,
                updated_at_1,
                root_username
            )
            JOIN engaged_tweets e ON e.quoted_post_id = r.post_id
            AND e.replied_post_id IS NULL
    ),
    engagements_with_scores AS (
        SELECT
            e.root_post_id,
            e.root_user_id,
            e.root_username,
            e.root_tweet_created_at,
            e.is_root_post,
            e.is_root_quote,
            e.is_root_reply,
            e.root_favorite_count,
            e.root_reply_count,
            e.engaged_tweet_id,
            e.engaged_user_id,
            e.is_engaged_reply,
            e.is_engaged_quote,
            e.is_engaged_repost,
            e.engaged_tweet_created_at,
            eu.score AS engaged_user_score
        FROM engagements e
            LEFT JOIN mindshare.mindshare_user eu ON eu.x_id::text = e.engaged_user_id
    ),
    posts_with_no_engagement AS (
        SELECT
            r.post_id AS root_post_id,
            r.user_x_id AS root_user_id,
            r.root_username,
            r.post_created_at AS root_tweet_created_at,
            r.is_post AS is_root_post,
            r.is_quote AS is_root_quote,
            r.is_reply AS is_root_reply,
            r.favorite_count AS root_favorite_count,
            r.reply_count AS root_reply_count,
            NULL::text AS engaged_tweet_id,
            NULL::text AS engaged_user_id,
            NULL::boolean AS is_engaged_reply,
            NULL::boolean AS is_engaged_quote,
            NULL::boolean AS is_engaged_repost,
            NULL::timestamp with time zone AS engaged_tweet_created_at,
            NULL::numeric AS engaged_user_score
        FROM roots r (
                post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id, is_retweet, is_reply, is_quote, is_post, view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at, sentiment_score, sentiment_label, entities, content_score, x_id, x_username, display_name, score, avatar_url, adjustment_config, followers_count, verified, created_at_1, updated_at_1, root_username
            )
        WHERE
            NOT (
                EXISTS (
                    SELECT 1
                    FROM engagements_with_scores e
                    WHERE
                        e.root_post_id = r.post_id
                )
            )
    )
SELECT
    engagements_with_scores.root_post_id,
    engagements_with_scores.root_user_id,
    engagements_with_scores.root_username,
    engagements_with_scores.root_tweet_created_at,
    engagements_with_scores.is_root_post,
    engagements_with_scores.is_root_quote,
    engagements_with_scores.is_root_reply,
    engagements_with_scores.root_favorite_count,
    engagements_with_scores.root_reply_count,
    engagements_with_scores.engaged_tweet_id,
    engagements_with_scores.engaged_user_id,
    engagements_with_scores.is_engaged_reply,
    engagements_with_scores.is_engaged_quote,
    engagements_with_scores.is_engaged_repost,
    engagements_with_scores.engaged_tweet_created_at,
    engagements_with_scores.engaged_user_score
FROM engagements_with_scores
UNION ALL
SELECT
    posts_with_no_engagement.root_post_id,
    posts_with_no_engagement.root_user_id,
    posts_with_no_engagement.root_username,
    posts_with_no_engagement.root_tweet_created_at,
    posts_with_no_engagement.is_root_post,
    posts_with_no_engagement.is_root_quote,
    posts_with_no_engagement.is_root_reply,
    posts_with_no_engagement.root_favorite_count,
    posts_with_no_engagement.root_reply_count,
    posts_with_no_engagement.engaged_tweet_id,
    posts_with_no_engagement.engaged_user_id,
    posts_with_no_engagement.is_engaged_reply,
    posts_with_no_engagement.is_engaged_quote,
    posts_with_no_engagement.is_engaged_repost,
    posts_with_no_engagement.engaged_tweet_created_at,
    posts_with_no_engagement.engaged_user_score
FROM posts_with_no_engagement
WITH
    DATA;

-- View indexes:
CREATE INDEX ix_mv_engagement__technotainment_root ON analytics.mv_engagement__technotainment USING btree (root_post_id);

CREATE UNIQUE INDEX ix_mv_engagement__technotainment_tweet ON analytics.mv_engagement__technotainment USING btree (engaged_tweet_id);

CREATE INDEX ix_mv_engagement__technotainment_user ON analytics.mv_engagement__technotainment USING btree (engaged_user_id);

-- analytics.mv_engagement_quipnetwork source

CREATE MATERIALIZED VIEW analytics.mv_engagement_quipnetwork TABLESPACE pg_default AS
WITH
    roots AS (
        SELECT
            mindshare_post.post_id,
            mindshare_post.project_keyword,
            mindshare_post.user_x_id,
            mindshare_post.full_text,
            mindshare_post.retweeted_post_id,
            mindshare_post.replied_post_id,
            mindshare_post.quoted_post_id,
            mindshare_post.root_post_id,
            mindshare_post.is_retweet,
            mindshare_post.is_reply,
            mindshare_post.is_quote,
            mindshare_post.is_post,
            mindshare_post.view_count,
            mindshare_post.reply_count,
            mindshare_post.retweet_count,
            mindshare_post.quote_count,
            mindshare_post.favorite_count,
            mindshare_post.post_created_at,
            mindshare_post.created_at,
            mindshare_post.updated_at,
            mindshare_post.sentiment_score,
            mindshare_post.sentiment_label,
            mindshare_post.entities,
            mindshare_post.content_score,
            mu.x_id,
            mu.x_username,
            mu.display_name,
            mu.score,
            mu.avatar_url,
            mu.adjustment_config,
            mu.followers_count,
            mu.verified,
            mu.created_at,
            mu.updated_at,
            mu.x_username AS root_username
        FROM mindshare.mindshare_post
            LEFT JOIN mindshare.mindshare_user mu ON mu.x_id::text = mindshare_post.user_x_id
        WHERE
            mindshare_post.project_keyword = 'quipnetwork'::text
            AND (
                mindshare_post.is_post = true
                OR mindshare_post.is_reply = true
                OR mindshare_post.is_quote = true
            )
    ),
    engaged_tweets AS (
        SELECT mindshare_post.post_id, mindshare_post.user_x_id, mindshare_post.is_reply, mindshare_post.is_quote, mindshare_post.is_retweet, mindshare_post.post_created_at, mindshare_post.replied_post_id, mindshare_post.quoted_post_id, mindshare_post.retweeted_post_id
        FROM mindshare.mindshare_post
        WHERE
            mindshare_post.project_keyword = 'quipnetwork'::text
            AND (
                mindshare_post.replied_post_id IS NOT NULL
                OR mindshare_post.quoted_post_id IS NOT NULL
            )
    ),
    engagements AS (
        SELECT
            r.post_id AS root_post_id,
            r.user_x_id AS root_user_id,
            r.root_username,
            r.post_created_at AS root_tweet_created_at,
            r.is_post AS is_root_post,
            r.is_quote AS is_root_quote,
            r.is_reply AS is_root_reply,
            r.favorite_count AS root_favorite_count,
            r.reply_count AS root_reply_count,
            e.post_id AS engaged_tweet_id,
            e.user_x_id AS engaged_user_id,
            e.is_reply AS is_engaged_reply,
            e.is_quote AS is_engaged_quote,
            e.is_retweet AS is_engaged_repost,
            e.post_created_at AS engaged_tweet_created_at
        FROM roots r (
                post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id, is_retweet, is_reply, is_quote, is_post, view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at, sentiment_score, sentiment_label, entities, content_score, x_id, x_username, display_name, score, avatar_url, adjustment_config, followers_count, verified, created_at_1, updated_at_1, root_username
            )
            JOIN engaged_tweets e ON e.replied_post_id = r.post_id
        UNION ALL
        SELECT
            r.post_id AS root_post_id,
            r.user_x_id AS root_user_id,
            r.root_username,
            r.post_created_at AS root_tweet_created_at,
            r.is_post AS is_root_post,
            r.is_quote AS is_root_quote,
            r.is_reply AS is_root_reply,
            r.favorite_count AS root_favorite_count,
            r.reply_count AS root_reply_count,
            e.post_id AS engaged_tweet_id,
            e.user_x_id AS engaged_user_id,
            e.is_reply AS is_engaged_reply,
            e.is_quote AS is_engaged_quote,
            e.is_retweet AS is_engaged_repost,
            e.post_created_at AS engaged_tweet_created_at
        FROM
            roots r (
                post_id,
                project_keyword,
                user_x_id,
                full_text,
                retweeted_post_id,
                replied_post_id,
                quoted_post_id,
                root_post_id,
                is_retweet,
                is_reply,
                is_quote,
                is_post,
                view_count,
                reply_count,
                retweet_count,
                quote_count,
                favorite_count,
                post_created_at,
                created_at,
                updated_at,
                sentiment_score,
                sentiment_label,
                entities,
                content_score,
                x_id,
                x_username,
                display_name,
                score,
                avatar_url,
                adjustment_config,
                followers_count,
                verified,
                created_at_1,
                updated_at_1,
                root_username
            )
            JOIN engaged_tweets e ON e.quoted_post_id = r.post_id
            AND e.replied_post_id IS NULL
    ),
    engagements_with_scores AS (
        SELECT
            e.root_post_id,
            e.root_user_id,
            e.root_username,
            e.root_tweet_created_at,
            e.is_root_post,
            e.is_root_quote,
            e.is_root_reply,
            e.root_favorite_count,
            e.root_reply_count,
            e.engaged_tweet_id,
            e.engaged_user_id,
            e.is_engaged_reply,
            e.is_engaged_quote,
            e.is_engaged_repost,
            e.engaged_tweet_created_at,
            eu.score AS engaged_user_score
        FROM engagements e
            LEFT JOIN mindshare.mindshare_user eu ON eu.x_id::text = e.engaged_user_id
    ),
    posts_with_no_engagement AS (
        SELECT
            r.post_id AS root_post_id,
            r.user_x_id AS root_user_id,
            r.root_username,
            r.post_created_at AS root_tweet_created_at,
            r.is_post AS is_root_post,
            r.is_quote AS is_root_quote,
            r.is_reply AS is_root_reply,
            r.favorite_count AS root_favorite_count,
            r.reply_count AS root_reply_count,
            NULL::text AS engaged_tweet_id,
            NULL::text AS engaged_user_id,
            NULL::boolean AS is_engaged_reply,
            NULL::boolean AS is_engaged_quote,
            NULL::boolean AS is_engaged_repost,
            NULL::timestamp with time zone AS engaged_tweet_created_at,
            NULL::numeric AS engaged_user_score
        FROM roots r (
                post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id, is_retweet, is_reply, is_quote, is_post, view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at, sentiment_score, sentiment_label, entities, content_score, x_id, x_username, display_name, score, avatar_url, adjustment_config, followers_count, verified, created_at_1, updated_at_1, root_username
            )
        WHERE
            NOT (
                EXISTS (
                    SELECT 1
                    FROM engagements_with_scores e
                    WHERE
                        e.root_post_id = r.post_id
                )
            )
    )
SELECT
    engagements_with_scores.root_post_id,
    engagements_with_scores.root_user_id,
    engagements_with_scores.root_username,
    engagements_with_scores.root_tweet_created_at,
    engagements_with_scores.is_root_post,
    engagements_with_scores.is_root_quote,
    engagements_with_scores.is_root_reply,
    engagements_with_scores.root_favorite_count,
    engagements_with_scores.root_reply_count,
    engagements_with_scores.engaged_tweet_id,
    engagements_with_scores.engaged_user_id,
    engagements_with_scores.is_engaged_reply,
    engagements_with_scores.is_engaged_quote,
    engagements_with_scores.is_engaged_repost,
    engagements_with_scores.engaged_tweet_created_at,
    engagements_with_scores.engaged_user_score
FROM engagements_with_scores
UNION ALL
SELECT
    posts_with_no_engagement.root_post_id,
    posts_with_no_engagement.root_user_id,
    posts_with_no_engagement.root_username,
    posts_with_no_engagement.root_tweet_created_at,
    posts_with_no_engagement.is_root_post,
    posts_with_no_engagement.is_root_quote,
    posts_with_no_engagement.is_root_reply,
    posts_with_no_engagement.root_favorite_count,
    posts_with_no_engagement.root_reply_count,
    posts_with_no_engagement.engaged_tweet_id,
    posts_with_no_engagement.engaged_user_id,
    posts_with_no_engagement.is_engaged_reply,
    posts_with_no_engagement.is_engaged_quote,
    posts_with_no_engagement.is_engaged_repost,
    posts_with_no_engagement.engaged_tweet_created_at,
    posts_with_no_engagement.engaged_user_score
FROM posts_with_no_engagement
WITH
    DATA;

-- View indexes:
CREATE INDEX ix_mv_engagement_quipnetwork_root ON analytics.mv_engagement_quipnetwork USING btree (root_post_id);

CREATE UNIQUE INDEX ix_mv_engagement_quipnetwork_tweet ON analytics.mv_engagement_quipnetwork USING btree (engaged_tweet_id);

CREATE INDEX ix_mv_engagement_quipnetwork_user ON analytics.mv_engagement_quipnetwork USING btree (engaged_user_id);

-- analytics.mv_engagement_pact_swap source

CREATE MATERIALIZED VIEW analytics.mv_engagement_pact_swap TABLESPACE pg_default AS
WITH
    roots AS (
        SELECT
            mindshare_post.post_id,
            mindshare_post.project_keyword,
            mindshare_post.user_x_id,
            mindshare_post.full_text,
            mindshare_post.retweeted_post_id,
            mindshare_post.replied_post_id,
            mindshare_post.quoted_post_id,
            mindshare_post.root_post_id,
            mindshare_post.is_retweet,
            mindshare_post.is_reply,
            mindshare_post.is_quote,
            mindshare_post.is_post,
            mindshare_post.view_count,
            mindshare_post.reply_count,
            mindshare_post.retweet_count,
            mindshare_post.quote_count,
            mindshare_post.favorite_count,
            mindshare_post.post_created_at,
            mindshare_post.created_at,
            mindshare_post.updated_at,
            mindshare_post.sentiment_score,
            mindshare_post.sentiment_label,
            mindshare_post.entities,
            mindshare_post.content_score,
            mu.x_id,
            mu.x_username,
            mu.display_name,
            mu.score,
            mu.avatar_url,
            mu.adjustment_config,
            mu.followers_count,
            mu.verified,
            mu.created_at,
            mu.updated_at,
            mu.x_username AS root_username
        FROM mindshare.mindshare_post
            LEFT JOIN mindshare.mindshare_user mu ON mu.x_id::text = mindshare_post.user_x_id
        WHERE
            mindshare_post.project_keyword = 'Pact_Swap'::text
            AND (
                mindshare_post.is_post = true
                OR mindshare_post.is_reply = true
                OR mindshare_post.is_quote = true
            )
    ),
    engaged_tweets AS (
        SELECT mindshare_post.post_id, mindshare_post.user_x_id, mindshare_post.is_reply, mindshare_post.is_quote, mindshare_post.is_retweet, mindshare_post.post_created_at, mindshare_post.replied_post_id, mindshare_post.quoted_post_id, mindshare_post.retweeted_post_id
        FROM mindshare.mindshare_post
        WHERE
            mindshare_post.project_keyword = 'Pact_Swap'::text
            AND (
                mindshare_post.replied_post_id IS NOT NULL
                OR mindshare_post.quoted_post_id IS NOT NULL
            )
    ),
    engagements AS (
        SELECT
            r.post_id AS root_post_id,
            r.user_x_id AS root_user_id,
            r.root_username,
            r.post_created_at AS root_tweet_created_at,
            r.is_post AS is_root_post,
            r.is_quote AS is_root_quote,
            r.is_reply AS is_root_reply,
            r.favorite_count AS root_favorite_count,
            r.reply_count AS root_reply_count,
            e.post_id AS engaged_tweet_id,
            e.user_x_id AS engaged_user_id,
            e.is_reply AS is_engaged_reply,
            e.is_quote AS is_engaged_quote,
            e.is_retweet AS is_engaged_repost,
            e.post_created_at AS engaged_tweet_created_at
        FROM roots r (
                post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id, is_retweet, is_reply, is_quote, is_post, view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at, sentiment_score, sentiment_label, entities, content_score, x_id, x_username, display_name, score, avatar_url, adjustment_config, followers_count, verified, created_at_1, updated_at_1, root_username
            )
            JOIN engaged_tweets e ON e.replied_post_id = r.post_id
        UNION ALL
        SELECT
            r.post_id AS root_post_id,
            r.user_x_id AS root_user_id,
            r.root_username,
            r.post_created_at AS root_tweet_created_at,
            r.is_post AS is_root_post,
            r.is_quote AS is_root_quote,
            r.is_reply AS is_root_reply,
            r.favorite_count AS root_favorite_count,
            r.reply_count AS root_reply_count,
            e.post_id AS engaged_tweet_id,
            e.user_x_id AS engaged_user_id,
            e.is_reply AS is_engaged_reply,
            e.is_quote AS is_engaged_quote,
            e.is_retweet AS is_engaged_repost,
            e.post_created_at AS engaged_tweet_created_at
        FROM
            roots r (
                post_id,
                project_keyword,
                user_x_id,
                full_text,
                retweeted_post_id,
                replied_post_id,
                quoted_post_id,
                root_post_id,
                is_retweet,
                is_reply,
                is_quote,
                is_post,
                view_count,
                reply_count,
                retweet_count,
                quote_count,
                favorite_count,
                post_created_at,
                created_at,
                updated_at,
                sentiment_score,
                sentiment_label,
                entities,
                content_score,
                x_id,
                x_username,
                display_name,
                score,
                avatar_url,
                adjustment_config,
                followers_count,
                verified,
                created_at_1,
                updated_at_1,
                root_username
            )
            JOIN engaged_tweets e ON e.quoted_post_id = r.post_id
            AND e.replied_post_id IS NULL
    ),
    engagements_with_scores AS (
        SELECT
            e.root_post_id,
            e.root_user_id,
            e.root_username,
            e.root_tweet_created_at,
            e.is_root_post,
            e.is_root_quote,
            e.is_root_reply,
            e.root_favorite_count,
            e.root_reply_count,
            e.engaged_tweet_id,
            e.engaged_user_id,
            e.is_engaged_reply,
            e.is_engaged_quote,
            e.is_engaged_repost,
            e.engaged_tweet_created_at,
            eu.score AS engaged_user_score
        FROM engagements e
            LEFT JOIN mindshare.mindshare_user eu ON eu.x_id::text = e.engaged_user_id
    ),
    posts_with_no_engagement AS (
        SELECT
            r.post_id AS root_post_id,
            r.user_x_id AS root_user_id,
            r.root_username,
            r.post_created_at AS root_tweet_created_at,
            r.is_post AS is_root_post,
            r.is_quote AS is_root_quote,
            r.is_reply AS is_root_reply,
            r.favorite_count AS root_favorite_count,
            r.reply_count AS root_reply_count,
            NULL::text AS engaged_tweet_id,
            NULL::text AS engaged_user_id,
            NULL::boolean AS is_engaged_reply,
            NULL::boolean AS is_engaged_quote,
            NULL::boolean AS is_engaged_repost,
            NULL::timestamp with time zone AS engaged_tweet_created_at,
            NULL::numeric AS engaged_user_score
        FROM roots r (
                post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id, is_retweet, is_reply, is_quote, is_post, view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at, sentiment_score, sentiment_label, entities, content_score, x_id, x_username, display_name, score, avatar_url, adjustment_config, followers_count, verified, created_at_1, updated_at_1, root_username
            )
        WHERE
            NOT (
                EXISTS (
                    SELECT 1
                    FROM engagements_with_scores e
                    WHERE
                        e.root_post_id = r.post_id
                )
            )
    )
SELECT
    engagements_with_scores.root_post_id,
    engagements_with_scores.root_user_id,
    engagements_with_scores.root_username,
    engagements_with_scores.root_tweet_created_at,
    engagements_with_scores.is_root_post,
    engagements_with_scores.is_root_quote,
    engagements_with_scores.is_root_reply,
    engagements_with_scores.root_favorite_count,
    engagements_with_scores.root_reply_count,
    engagements_with_scores.engaged_tweet_id,
    engagements_with_scores.engaged_user_id,
    engagements_with_scores.is_engaged_reply,
    engagements_with_scores.is_engaged_quote,
    engagements_with_scores.is_engaged_repost,
    engagements_with_scores.engaged_tweet_created_at,
    engagements_with_scores.engaged_user_score
FROM engagements_with_scores
UNION ALL
SELECT
    posts_with_no_engagement.root_post_id,
    posts_with_no_engagement.root_user_id,
    posts_with_no_engagement.root_username,
    posts_with_no_engagement.root_tweet_created_at,
    posts_with_no_engagement.is_root_post,
    posts_with_no_engagement.is_root_quote,
    posts_with_no_engagement.is_root_reply,
    posts_with_no_engagement.root_favorite_count,
    posts_with_no_engagement.root_reply_count,
    posts_with_no_engagement.engaged_tweet_id,
    posts_with_no_engagement.engaged_user_id,
    posts_with_no_engagement.is_engaged_reply,
    posts_with_no_engagement.is_engaged_quote,
    posts_with_no_engagement.is_engaged_repost,
    posts_with_no_engagement.engaged_tweet_created_at,
    posts_with_no_engagement.engaged_user_score
FROM posts_with_no_engagement
WITH
    DATA;

-- View indexes:
CREATE INDEX ix_mv_engagement_pact_swap_root ON analytics.mv_engagement_pact_swap USING btree (root_post_id);

CREATE UNIQUE INDEX ix_mv_engagement_pact_swap_tweet ON analytics.mv_engagement_pact_swap USING btree (engaged_tweet_id);

CREATE INDEX ix_mv_engagement_pact_swap_user ON analytics.mv_engagement_pact_swap USING btree (engaged_user_id);

----- NOTES
--- It took about 2 minute and 19 seconds to create a MATERIALIZED view for quipnetwork (which contains about 2.6 million records) 2