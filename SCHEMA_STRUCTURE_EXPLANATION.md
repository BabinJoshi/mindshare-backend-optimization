# Why Score Tables Were Added to Migration Scripts

## Original Design Decision

Initially, `MIGRATION_EXECUTE_ALL.sql` did NOT include DDL for `contribution_scores` and `global_contribution_scores` tables because:

1. **Those tables already exist in production** - The migration was designed to ADD incremental decay logic to existing systems, not create tables from scratch
2. **Focus on incremental logic** - The original script focused on the core changes: watermark tracking, logging, core functions, and incremental entry points
3. **Assumption of pre-existing infrastructure** - It assumed you had already set up the score tables

## What Changed

I've now **updated both migration scripts** to include comprehensive table creation:

### MIGRATION_EXECUTE_ALL.sql (Production)
Added **Phase 1** with DDL for:
- `contribution_scores` table (project-scoped)
- `global_contribution_scores` table (global scope)
- Associated indexes on both tables

This makes the script **completely self-contained** - you can run it on a fresh database and it will create everything needed.

### MIGRATION_EXECUTE_ALL_TEST_TABLES.sql (Test/Validation)
Already included test table creation. Updated comments to clarify the phase structure:
- Phase 1-2: Infrastructure (sequence, state, logging tables)
- Phase 3: Score tables (_test versions)
- Phase 4: Core decay functions
- Phase 5: Tail cores
- Phase 6: Incremental entry points

## Table Structure Included

### contribution_scores
```sql
CREATE TABLE mindshare_score.contribution_scores (
    project_keyword       text        NOT NULL,
    reply_post_id         text        NOT NULL,    -- PRIMARY KEY part 1
    replier_x_id          text        NOT NULL,
    original_post_id      text        NOT NULL,
    original_author_x_id  text        NOT NULL,
    post_created_at       timestamptz NOT NULL,
    replier_base_score    numeric     NOT NULL,
    effective_score       numeric     NOT NULL,
    contribution_score    numeric     NOT NULL,
    active_multipliers    numeric[]   NOT NULL,    -- Penalty window array
    reply_number          integer     NOT NULL,
    local_reply_count     integer     NOT NULL,
    decay_type            text        NOT NULL,    -- FIRST_REPLY, LOCAL_DECAY, GLOBAL_DECAY
    CONSTRAINT pk_cs PRIMARY KEY (project_keyword, reply_post_id)
);

-- Indexes
ix_cs_keyword_orig_replier_time  -- For decay queries (project, original_post, replier, time)
ix_cs_keyword_replier_time       -- For per-replier scanning
```

### global_contribution_scores
```sql
CREATE TABLE mindshare_score.global_contribution_scores (
    reply_post_id         text        NOT NULL,    -- PRIMARY KEY
    original_post_id      text        NOT NULL,
    replier_x_id          text        NOT NULL,
    original_author_x_id  text        NOT NULL,
    post_created_at       timestamptz NOT NULL,
    replier_base_score    numeric     NOT NULL,
    effective_score       numeric     NOT NULL,
    contribution_score    numeric     NOT NULL,
    active_multipliers    numeric[]   NOT NULL,
    reply_number          integer     NOT NULL,
    local_reply_count     integer     NOT NULL,
    decay_type            text        NOT NULL,
    CONSTRAINT pk_gcs PRIMARY KEY (reply_post_id)
);

-- Indexes
ix_gcs_orig_replier_time  -- For decay queries (original_post, replier, time)
ix_gcs_replier_time       -- For per-replier scanning
```

## Key Fields Explained

| Field | Purpose |
|-------|---------|
| **reply_post_id** | ID of the reply post (PRIMARY KEY) |
| **replier_x_id** | ID of the user who made the reply |
| **original_post_id** | ID of the post being replied to |
| **original_author_x_id** | ID of the author of the original post |
| **post_created_at** | When the reply was created (used for time-based filtering) |
| **replier_base_score** | User's base score at time of calculation |
| **effective_score** | Score after applying penalty multipliers |
| **contribution_score** | Final score used for rankings |
| **active_multipliers[]** | Array of penalty multipliers in the 30-day window |
| **reply_number** | Sequence number of this reply from the user |
| **local_reply_count** | How many replies to this specific user appear in the window |
| **decay_type** | FIRST_REPLY (mult=1.0), GLOBAL_DECAY (mult=0.9), LOCAL_DECAY (mult=0.5) |

## Benefits of Adding Table DDL

1. **Self-contained migration** - No external dependencies on pre-existing tables
2. **Idempotent** - Can run multiple times safely (CREATE TABLE IF NOT EXISTS)
3. **Complete documentation** - Shows exactly what structure is needed
4. **Easier testing** - Can run on fresh databases for validation
5. **Clear schema contract** - Incremental functions expect these exact tables

## Indexes Rationale

### For contribution_scores:
- **ix_cs_keyword_orig_replier_time**: Used by decay calculations to find scores for a specific user's replies to a specific post
- **ix_cs_keyword_replier_time**: Used to iterate through a replier's history (tail-from-t_min replay)

### For global_contribution_scores:
- **ix_gcs_orig_replier_time**: Used to find scores without project filtering
- **ix_gcs_replier_time**: Used to iterate through a replier's global history

Both include INCLUDE clauses to avoid heap lookups for common queries (original_author_x_id, contribution_score).

## Summary of Changes

| Script | Change |
|--------|--------|
| MIGRATION_EXECUTE_ALL.sql | Added Phase 1 with score table DDL + indexes |
| MIGRATION_EXECUTE_ALL_TEST_TABLES.sql | Clarified phase structure (tables created in Phase 3) |

Both scripts now have **everything needed** to deploy incremental decay on a fresh database.
