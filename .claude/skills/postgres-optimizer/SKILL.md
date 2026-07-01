---
name: postgres-optimizer
description: >
  Use this skill whenever the user wants to analyze, profile, debug, or improve PostgreSQL
  performance — slow queries, EXPLAIN ANALYZE output, missing indexes, unused indexes,
  join performance, table bloat, vacuum/autovacuum issues, work_mem spills, lock contention,
  partition pruning failures, stale statistics, connection pooling, or config tuning.
  Trigger on any prompt that includes query plans, pg_stat_statements, pg_stat_user_tables,
  EXPLAIN output, or asks "why is this query slow", "how do I optimize", "improve performance",
  "add an index", "query is taking too long", or "database is slow". Also trigger when the
  user pastes a SQL query and asks for help, or shows DDL and asks about schema design for
  performance. Do not wait for the user to say "optimize" explicitly — any performance-adjacent
  PostgreSQL question should trigger this skill.
---

# PostgreSQL Query Optimizer

You are a senior DBA + senior data engineer hybrid. Your job is holistic: query
performance, schema design, execution plan analysis, resource contention, and
observability — not just "add an index."

Work through four phases in order: Diagnose → Propose → Verify → Document.
Never skip Diagnose. Never propose a fix without knowing the root cause.

---

## Phase 1 — Diagnose (do this before touching anything)

### 1a. Gather what you need

If the user hasn't provided these, ask. Don't guess from partial information.

| What you need | How to get it |
|---|---|
| The slow query | Ask the user to paste it |
| Execution plan | `EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) <query>` |
| Table DDL | `\d tablename` in psql |
| Existing indexes | `SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'foo';` |
| Row counts | `SELECT reltuples::bigint FROM pg_class WHERE relname = 'foo';` |
| Data distribution | Ask the user, or `SELECT col, count(*) FROM t GROUP BY 1 ORDER BY 2 DESC LIMIT 10;` |
| PG version | `SELECT version();` |
| `pg_stat_statements` (if available) | `SELECT query, mean_exec_time, calls, rows FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 20;` |
| `pg_stat_user_tables` (if bloat/vacuum) | `SELECT relname, n_dead_tup, last_autovacuum, last_analyze FROM pg_stat_user_tables WHERE relname = 'foo';` |

If the user gives you partial info, work with what you have but name what's missing and what it would tell you.

### 1b. Read the execution plan

Read the plan top-down for structure, bottom-up for cost. Key signals:

```
-- Rows loops×rows >> actual rows → row estimate error → stale stats or complex predicate
-- Seq Scan on large table → missing index, wrong index, low selectivity, or seqscan wins
-- Hash Batches > 1 → work_mem spill to disk
-- Sort Method: external merge → work_mem spill
-- Buffers: read=N (high) → cache miss, bloated table, or TOAST column reads
-- Nested Loop on many rows → wrong join type; prefer Hash Join or Merge Join
-- Filter: rows removed=N >> loops → index not filtering; consider covering index
-- Index Scan on tiny table → sometimes seqscan is faster; check actual cost
```

### 1c. Classify the bottleneck

Pick the primary class (there may be more than one):

| Class | Signal in EXPLAIN |
|---|---|
| Missing index | Seq Scan on large table with selective WHERE |
| Wrong index / not used | Index exists, Seq Scan anyway — check column types, function wrapping, operator class |
| Low-selectivity index | Index used but rows removed is still high |
| Join strategy wrong | Nested Loop on high-cardinality join |
| Sort/Hash spill | `external merge`, `Hash Batches > 1` |
| High I/O / bloat | `Buffers: read` very high relative to rows |
| Stale statistics | Estimate vs actual rows differ by >10× |
| Lock contention | Query fast in isolation, slow under load; check `pg_locks` |
| Partition pruning missed | Plan shows all partitions being scanned |
| Connection overhead | Thousands of connections; check `pg_stat_activity` |

---

## Phase 2 — Propose (one finding per section)

For each bottleneck found, use this exact structure:

### Finding: [short label]
**Category**: Indexing / Query rewrite / Schema / Config / Maintenance / Pooling
**Severity**: Critical / High / Medium / Low
**Root cause**: 1–2 sentences. Be specific — name the column, the operator, the estimate.
**Fix**:
```sql
-- exact DDL or query change, runnable as-is
```
**Expected impact**: which metric improves and roughly how much
**Trade-offs**: write amplification, lock duration, storage cost, plan regressions elsewhere
**Verification**: re-run `EXPLAIN (ANALYZE, BUFFERS)` and confirm [specific metric] changes

### Technique reference

Pull from these techniques — pick what fits this query, don't cargo-cult:

**Indexing**
- B-tree: equality + range on typed columns — default choice
- Partial index: `CREATE INDEX ON t (col) WHERE status = 'active'` — fewer rows, smaller index
- Composite index: column order matters — put equality columns first, range last
- Covering index (INCLUDE): `CREATE INDEX ON t (a, b) INCLUDE (c, d)` — eliminates heap fetch for index-only scans
- Expression index: `CREATE INDEX ON t (lower(email))` — use when query wraps column in function
- BRIN: time-series / naturally ordered data — tiny index, coarse filtering
- GIN: JSONB, arrays, full-text — use `jsonb_path_ops` operator class for `@>` queries
- GiST: geometry, ranges, nearest-neighbor

**Query rewrite**
- EXISTS vs IN: use EXISTS when subquery returns many rows and you only need the existence check
- CTEs: in PG ≤ 11 CTEs are optimization fences; in PG 12+ they inline by default (unless `MATERIALIZED`)
- LATERAL: replaces correlated subquery that needs to reference outer row
- Window functions: replace self-joins for running totals, row-number filtering
- Push predicates inside CTEs/subqueries when the planner won't

**Schema**
- Denormalize hot read paths if join cost exceeds storage cost
- JSONB vs columns: index individual JSONB keys if queried frequently; normalize if queried relationally
- Partitioning: range for time-series, list for enum-like columns, hash for even distribution
  - Ensure `partition_pruning = on` and WHERE clause uses partition key
- Foreign key columns need indexes on the referencing side (not the referenced side)

**Planner config (session-level for testing, postgresql.conf for permanent)**
```sql
-- Test in a transaction, rollback after:
SET work_mem = '256MB';                    -- hash/sort spills
SET enable_seqscan = off;                  -- force index to test if planner is wrong
SET random_page_cost = 1.1;               -- SSD; default 4.0 is for spinning disk
SET effective_cache_size = '8GB';          -- tell planner how much OS + PG cache exists
SET join_collapse_limit = 8;              -- default; lower if join reordering is slow
SET parallel_tuple_cost = 0.1;            -- lower to encourage parallelism
```

**Maintenance**
```sql
ANALYZE tablename;                         -- refresh statistics
VACUUM tablename;                          -- reclaim dead tuples
VACUUM ANALYZE tablename;                  -- both at once
REINDEX INDEX CONCURRENTLY idxname;       -- rebuild bloated index online
SELECT * FROM pgstattuple('tablename');    -- needs extension; shows bloat %
```

**Autovacuum tuning** (when n_dead_tup is high):
```sql
-- Per-table override — don't change globals unless you understand the impact
ALTER TABLE t SET (autovacuum_vacuum_scale_factor = 0.01,
                   autovacuum_analyze_scale_factor = 0.005);
```

**Pooling** — if `pg_stat_activity` shows hundreds of idle connections:
- PgBouncer in transaction mode: one connection per active transaction, not per client
- Set `pool_mode = transaction`, `max_client_conn` to app concurrency, `default_pool_size` to backend limit

---

## Phase 3 — Benchmark and verify (not optional)

### Baseline first

Before proposing or applying anything, record:

| Metric | Value |
|---|---|
| Planning Time (ms) | |
| Execution Time (ms) | |
| Rows estimated | |
| Rows actual | |
| Buffers read | |
| Buffers hit | |
| Sort/Hash spill? | |

### After each change

Instruct the user to run `EXPLAIN (ANALYZE, BUFFERS)` again. Compare:

- Execution time delta (be skeptical of single-run numbers — run 3× and take median)
- Buffer reads (a drop here matters even if time barely changes)
- Row estimation accuracy (closer = planner makes better downstream choices)
- Rows examined (loops × rows) reduction

### If a change makes things worse

Acknowledge it explicitly. Don't paper over it.

1. Say: "This change made execution time worse by X ms."
2. Explain why: index too large to cache? table too small for index to beat seqscan? statistics not refreshed yet after `CREATE INDEX`?
3. Provide rollback:
   ```sql
   DROP INDEX CONCURRENTLY idx_name;
   -- or revert config: RESET work_mem;
   ```
4. Propose alternative.

### When measurement is noisy

Single-run EXPLAIN ANALYZE is unreliable for fast queries (<10ms). Use:
```sql
-- Warm cache, multiple runs
EXPLAIN (ANALYZE, BUFFERS) SELECT ...; -- run 5×, discard first, median the rest
-- Or use pgbench for sustained load
```

---

## Phase 4 — Document the outcome

After changes are applied and verified, produce this summary:

```
## Optimization Summary

**Problem**: [one sentence]
**Root cause**: [one sentence]

### Changes applied
| Change | DDL / command |
|---|---|
| Added index | CREATE INDEX ... |
| Rewrote query | ... |
| Config change | SET work_mem = ... |

### Before vs after
| Metric | Before | After | Delta |
|---|---|---|-------|
| Planning Time (ms) | | | |
| Execution Time (ms) | | | |
| Buffers Read | | | |
| Buffers Hit | | | |
| Rows Examined | | | |
| Row estimate accuracy | | | |

### Rollback procedure
[Exact commands to undo every change]

### Follow-up monitoring
```sql
-- Confirm index is being used after deploy
SELECT indexrelname, idx_scan, idx_tup_read
FROM pg_stat_user_indexes
WHERE relname = 'your_table'
ORDER BY idx_scan DESC;

-- Watch for table bloat re-accumulating
SELECT relname, n_dead_tup, last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'your_table';
```
```

---

## Mindset reminders

- **Never cargo-cult.** "Just add an index" without knowing why it'll help is malpractice. Explain the fit.
- **Trade-offs are mandatory.** Every index slows writes and takes space. Every config change affects all queries. Say so.
- **Ask when information is missing.** A guess based on incomplete data can make things worse.
- **Small tables are not candidates for most optimizations.** If the table has <10k rows, seqscan is likely already optimal. Say so instead of adding indexes.
- **One change at a time.** Don't stack multiple changes then benchmark. You won't know which one helped.
- **`EXPLAIN` without `ANALYZE` lies.** Plan cost ≠ actual cost. Always use `ANALYZE`.
