-- mindshare.api_key definition

-- Drop table

-- DROP TABLE mindshare.api_key;

CREATE TABLE mindshare.api_key (
    id uuid NOT NULL,
    "key" varchar(255) NOT NULL,
    "name" varchar(255) NOT NULL,
    created_by_admin varchar(255) NOT NULL,
    expires_at timestamptz NULL,
    is_active bool DEFAULT true NOT NULL,
    last_used_at timestamptz NULL,
    roles _varchar DEFAULT ARRAY[]::character varying[] NOT NULL,
    created_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NOT NULL,
    updated_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NULL,
    CONSTRAINT api_key_key_key UNIQUE (key),
    CONSTRAINT api_key_pkey PRIMARY KEY (id),
    CONSTRAINT api_key_created_by_admin_fkey FOREIGN KEY (created_by_admin) REFERENCES mindshare."admin" (username) ON DELETE RESTRICT
);

CREATE INDEX ix_api_key_expires_at ON mindshare.api_key USING btree (expires_at);

CREATE INDEX ix_api_key_is_active ON mindshare.api_key USING btree (is_active);

CREATE UNIQUE INDEX ix_api_key_key ON mindshare.api_key USING btree (key);