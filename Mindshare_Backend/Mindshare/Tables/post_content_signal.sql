-- mindshare.post_content_signal definition

-- Drop table

-- DROP TABLE mindshare.post_content_signal;

CREATE TABLE mindshare.post_content_signal (
    post_id text NOT NULL,
    project_keyword text NOT NULL,
    post_created_at timestamptz NOT NULL,
    relevance numeric(5, 2) NULL,
    context_depth numeric(5, 2) NULL,
    meme_communication_value numeric(5, 2) NULL,
    visual_information_density numeric(5, 2) NULL,
    human_signal numeric(5, 2) NULL,
    project_focus numeric(5, 2) NULL,
    mention_farming_risk numeric(5, 2) NULL,
    ai_generated_probability numeric(5, 2) NULL,
    sentiment numeric(4, 2) NULL,
    reason text NULL,
    created_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NOT NULL,
    updated_at timestamptz DEFAULT (
        now() AT TIME ZONE 'utc'::text
    ) NULL,
    CONSTRAINT post_content_signal_pkey PRIMARY KEY (
        project_keyword,
        post_created_at,
        post_id
    )
)
PARTITION BY
    LIST (project_keyword);