-- mindshare_score.global_contribution_scores definition

-- Drop table

-- DROP TABLE mindshare_score.global_contribution_scores;

CREATE TABLE mindshare_score.global_contribution_scores (
    reply_post_id text NOT NULL,
    replier_x_id text NOT NULL,
    original_post_id text NOT NULL,
    original_author_x_id text NOT NULL,
    post_created_at timestamptz NOT NULL,
    replier_base_score numeric NOT NULL,
    effective_score numeric NOT NULL,
    contribution_score numeric NOT NULL,
    active_multipliers _numeric NOT NULL,
    reply_number int4 NOT NULL,
    local_reply_count int4 NOT NULL,
    decay_type text NOT NULL
);

CREATE INDEX idx_ucs_original_author ON mindshare_score.global_contribution_scores USING btree (original_author_x_id);

CREATE INDEX idx_ucs_original_post_id ON mindshare_score.global_contribution_scores USING btree (original_post_id);

CREATE INDEX idx_ucs_post_created ON mindshare_score.global_contribution_scores USING btree (post_created_at);

CREATE INDEX idx_ucs_replier ON mindshare_score.global_contribution_scores USING btree (replier_x_id);

CREATE INDEX idx_ucs_reply_post_id ON mindshare_score.global_contribution_scores USING btree (reply_post_id);