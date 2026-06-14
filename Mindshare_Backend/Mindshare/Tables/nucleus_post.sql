-- mindshare.nucleus_post definition

-- Drop table

-- DROP TABLE mindshare.nucleus_post;

CREATE TABLE mindshare.nucleus_post (
    post_id text NOT NULL,
    project_keyword text NOT NULL,
    user_x_id text NOT NULL,
    full_text text NOT NULL,
    retweeted_post_id text NULL,
    replied_post_id text NULL,
    quoted_post_id text NULL,
    root_post_id text NULL,
    is_retweet bool GENERATED ALWAYS AS (retweeted_post_id IS NOT NULL) STORED NOT NULL,
    is_reply bool GENERATED ALWAYS AS (replied_post_id IS NOT NULL) STORED NOT NULL,
    is_quote bool GENERATED ALWAYS AS (quoted_post_id IS NOT NULL) STORED NOT NULL,
    is_post bool GENERATED ALWAYS AS (
        retweeted_post_id IS NULL
        AND replied_post_id IS NULL
        AND quoted_post_id IS NULL
    ) STORED NOT NULL,
    view_count int4 NOT NULL,
    reply_count int4 NOT NULL,
    retweet_count int4 NOT NULL,
    quote_count int4 NOT NULL,
    favorite_count int4 NOT NULL,
    post_created_at timestamptz NOT NULL,
    sentiment_score numeric(3, 2) NULL,
    sentiment_label varchar(20) NULL,
    entities jsonb NULL,
    content_score numeric(5, 2) NULL,
    created_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NOT NULL,
    updated_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NULL,
    is_reply_fetched bool DEFAULT false NOT NULL,
    CONSTRAINT nucleus_post_pkey PRIMARY KEY (
        project_keyword,
        post_created_at,
        post_id
    )
)
PARTITION BY
    LIST (project_keyword);

CREATE INDEX ix_nucleus_post_post_created_at ON ONLY mindshare.nucleus_post USING btree (post_created_at);

CREATE INDEX ix_nucleus_post_post_id ON ONLY mindshare.nucleus_post USING btree (post_id);

CREATE INDEX ix_nucleus_post_user_x_id_time ON ONLY mindshare.nucleus_post USING btree (user_x_id, post_created_at);