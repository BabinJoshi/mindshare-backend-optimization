# Choose Your Path: Production vs Test Tables

You now have TWO options for migrating incremental decay. Choose based on your confidence and validation needs.

---

## 🎯 Path 1: Direct to Production (FAST)

**Use this if**: You trust the test schema implementation and want to deploy quickly.

### What you get:
- Writes directly to: `contribution_scores`, `global_contribution_scores`
- No separate validation step needed
- Functions: `calculate_decay_scores_incremental()`, `calculate_global_decay_scores_incremental()`

### Files you need:
- `MIGRATION_EXECUTE_ALL.sql` ⭐ (41 KB)
- `EXECUTION_GUIDE.md` (reference)
- `MIGRATION_SUMMARY.md` (reference)

### Quick execution:
```bash
# 1. Backup
pg_dump -h 195.35.23.78 -U postgres_user -d mindshare_db | gzip > backup.sql.gz

# 2. Migrate
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -f MIGRATION_EXECUTE_ALL.sql

# 3. Initialize (during low-traffic window)
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
  "SELECT mindshare_score.calculate_all_decay_scores_incremental();"
```

### Timeline:
- Setup: 5-10 minutes
- First run (full): 5-30 minutes
- Subsequent runs: 1-5 minutes

### Risk Level: ⚠️ **MEDIUM**
- No validation step before writing to production
- But logic is identical to test schema (which you can verify first)

### Best for:
- Dev/staging environments
- Teams with high confidence in test schema
- Quick deployment needed

---

## 🧪 Path 2: Validate with Test Tables (SAFE)

**Use this if**: You want to validate results before writing to production tables.

### What you get:
- Writes to: `contribution_scores_test`, `global_contribution_scores_test` (temporary)
- Run incremental decay on production data
- Validate results in isolation
- Switch to production tables once confident
- Functions: `calculate_decay_scores_incremental_test()`, `calculate_global_decay_scores_incremental_test()`

### Files you need:
- `MIGRATION_EXECUTE_ALL_TEST_TABLES.sql` ⭐ (43 KB)
- `TEST_TABLES_EXECUTION_GUIDE.md` (reference)
- `MIGRATION_SUMMARY.md` (reference)

### Execution (3-phase):
```bash
# Phase 1: Deploy migration (5-10 min)
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -f MIGRATION_EXECUTE_ALL_TEST_TABLES.sql

# Phase 2: Run on test tables (5-30 min, during low-traffic)
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
  "SELECT mindshare_score.calculate_decay_scores_incremental_test('default', '30 days'::interval);"
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
  "SELECT mindshare_score.calculate_global_decay_scores_incremental_test('30 days'::interval);"

# Phase 3: Validate & compare (5-10 min)
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
  "SELECT COUNT(*) FROM mindshare_score.contribution_scores_test WHERE project_keyword='default';"
# Compare with production counts

# Phase 4: Switch to production (when ready)
psql -h 195.35.23.78 -U postgres_user -d mindshare_db -c \
  "SELECT mindshare_score.calculate_decay_scores_incremental('default', '30 days'::interval);"
```

### Timeline:
- Phase 1 Setup: 5-10 minutes
- Phase 2 Test run: 5-30 minutes
- Phase 3 Validation: 5-10 minutes
- Phase 4 Production: 5-30 minutes
- **TOTAL: 20-80 minutes**

### Risk Level: ✅ **LOW**
- Production tables untouched until you say so
- Can compare test vs production side-by-side
- Full rollback available (just drop test tables)
- Validation step prevents surprises

### Best for:
- Production deployments
- Teams wanting to validate before going live
- Data-sensitive environments
- Peace of mind

---

## 📊 Comparison Table

| Aspect | Path 1: Production | Path 2: Test Tables |
|--------|---------|-----------|
| **Target tables** | contribution_scores (live) | contribution_scores_test (sandbox) |
| **Risk level** | Medium | Low |
| **Validation step** | No | Yes |
| **Rollback if issues** | Restore from backup | Drop test tables |
| **Time to go live** | 20-40 min | 20-80 min |
| **Confidence needed** | High | Medium |
| **Best for** | Dev/staging | Production |
| **Migration files** | MIGRATION_EXECUTE_ALL.sql | MIGRATION_EXECUTE_ALL_TEST_TABLES.sql |

---

## 🤔 Decision Matrix

Choose **Path 1** if:
- ✅ You've validated logic in test schemas thoroughly
- ✅ You have a fast rollback plan
- ✅ Your team trusts the implementation
- ✅ Deployment speed is critical
- ✅ You can run backup/restore quickly if needed

Choose **Path 2** if:
- ✅ This is a production system
- ✅ You want side-by-side comparison before going live
- ✅ You prefer gradual confidence building
- ✅ Data accuracy is mission-critical
- ✅ You have time for validation
- ✅ You want minimal risk

---

## 🎬 Step-by-Step Recommended Path

### For Production (Recommended)

```
1. Review MIGRATION_SUMMARY.md (5 min)
   ↓
2. Run Path 2 (test tables) (60-80 min)
   - Deploy test migration script
   - Run incremental on test tables
   - Validate results match production expectations
   - Run a second time to verify incremental efficiency
   ↓
3. Deploy Path 1 (production) (10-15 min)
   - Run MIGRATION_EXECUTE_ALL.sql
   - Verify infrastructure
   ↓
4. Switch on (5-30 min, low-traffic window)
   - Run first incremental on production tables
   - Monitor execution
   - Verify watermarks advanced
   ↓
5. Schedule recurring runs (5 min)
   - Set up cron job for daily/weekly execution
   - Set up monitoring for failures
```

### For Dev/Staging (Quick Path)

```
1. Review MIGRATION_SUMMARY.md (5 min)
   ↓
2. Run Path 1 (production) directly (10-15 min)
   - Execute MIGRATION_EXECUTE_ALL.sql
   ↓
3. Initialize (5-30 min)
   - Run calculate_all_decay_scores_incremental()
   - Verify success
   ↓
4. Done! (0 min)
   - No extra validation needed
```

---

## 📋 Quick Reference

### Path 1 Files
```
├── MIGRATION_EXECUTE_ALL.sql          (Main script - run this)
├── EXECUTION_GUIDE.md                 (Step-by-step instructions)
└── MIGRATION_SUMMARY.md               (Reference/understanding)
```

### Path 2 Files
```
├── MIGRATION_EXECUTE_ALL_TEST_TABLES.sql    (Main script - run this)
├── TEST_TABLES_EXECUTION_GUIDE.md           (Step-by-step instructions)
└── MIGRATION_SUMMARY.md                     (Reference/understanding)
```

---

## ⚡ Validation Queries

### Check if production is ready
```sql
-- Only works AFTER you run Path 1
SELECT COUNT(*) as current_rows FROM mindshare_score.contribution_scores;
SELECT COUNT(*) as current_rows FROM mindshare_score.global_contribution_scores;
```

### Check if test table validation passed
```sql
-- Only works AFTER you run Path 2
SELECT COUNT(*) as test_rows FROM mindshare_score.contribution_scores_test;
SELECT COUNT(*) as prod_rows FROM mindshare_score.contribution_scores;
-- Compare the two counts
```

---

## 🔄 Can You Do Both?

**Yes!** In fact, the recommended approach for production is:

1. Run **Path 2** first (test tables)
2. Validate thoroughly
3. Clean up test tables
4. Run **Path 1** (production)
5. Initialize production tables
6. Monitor and verify

This gives you maximum confidence with minimal risk.

---

## 💡 Pro Tips

### Tip 1: Run Path 2 first even if deploying Path 1
```bash
# 1. Test with Path 2 (in dev environment or using test tables)
psql ... -f MIGRATION_EXECUTE_ALL_TEST_TABLES.sql

# 2. Validate thoroughly
# (run validation queries, compare results)

# 3. Drop test tables when satisfied
# (or keep for reference)

# 4. Deploy Path 1 to production
psql ... -f MIGRATION_EXECUTE_ALL.sql
```

### Tip 2: Schedule recurring runs after initialization
```bash
# Add to crontab for daily execution (after first run)
0 2 * * * psql postgresql://postgres_user:postgres_pass@195.35.23.78:5432/mindshare_db -c "SELECT mindshare_score.calculate_all_decay_scores_incremental();"
```

### Tip 3: Monitor execution time
```sql
-- After a few runs, check efficiency
SELECT 
    CASE WHEN dirty_repliers IS NULL THEN 'Full' ELSE 'Incremental' END as type,
    COUNT(*) as runs,
    AVG(EXTRACT(epoch FROM (finished_at - started_at)))::int as avg_seconds
FROM mindshare_score.decay_run_log
WHERE status = 'success'
GROUP BY type;
```

---

## ✅ Final Checklist

Before you start, verify:
- [ ] Database backed up
- [ ] Scheduled maintenance window (if needed)
- [ ] Have access to psql
- [ ] Know which path you're taking
- [ ] Have read the relevant guide (EXECUTION_GUIDE.md or TEST_TABLES_EXECUTION_GUIDE.md)

Before you switch to production (Path 1 or after Path 2):
- [ ] Verified infrastructure created successfully
- [ ] Validated first run completed
- [ ] Checked watermarks advanced
- [ ] Confirmed row counts reasonable

---

## 🚀 Ready?

- **Choose Path 1**: Start with `MIGRATION_EXECUTE_ALL.sql` → `EXECUTION_GUIDE.md`
- **Choose Path 2**: Start with `MIGRATION_EXECUTE_ALL_TEST_TABLES.sql` → `TEST_TABLES_EXECUTION_GUIDE.md`

Both paths use identical logic. Path 2 is just safer because you validate first.

Good luck! 🎉
