-- mindshare."admin" definition

-- Drop table

-- DROP TABLE mindshare."admin";

CREATE TABLE mindshare."admin" (
    username varchar(255) NOT NULL,
    hashed_password varchar(255) NOT NULL,
    is_active bool DEFAULT true NOT NULL,
    created_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NOT NULL,
    updated_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NULL,
    CONSTRAINT admin_pkey PRIMARY KEY (username)
);