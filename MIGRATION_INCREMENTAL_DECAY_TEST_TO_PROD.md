# Migration Plan: Incremental Decay Logic from Test to Prod

## Overview
Replicate the incremental decay optimization from test schemas (`test_mindshare`, `test_analytics`, `test_mindshare_score`) to production schemas (`mindshare`, `analytics`, `mindshare_score`).

### What is Incremental Decay?
The incremental decay system only recomputes repliers whose data changed since the last successful run, instead of rebuilding the entire score table from scratch. This significantly reduces processing time and database load.

---

## Environment Summary

### Production Schemas (Target)
- `mindshare` - Core mindshare data (posts, users, etc.)
- `analytics` - Analytics views and calculations
- `mindshare_score` - Score calculation results

### Test Schemas (Source)
- `test_mindshare` - Test version of core data
- `test_analytics` - Test version of analytics
- `test_mindshare_score` - Test version with incremental decay logic implemented

### Database Connection
```
postgresql://postgres_user:postgres_pass@195.35.23.78:5432/mindshare_db
```

---

## Step-by-Step Migration Process

### Phase 1: Validate Pre-Migration State (NO CHANGES)
**Duration**: ~5-10 minutes
**Actions**:
1. Backup production database
2. Verify current state of prod schemas
3. Document current table structures and functions
4. Check for any ongoing decay runs

**Commands to Run**:
```bash
# Backup database
pg_dump -h 195.35.23.78 -U postgres_user -d mindshare_db > mindshare_db_backup_$(date +%Y%m%d_%H%M%S).sql

# Check current contribution_scores table size
psql postgresql://postgres_user:postgres_pass@195.35.23.78:5432/mindshare_db -c \
  "SELECT COUNT(*) FROM mindshare_score.contribution_scores;"
```

### Phase 2: Create Support Infrastructure (Non-Breaking)
**Duration**: ~2-3 minutes
**Actions**:
1. Ensure dblink extension is enabled
2. Create sequence for run IDs (if not exists)
3. Create decay_run_state table
4. Create decay_run_log table
5. Create logging function

**SQL File to Execute**: `01_setup_infrastructure.sql`

**What Gets Created**:
- `mindshare_score.decay_run_id_seq` - Sequence for unique run IDs
- `mindshare_score.decay_run_state` - Watermark tracking per scope
- `mindshare_score.decay_run_log` - Run execution logs
- `mindshare_score._decay_log()` - Autonomous logging function
- `mindshare_score.next_decay_run_id()` - Helper to mint run IDs

### Phase 3: Create Indexes and State Management (Non-Breaking)
**Duration**: ~3-5 minutes
**Actions**:
1. Create expression indexes on source tables for dirty detection
2. Tune autovacuum on score tables
3. Analyze tables for statistics

**SQL File to Execute**: `02_create_indexes_and_state.sql`

**Indexes Created**:
- `ix_tmp_mp_ingest` on `mindshare.mindshare_post(GREATEST(created_at, updated_at))`
- `ix_tmp_up_ingest` on `mindshare.user_post(GREATEST(created_at, updated_at))`
- `ix_tmp_mu_ingest` on `mindshare.mindshare_user(GREATEST(created_at, updated_at))`
- `ix_tmp_mp_replied_post_id` on `mindshare.mindshare_post(replied_post_id)`

### Phase 4: Create Core Decay Functions (Non-Breaking)
**Duration**: ~2 minutes
**Actions**:
1. Create `_decay_apply_project()` function (full project-scoped replay)
2. Create `_decay_apply_global()` function (full global replay)

**SQL File to Execute**: `03_create_core_decay_functions.sql`

**Notes**:
- These are copied from test schema, adapted to use `mindshare_score` namespace
- These functions already exist in prod but are being re-created for consistency
- They are the foundation for both full and incremental paths

### Phase 5: Create Tail Core Functions for Incremental Path (Non-Breaking)
**Duration**: ~2 minutes
**Actions**:
1. Create `_decay_apply_project_tail()` function
2. Create `_decay_apply_global_tail()` function

**SQL File to Execute**: `04_create_tail_core_functions.sql`

**What They Do**:
- Replay only the "tail" (rows >= t_min) for dirty repliers
- Much faster than full replay for recent appends
- Seeds penalty window from stored rows before t_min

### Phase 6: Deploy Incremental Entry Points (Non-Breaking)
**Duration**: ~1-2 minutes
**Actions**:
1. Create `calculate_decay_scores_incremental()` function for project-scoped scores
2. Create `calculate_global_decay_scores_incremental()` function for global scores
3. Create `calculate_all_decay_scores_incremental()` procedure to call both

**SQL File to Execute**: `05_create_incremental_functions.sql`

**Key Functions**:
- `calculate_decay_scores_incremental(project_keyword, reset_interval, run_id, log_every)`
- `calculate_global_decay_scores_incremental(reset_interval, run_id, log_every)`
- `calculate_all_decay_scores_incremental()` - Calls both in sequence

### Phase 7: First Run - Initialize Watermarks (Breaking Point)
**Duration**: ~5-30 minutes (depends on data volume)
**Actions**:
1. Run incremental decay on all projects
2. Initialize watermarks in `decay_run_state`
3. Verify success via `decay_run_log`

**Command to Execute**:
```sql
-- Mint a run ID
SELECT mindshare_score.next_decay_run_id() as run_id;

-- Run for a specific project (e.g., 'default')
-- First run will be full build (all repliers marked dirty)
SELECT mindshare_score.calculate_decay_scores_incremental('default', '30 days'::interval);

-- Or run all projects and global:
SELECT mindshare_score.calculate_all_decay_scores_incremental();

-- Check status
SELECT run_id, scope, project_keyword, status, phase, message, rows_processed, updated_at
FROM mindshare_score.decay_run_log
ORDER BY run_id DESC LIMIT 5;
```

**Expected Result**:
- First run processes ALL repliers (no watermark yet)
- `decay_run_state` table gets populated with watermarks
- `decay_run_log` shows 'success'

### Phase 8: Subsequent Runs - Incremental Path (Ongoing)
**Duration**: ~1-5 minutes (much faster than full rebuild)
**Actions**:
1. Schedule incremental decay to run periodically
2. Only changed repliers are recomputed
3. Watermarks advance automatically on success

**Command to Execute**:
```sql
-- Run incremental decay (only changed repliers)
SELECT mindshare_score.calculate_all_decay_scores_incremental();

-- Check which repliers were dirty
SELECT run_id, scope, project_keyword, dirty_repliers, rows_written, updated_at
FROM mindshare_score.decay_run_log
WHERE status = 'success'
ORDER BY run_id DESC LIMIT 5;
```

**Expected Result**:
- Only repliers with changes since last watermark are recomputed
- Much faster than first run
- Watermarks advance to new ingest timestamp

---

## Key Components Deployed

### Tables
1. **decay_run_state** - Watermark tracking (last_ingest_ts, last_user_ingest_ts per scope)
2. **decay_run_log** - Execution log with progress and error details
3. **contribution_scores** - Existing; gets incremental updates
4. **global_contribution_scores** - Existing; gets incremental updates

### Functions
#### Infrastructure
- `_decay_log()` - Autonomous logging (survives on failures)
- `next_decay_run_id()` - Mint run IDs

#### Core Calculation
- `_decay_apply_project()` - Full project-scoped replay
- `_decay_apply_global()` - Full global replay

#### Incremental Calculation
- `_decay_apply_project_tail()` - Tail-from-t_min replay for project scope
- `_decay_apply_global_tail()` - Tail-from-t_min replay for global scope

#### Entry Points
- `calculate_decay_scores_incremental()` - Incremental project-scoped
- `calculate_global_decay_scores_incremental()` - Incremental global
- `calculate_all_decay_scores_incremental()` - Orchestrate both

---

## Dirty Detection Logic

The incremental path identifies "dirty" repliers (those that changed) via three branches:

1. **Changed Replies**: Posts a replier created/updated since last_ingest_ts
   - Detected via: `ix_tmp_mp_ingest` on mindshare_post
   
2. **Parent Late**: Replies whose parent post was created/updated since last_ingest_ts
   - Detected via: Join on replied_post_id with changed posts
   - Handles cases where a parent is updated after replies
   
3. **Base-Score Drift**: Repliers whose mindshare_user.score changed since last_user_ingest_ts
   - Detected via: `ix_tmp_mu_ingest` on mindshare_user
   - Tracks separately from post ingest (user score is global)

Each dirty replier's **tail** (post_created_at >= t_min) is replayed from the earliest changed reply.

---

## Rollback Plan

If incremental decay causes issues:

```sql
-- Option 1: Revert to full rebuild
-- (drop incremental functions, keep support tables)
DROP FUNCTION IF EXISTS mindshare_score.calculate_decay_scores_incremental(text, interval, bigint, integer);
DROP FUNCTION IF EXISTS mindshare_score.calculate_global_decay_scores_incremental(interval, bigint, integer);
DROP FUNCTION IF EXISTS mindshare_score.calculate_all_decay_scores_incremental();
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_project_tail(text, interval, bigint, integer);
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_global_tail(interval, bigint, integer);

-- Then run the old full-rebuild functions
SELECT mindshare_score.calculate_all_decay_scores();

-- Option 2: Complete rollback to pre-migration state
-- Restore from backup
pg_restore -h 195.35.23.78 -U postgres_user -d mindshare_db mindshare_db_backup_<timestamp>.sql
```

---

## Monitoring & Validation

### Check Incremental Execution
```sql
-- Recent decay runs
SELECT run_id, scope, project_keyword, status, dirty_repliers, rows_written, 
       started_at, finished_at, EXTRACT(epoch FROM (finished_at - started_at)) as duration_sec
FROM mindshare_score.decay_run_log
ORDER BY run_id DESC LIMIT 10;

-- Detect failures
SELECT run_id, scope, project_keyword, error_message, error_detail
FROM mindshare_score.decay_run_log
WHERE status = 'failed'
ORDER BY run_id DESC LIMIT 5;

-- Verify watermarks advanced
SELECT scope, last_ingest_ts, last_user_ingest_ts, last_run_at, dirty_repliers
FROM mindshare_score.decay_run_state
ORDER BY last_run_at DESC;
```

### Compare Results
```sql
-- Check contribution_scores row counts over time
SELECT COUNT(*) FROM mindshare_score.contribution_scores;

-- Verify specific project scores
SELECT project_keyword, COUNT(*) as row_count, 
       MIN(post_created_at) as earliest, MAX(post_created_at) as latest
FROM mindshare_score.contribution_scores
GROUP BY project_keyword
ORDER BY row_count DESC;
```

### Performance Benchmarking
```sql
-- Compare first run (full) vs subsequent runs (incremental)
SELECT 
    status,
    COUNT(*) as run_count,
    AVG(EXTRACT(epoch FROM (finished_at - started_at))) as avg_duration_sec,
    MAX(EXTRACT(epoch FROM (finished_at - started_at))) as max_duration_sec,
    AVG(dirty_repliers) as avg_dirty,
    AVG(rows_written) as avg_rows_written
FROM mindshare_score.decay_run_log
WHERE scope = 'project:default'
GROUP BY status
ORDER BY status;
```

---

## Execution Timeline

| Phase | Duration | Risk | Actions |
|-------|----------|------|---------|
| Phase 1: Validate | 5-10 min | Low | Backup, verify state |
| Phase 2: Infrastructure | 2-3 min | Low | Create tables/sequences |
| Phase 3: Indexes | 3-5 min | Low | Create indexes, analyze |
| Phase 4: Core Functions | 2 min | Low | Deploy calculation cores |
| Phase 5: Tail Cores | 2 min | Low | Deploy incremental cores |
| Phase 6: Entry Points | 1-2 min | Low | Deploy main functions |
| Phase 7: First Run | 5-30 min | **MEDIUM** | Initialize (full rebuild) |
| Phase 8: Ongoing | 1-5 min | Low | Incremental runs |

**Total Expected Time**: 20-60 minutes (depending on data volume in Phase 7)

---

## Testing Recommendations

### Before Production
1. Run on test schemas to validate logic
2. Compare results between test and prod (select sample rows)
3. Monitor performance metrics (execution time, dirty replier count)

### During Migration
1. Run Phase 7 (first run) during low-traffic window
2. Monitor `decay_run_log` for failures
3. Verify `contribution_scores` row counts match expectations

### Post-Migration
1. Schedule incremental runs periodically (e.g., daily)
2. Set up alerts for failed runs
3. Monitor execution time trends (should be much faster than full rebuild)

---

## Important Notes

1. **Watermarks are the key**: Once initialized, they drive dirty detection. Ensure Phase 7 completes successfully.

2. **dblink credentials**: The `_decay_log()` function uses a hardcoded loopback connection. In production, consider moving credentials to a dblink FOREIGN SERVER.

3. **Transaction semantics**: Failures during the main transaction roll back watermark advances, so re-running picks up where it left off.

4. **Index on GREATEST()**: The dirty detection relies on expression indexes. Ensure `ANALYZE` runs after creation.

5. **autovacuum tuning**: `decay_run_state` is tiny (one row per scope). The score tables are tuned for aggressive vacuuming due to incremental DELETE+INSERT churn.

---

## Files Needed

The following SQL scripts will be created:
- `01_setup_infrastructure.sql` - Tables, sequences, logging
- `02_create_indexes_and_state.sql` - Indexes and autovacuum tuning
- `03_create_core_decay_functions.sql` - Full rebuild cores
- `04_create_tail_core_functions.sql` - Incremental tail replay
- `05_create_incremental_functions.sql` - Incremental entry points
- `MIGRATION_EXECUTE_ALL.sql` - Master script to run all phases

Run them in order, or use `MIGRATION_EXECUTE_ALL.sql` to execute the entire migration in one go.
