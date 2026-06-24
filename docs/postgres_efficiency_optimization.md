# PostgreSQL Efficiency Optimization (Measured)

This document is a **measured, prioritized optimization plan** for the
PostgreSQL side of Mindshare. Unlike
[postgres_performance_improvements.md](postgres_performance_improvements.md)
(which is a catalog of recommendations derived from reading the SQL), every
finding here was reproduced against the **live `mindshare_db` database** and is
backed by an actual `EXPLAIN (ANALYZE, BUFFERS)` plan or `pg_catalog`/`pg_stat_*`
reading.

- **Measured on:** 2026-06-21, against `mindshare_db` @ `195.35.23.78:5432`
  (PostgreSQL 16.11, Debian).
- **Method:** read-only inspection + `EXPLAIN (ANALYZE, BUFFERS)` on the three
  hottest paths (project decay source read, global decay source read, leaderboard
  / global analytics functions). No schema or data was modified.
- **Scope:** source tables, the decay source reads (the live Polars path),
  analytics/feature materialized views, and the leaderboard/analytics functions.

> Cross-reference: object inventory and dependency graph live in
> [database_object_dependencies.md](database_object_dependencies.md). Index
> recommendations that still stand from the earlier pass are referenced rather
> than repeated.

---

## Executive Summary — ranked by (impact ÷ effort)

| # | Finding | Measured impact | Effort | Risk |
|---|---|---|---|---|
| 1 | **Redundant `is_reply = true` filter blocks the covering index** on both decay source reads | Project read **9.3 s → 0.67 s** (~14×); global read **21.7 s → 0.95 s** (~23×) | 1-line code change ×2 | Very low (semantically identical predicate) |
| 2 | **Server runs on stock PostgreSQL defaults** (`shared_buffers` 128 MB, `work_mem` 4 MB, `random_page_cost` 4) on a multi-GB DB | Affects every sort, hash, refresh, and index decision DB-wide | Config + reload | Low |
| 3 | **`get_all_users_analytics()` runs in 52.6 s** — OR-join self-join + repeated dedup sub-aggregates | One dashboard call = 52 s | Function rewrite (or scheduled matview) | Medium |
| 4 | **`get_mindshare_leaderboard` is ambiguously overloaded** — a 3-arg call **errors** (`AmbiguousFunction`) | API path can be broken outright | Drop/rename one overload | Low–medium (API contract) |
| 5 | **~30+ indexes with `idx_scan = 0`**, incl. a 286 MB one made unused by finding #1 and the `test_*` table indexes | Wasted disk + write/refresh overhead | Drop after confirming | Low (verify first) |
| 6 | **Composite `DISTINCT ON` indexes never applied to production score tables** | Sort/scan pressure on leaderboards as data grows | `CREATE INDEX CONCURRENTLY` | Low |
| 7 | **Stale planner stats on big matviews + a 36-billion-row join misestimate** | Risk of bad plans | `ANALYZE` + raise stats target | Low |

Findings #1–#2 are the headline: a one-line predicate change and a config pass
together remove tens of seconds from the hottest jobs at almost no risk.

---

## Environment snapshot (the numbers everything else is judged against)

Current server settings (all at PostgreSQL stock defaults):

| Setting | Current | Note |
|---|---|---|
| `shared_buffers` | **128 MB** (`16384` × 8 kB) | Default. DB working set is multi-GB. |
| `work_mem` | **4 MB** | Default. Forces external (on-disk) sorts/hashes. |
| `maintenance_work_mem` | **64 MB** | Default. Slows index builds / `VACUUM`. |
| `effective_cache_size` | **4 GB** | Default. Planner's cache assumption. |
| `random_page_cost` | **4** | Default (spinning-disk assumption). |
| `max_parallel_workers_per_gather` | **2** | Default. |
| `default_statistics_target` | **100** | Default. |
| Installed extensions | **`plpgsql` only** | No `pg_stat_statements` → no query-level telemetry. |

Largest objects (heap + indexes):

| Object | Total size | Est. rows |
|---|---|---|
| `mindshare.nucleus_post_general` | 2968 MB | 5.85 M |
| `mindshare.user_post` | 2627 MB | 3.47 M |
| `mindshare.mindshare_post_quipnetwork` (partition) | 1888 MB | 2.84 M |
| `mindshare_score.global_contribution_scores` | 1428 MB | 2.11 M |
| `test_mindshare_score.test_contribution_scores` | 1305 MB | 4.81 M |
| `mindshare_score.contribution_scores` | 1231 MB | 1.94 M |
| `analytics.mv_engagement_quipnetwork` | 384 MB | 1.99 M |
| `analytics.mv_user_posts_engagement` | 382 MB | 2.26 M |

`mindshare.mindshare_post` is **LIST-partitioned by `project_keyword`** (12
partitions). All five expected parent indexes are **valid and attached to all 12
partitions** (verified via `pg_index` / `pg_inherits`) — so index *presence* is
healthy; the problems below are about whether queries can *use* them.

---

## Finding 1 — Drop the redundant `is_reply = true` from decay source reads ⭐

**This is the single highest-value, lowest-risk change in this document.**

Both decay source queries in the live Polars path filter on **both**
`is_reply = true` **and** `replied_post_id IS NOT NULL`. But `is_reply` is a
`GENERATED ALWAYS AS (replied_post_id IS NOT NULL) STORED` column — the two
predicates are *logically identical*.

The cost is not cosmetic. The covering partial index
(`… INCLUDE (post_id, replied_post_id) WHERE replied_post_id IS NOT NULL`) can
satisfy the query with an **Index-Only Scan** — but only if every referenced
column is in the index. `is_reply` is **not** stored in the index, so adding it
to `WHERE` forces PostgreSQL to visit the heap for **every** candidate row,
collapsing the Index-Only Scan into a plain Index Scan.

### Measured — project (`mindshare_post`, quipnetwork partition, 2.70 M reply rows)

```text
WITH  is_reply = true   → Index Scan      … Execution Time:  9312 ms
WITHOUT is_reply        → Index Only Scan … Heap Fetches: 3351 … 665 ms
```

≈ **14× faster** (9.3 s → 0.67 s) on the scan that dominates the project decay
read. (The full join query measured 45 s end-to-end; this is its largest
component.)

### Measured — global (`user_post`, 3.19 M reply rows)

```text
WITH  is_reply = true   → Index Scan on idx_user_post_user_x_id_time … 21740 ms
WITHOUT is_reply        → Index Only Scan on ix_user_post_decay_source_order
                          … Heap Fetches: 0 … 952 ms
```

≈ **23× faster** (21.7 s → 0.95 s). Note the planner with `is_reply = true`
doesn't even *pick* the purpose-built partial index — it falls back to the full
`user_x_id_time` index. **This is why `ix_user_post_decay_source_order` (286 MB)
shows `idx_scan = 0`** in `pg_stat_user_indexes`: the current predicate makes the
index the pipeline was built around unusable. One predicate change fixes the slow
read *and* activates a 286 MB index that is currently dead weight.

### Fix

In [mindshare_compute/db.py](../mindshare_compute/db.py), `iter_decay_source`,
change the project branch ([db.py:119](../mindshare_compute/db.py#L119)) and the
global branch ([db.py:135](../mindshare_compute/db.py#L135)):

```diff
- WHERE p.is_reply = true AND p.replied_post_id IS NOT NULL
+ WHERE p.replied_post_id IS NOT NULL
```

The result set is byte-for-byte identical (the predicates are equivalent), so no
numeric-parity risk to the Polars output. Apply the same change to the legacy
`calculate_*decay_scores` SQL functions if they are ever run.

Validate after the change:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT user_x_id, post_created_at, post_id, replied_post_id
FROM mindshare.user_post
WHERE replied_post_id IS NOT NULL
ORDER BY user_x_id, post_created_at;   -- expect "Index Only Scan", low Heap Fetches
```

---

## Finding 2 — The server is running on stock defaults

Every memory and cost setting is at the PostgreSQL out-of-the-box default
(table above). For a database whose hot objects are 1–3 GB each, this is the most
pervasive bottleneck after Finding 1.

Consequences observed:

- **`work_mem = 4 MB`** → large sorts/hashes spill to disk. The project decay
  read sorts ~2.7 M rows; the global analytics function sorts/aggregates millions
  of engagement rows; matview refresh builds millions of rows. All of these are
  paying external-merge-sort I/O.
- **`shared_buffers = 128 MB`** vs multi-GB working set → the reply→original
  lookup in the decay join did **10.1 M shared buffer hits + 1.24 M reads**
  for a single project; almost nothing stays cached between calls.
- **`random_page_cost = 4`** assumes spinning disk. On SSD/NVMe (typical for a
  VPS) this over-penalizes index scans and biases the planner toward seq scans.

### Recommended starting values

Set relative to actual RAM (unknown from SQL — confirm on the host with
`free -h`). `effective_cache_size = 4 GB` *hints* the box is ~4–8 GB; tune to
real memory. Conservative starting points:

For an **8 GB** box:
```conf
shared_buffers = 2GB                # ~25% RAM
effective_cache_size = 6GB          # ~75% RAM
work_mem = 32MB                     # per sort/hash node; raise carefully
maintenance_work_mem = 512MB        # faster CREATE INDEX / VACUUM
random_page_cost = 1.1             # SSD/NVMe
effective_io_concurrency = 200      # SSD/NVMe
max_parallel_workers_per_gather = 4
default_statistics_target = 200     # better estimates on skewed join keys
```

For a **16 GB** box: `shared_buffers = 4GB`, `effective_cache_size = 12GB`,
`work_mem = 64MB`.

`work_mem` is **per node per connection** — multiply by concurrent queries ×
sort/hash nodes before going aggressive. The decay pipeline and refreshes are the
big sorters; if connection count is low you can afford a higher `work_mem` (or
`SET work_mem` locally for those sessions/the refresh procedures rather than
globally).

`shared_buffers` and `max_parallel_workers_per_gather` need a **restart**; the
rest take a reload (`SELECT pg_reload_conf();`). Change one group, re-measure with
the queries in this doc, iterate.

### Install `pg_stat_statements`

There is currently **no query-level telemetry**. Without it, "which query is
slow" is guesswork. Add to `postgresql.conf` and restart:

```conf
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.max = 5000
pg_stat_statements.track = top
```
```sql
CREATE EXTENSION pg_stat_statements;
-- then, after a representative day:
SELECT calls, round(mean_exec_time) ms, round(total_exec_time) total_ms,
       left(query,120) FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 25;
```

This turns the next optimization pass from anecdote into data.

### JIT note

The project decay read plan spent ~288 ms in JIT (`Inlining`, `Optimization`,
`Emission`) on top of execution. For the short, high-frequency API function calls
JIT can cost more than it saves. Once Finding 1 lands and queries get cheap,
consider raising `jit_above_cost` / `jit_optimize_above_cost`, or `SET jit = off`
for the API function sessions, and compare.

---

## Finding 3 — `get_all_users_analytics()` takes 52.6 s

Measured: `SELECT * FROM analytics.get_all_users_analytics()` → **52,635 ms**,
2012 rows. This is a global dashboard function; 52 s per call is a UX problem and
a connection-hog. Three compounding causes:

1. **OR-join self-join.** `incoming_engagements` joins `user_post` to target
   posts on `(mp.replied_post_id = tp.post_id OR mp.quoted_post_id = tp.post_id)`.
   `EXPLAIN` confirms a `BitmapOr` over two indexes feeding a nested loop over a
   **Parallel Seq Scan** of `user_post`. Split into `UNION ALL` (replies branch
   + quotes branch) so each side is a clean indexed join — the pattern the
   engagement matviews already use.

2. **Repeated identical sub-aggregates.** This exact subquery —
   ```sql
   SELECT author_id, engaged_user_id, MAX(COALESCE(engaged_user_score,0))
   FROM incoming_engagements WHERE NOT is_self_reply
   GROUP BY author_id, engaged_user_id
   ```
   is written **twice** verbatim (in `unique_reach_agg` and
   `unique_engager_stats`), plus a per-post variant in `post_reach_agg`. Factor
   the per-`(author, engager)` max into **one** CTE and join it three ways.
   (`incoming_engagements` itself is referenced multiple times, so PG 12+ already
   materializes it once — but these inline subqueries are recomputed.)

3. **`work_mem`-bound aggregation + `percentile_cont`** over millions of rows
   spills to disk under the current 4 MB. Finding 2 helps directly.

### Recommendation

Short term: rewrite (OR→`UNION ALL`, dedup the shared sub-aggregate) and re-time.
Medium term: because this is "all users, no time bound," it is an ideal
**scheduled materialized view** — refresh it right after
`mv_user_posts_engagement_features` and `global_contribution_scores` are
refreshed, and keep the live function only for the parameterized
`limit_per_user` path. The earlier perf doc reaches the same conclusion; the
52 s measurement is the justification to actually do it.

---

## Finding 4 — `get_mindshare_leaderboard` is ambiguously overloaded

`pg_proc` shows **two** functions named
`mindshare_score.get_mindshare_leaderboard`:

```text
(startdate bigint, enddate bigint, projectname text)
(startdate bigint, enddate bigint, projectname text,
 p_private_user_list text[], p_exclude_list text[], p_limit integer,
 p_target_username text)
```

The 7-arg version has **defaults** on the trailing params, so a 3-argument call
matches **both** and PostgreSQL refuses it:

```text
ERROR: function mindshare_score.get_mindshare_leaderboard(bigint, bigint, unknown)
       is not unique
```

This reproduced even with explicit `::bigint` casts. Any caller using the 3-arg
form is broken unless it always supplies all 7 args. Decide which signature is
the contract and **drop or rename the other** (e.g. keep the 7-arg as
`get_mindshare_leaderboard_v2`, or remove the defaults from the 7-arg version so
the arities are unambiguous). This is a correctness item that also blocks
benchmarking the leaderboard path.

(Related reliability items already documented and still open: the
`get_unique_reach_increase` view-name normalization bug and the global metric
functions reading the **project** `contribution_scores` — see
[postgres_performance_improvements.md](postgres_performance_improvements.md#reliability-issues-worth-fixing-alongside-performance).)

---

## Finding 5 — Unused indexes (drop after confirmation)

`pg_stat_user_indexes` shows **`idx_scan = 0`** for many indexes. Caveat: these
counters reset on stats reset / failover, so confirm over a representative window
(ideally after `pg_stat_statements` is in place) before dropping. Strong
candidates:

| Index | Size | Why it's a candidate |
|---|---|---|
| `mindshare.user_post.ix_user_post_decay_source_order` | 286 MB | **Keep** — currently 0 scans *only because of Finding 1*; it becomes the hot path once `is_reply` is removed. Re-check after that change. |
| `test_mindshare_score.test_*` indexes (reply_post_id, post_created, original_post_id, keyword_author, original_author, …) | ~600 MB total | The API reads **production** `contribution_scores` / `global_contribution_scores`, not the Polars `test_*` tables. In a dev/test DB these indexes are pure write/refresh overhead. Drop unless something queries `test_*`. |
| `analytics.mv_engagement_<project>` `…_user` (engaged_user_id) indexes | ~50 MB across projects | 0 scans on every project sampled. The leaderboard/analytics functions group by `root_*`, not `engaged_user_id`. Verify no function needs them, then drop from `create_engagement_view`. |
| `mindshare_score.mv_engagement_features_<project>` `…_root` | varies | 0 scans on several projects — but these back `CONCURRENT` refresh (unique key) and feature-view joins; **keep** unless proven redundant. |

Net: there is likely **~0.5–1 GB** of droppable index in `test_*` alone, plus the
per-project `_user` indexes, which also speeds up every matview rebuild/refresh.

---

## Finding 6 — Composite `DISTINCT ON` indexes still missing on production score tables

The leaderboard and analytics functions all run the same shape:

```sql
SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id) …
FROM mindshare_score.contribution_scores cs
… ORDER BY cs.original_post_id, cs.replier_x_id, cs.post_created_at ASC
```

`pg_indexes` confirms production `contribution_scores` still has only the five
original single/double-column indexes — the composite `DISTINCT ON` indexes
recommended previously were **never created**. (In my test window the inner query
returned 0 rows and ran in 176 ms off `idx_cs_post_created`, because production
`contribution_scores` for quipnetwork only spans 2026-02-11 → 2026-06-16 and my
first window predated it — so this isn't *currently* hot, but it will be as the
window overlaps live data.)

Apply, using `CONCURRENTLY` to avoid blocking:

```sql
-- Shape A: post-scoped DISTINCT ON (account/post metrics, smart reach, v2 user posts)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_cs_original_replier_created
  ON mindshare_score.contribution_scores (original_post_id, replier_x_id, post_created_at);

-- Shape B: project-filtered DISTINCT ON (leaderboards, get_v2_analytics)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_cs_keyword_original_replier_created
  ON mindshare_score.contribution_scores (project_keyword, original_post_id, replier_x_id, post_created_at);

-- Mirror Shape A onto the global table (get_all_users_analytics, get_user_posts_analytics)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_gcs_original_replier_created
  ON mindshare_score.global_contribution_scores (original_post_id, replier_x_id, post_created_at);
```

Shape B supersedes the narrow `idx_cs_keyword_replier` / `idx_cs_keyword_author`
for the hot leaderboard paths; drop those two only after confirming nothing else
relies on them (tie this into Finding 5).

---

## Finding 7 — Statistics and the 36-billion-row misestimate

The project decay join plan estimated **`rows = 36,374,415,303`** for a join that
actually returns **2.49 M** — a 14,000× overestimate. Gross misestimates like this
on a join key are how the planner picks pathological plans elsewhere. Two actions:

1. **Refresh stale stats.** Several large matviews were last analyzed in
   **April–May 2026** (e.g. `mv_engagement_features_quipnetwork` last
   autoanalyze 2026-05-20; several feature views 2026-04-30) while their base
   data refreshes nightly. Run `ANALYZE` after every refresh — bake it into the
   refresh procedures:
   ```sql
   ANALYZE mindshare.mindshare_post;
   ANALYZE mindshare.user_post;
   ANALYZE mindshare.mindshare_user;
   ANALYZE mindshare_score.contribution_scores;
   ANALYZE mindshare_score.global_contribution_scores;
   -- and each matview right after REFRESH
   ```
2. **Raise the stats target on the high-cardinality join keys** so estimates on
   `user_x_id` / `post_id` / `replied_post_id` improve:
   ```sql
   ALTER TABLE mindshare.mindshare_post ALTER COLUMN replied_post_id SET STATISTICS 500;
   ALTER TABLE mindshare.mindshare_post ALTER COLUMN user_x_id        SET STATISTICS 500;
   ALTER TABLE mindshare.user_post      ALTER COLUMN replied_post_id  SET STATISTICS 500;
   ALTER TABLE mindshare.user_post      ALTER COLUMN user_x_id        SET STATISTICS 500;
   -- then ANALYZE the tables
   ```
   (Or raise `default_statistics_target` globally per Finding 2.)

Minor housekeeping: tiny tables (`mindshare_project`, `api_key`, `admin`) show
>200% dead-tuple ratios — negligible in size, but a one-time `VACUUM` tidies
them.

---

## Recommended order of work

1. **Finding 1** — remove `is_reply = true` from both decay source reads, re-time
   (expect project ~14×, global ~23× on the scan). *Zero-risk, biggest win.*
2. **Finding 2** — apply config (start with `work_mem`, `random_page_cost`,
   `effective_cache_size` via reload; schedule `shared_buffers` + restart),
   install `pg_stat_statements`. Re-measure.
3. **Finding 7** — wire `ANALYZE` into refresh procedures; raise stats targets.
4. **Finding 6** — create the composite `DISTINCT ON` indexes `CONCURRENTLY`.
5. **Finding 5** — after a representative window with `pg_stat_statements`, drop
   confirmed-unused `test_*` and `_user` indexes (re-verify the 286 MB decay
   index is now used).
6. **Finding 4** — resolve the ambiguous `get_mindshare_leaderboard` overload.
7. **Finding 3** — rewrite `get_all_users_analytics` (OR→`UNION ALL`, dedup
   sub-aggregate); if still hot, promote to a scheduled matview.

## Reproduce the measurements

The plans in this doc come from running, via the project's own
`connect_with_ssl_fallback` connection:

```sql
SET statement_timeout = '180s';

-- Finding 1 (project): compare these two plans
EXPLAIN (ANALYZE, BUFFERS) SELECT user_x_id, post_created_at, post_id, replied_post_id
  FROM mindshare.mindshare_post
  WHERE project_keyword='quipnetwork' AND is_reply=true AND replied_post_id IS NOT NULL
  ORDER BY user_x_id, post_created_at;
EXPLAIN (ANALYZE, BUFFERS) SELECT user_x_id, post_created_at, post_id, replied_post_id
  FROM mindshare.mindshare_post
  WHERE project_keyword='quipnetwork' AND replied_post_id IS NOT NULL
  ORDER BY user_x_id, post_created_at;

-- Finding 3
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM analytics.get_all_users_analytics();

-- Finding 4
SELECT pg_get_function_identity_arguments(p.oid)
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='mindshare_score' AND p.proname='get_mindshare_leaderboard';

-- Findings 5/6: index inventory & usage
SELECT * FROM pg_stat_user_indexes
WHERE schemaname IN ('mindshare','mindshare_score','test_mindshare_score','analytics')
ORDER BY idx_scan, pg_relation_size(indexrelid) DESC;
```
