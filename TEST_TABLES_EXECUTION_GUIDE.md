# Test Tables Execution Guide

## Overview

The `MIGRATION_EXECUTE_ALL_TEST_TABLES.sql` script deploys the incremental decay logic to production data sources, but writes results to **test versions of the score tables**:

- Reads from: `mindshare`, `mindshare_user`, `user_post` (production source tables)
- Writes to: `contribution_scores_test`, `global_contribution_scores_test` (new test tables)
- Purpose: Validate incremental decay results before switching to live tables

This allows you to:
1. Run the incremental decay on real production data
2. Validate results in isolated test tables
3. Compare test vs production results
4. Switch to live tables once fully validated

---

## Quick Start

### Step 1: Execute Migration Script

```bash
# Run the test tables migration script
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -f MIGRATION_EXECUTE_ALL_TEST_TABLES.sql

# This creates:
# - contribution_scores_test table
# - global_contribution_scores_test table
# - Functions with _test suffix (e.g., calculate_decay_scores_incremental_test)
# - Indexes on test tables
```

### Step 2: Run Incremental Decay on Test Tables

```bash
# Run for a specific project
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
  "SELECT mindshare_score.calculate_decay_scores_incremental_test('default', '30 days'::interval);"

# Run for global scores
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
  "SELECT mindshare_score.calculate_global_decay_scores_incremental_test('30 days'::interval);"

# Or run all projects (if you created this procedure)
# SELECT mindshare_score.calculate_all_decay_scores_incremental_test();
```

### Step 3: Monitor Execution

```bash
# Check progress in real-time
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
  "SELECT run_id, scope, status, dirty_repliers, rows_written, updated_at 
   FROM mindshare_score.decay_run_log 
   WHERE scope LIKE '%TEST%' 
   ORDER BY run_id DESC LIMIT 5;"
```

### Step 4: Validate Results

```bash
# Compare row counts (test vs production)
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
SELECT 'Test table' as source, COUNT(*) as rows
FROM mindshare_score.contribution_scores_test
WHERE project_keyword = 'default'
UNION ALL
SELECT 'Production table', COUNT(*)
FROM mindshare_score.contribution_scores
WHERE project_keyword = 'default';
EOF

# Compare specific scores
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
  "SELECT contribution_score 
   FROM mindshare_score.contribution_scores_test 
   WHERE project_keyword = 'default' 
   ORDER BY RANDOM() LIMIT 10;"

# Compare with production
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
  "SELECT contribution_score 
   FROM mindshare_score.contribution_scores 
   WHERE project_keyword = 'default' 
   ORDER BY RANDOM() LIMIT 10;"
```

### Step 5: Switch to Production Tables (When Ready)

Once validation is complete, use the original functions:

```bash
# Switch to production tables
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
BEGIN;
-- Delete test tables to free space
TRUNCATE TABLE mindshare_score.contribution_scores_test CASCADE;
TRUNCATE TABLE mindshare_score.global_contribution_scores_test CASCADE;

-- Run on production tables
SELECT mindshare_score.calculate_decay_scores_incremental('default', '30 days'::interval);
SELECT mindshare_score.calculate_global_decay_scores_incremental('30 days'::interval);

COMMIT;
EOF
```

---

## Functions Available (Test Versions)

### Project-Scoped Incremental
```sql
SELECT mindshare_score.calculate_decay_scores_incremental_test(
    'project_keyword',      -- e.g., 'default', 'acurast'
    '30 days'::interval,    -- reset interval
    NULL,                   -- run_id (auto-generated)
    50000                   -- log_every (progress log every N rows)
);
```

### Global Incremental
```sql
SELECT mindshare_score.calculate_global_decay_scores_incremental_test(
    '30 days'::interval,
    NULL,
    50000
);
```

### Core Functions (Internal, called by entry points)
- `_decay_apply_project_test()` - Full rebuild loop
- `_decay_apply_global_test()` - Global full rebuild loop
- `_decay_apply_project_tail_test()` - Tail replay (incremental)
- `_decay_apply_global_tail_test()` - Global tail replay (incremental)

---

## Validation Checklist

After running test tables, verify:

- [ ] **First run completed**: Check `decay_run_log` for success
- [ ] **Row counts match**: Test table rows ≈ production table rows
- [ ] **Watermarks initialized**: Check `decay_run_state` for 'project:*:TEST' and 'global:TEST' scopes
- [ ] **Specific scores accurate**: Sample 10-20 rows and compare with production
- [ ] **Incremental efficiency**: Second run should process far fewer repliers than first run
- [ ] **No errors in logs**: Check `error_message` column in `decay_run_log`

### Validation Queries

```sql
-- 1. Check first run success
SELECT scope, dirty_repliers, rows_written, status
FROM mindshare_score.decay_run_log
WHERE scope LIKE '%TEST%' AND status = 'success'
ORDER BY run_id DESC LIMIT 5;

-- 2. Compare row counts per project
SELECT project_keyword,
  (SELECT COUNT(*) FROM mindshare_score.contribution_scores_test 
   WHERE project_keyword = t.project_keyword) as test_rows,
  (SELECT COUNT(*) FROM mindshare_score.contribution_scores 
   WHERE project_keyword = t.project_keyword) as prod_rows
FROM (SELECT DISTINCT project_keyword FROM mindshare_score.contribution_scores) t
ORDER BY project_keyword;

-- 3. Sample score comparison
SELECT 
  t.reply_post_id,
  t.contribution_score as test_score,
  p.contribution_score as prod_score,
  ROUND(t.contribution_score::numeric - p.contribution_score::numeric, 4) as diff
FROM mindshare_score.contribution_scores_test t
FULL OUTER JOIN mindshare_score.contribution_scores p
  ON t.reply_post_id = p.reply_post_id
WHERE t.project_keyword = 'default'
AND (t.contribution_score IS DISTINCT FROM p.contribution_score OR p.contribution_score IS NULL OR t.contribution_score IS NULL)
LIMIT 20;

-- 4. Check incremental efficiency (second run should be fast)
SELECT run_id, scope, status, dirty_repliers, rows_written,
  EXTRACT(epoch FROM (finished_at - started_at))::int as duration_sec
FROM mindshare_score.decay_run_log
WHERE scope LIKE '%TEST%'
ORDER BY run_id DESC LIMIT 5;
```

---

## Cleanup

Once you've validated and switched to production:

```bash
# Drop test tables and functions
psql -h 195.35.23.78 -U postgres_user -d mindshare_db << 'EOF'
-- Drop test functions
DROP FUNCTION IF EXISTS mindshare_score.calculate_decay_scores_incremental_test(text, interval, bigint, integer);
DROP FUNCTION IF EXISTS mindshare_score.calculate_global_decay_scores_incremental_test(interval, bigint, integer);
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_project_test(text, interval, bigint, boolean, integer);
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_global_test(interval, bigint, boolean, integer);
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_project_tail_test(text, interval, bigint, integer);
DROP FUNCTION IF EXISTS mindshare_score._decay_apply_global_tail_test(interval, bigint, integer);

-- Drop test tables
DROP TABLE IF EXISTS mindshare_score.contribution_scores_test CASCADE;
DROP TABLE IF EXISTS mindshare_score.global_contribution_scores_test CASCADE;
EOF
```

---

## Key Differences from Original Script

| Aspect | Original (MIGRATION_EXECUTE_ALL.sql) | Test Version (MIGRATION_EXECUTE_ALL_TEST_TABLES.sql) |
|--------|------|-----------|
| **Reads from** | Production source tables | Production source tables (same) |
| **Writes to** | `contribution_scores` | `contribution_scores_test` |
| **Writes to** | `global_contribution_scores` | `global_contribution_scores_test` |
| **Function names** | `calculate_decay_scores_incremental` | `calculate_decay_scores_incremental_test` |
| **Watermark scope** | `project:*` / `global` | `project:*:TEST` / `global:TEST` |
| **Purpose** | Production deployment | Validation & testing |

---

## Troubleshooting

### Issue: Test script fails during execution

**Solution**:
1. Check the error in `decay_run_log`
2. Rollback: Drop test tables and functions (see Cleanup section)
3. Re-run the script
4. Check for schema issues (tables, permissions)

### Issue: Test table row count differs from production

**Possible causes**:
- Incremental logic difference (shouldn't happen - same algorithm)
- Data changed between runs (production data is live)
- Different watermark initialization

**Solution**: 
- Run the test script first without any changes to production
- Compare the decay_run_log for errors
- Check if specific repliers have different counts

### Issue: Validation shows scores differ

**This could indicate**:
- Bug in incremental logic (worth investigating)
- Data changes during run (production is live)
- Different starting point (watermarks differ)

**Solution**:
- Sample specific rows and trace through the calculation manually
- Compare penalty_mults arrays between test and prod
- Check decay_type and decay logic in both results

---

## Next Steps

1. **Deploy test script**: Run `MIGRATION_EXECUTE_ALL_TEST_TABLES.sql`
2. **Run test executions**: Execute `calculate_decay_scores_incremental_test()` for each project
3. **Validate thoroughly**: Use validation queries above
4. **Switch to production**: Once confident, run the original functions on live tables
5. **Clean up**: Drop test tables and functions
6. **Monitor**: Watch production runs for performance and correctness

---

## Connection String

```
postgresql://postgres_user:postgres_pass@195.35.23.78:5432/mindshare_db
```

All commands use this connection by default.
