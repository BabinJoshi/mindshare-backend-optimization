-- ============================================================================
-- CREATE_TEST_DATA_ACURAST.sql
--
-- This script creates a test dataset for incremental decay testing:
-- 1. Creates mindshare_post_test table (same structure as mindshare_post)
-- 2. Populates it with Acurast data (excluding 50 latest records)
-- 3. Generates INSERT statements for the 50 latest records
--
-- Usage:
--   1. Run this script to create the test table and base data
--   2. Later, run the INSERT statements to add the 50 latest records
--      (this simulates new data arriving, which triggers incremental decay)
--
-- Connection: postgresql://postgres_user:postgres_pass@195.35.23.78:5432/mindshare_db
-- ============================================================================

-- ============================================================================
-- STEP 1: Create mindshare_post_test table (same structure as mindshare_post)
-- ============================================================================

CREATE TABLE IF NOT EXISTS mindshare.mindshare_post_test (
    post_id           text                     NOT NULL,
    project_keyword   text                     NOT NULL,
    user_x_id         text                     NOT NULL,
    full_text         text                     NOT NULL,
    retweeted_post_id text,
    replied_post_id   text,
    quoted_post_id    text,
    root_post_id      text,
    is_retweet        boolean                  NOT NULL GENERATED ALWAYS AS (retweeted_post_id IS NOT NULL) STORED,
    is_reply          boolean                  NOT NULL GENERATED ALWAYS AS (replied_post_id IS NOT NULL) STORED,
    is_quote          boolean                  NOT NULL GENERATED ALWAYS AS (quoted_post_id IS NOT NULL) STORED,
    is_post           boolean                  NOT NULL GENERATED ALWAYS AS (retweeted_post_id IS NULL AND replied_post_id IS NULL AND quoted_post_id IS NULL) STORED,
    view_count        integer                  NOT NULL,
    reply_count       integer                  NOT NULL,
    retweet_count     integer                  NOT NULL,
    quote_count       integer                  NOT NULL,
    favorite_count    integer                  NOT NULL,
    post_created_at   timestamp with time zone NOT NULL,
    created_at        timestamp with time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'::text),
    updated_at        timestamp with time zone DEFAULT (now() AT TIME ZONE 'utc'::text),
    sentiment_score   numeric(3,2),
    sentiment_label   character varying(20),
    entities          jsonb,
    content_score     numeric(5,2),
    latest_reply_at   timestamp with time zone,
    CONSTRAINT pk_mindshare_post_test PRIMARY KEY (project_keyword, post_created_at, post_id)
);

-- Create indexes (matching production table)
CREATE INDEX IF NOT EXISTS ix_mindshare_post_test_decay_original_lookup
    ON mindshare.mindshare_post_test (project_keyword, post_id)
    INCLUDE (user_x_id);

CREATE INDEX IF NOT EXISTS ix_mindshare_post_test_decay_source_order
    ON mindshare.mindshare_post_test (project_keyword, user_x_id, post_created_at)
    INCLUDE (post_id, replied_post_id)
    WHERE replied_post_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_mindshare_post_test_post_created_at
    ON mindshare.mindshare_post_test (post_created_at);

CREATE INDEX IF NOT EXISTS ix_mindshare_post_test_post_id
    ON mindshare.mindshare_post_test (post_id);

CREATE INDEX IF NOT EXISTS ix_mindshare_post_test_user_x_id_time
    ON mindshare.mindshare_post_test (user_x_id, post_created_at);

CREATE INDEX IF NOT EXISTS ix_mindshare_post_test_replied_post_id
    ON mindshare.mindshare_post_test (replied_post_id)
    WHERE replied_post_id IS NOT NULL;

-- ============================================================================
-- STEP 2: Populate test table with all Acurast data EXCEPT 50 latest records
-- ============================================================================

INSERT INTO mindshare.mindshare_post_test (
    post_id, project_keyword, user_x_id, full_text, retweeted_post_id,
    replied_post_id, quoted_post_id, root_post_id,
    view_count, reply_count, retweet_count, quote_count, favorite_count,
    post_created_at, created_at, updated_at,
    sentiment_score, sentiment_label, entities, content_score, latest_reply_at
)
SELECT
    post_id, project_keyword, user_x_id, full_text, retweeted_post_id,
    replied_post_id, quoted_post_id, root_post_id,
    view_count, reply_count, retweet_count, quote_count, favorite_count,
    post_created_at, created_at, updated_at,
    sentiment_score, sentiment_label, entities, content_score, latest_reply_at
FROM mindshare.mindshare_post
WHERE project_keyword = 'Acurast'
-- Exclude the 50 latest records (by post_created_at DESC, then post_id DESC as tiebreaker)
AND (post_created_at, post_id) NOT IN (
    SELECT post_created_at, post_id
    FROM mindshare.mindshare_post
    WHERE project_keyword = 'Acurast'
    ORDER BY post_created_at DESC, post_id DESC
    LIMIT 50
)
ORDER BY post_created_at;

-- Verify the count
SELECT COUNT(*) as loaded_records FROM mindshare.mindshare_post_test;

-- ============================================================================
-- STEP 3: Generate INSERT statements for the 50 latest records
-- ============================================================================

-- Output the INSERT statements as a separate block you can copy/paste later
\echo ''
\echo '============================================================================'
\echo 'INSERT STATEMENTS FOR 50 LATEST ACURAST RECORDS'
\echo '============================================================================'
\echo 'Copy everything below and run it separately when you want to test incremental'
\echo ''

SELECT
    'INSERT INTO mindshare.mindshare_post_test (' ||
    'post_id, project_keyword, user_x_id, full_text, retweeted_post_id, ' ||
    'replied_post_id, quoted_post_id, root_post_id, ' ||
    'view_count, reply_count, retweet_count, quote_count, favorite_count, ' ||
    'post_created_at, created_at, updated_at, ' ||
    'sentiment_score, sentiment_label, entities, content_score, latest_reply_at' ||
    ') VALUES (' ||
    quote_literal(post_id) || ', ' ||
    quote_literal(project_keyword) || ', ' ||
    quote_literal(user_x_id) || ', ' ||
    quote_literal(full_text) || ', ' ||
    CASE WHEN retweeted_post_id IS NULL THEN 'NULL' ELSE quote_literal(retweeted_post_id) END || ', ' ||
    CASE WHEN replied_post_id IS NULL THEN 'NULL' ELSE quote_literal(replied_post_id) END || ', ' ||
    CASE WHEN quoted_post_id IS NULL THEN 'NULL' ELSE quote_literal(quoted_post_id) END || ', ' ||
    CASE WHEN root_post_id IS NULL THEN 'NULL' ELSE quote_literal(root_post_id) END || ', ' ||
    view_count || ', ' ||
    reply_count || ', ' ||
    retweet_count || ', ' ||
    quote_count || ', ' ||
    favorite_count || ', ' ||
    quote_literal(post_created_at) || ', ' ||
    quote_literal(created_at) || ', ' ||
    CASE WHEN updated_at IS NULL THEN 'NULL' ELSE quote_literal(updated_at) END || ', ' ||
    CASE WHEN sentiment_score IS NULL THEN 'NULL' ELSE sentiment_score::text END || ', ' ||
    CASE WHEN sentiment_label IS NULL THEN 'NULL' ELSE quote_literal(sentiment_label) END || ', ' ||
    CASE WHEN entities IS NULL THEN 'NULL' ELSE quote_literal(entities::text) || '::jsonb' END || ', ' ||
    CASE WHEN content_score IS NULL THEN 'NULL' ELSE content_score::text END || ', ' ||
    CASE WHEN latest_reply_at IS NULL THEN 'NULL' ELSE quote_literal(latest_reply_at) END ||
    ');'
FROM mindshare.mindshare_post
WHERE project_keyword = 'Acurast'
ORDER BY post_created_at DESC, post_id DESC
LIMIT 50;

-- ============================================================================
-- Summary
-- ============================================================================

\echo ''
\echo '============================================================================'
\echo 'SUMMARY'
\echo '============================================================================'

SELECT
    'Test table created: mindshare.mindshare_post_test' as message
UNION ALL
SELECT
    'Loaded records: ' || COUNT(*)::text || ' (Acurast without 50 latest)'
FROM mindshare.mindshare_post_test
UNION ALL
SELECT
    'Ready to insert: 50 latest Acurast records (see INSERT statements above)'
UNION ALL
SELECT
    'Test scenario: After inserting 50 records, run incremental decay to test'
ORDER BY 1;

\echo ''
\echo 'Next steps:'
\echo '1. This script creates mindshare.mindshare_post_test with Acurast data'
\echo '2. Copy the INSERT statements above to a separate file'
\echo '3. Create test functions pointing to mindshare_post_test instead of mindshare_post'
\echo '4. Run incremental decay on the test table'
\echo '5. Then insert the 50 latest records'
\echo '6. Run incremental decay again to verify it only processes changed repliers'
\echo ''
