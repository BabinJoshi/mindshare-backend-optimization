-- mindshare.mindshare_project definition

-- Drop table

-- DROP TABLE mindshare.mindshare_project;

CREATE TABLE mindshare.mindshare_project (
    project_name varchar(100) NOT NULL,
    description text NOT NULL,
    start_ts int8 NULL,
    end_ts int8 NULL,
    valid_keywords jsonb NOT NULL,
    status bool DEFAULT true NOT NULL,
    created_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NOT NULL,
    updated_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NULL,
    track_tweets bool DEFAULT true NOT NULL,
    thumbnail_url varchar(500) NULL,
    CONSTRAINT mindshare_project_pkey PRIMARY KEY (project_name)
);