# Execution Guide: Incremental Decay Migration

## Quick Start

This guide walks you through executing the incremental decay migration from test to prod schemas in a safe, step-by-step manner.

### Files You Need

- `MIGRATION_INCREMENTAL_DECAY_TEST_TO_PROD.md` - Detailed planning document
- `MIGRATION_EXECUTE_ALL.sql` - Master SQL script (all phases in one)
- `01_setup_infrastructure.sql` - Phase 2 only (optional, if running separately)
- `02_create_indexes_and_state.sql` - Phase 3 only (optional, if running separately)

### Database Connection

```
Host: 195.35.23.78
Port: 5432
User: postgres_user
Password: postgres_pass
Database: mindshare_db
```

---

## Execution Methods

### Method 1: All-in-One (RECOMMENDED)

**Best for**: First-time migration, controlled environment

Execute all phases in a single transaction:

```bash
# 1. Backup the database (CRITICAL!)
pg_dump -h 195.35.23.78 -U postgres_user -d mindshare_db | gzip > mindshare_db_backup_$(date +%Y%m%d_%H%M%S).sql.gz

# 2. Connect to psql and run the master script
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
BEGIN;
\i MIGRATION_EXECUTE_ALL.sql
-- Review the output above
-- If everything looks good:
COMMIT;
-- If there are errors:
-- ROLLBACK;
EOF

# 3. Verify the migration succeeded
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
  "SELECT COUNT(*) FROM mindshare_score.decay_run_log;"
```

**Expected Output**:
```
Migration complete!
status        tables_created  functions_created
-----------   --------------- -----------------
Migration...  2               10
```

### Method 2: Phase-by-Phase (SAFER)

**Best for**: Large production migrations, need to test each phase

```bash
# Phase 1: Validate (no changes, just checking)
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
SELECT COUNT(*) as contribution_scores_rows FROM mindshare_score.contribution_scores;
SELECT COUNT(*) as global_scores_rows FROM mindshare_score.global_contribution_scores;
EOF

# Phase 2: Infrastructure (tables, sequences, logging)
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
BEGIN;
\i 01_setup_infrastructure.sql
-- Review output, then:
COMMIT;
EOF

# Phase 3: Indexes (optional, can be in separate transaction)
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
BEGIN;
\i 02_create_indexes_and_state.sql
-- Review output, then:
COMMIT;
EOF

# Phase 4-6: Core functions (run MIGRATION_EXECUTE_ALL.sql from Phase 2 onwards)
# Or manually run decay_02, decay_03, decay_11, decay_12, decay_13 scripts
```

### Method 3: Using psql Directly (SIMPLE)

```bash
# One-liner: Run master script
psql postgresql://postgres_user:postgres_pass@195.35.23.78:5432/mindshare_db -f MIGRATION_EXECUTE_ALL.sql
```

---

## Step-by-Step Execution with Verification

### Step 1: Backup (5 minutes)

```bash
# Full backup
pg_dump -h 195.35.23.78 -U postgres_user -d mindshare_db > mindshare_db_backup_$(date +%Y%m%d_%H%M%S).sql

# Verify backup
ls -lh mindshare_db_backup_*.sql
```

### Step 2: Run Migration Script (2-3 minutes)

```bash
# Option A: In a transaction (safest)
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'SQLEOF'
BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;

\i MIGRATION_EXECUTE_ALL.sql

-- Review the output above for any errors
-- If no errors, commit; otherwise rollback:
COMMIT;
-- ROLLBACK;
SQLEOF

# Option B: Direct execution
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -f MIGRATION_EXECUTE_ALL.sql
```

### Step 3: Verify Infrastructure (1 minute)

```bash
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
-- Check tables exist
SELECT table_name FROM information_schema.tables
WHERE table_schema='mindshare_score'
AND table_name IN ('decay_run_log','decay_run_state')
ORDER BY table_name;

-- Check sequence exists
SELECT sequencename FROM pg_sequences
WHERE schemaname='mindshare_score'
AND sequencename='decay_run_id_seq';

-- Check functions exist
SELECT routine_name FROM information_schema.routines
WHERE routine_schema='mindshare_score'
AND (routine_name LIKE '%decay%' OR routine_name LIKE '%next%')
ORDER BY routine_name;
EOF

-- Expected output:
-- table_name: decay_run_log, decay_run_state
-- sequencename: decay_run_id_seq
-- 10+ functions listed
```

### Step 4: Verify Indexes (1 minute)

```bash
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
SELECT indexname FROM pg_indexes
WHERE schemaname='mindshare'
AND indexname LIKE 'ix_tmp%'
ORDER BY indexname;

-- Expected: ix_tmp_mp_ingest, ix_tmp_mp_replied_post_id, ix_tmp_mu_ingest, ix_tmp_up_ingest
EOF
```

### Step 5: Phase 7 - First Run (Initialization)

**IMPORTANT**: The first run processes ALL repliers and initializes watermarks. It will be slow.

**Choose One**:

#### Option A: Run All Projects + Global (Simplest)

```bash
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
-- This is a master procedure that runs all projects
SELECT mindshare_score.calculate_all_decay_scores_incremental();
EOF
```

#### Option B: Run Projects Individually (More Control)

```bash
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
-- Get list of all project keywords first
SELECT DISTINCT project_keyword FROM mindshare.mindshare_post
ORDER BY project_keyword;
EOF
```

Then run for each project:

```bash
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
-- Run for a specific project (example: 'default')
SELECT mindshare_score.calculate_decay_scores_incremental(
    'default',
    '30 days'::interval,
    NULL,  -- run_id (auto-generated)
    50000  -- log_every (progress log every N rows)
);
EOF
```

#### Option C: Run Global Only (Test)

```bash
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
-- Test with global scores only (faster)
SELECT mindshare_score.calculate_global_decay_scores_incremental();
EOF
```

### Step 6: Monitor Progress (During Run)

**In a separate terminal**, monitor the decay run log in real-time:

```bash
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
-- Watch progress (run every 10-30 seconds)
SELECT run_id, scope, project_keyword, status, phase, message, rows_processed, 
       EXTRACT(epoch FROM (now() - started_at))::int as elapsed_sec
FROM mindshare_score.decay_run_log
ORDER BY run_id DESC LIMIT 5;
EOF
```

Or use a loop:

```bash
while true; do
  psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
    "SELECT run_id, scope, status, rows_processed, EXTRACT(epoch FROM (now() - started_at))::int as elapsed_sec FROM mindshare_score.decay_run_log ORDER BY run_id DESC LIMIT 3;"
  sleep 15
done
```

### Step 7: Verify First Run Success (After Run Completes)

```bash
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
-- Check for failures
SELECT run_id, scope, project_keyword, status, error_message
FROM mindshare_score.decay_run_log
WHERE status != 'success'
ORDER BY run_id DESC;

-- If there are failures, investigate the error_message, error_detail
-- and then re-run (watermark won't advance until success)

-- Check watermarks (should have rows now)
SELECT scope, last_ingest_ts, last_user_ingest_ts, last_run_id, dirty_repliers, rows_written
FROM mindshare_score.decay_run_state
ORDER BY last_run_at DESC;

-- Expected: One row per scope (project:* and global) with watermarks set
EOF
```

### Step 8: Run Incremental (Subsequent Runs)

After the first run succeeds, subsequent runs will be much faster (only changed repliers):

```bash
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
-- Run incremental (1-5 minutes, not 30+)
SELECT mindshare_score.calculate_all_decay_scores_incremental();

-- Check how many repliers were dirty
SELECT run_id, scope, project_keyword, dirty_repliers, rows_written
FROM mindshare_score.decay_run_log
WHERE scope IN ('global','project:default')
ORDER BY run_id DESC LIMIT 3;

-- Expected: dirty_repliers << all_repliers (e.g., 100 out of 10,000)
EOF
```

---

## Monitoring Queries

### Check Current State

```sql
-- Recent runs
SELECT run_id, scope, project_keyword, status, dirty_repliers, rows_written, 
       EXTRACT(epoch FROM (finished_at - started_at))::numeric(10,2) as duration_sec,
       finished_at
FROM mindshare_score.decay_run_log
WHERE finished_at IS NOT NULL
ORDER BY run_id DESC LIMIT 10;

-- Watermark status
SELECT scope, last_ingest_ts, last_user_ingest_ts, last_run_at, dirty_repliers
FROM mindshare_score.decay_run_state
ORDER BY last_run_at DESC;

-- Contribution scores (verify data is there)
SELECT project_keyword, COUNT(*) as row_count, 
       MIN(post_created_at) as earliest, 
       MAX(post_created_at) as latest
FROM mindshare_score.contribution_scores
GROUP BY project_keyword
ORDER BY row_count DESC;
```

### Detect Failures

```sql
-- All failures
SELECT run_id, scope, project_keyword, error_message, error_detail, error_context
FROM mindshare_score.decay_run_log
WHERE status = 'failed'
ORDER BY run_id DESC;

-- Last N failures with context
SELECT run_id, scope, project_keyword, status, started_at, finished_at, 
       COALESCE(error_message,'(no error)') as error
FROM mindshare_score.decay_run_log
ORDER BY run_id DESC LIMIT 20;
```

### Performance Analysis

```sql
-- Average execution time per scope
SELECT 
    scope,
    COUNT(*) as run_count,
    AVG(EXTRACT(epoch FROM (finished_at - started_at)))::numeric(10,2) as avg_duration_sec,
    MAX(EXTRACT(epoch FROM (finished_at - started_at)))::numeric(10,2) as max_duration_sec,
    AVG(dirty_repliers)::numeric(10,1) as avg_dirty_repliers
FROM mindshare_score.decay_run_log
WHERE status = 'success'
GROUP BY scope
ORDER BY scope;

-- First run (full) vs subsequent (incremental)
SELECT 
    CASE WHEN dirty_repliers IS NULL THEN 'FULL_BUILD' ELSE 'INCREMENTAL' END as type,
    COUNT(*) as run_count,
    AVG(EXTRACT(epoch FROM (finished_at - started_at)))::numeric(10,2) as avg_duration_sec,
    MIN(EXTRACT(epoch FROM (finished_at - started_at)))::numeric(10,2) as min_duration_sec,
    MAX(EXTRACT(epoch FROM (finished_at - started_at)))::numeric(10,2) as max_duration_sec
FROM mindshare_score.decay_run_log
WHERE status = 'success' AND scope LIKE 'project:%'
GROUP BY type
ORDER BY type;
```

---

## Troubleshooting

### Issue: Migration Script Fails at Phase X

**Solution**:
1. Check the error message in the script output
2. Run `ROLLBACK` if in a transaction
3. Restore from backup: `pg_restore -h ... mindshare_db_backup_*.sql`
4. Fix the issue (likely schema mismatch or missing prerequisites)
5. Re-run the migration

### Issue: First Run (Phase 7) is Slow

**Expected**: First run recomputes ALL repliers. This is normal and expected.

**Typical times**:
- 10,000 repliers: 5-10 minutes
- 100,000 repliers: 30-60 minutes
- 1,000,000 repliers: 2-4 hours

**If slower than expected**:
1. Check system load: `top`, `iostat`
2. Check PostgreSQL slow queries: `log_min_duration_statement`
3. Verify indexes were created: See "Step 3" above

### Issue: Watermarks Not Advancing

**Cause**: The decay run failed (not committed)

**Check**:
```sql
SELECT run_id, status, error_message FROM mindshare_score.decay_run_log
ORDER BY run_id DESC LIMIT 5;
```

**Fix**:
1. Identify the error
2. Fix the underlying issue
3. Re-run the decay function (watermark advances on success)

### Issue: "could not open relation with OID..."

**Cause**: Function references the wrong schema

**Check the functions**: Make sure all functions have `SET search_path = mindshare, mindshare_score, public`

**Fix**: Re-run MIGRATION_EXECUTE_ALL.sql

### Issue: Incremental Runs Still Process All Repliers

**Cause**: Watermark not initialized or data changed significantly

**Check**:
```sql
SELECT scope, last_ingest_ts FROM mindshare_score.decay_run_state;
-- If last_ingest_ts is NULL or very old, the watermark is stale
```

**Fix**: Reset watermarks (if you know what you're doing):
```sql
DELETE FROM mindshare_score.decay_run_state;
-- Re-run Phase 7 (first run)
```

---

## Rollback Procedure

If you need to revert to the pre-migration state:

### Quick Rollback (Within Transaction)

If the migration script failed in a transaction:

```sql
ROLLBACK;
-- That's it! Everything rolls back.
```

### Full Rollback (After Commit)

Drop all migration components:

```sql
-- Drop incremental functions
DROP FUNCTION IF EXISTS mindshare_score.calculate_all_decay_scores_incremental();
DROP FUNCTION IF EXISTS mindshare_score.calculate_decay_scores_incremental(text, interval, bigint, integer);
DROP FUNCTION IF EXISTS mindshare_score.calculate_global_decay_scores_incremental(interval, bigint, integer);
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_project_tail(text, interval, bigint, integer);
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_global_tail(interval, bigint, integer);

-- Drop tables (careful: this deletes the run log and state!)
DROP TABLE IF EXISTS mindshare_score.decay_run_state;
DROP TABLE IF EXISTS mindshare_score.decay_run_log;

-- Drop sequence
DROP SEQUENCE IF EXISTS mindshare_score.decay_run_id_seq;

-- Drop logging function
DROP FUNCTION IF EXISTS mindshare_score._decay_log(bigint, text, text, text, text, text, bigint, text, text, text, text, boolean);
DROP FUNCTION IF EXISTS mindshare_score.next_decay_run_id();

-- Drop indexes (optional; they don't hurt to keep)
DROP INDEX IF EXISTS mindshare.ix_tmp_mp_ingest;
DROP INDEX IF EXISTS mindshare.ix_tmp_up_ingest;
DROP INDEX IF EXISTS mindshare.ix_tmp_mu_ingest;
DROP INDEX IF EXISTS mindshare.ix_tmp_mp_replied_post_id;
```

### Database Restore from Backup

If all else fails, restore from backup:

```bash
# Restore the full database backup
psql -h 195.35.23.78 -U postgres_user -d mindshare_db < mindshare_db_backup_20240101_120000.sql

# Or restore with pg_restore (if backup was in custom format)
pg_restore -h 195.35.23.78 -U postgres_user -d mindshare_db mindshare_db_backup_20240101_120000.dump
```

---

## Next Steps After Successful Migration

1. **Schedule incremental runs**: Set up a cron job to run `calculate_all_decay_scores_incremental()` daily or weekly
2. **Monitor**: Set up alerts for failed runs (query `decay_run_log` for `status='failed'`)
3. **Tune**: Monitor execution time and adjust reset_interval if needed
4. **Document**: Add notes to your runbooks about the incremental decay path

### Example Cron Job

```bash
# Run incremental decay daily at 2 AM
0 2 * * * psql postgresql://postgres_user:postgres_pass@195.35.23.78:5432/mindshare_db -c "SELECT mindshare_score.calculate_all_decay_scores_incremental();"
```

---

## Support

If you encounter issues not covered here:

1. Check the detailed planning document: `MIGRATION_INCREMENTAL_DECAY_TEST_TO_PROD.md`
2. Review `decay_run_log` for specific error messages
3. Compare test schema functions to prod (they should be identical)
4. Check PostgreSQL logs for system-level errors
