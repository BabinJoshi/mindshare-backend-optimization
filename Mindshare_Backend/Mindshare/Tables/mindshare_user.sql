-- mindshare.mindshare_user definition

-- Drop table

-- DROP TABLE mindshare.mindshare_user;

CREATE TABLE mindshare.mindshare_user (
    x_id varchar(50) NOT NULL,
    x_username varchar(255) NOT NULL,
    display_name varchar(255) NOT NULL,
    score numeric(10, 2) NOT NULL,
    avatar_url varchar(1000) NOT NULL,
    adjustment_config jsonb NOT NULL,
    followers_count int4 NOT NULL,
    verified bool DEFAULT false NOT NULL,
    created_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NOT NULL,
    updated_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NULL,
    last_score_fetched_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NULL,
    CONSTRAINT mindshare_user_pkey PRIMARY KEY (x_id)
);

CREATE INDEX ix_mindshare_mindshare_user_x_username ON mindshare.mindshare_user USING btree (x_username);