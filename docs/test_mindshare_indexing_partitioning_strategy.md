# `test_mindshare` — Indexing & Partitioning Strategy (Base Tables)

> **Status:** Recommendation / runbook. No DDL has been executed against the database by this
> document — every statement below is meant to be reviewed and run by you.
>
> **Scope:** The **base tables physically stored in `test_mindshare`**. Decay is the immediate
> priority: the decay functions (`calculate_decay_scores`, `calculate_global_decay_scores`,
> `calculate_scores_by_project`) read these base tables directly. Score tables
> (`test_mindshare_score.contribution_scores` / `global_contribution_scores`) **do not exist
> yet** and are covered in the [Deferred](#deferred--score-tables) section only.

---

## 1. Purpose

`test_mindshare` is a verified, index-light replica of `mindshare` (raw data + PK/unique/FK
only — all secondary indexes were intentionally removed). This document specifies, table by
table, the indexes and the partitioning each base table needs so that when the
functions/procedures from `mindshare`, `mindshare_score`, and `analytics` are replicated (or
rewritten) against `test_mindshare`, they run efficiently — with decay as the first-class
workload.

Every recommendation below is derived from the **actual query shapes** of all 70 routines and
the views/matviews in those three schemas (filters, joins, `ORDER BY` / `DISTINCT ON` /
`PARTITION BY` columns), not from guesswork.

---

## 2. Current state

Sizes below are the live **on-disk size of `test_mindshare`** (heap + PK + TOAST, **after the
secondary indexes were dropped**); for partitioned tables it is the sum across all partitions.
They are therefore smaller than the source `mindshare` schema, which still carries every index.

| Table | Primary key | Partitioning | Rows | Size (test_mindshare) |
|---|---|---|---|---|
| `mindshare_post` | `(project_keyword, post_created_at, post_id)` | **LIST(project_keyword)**, 12 parts (+DEFAULT) | 8.22M | 2.7 GB |
| `nucleus_post` | `(project_keyword, post_created_at, post_id)` | **LIST(project_keyword)**, 11 parts (**no DEFAULT**) | 6.33M | 2.2 GB |
| `post_content_signal` | `(project_keyword, post_created_at, post_id)` | **LIST(project_keyword)**, 10 parts (+DEFAULT) | 0.30M | 89 MB |
| `user_post` | `(post_created_at, post_id)` | none | 3.47M | 1.0 GB |
| `mindshare_user` | `(x_id)` | none | 376K | 92 MB |
| `user` | `(x_id)` | none | 94K | 20 MB |
| `nucleus_user` | `(x_id)` | none | 23K | 5 MB |

**Key consequence of the PK shapes:**

- On the post tables the PK leads with `project_keyword, post_created_at` → a **bare `post_id`
  lookup is not served by any PK**. `post_id` joins are everywhere (decay self-join, every
  metrics/leaderboard function), so a dedicated `(post_id)` index is required.
- `user_post`'s PK leads with `post_created_at` → it **does serve time-window scans**
  (`WHERE post_created_at BETWEEN …`) but **not** `user_x_id`, `post_id`, `root_post_id`, or
  `replied_post_id` lookups.

---

## 3. Access-pattern catalog

This is the evidence base for §4. Each pattern maps to the columns an index must provide.

### A. Project decay — `mindshare_score.calculate_decay_scores` / `mindshare.calculate_scores_by_project`
```sql
FROM mindshare.mindshare_post p
INNER JOIN mindshare.mindshare_post op
       ON p.replied_post_id = op.post_id AND p.project_keyword = op.project_keyword
INNER JOIN mindshare.mindshare_user u ON p.user_x_id = u.x_id
WHERE p.replied_post_id IS NOT NULL          -- (is_reply = true is redundant; generated column)
  AND p.project_keyword = $1
ORDER BY p.user_x_id, p.post_created_at;      -- loop / window PARTITION BY replier ORDER BY time
```
Needs: an **ordered, reply-only scan** of one project partition by `(user_x_id,
post_created_at)` with **no Sort**, and a `post_id` lookup for the self-join `op`
(returning `op.user_x_id` = original author).

### B. Global decay — `mindshare_score.calculate_global_decay_scores`
Identical shape on **`user_post`**, no project filter: ordered reply-only scan by
`(user_x_id, post_created_at)` + `post_id` self-join lookup.

### C. `mindshare_post` — project + user + time scans
- `get_v2_user_posts_analytics`: `WHERE user_x_id=$1 AND project_keyword=$2 AND post_created_at
  BETWEEN $3 AND $4` ⇒ `(user_x_id, post_created_at)` inside the project partition.
- `get_unique_reach_increase`: `WHERE post_created_at BETWEEN …`, window `PARTITION BY user_x_id
  ORDER BY post_created_at, post_id` ⇒ `(user_x_id, post_created_at)`.
- `get_v2_analytics`: `WHERE project_keyword=$1 AND post_created_at BETWEEN $2 AND $3 AND
  post_id IN (…)` ⇒ **served by PK** `(project_keyword, post_created_at, …)`.
- `get_post_engagement_ratios`, `get_account_level_metrics`, `get_post_level_metrics`,
  `get_single_post_smart_reach`, `get_mindshare_leaderboard` (both arities), `get_v2_analytics`:
  `JOIN mindshare_post p ON p.post_id = <root_post_id> AND p.project_keyword = $` ⇒ `(post_id)`.

### D. `user_post` — engagement self-joins + time windows
- Time-window root scan (`WHERE post_created_at BETWEEN …`) — `get_account_level_metrics`,
  `get_global_*`, `get_post_metrics_from_user_post`, `get_account_and_keyword_unique_reach_ratio`
  ⇒ **served by PK** `(post_created_at, post_id)`.
- `JOIN user_post root_up ON root_up.post_id = reply_up.root_post_id`
  (`get_post_metrics_from_user_post`, `get_global_post_level_metrics`) ⇒ `(post_id)`.
- `JOIN user_post e ON e.replied_post_id = up.root_post_id WHERE e.post_created_at BETWEEN …`
  (`get_account_level_metrics`, `get_account_and_keyword_unique_reach_ratio`,
  `get_global_post_engagement_ratios`, `get_global_unique_reach_increase`) ⇒
  `(replied_post_id, post_created_at)`.
- `e.root_post_id = bp.post_id`, `r.root_post_id = pm.root_post_id` ⇒ `(root_post_id)`.
- `mp.replied_post_id = tp.post_id OR mp.quoted_post_id = tp.post_id` (`get_all_users_analytics`)
  ⇒ BitmapOr of `(replied_post_id)` + `(quoted_post_id)`.
- `get_post_from_user_id` (user_post branch): `WHERE user_x_id=ANY AND time AND NOT is_reply`
  ⇒ `(user_x_id, post_created_at)`.

### E. `nucleus_post`
- `get_post_from_user_id` (nucleus) + `get_top_nucleus_posts_per_user` (`PARTITION BY user_x_id
  ORDER BY post_created_at DESC`, **no project filter**) ⇒ `(user_x_id, post_created_at)`.
- `get_user_engagement_quality`: `WHERE user_x_id = ANY(...)` plus a second scan
  `WHERE replied_post_id IN (…)` ⇒ `(user_x_id, …)` + `(replied_post_id)`.

### F. Engagement matview builds — `analytics.create_engagement_view` / `create_user_posts_engagement_view`
Bulk full-partition / full-table reads, hash self-joins on
`post_id = replied/quoted/retweeted_post_id`. These benefit from the `(post_id)` and the
`quoted/retweeted` lookup indexes when windows are selective; the builders create the matviews'
**own** output indexes, so nothing extra is required *for the build itself*.

### G. Tables that need nothing new (verified by full reference scan)
- `mindshare_user`, `user` — only ever joined on `x_id` (PK).
- `post_content_signal`, `nucleus_user` — **0 references** in any routine/view → PK only.
- `mindshare_project` (PK `project_name`), `project_post_cap` (unique `(project_keyword,
  leaderboard_type)`) and the remaining small tables — existing keys suffice.

---

## 4. Recommended indexes

**Conventions**
- Indexes on partitioned tables are created **on the parent** so they propagate to all current
  and future partitions.
- Partitioned-table indexes **omit `project_keyword`** — it is constant within each partition,
  and partition pruning already isolates the project, so leading with it would only waste space.
- Partial indexes use `WHERE <col> IS NOT NULL` (not `is_reply`) so they remain usable whether
  or not the redundant generated-column filter is present in the query.
- **Tier 1** = create now (decay + the hot reader paths). **Tier 2** = add if EXPLAIN shows the
  query is hot / chooses a nested loop.

### 4.1 `mindshare_post` (partitioned) — 3 indexes

```sql
-- (Tier 1) PROJECT DECAY driving scan: ordered + partial + covering → no Sort, INDEX-ONLY for p.
-- project_keyword is INCLUDEd because the decay SELECT returns it (it is the partition key /
-- constant per partition, but PG still needs it materialized for an index-only scan).
CREATE INDEX ix_tmp_mp_replier_time
  ON test_mindshare.mindshare_post (user_x_id, post_created_at)
  INCLUDE (post_id, replied_post_id, project_keyword)
  WHERE replied_post_id IS NOT NULL;

-- (Tier 1) post_id lookup: decay self-join (op) + every "JOIN mindshare_post ON post_id = …" reader
CREATE INDEX ix_tmp_mp_post_lookup
  ON test_mindshare.mindshare_post (post_id) INCLUDE (user_x_id);

-- (Tier 1) general user timeline (NON-reply rows, which the partial index above does NOT cover):
--          get_v2_user_posts_analytics, get_unique_reach_increase, get_post_from_user_id
CREATE INDEX ix_tmp_mp_user_time
  ON test_mindshare.mindshare_post (user_x_id, post_created_at);
```

### 4.2 `user_post` (unpartitioned) — 4 Tier-1, 3 Tier-2

```sql
-- (Tier 1) GLOBAL DECAY driving scan: ordered + partial + covering → no Sort, index-only for p
CREATE INDEX ix_tmp_up_replier_time
  ON test_mindshare.user_post (user_x_id, post_created_at)
  INCLUDE (post_id, replied_post_id)
  WHERE replied_post_id IS NOT NULL;

-- (Tier 1) post_id lookup: global decay self-join + root_up.post_id = reply_up.root_post_id joins
CREATE INDEX ix_tmp_up_post_lookup
  ON test_mindshare.user_post (post_id) INCLUDE (user_x_id);

-- (Tier 1) replied_post_id (+time): account/global metrics engagement join
--          JOIN user_post e ON e.replied_post_id = root WHERE e.post_created_at BETWEEN …
CREATE INDEX ix_tmp_up_replied_time
  ON test_mindshare.user_post (replied_post_id, post_created_at)
  WHERE replied_post_id IS NOT NULL;

-- (Tier 1) root_post_id: get_post_metrics_from_user_post + replies/post_metrics joins
CREATE INDEX ix_tmp_up_root_post_id
  ON test_mindshare.user_post (root_post_id);

-- (Tier 2) non-reply user timeline (get_post_from_user_id)
CREATE INDEX ix_tmp_up_user_time
  ON test_mindshare.user_post (user_x_id, post_created_at);

-- (Tier 2) quoted / retweeted lookups: get_all_users_analytics OR-join + engagement matview builds
CREATE INDEX ix_tmp_up_quoted_post_id
  ON test_mindshare.user_post (quoted_post_id)    WHERE quoted_post_id    IS NOT NULL;
CREATE INDEX ix_tmp_up_retweeted_post_id
  ON test_mindshare.user_post (retweeted_post_id) WHERE retweeted_post_id IS NOT NULL;
```
> The PK `(post_created_at, post_id)` already serves the pure time-window root scans, so no
> separate `(post_created_at)` index is needed.

### 4.3 `nucleus_post` (partitioned) — 1 Tier-1, 1 Tier-2

```sql
-- (Tier 1) get_post_from_user_id (nucleus) + get_top_nucleus_posts_per_user + get_user_engagement_quality
CREATE INDEX ix_tmp_np_user_time
  ON test_mindshare.nucleus_post (user_x_id, post_created_at);

-- (Tier 2) get_user_engagement_quality second scan: WHERE replied_post_id IN (…)
CREATE INDEX ix_tmp_np_replied_post_id
  ON test_mindshare.nucleus_post (replied_post_id) WHERE replied_post_id IS NOT NULL;
```

### 4.4 `mindshare_user` (unpartitioned) — 1 covering index

```sql
-- Covering (x_id) INCLUDE (score): makes the replier-base-score join INDEX-ONLY in BOTH decay
-- functions and the engagement matview builds (u.score / eu.score read in 60+ call sites).
CREATE INDEX ix_tmp_mu_xid_score
  ON test_mindshare.mindshare_user (x_id) INCLUDE (score);
```
> Found during the re-evaluation pass. Verified: in global decay the score join went from an
> Index Scan on the PK (607 ms, 155K buffer reads, heap fetches) to an **Index Only Scan,
> `Heap Fetches: 0` (55 ms, ~1.9K buffers)** — global decay total **12.4 s → 8.1 s**.

### 4.5 No new indexes (verified)
`user` (join on `x_id` = PK); `nucleus_user`, `post_content_signal` (**0 references** anywhere →
PK only); `mindshare_project`, `project_post_cap`, and the remaining small config tables
(existing PK/unique suffice). **No GIN** (no JSONB containment/path filtering exists — the
`entities` jsonb column and `jsonb_build_object`/`jsonb_agg` calls are output-only) and **no
full-text search** (no `tsvector`/`tsquery` usage) anywhere.

### 4.5 Summary

| Table | Tier 1 | Tier 2 |
|---|---|---|
| `mindshare_post` | `mp_replier_time` (partial/cov), `mp_post_lookup` (cov), `mp_user_time` | — |
| `user_post` | `up_replier_time` (partial/cov), `up_post_lookup` (cov), `up_replied_time`, `up_root_post_id` | `up_user_time`, `up_quoted_post_id`, `up_retweeted_post_id` |
| `nucleus_post` | `np_user_time` | `np_replied_post_id` |
| `mindshare_user` | `mu_xid_score` (cov) | — |
| others | — | — |

> **Note — the two `(user_x_id, post_created_at)` index pairs are complementary, not duplicate.**
> On `mindshare_post` and `user_post`, `*_replier_time` is **partial** (`WHERE replied_post_id IS
> NOT NULL`) + covering, used for the decay reply scan (index-only); `*_user_time` is the
> **full** index used by the non-reply timeline readers (`get_v2_user_posts_analytics`,
> `get_post_from_user_id`) which the partial index cannot serve. Keep both.

---

## 5. Partitioning strategy

### Keep `LIST(project_keyword)` on `mindshare_post`, `nucleus_post`, `post_content_signal`
- Nearly every project-scoped query filters `project_keyword = $` → **partition pruning
  isolates a single partition**.
- Project decay reads one project's full reply history ordered per replier; that ordered scan
  stays entirely inside one partition's `(user_x_id, post_created_at)` index.

### Do NOT add time sub-partitioning to the post tables
- Decay and the matview builds read **full project history** (no time predicate), so a time
  sub-key prunes nothing for them.
- Worse, sub-partitioning by time would **fragment the single ordered index scan** that decay
  relies on (it would force a merge across sub-partitions or a Sort).
- The time filters that do exist live in metrics/leaderboard functions and hit **matviews /
  score tables**, not these base partitions. Where a base time-window scan exists
  (`user_post`), the PK already serves it.

### `user_post`: keep unpartitioned
Rely on the §4.2 indexes. A `HASH(user_x_id)` layout to parallelize global decay was considered
and **rejected for now**: it would stop `post_id` / `root_post_id` joins from pruning, and the
global decay scan is already efficient as a single ordered index scan. (Matches existing repo
guidance to avoid over-partitioning `user_post`.)

### Robustness fix to apply
`nucleus_post` has **no DEFAULT partition** (unlike `mindshare_post` / `post_content_signal`),
so an insert for an unlisted `project_keyword` will fail. If nucleus ingestion can see new
projects, add one:
```sql
CREATE TABLE test_mindshare.nucleus_post_default
  PARTITION OF test_mindshare.nucleus_post DEFAULT;
```

---

## 6. Apply order (runbook)

```sql
-- 1. Create Tier-1 indexes (data is already loaded; plain CREATE INDEX is fine on a test schema).
--    Use CREATE INDEX CONCURRENTLY only if other sessions are reading the table.
\i  -- (paste the Tier-1 blocks from §4)

-- 2. Refresh planner statistics for the schema.
ANALYZE test_mindshare.mindshare_post;
ANALYZE test_mindshare.user_post;
ANALYZE test_mindshare.nucleus_post;

-- 3. Replicate / point the decay function at test_mindshare and run EXPLAIN (§7).
-- 4. Add Tier-2 indexes only if EXPLAIN shows the corresponding query is hot.
```

---

## 7. Verification

For each Tier-1 index, capture `EXPLAIN (ANALYZE, BUFFERS)` **before and after** and confirm the
expected plan change. Record cost + actual time so the speedup is evidenced.

```sql
SET search_path = test_mindshare, public;
EXPLAIN (ANALYZE, BUFFERS) <representative query>;
```

| Workload | Representative query | Expected plan after index |
|---|---|---|
| **Project decay** (priority) | `calculate_decay_scores` driving SELECT for a big project (`quipnetwork`) | Partition prune → **Index Scan** on `ix_tmp_mp_replier_time`, **no Sort**; nested loop to `op` via `ix_tmp_mp_post_lookup` |
| **Global decay** (priority) | `calculate_global_decay_scores` driving SELECT | **Index Scan** on `ix_tmp_up_replier_time`, **no Sort**; `op` via `ix_tmp_up_post_lookup` |
| Project user timeline | `get_v2_user_posts_analytics` base scan | Partition prune → Index Scan on `ix_tmp_mp_user_time` |
| Account metrics | `get_account_level_metrics` engagement join | Index Scan on `ix_tmp_up_replied_time` |
| Post metrics | `get_post_metrics_from_user_post` | Index used: `ix_tmp_up_root_post_id` |

**Success criteria:** the two decay drivers show an ordered Index Scan with **no Sort node** and
a sharp drop in actual time / buffers vs the pre-index baseline.

### Measured result (project decay driver, `quipnetwork`, ~2.7M reply rows)
After applying the indexes + `VACUUM`:
- Driving scan → **Index Only Scan, `Heap Fetches: 0`** (`ix_tmp_mp_replier_time`):
  **11,204 ms → 881 ms** (~13×).
- Self-join `op` → Memoize + `ix_tmp_mp_post_lookup` (2.5M cache hits).
- Total query: **17.5 s → 5.6 s**, **no Sort node**.

### Two prerequisites to realize this (both matter as much as the index)
1. **`VACUUM` after the bulk load** — sets the visibility map so the covering index can do an
   index-only scan. Without it the same index heap-fetches every row (no speedup). Included in
   `backend_optimization/00_apply_all.sql`.
2. **SSD-appropriate planner config** — with stock `random_page_cost = 4`, the planner ignores
   the index and does a Parallel Seq Scan + ~91 MB on-disk Sort (~9.9 s). Set
   `random_page_cost = 1.1` (and a larger `work_mem`) to get the index-only plan. Scope it as
   you prefer:
   ```sql
   ALTER DATABASE mindshare_db SET random_page_cost = 1.1;            -- whole DB
   -- or, local to the decay function once created in the test schema:
   ALTER FUNCTION test_mindshare.calculate_decay_scores(text, interval)
     SET random_page_cost = 1.1 SET work_mem = '256MB';
   ```
   (Consistent with `postgres_efficiency_optimization.md` Finding #2 — the server is on stock
   defaults.)

### Remaining non-index levers (optional, lower priority now that decay is index-only)
- **Statistics target on `user_x_id`** — `ANALYZE` estimates `n_distinct ≈ 15.6K` on
  `user_post.user_x_id`, an underestimate that can skew `GROUP BY user_x_id` / join rowcounts in
  the analytics functions. If those plans misbehave, raise it and re-analyze:
  ```sql
  ALTER TABLE test_mindshare.user_post     ALTER COLUMN user_x_id SET STATISTICS 1000;
  ALTER TABLE test_mindshare.mindshare_post ALTER COLUMN user_x_id SET STATISTICS 1000;
  ANALYZE test_mindshare.user_post, test_mindshare.mindshare_post;
  ```
- **Prune unused indexes after running the real workload.** The Tier-2 indexes
  (`up_user_time`, `up_quoted_post_id`, `up_retweeted_post_id`, `np_replied_post_id`) are
  justified by query shape but should be confirmed in practice:
  ```sql
  SELECT relname, indexrelname, idx_scan
  FROM pg_stat_user_indexes
  WHERE schemaname='test_mindshare' AND indexrelname LIKE 'ix_tmp_%'
  ORDER BY idx_scan;            -- drop any that stay at idx_scan = 0 after the workload runs
  ```
- **Not needed (verified):** GIN (no JSONB filtering), full-text (no tsvector), BRIN
  (`post_created_at` correlation ≈ 0.91 but the PK already covers time-range scans).

---

## Deferred — score tables

`test_mindshare_score.contribution_scores` / `global_contribution_scores` do not exist yet.
When they are created (by the Polars writer or manually), index them for the verified
`DISTINCT ON (original_post_id, replier_x_id) ORDER BY …, post_created_at` shape used by
`get_mindshare_leaderboard`, `get_v2_analytics`, `get_post_level_metrics`,
`get_global_post_level_metrics`, etc.:

```sql
-- contribution_scores (project)
ALTER TABLE test_mindshare_score.contribution_scores
  ADD CONSTRAINT pk_tcs PRIMARY KEY (project_keyword, reply_post_id);
CREATE INDEX ix_tcs_keyword_orig_replier_time
  ON test_mindshare_score.contribution_scores
     (project_keyword, original_post_id, replier_x_id, post_created_at)
  INCLUDE (original_author_x_id, contribution_score);
CREATE INDEX ix_tcs_keyword_replier_time
  ON test_mindshare_score.contribution_scores (project_keyword, replier_x_id, post_created_at);

-- global_contribution_scores
ALTER TABLE test_mindshare_score.global_contribution_scores
  ADD CONSTRAINT pk_tgcs PRIMARY KEY (reply_post_id);
CREATE INDEX ix_tgcs_orig_replier_time
  ON test_mindshare_score.global_contribution_scores
     (original_post_id, replier_x_id, post_created_at)
  INCLUDE (original_author_x_id, contribution_score);
CREATE INDEX ix_tgcs_replier_time
  ON test_mindshare_score.global_contribution_scores (replier_x_id, post_created_at);
```

---

## Adjacent notes (not part of this scope)
- Engagement matview output indexes are created by the `create_engagement_view` /
  `create_user_posts_engagement_view` builders. The leaderboard filters the matview by
  `root_tweet_created_at BETWEEN …`; if that scan is slow, add `(root_tweet_created_at)` on the
  engagement matview.
- The decay queries' `is_reply = true` filter is redundant with `replied_post_id IS NOT NULL`
  (a generated column). The partial indexes here are keyed on `replied_post_id IS NOT NULL`, so
  they apply either way.
- `get_unique_reach_increase` / `get_v2_analytics` scan `mindshare_post` by time **without** a
  `project_keyword` predicate in the base CTE → they touch all partitions. If that proves hot,
  pushing the project filter down is a function-level fix, not an index.
