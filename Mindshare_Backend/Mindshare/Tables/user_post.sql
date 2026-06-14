-- mindshare.user_post definition

-- Drop table

-- DROP TABLE mindshare.user_post;

CREATE TABLE mindshare.user_post (
    post_id text NOT NULL,
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
    created_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NOT NULL,
    updated_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NULL,
    entities jsonb NULL,
    project_keyword varchar(255) NULL,
    CONSTRAINT user_post_pkey PRIMARY KEY (post_created_at, post_id)
);

CREATE INDEX idx_user_post_replied_post_id_time ON mindshare.user_post USING btree (
    replied_post_id,
    post_created_at
);

CREATE INDEX idx_user_post_root_post_id ON mindshare.user_post USING btree (root_post_id);

CREATE INDEX idx_user_post_user_x_id_time ON mindshare.user_post USING btree (user_x_id, post_created_at);

CREATE INDEX ix_user_post_post_created_at ON mindshare.user_post USING btree (post_created_at);

CREATE INDEX ix_user_post_post_id ON mindshare.user_post USING btree (post_id);

CREATE INDEX ix_user_post_quoted_post_id ON mindshare.user_post USING btree (quoted_post_id);

CREATE INDEX ix_user_post_replied_post_id ON mindshare.user_post USING btree (replied_post_id);

CREATE INDEX ix_user_post_user_x_id_time ON mindshare.user_post USING btree (user_x_id, post_created_at);