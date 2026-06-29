# Backend Optimization — `test_mindshare` indexes & partitioning

SQL to apply the base-table indexing & partitioning strategy documented in
[`docs/test_mindshare_indexing_partitioning_strategy.md`](../docs/test_mindshare_indexing_partitioning_strategy.md).

Target schema: **`test_mindshare`**. Everything here is derived from the actual query shapes of
the functions/procedures/views/matviews in the `mindshare`, `mindshare_score`, and `analytics`
schemas — with the **decay computation** (`calculate_decay_scores` /
`calculate_global_decay_scores`) treated as the priority workload, because those functions read
the base tables directly.

## Files (apply in order)

| File | What it does |
|---|---|
| `01_partitions.sql` | Partitioning fix — adds the missing `nucleus_post` DEFAULT partition. |
| `02_indexes_tier1.sql` | Tier-1 indexes — decay drivers + the hot reader paths. Create these now. |
| `03_indexes_tier2.sql` | Tier-2 indexes — secondary readers; add if EXPLAIN shows them hot. |
| `00_apply_all.sql` | Runner: `\ir` 01 → 02 → 03, then `VACUUM (ANALYZE)`. |

## How to run

```bash
psql "postgresql://<user>:<pass>@<host>:5432/mindshare_db?sslmode=disable" \
     -v ON_ERROR_STOP=1 -f backend_optimization/00_apply_all.sql
```

All `CREATE INDEX` statements use `IF NOT EXISTS` and the partition uses `CREATE TABLE IF NOT
EXISTS`, so re-running is safe (idempotent). Indexes are built non-concurrently (fine for a test
schema with no concurrent readers); for a live schema switch to `CREATE INDEX CONCURRENTLY` and
run one statement per transaction.

---

## Background: the table shapes that drive every decision

| Table | Primary key | Partitioning |
|---|---|---|
| `mindshare_post` | `(project_keyword, post_created_at, post_id)` | LIST(project_keyword) |
| `nucleus_post` | `(project_keyword, post_created_at, post_id)` | LIST(project_keyword) |
| `user_post` | `(post_created_at, post_id)` | none |
| `mindshare_user` | `(x_id)` | none |

Two facts about these PKs explain almost every index below:

1. **A bare `post_id` lookup is not served by any PK** — on the post tables `post_id` is the
   *last* PK column (after `project_keyword`/`post_created_at`), so it cannot be used as a search
   prefix. Yet `post_id` joins are everywhere (the decay self-join, every metrics/leaderboard
   function). → we need dedicated `(post_id)` indexes.
2. **`user_post`'s PK leads with `post_created_at`**, so it *does* serve time-window scans
   (`WHERE post_created_at BETWEEN …`) but not `user_x_id` / `post_id` / `replied_post_id` /
   `root_post_id` lookups.

Two recurring index techniques are used below:
- **Partial index** (`WHERE replied_post_id IS NOT NULL`): only indexes the rows that match, so
  it is smaller and the scan touches only relevant rows. Used for the decay reply-scan.
- **Covering index** (`INCLUDE (...)`): stores extra columns in the index leaf so the query can
  be answered from the index alone — an **Index Only Scan** with `Heap Fetches: 0`, avoiding
  random trips to the table heap. This is what makes the decay scans fast.

---

## Partitioning (`01_partitions.sql`)

**Decision: keep the existing `LIST(project_keyword)` partitioning; change nothing structural
except adding one missing default partition.**

- **Why keep LIST(project_keyword):** nearly every project-scoped query filters
  `project_keyword = $`, so the planner prunes straight to a single partition. Decay reads one
  project's full reply history ordered per replier — that ordered scan stays entirely inside one
  partition's index.
- **Why NOT sub-partition by time (day/week/month/etc.):** decay and the matview builds read a
  project's *full* history (no time predicate), so a time sub-key would prune nothing for them,
  and it would fragment the single ordered index scan the decay loop depends on (forcing a merge
  or a sort). The only fixed time periods in the codebase (the leaderboard's `week`/`month` cap
  bucket and the decay `30 day` window) are computed on the full history, not used to filter a
  sub-range.
- **Why `user_post` stays unpartitioned:** there is no `project_keyword` to partition on, and a
  `HASH(user_x_id)` layout would stop the `post_id` / `root_post_id` joins from pruning. The
  global decay scan is already efficient as one ordered index-only scan.

```sql
CREATE TABLE IF NOT EXISTS test_mindshare.nucleus_post_default
    PARTITION OF test_mindshare.nucleus_post DEFAULT;
```
**Why:** unlike `mindshare_post` and `post_content_signal`, `nucleus_post` had **no DEFAULT
partition** — an insert for a `project_keyword` that isn't an explicit partition would fail.
This adds the catch-all so ingestion of a new/unlisted project can't error out.

---

## Tier-1 indexes (`02_indexes_tier1.sql`) — create now

### `mindshare_post` (partitioned)

| Index | Definition | Why it exists |
|---|---|---|
| `ix_tmp_mp_replier_time` | `(user_x_id, post_created_at) INCLUDE (post_id, replied_post_id, project_keyword) WHERE replied_post_id IS NOT NULL` | **The project-decay driver.** Decay scans replies for one project ordered by `(user_x_id, post_created_at)`. Partial = only replies; covering (incl. `project_keyword`, which the decay `SELECT` returns) = **Index Only Scan, no Sort**. Measured: driving scan 11.2 s → 0.88 s on `quipnetwork`. |
| `ix_tmp_mp_post_lookup` | `(post_id) INCLUDE (user_x_id)` | The decay self-join `op ON p.replied_post_id = op.post_id` does ~2.7M `post_id` lookups (served via Memoize) to fetch the original author. Also used by every `JOIN mindshare_post ON post_id = …` reader (`get_post_engagement_ratios`, `get_post_level_metrics`, `get_mindshare_leaderboard`, …). |
| `ix_tmp_mp_user_time` | `(user_x_id, post_created_at)` | The **full** (non-partial) timeline index for queries over *non-reply* rows, which the partial index above cannot serve: `get_v2_user_posts_analytics` (`user_x_id + project + time`), `get_unique_reach_increase`, `get_post_from_user_id`. |

### `user_post` (unpartitioned)

| Index | Definition | Why it exists |
|---|---|---|
| `ix_tmp_up_replier_time` | `(user_x_id, post_created_at) INCLUDE (post_id, replied_post_id) WHERE replied_post_id IS NOT NULL` | **The global-decay driver** (same idea as `mindshare_post`, no project filter). Covering → Index Only Scan, no Sort. |
| `ix_tmp_up_post_lookup` | `(post_id) INCLUDE (user_x_id)` | Global decay self-join + `root_up.post_id = reply_up.root_post_id` lookups in the global metrics functions. Covering makes the self-join index-only. |
| `ix_tmp_up_replied_time` | `(replied_post_id, post_created_at) WHERE replied_post_id IS NOT NULL` | The account/global metrics engagement join: `JOIN user_post e ON e.replied_post_id = root WHERE e.post_created_at BETWEEN …` (`get_account_level_metrics`, `get_global_post_engagement_ratios`, `get_global_unique_reach_increase`, `get_account_and_keyword_unique_reach_ratio`). Verified used. |
| `ix_tmp_up_root_post_id` | `(root_post_id)` | `get_post_metrics_from_user_post` and the metrics `replies`/`post_metrics` joins key on `root_post_id`. |

### `nucleus_post` (partitioned)

| Index | Definition | Why it exists |
|---|---|---|
| `ix_tmp_np_user_time` | `(user_x_id, post_created_at)` | `get_post_from_user_id` (nucleus branch) + `get_top_nucleus_posts_per_user` (`PARTITION BY user_x_id ORDER BY post_created_at DESC`, no project filter) + `get_user_engagement_quality`. |

### `mindshare_user` (unpartitioned)

| Index | Definition | Why it exists |
|---|---|---|
| `ix_tmp_mu_xid_score` | `(x_id) INCLUDE (score)` | The replier-base-score join (`u.score`) appears in **both** decay functions and the engagement matview builds (60+ call sites). Covering makes that join an **Index Only Scan, `Heap Fetches: 0`** — measured the score join 607 ms → 55 ms and global decay 12.4 s → 8.1 s. |

---

## Tier-2 indexes (`03_indexes_tier2.sql`) — add if confirmed hot

These serve secondary reader paths. They are justified by query shape but lower-frequency, so
verify with `pg_stat_user_indexes.idx_scan` after running the real workload and drop any that
stay unused.

| Index | Definition | Why it exists |
|---|---|---|
| `ix_tmp_up_user_time` | `user_post (user_x_id, post_created_at)` | `get_post_from_user_id` (user_post branch): non-reply user timeline (the partial decay index can't serve non-replies). |
| `ix_tmp_up_quoted_post_id` | `user_post (quoted_post_id) WHERE quoted_post_id IS NOT NULL` | `get_all_users_analytics` OR-join (`replied_post_id = … OR quoted_post_id = …`) + the user-posts engagement matview build. |
| `ix_tmp_up_retweeted_post_id` | `user_post (retweeted_post_id) WHERE retweeted_post_id IS NOT NULL` | The retweet branch of the user-posts engagement matview build. |
| `ix_tmp_np_replied_post_id` | `nucleus_post (replied_post_id) WHERE replied_post_id IS NOT NULL` | `get_user_engagement_quality` second scan: `WHERE replied_post_id IN (…)`. |

---

## Two prerequisites to actually realize the speedups

The index DDL alone is not enough — both of these matter as much as the indexes:

1. **`VACUUM` after the bulk load** (automated in `00_apply_all.sql`). It sets the visibility
   map; without it the covering indexes cannot do index-only scans and will heap-fetch every
   row (no speedup).
2. **SSD-appropriate planner config.** With the stock `random_page_cost = 4`, the planner
   *ignores* these indexes for the decay driver and falls back to a Parallel Seq Scan + ~91 MB
   on-disk Sort. Set it lower to get the index-only plan — scope it as you prefer:
   ```sql
   ALTER DATABASE mindshare_db SET random_page_cost = 1.1;            -- whole DB
   -- or, local to the decay function once created in the test schema:
   ALTER FUNCTION test_mindshare.calculate_decay_scores(text, interval)
     SET random_page_cost = 1.1 SET work_mem = '256MB';
   ```
   This is left as a recommendation (not auto-applied) because it is a server/DB-level setting.

---

## What was deliberately NOT created (and why)

- **No indexes on `post_content_signal` / `nucleus_user`** — they have **0 references** in any
  routine or view; PK only.
- **No extra index on `user` / `mindshare_project` / `project_post_cap`** — only ever accessed
  by their existing PK / unique key.
- **No GIN index** — the `entities` JSONB column is never filtered (`@>`, `->>`, `?`); JSONB only
  appears as query output (`jsonb_build_object`/`jsonb_agg`).
- **No full-text (tsvector) index** — no full-text search anywhere.
- **No BRIN index** — `post_created_at` is highly correlated with physical order (≈0.91, good for
  BRIN) but the existing PK already covers time-range scans, so BRIN would be redundant.

See the strategy doc for the full access-pattern catalog and the EXPLAIN verification recipe.
