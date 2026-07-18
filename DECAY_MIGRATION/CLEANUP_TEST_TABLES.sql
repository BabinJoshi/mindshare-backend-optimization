-- ============================================================================
-- CLEANUP_TEST_TABLES.sql
-- Drop all test tables and test functions with CASCADE
-- Purpose: Reset test environment for fresh migration runs
-- ============================================================================

BEGIN;

-- ============================================================================
-- Step 1: Drop all test functions (depends on test tables)
-- ============================================================================

DROP FUNCTION IF EXISTS mindshare_score._decay_apply_project_new_replies_test(text, interval, bigint, integer) CASCADE;
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_global_new_replies_test(interval, bigint, integer) CASCADE;
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_project_tail_test(text, interval, bigint, integer) CASCADE;
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_global_tail_test(interval, bigint, integer) CASCADE;
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_project_test(text, interval, bigint, boolean, integer) CASCADE;
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_global_test(interval, bigint, boolean, integer) CASCADE;
DROP FUNCTION IF EXISTS mindshare_score.calculate_decay_scores_incremental_test(text, interval, bigint, integer) CASCADE;
DROP FUNCTION IF EXISTS mindshare_score.calculate_global_decay_scores_incremental_test(interval, bigint, integer) CASCADE;

-- ============================================================================
-- Step 2: Drop all test indexes explicitly
-- ============================================================================

DROP INDEX IF EXISTS mindshare_score.ix_tcs_keyword_orig_replier_time CASCADE;
DROP INDEX IF EXISTS mindshare_score.ix_tcs_keyword_replier_time CASCADE;
DROP INDEX IF EXISTS mindshare_score.ix_tgcs_orig_replier_time CASCADE;
DROP INDEX IF EXISTS mindshare_score.ix_tgcs_replier_time CASCADE;

-- ============================================================================
-- Step 3: Drop all test tables with CASCADE
-- ============================================================================

DROP TABLE IF EXISTS mindshare_score.contribution_scores_test CASCADE;
DROP TABLE IF EXISTS mindshare_score.global_contribution_scores_test CASCADE;

-- ============================================================================
-- Step 4: Reset incremental watermarks for TEST scopes
-- CRITICAL: without this, the next run sees an old watermark and takes the
-- slow incremental path over the ENTIRE history (tables are empty, so every
-- reply looks "new") instead of the fast full rebuild.
-- ============================================================================

DELETE FROM mindshare_score.decay_run_state WHERE scope LIKE '%:TEST';

-- ============================================================================
-- Step 5: Verify cleanup
-- ============================================================================

DO $$
DECLARE
    v_test_tables INTEGER;
    v_test_functions INTEGER;
BEGIN
    -- Count remaining test tables
    SELECT COUNT(*) INTO v_test_tables
    FROM information_schema.tables
    WHERE table_schema = 'mindshare_score'
      AND (table_name LIKE '%_test%' OR table_name LIKE 'test_%');

    -- Count remaining test functions
    SELECT COUNT(*) INTO v_test_functions
    FROM information_schema.routines
    WHERE routine_schema = 'mindshare_score'
      AND routine_name LIKE '%_test%';

    IF v_test_tables = 0 AND v_test_functions = 0 THEN
        RAISE NOTICE '✓ Cleanup successful!';
        RAISE NOTICE '  - All test tables dropped';
        RAISE NOTICE '  - All test functions dropped';
    ELSE
        RAISE WARNING '⚠ Warning: Found remaining test objects';
        RAISE WARNING '  - Test tables remaining: %', v_test_tables;
        RAISE WARNING '  - Test functions remaining: %', v_test_functions;
    END IF;
END $$;

COMMIT;

-- ============================================================================
-- Summary
-- ============================================================================
-- This script dropped:
--   Indexes:
--     - ix_tcs_keyword_orig_replier_time
--     - ix_tcs_keyword_replier_time
--     - ix_tgcs_orig_replier_time
--     - ix_tgcs_replier_time
--
--   Tables:
--     - mindshare_score.contribution_scores_test
--     - mindshare_score.global_contribution_scores_test
--
--   Functions:
--     - _decay_apply_project_test
--     - _decay_apply_global_test
--     - _decay_apply_project_tail_test
--     - _decay_apply_global_tail_test
--     - _decay_apply_project_new_replies_test
--     - _decay_apply_global_new_replies_test
--     - calculate_decay_scores_incremental_test
--     - calculate_global_decay_scores_incremental_test
--
-- Next: Run MIGRATION_EXECUTE_ALL_TEST_TABLES.sql to recreate them all
-- ============================================================================
