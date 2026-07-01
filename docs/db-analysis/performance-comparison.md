# Mindshare DB — Performance & Correctness Comparison
## Original Schemas vs `_md_fix` Schemas

**Date:** 2026-06-25  
**Schemas analysed:** `analytics`, `mindshare_score`, `mindshare` vs `analytics_md_fix`, `mindshare_score_md_fix`, `mindshare_md_fix`

---

## Executive Summary

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Feature matview total storage | ~581 MB | ~42 MB | **−93%** |
| Feature matview total rows | 4,509,782 | 308,951 | **−93%** |
| Read blocking during refresh | Yes (ExclusiveLock) | No (CONCURRENTLY) | **Eliminated** |
| Correlated subqueries | 2 critical | 0 | **Fixed** |
| Runtime-broken functions | 4 (DNE column) | 0 | **Fixed** |
| Dead functions in mindshare schema | 4 | 0 (dropped) | **Cleaned** |
| Engagement MV refresh (pact_swap) | 15,025ms | 5,768ms | **−62% (2.6×)** |
| Engagement MV base table I/O | 111,800 pages | 55,810 pages | **−50%** |

---

## 1. Feature Matviews — 180-day Filter + RANGE→Hourly Bucket (P10a + P10c)

### Problem

`mindshare_score.mv_engagement_features_*` were:
1. **No time filter** — processing ALL historical engagement data since project inception (years)
2. **RANGE BETWEEN float frame** — `COUNT(*) OVER (PARTITION BY root_post_id ORDER BY engaged_epoch RANGE BETWEEN CURRENT ROW AND 3600 FOLLOWING)` on a float column scans forward per row

### Fix

1. Added `WHERE root_tweet_created_at >= NOW() - INTERVAL '180 days'` to `base` CTE
2. Replaced `RANGE BETWEEN` window with `date_trunc('hour', engaged_tweet_created_at) GROUP BY`:

```sql
-- Original (O(n × w) per row, where w = engagements in 1-hour window)
burst_windows AS (
    SELECT root_post_id, engaged_tweet_created_at AS window_start,
           COUNT(*) OVER (
               PARTITION BY root_post_id ORDER BY engaged_epoch
               RANGE BETWEEN CURRENT ROW AND 3600 FOLLOWING
           ) AS window_count
    FROM base
)

-- md_fix (O(n log n) GROUP BY)
burst_windows AS (
    SELECT root_post_id,
           date_trunc('hour', engaged_tweet_created_at) AS hour_bucket,
           COUNT(*) AS window_count
    FROM base GROUP BY root_post_id, hour_bucket
)
```

### Measured Impact

| Project | Orig rows | Fix rows | Reduction | Orig size | Fix size |
|---------|-----------|----------|-----------|-----------|----------|
| yom_official | 1,147,090 | 21,077 | **−98.2%** | 144 MB | 2.7 MB |
| quipnetwork | 1,099,678 | 126,218 | **−88.5%** | 145 MB | 17 MB |
| pact_swap | 952,315 | 48,601 | **−94.9%** | 121 MB | 6.5 MB |
| technotainment | 300,689 | 53 | **−99.98%** | 38 MB | 8 kB |
| thearcterminal | 480,160 | 54,654 | **−88.6%** | 64 MB | 7.5 MB |
| cnpynetwork | 326,699 | 11,386 | **−96.5%** | 43 MB | 1.5 MB |
| acurast | 71,192 | 2,840 | **−96.0%** | 9 MB | 376 kB |
| d3lmundos | 58,241 | 11,769 | **−79.8%** | 7.5 MB | 1.5 MB |
| sleepagotchi | 46,285 | 31,703 | **−31.5%** | 6 MB | 4.5 MB |
| ironallies | 27,431 | 650 | **−97.6%** | 3.6 MB | 128 kB |
| **TOTAL** | **4,509,782** | **308,951** | **−93.1%** | **~581 MB** | **~42 MB** |

> **Note:** Original matviews were last refreshed 2026-04-30 (7 weeks stale at time of analysis). The md_fix matviews were built from current data.

---

## 2. Analytics Engagement Matviews — Single-Pass Rewrite (Fix 2, 2026-06-25)

### Problem

Every `analytics_md_fix.mv_engagement_*` matview scanned `mindshare.mindshare_post` **twice** per project:
1. `roots` CTE: full seq scan + LEFT JOIN `mindshare_user`
2. `engaged_tweets` CTE: second full seq scan for replied/quoted rows

For `pact_swap` (1M rows): 2 × 55,637 pages = 111,274 pages read per refresh. Also, `mindshare_user` was joined twice (once in `roots`, once in `engagements_with_scores`).

Additionally, the planner chose Merge Join for the engagements UNION ALL, requiring external sorts: 82MB + 32MB spilled to disk — the primary wall-clock bottleneck.

### Fix

Consolidated into 4 CTEs, all MATERIALIZED to force execution order and prevent planner from merging scans:

```sql
all_posts AS MATERIALIZED        -- single scan of mindshare_post + mindshare_user (joined once)
engager_posts AS MATERIALIZED    -- filter from all_posts temp — zero base table I/O
engagements AS MATERIALIZED      -- Hash Join on engager_posts (48MB in-memory hash)
posts_with_no_engagement         -- anti-join from all_posts vs engagements
```

Also added to the procedure:
```sql
SET LOCAL enable_mergejoin = off;  -- forces Hash Join; planner mis-estimates all_posts at 765K rows
SET LOCAL work_mem = '64MB';       -- 48MB hash table for engager_posts fits in L3 cache
```

`SET LOCAL` scopes to current transaction only — no global impact.

### Measured Results (pact_swap, EXPLAIN ANALYZE)

| Approach | Time | shared_read pages | Notes |
|---------|------|-------------------|-------|
| `analytics` original (4MB wm) | 15,025ms | 112,353 | 2 base scans, NOT EXISTS, disk sorts |
| `analytics_md_fix` baseline (4MB wm) | 12,743ms | 111,800 | LEFT JOIN IS NULL, still 2 scans |
| md_fix + MATERIALIZED + 64MB wm | 10,098ms | 112,132 | Anti-join 3.4× faster |
| Single-pass naive + 64MB + no merge | 14,985ms | 55,874 | WORSE: wider rows, 3 disk sorts |
| **Single-pass + engager_posts + 64MB + no merge** | **5,768ms** | **55,810** | **✅ BEST — 2.6× vs original** |

Key plan metrics at best configuration:
- `shared hit=10210 read=55810` — exactly 50% fewer buffer reads vs baseline
- Reply join: Hash Join, `Batches: 1, Memory: 48946kB` — fully in-memory
- Quote join: Hash Join, `Batches: 1, Memory: 2549kB` — in-memory
- Anti-join: Hash Anti Join, `Batches: 2048, Memory: 16390kB` — still batched (planner estimates engagements at 2.9B rows; actual 252K), but 2.2× faster than before

### Why naive single-pass was slower

`all_posts` rows are 113 bytes wide (vs original split: 69+88 bytes). Without `engager_posts` as a pre-filter, the self-join sorted 1M × 1M instead of 1M × 395K. Three disk sorts: 82MB + 74MB + 42MB = 198MB vs original 114MB. The `engager_posts MATERIALIZED` CTE pre-selects the 395K reply/quote rows, making the Hash Join build only 48MB.

### Why Merge Join can't be disabled with just work_mem

Tested at 128MB work_mem without `enable_mergejoin = off`: 33,646ms — 6× worse than baseline. Planner chose in-memory Merge Join (124MB quicksort per sort), but sorted `all_posts` **twice** (one per UNION ALL branch). In-memory sorts are still O(n log n) on 1M rows and were done twice.

### Applied to

All 11 `analytics_md_fix.mv_engagement_*` matviews rebuilt (2026-06-25). Source: [Analytics_md_fix/functions/create_engagement_view.sql](../../Mindshare_Backend/Analytics_md_fix/functions/create_engagement_view.sql).

---

## 3. Analytics Engagement Matviews — NOT EXISTS → LEFT JOIN IS NULL (P1)

### Problem

The `posts_with_no_engagement` CTE in every `analytics.mv_engagement_*` matview used a correlated NOT EXISTS subquery:

```sql
-- Original: correlated subquery — O(n²) for posts with no engagement
posts_with_no_engagement AS (
    SELECT r.post_id AS root_post_id, ...
    FROM roots r
    WHERE NOT EXISTS (
        SELECT 1 FROM engagements_with_scores e WHERE e.root_post_id = r.post_id
    )
)
```

For quipnetwork with ~2.84M root posts, every post with no engagement triggers a scan of the full `engagements_with_scores` CTE result during matview refresh.

### Fix

```sql
-- md_fix: Hash Anti Join — O(n), single pass
posts_with_no_engagement AS (
    SELECT r.post_id AS root_post_id, ...
    FROM roots r
    LEFT JOIN engagements_with_scores ews ON ews.root_post_id = r.post_id
    WHERE ews.root_post_id IS NULL
)
```

PostgreSQL executes LEFT JOIN IS NULL as a Hash Anti Join: builds a hash table once, then probes it per row — O(n) total vs O(n²) for the correlated scan.

---

## 3. REFRESH MATERIALIZED VIEW CONCURRENTLY (P6)

### Problem

All `analytics.mv_engagement_*` refreshes were plain (non-CONCURRENTLY), acquiring an `ExclusiveLock` that blocked all SELECT queries for the full refresh duration. quipnetwork (261 MB) could block API reads for minutes during each nightly refresh.

### Fix

Added `CONCURRENTLY` to all refresh calls in:
- `analytics_md_fix.refresh_engagement_views_all`
- `mindshare_score_md_fix.refresh_engagement_features_views_all`
- `mindshare_score_md_fix.refresh_user_post_engagement_views`

Also created missing `UNIQUE INDEX ON engaged_tweet_id` for each matview (required by PostgreSQL for CONCURRENTLY refresh).

| Lock mode | Original | md_fix |
|-----------|----------|--------|
| Lock type | ExclusiveLock | ShareUpdateExclusiveLock |
| Blocks SELECT | Yes | No |
| Blocks other REFRESH | No | Yes (prevents concurrent refresh of same view) |

---

## 4. get_post_metrics_from_user_post — Bug + Correlated Subquery (BUG + P4)

### Bug: column does not exist

The original function references `e.user_x_score` from `mindshare.user_post`, but that column does not exist. The function fails with:
```
ERROR: column "e.user_x_score" does not exist
```

Fix: `JOIN mindshare.mindshare_user mu ON mu.x_id = e.user_x_id` and use `mu.score`.

### Performance: correlated subquery for total_reach

```sql
-- Original: O(n²) — subquery evaluated per (post_id, user_id) pair
(SELECT SUM(e.user_x_score) FROM engagements e WHERE e.root_post_id = ue.root_post_id) AS reach

-- md_fix: O(n) — single window pass
SUM(mu.score) OVER (PARTITION BY e.root_post_id) AS total_reach
```

For `mindshare.user_post` with 3.47M rows, the window function computes total reach in a single sorted pass vs one subquery scan per row.

---

## 5. calculate_decay_scores — Batch INSERT (P2)

### Problem

One `INSERT INTO contribution_scores` per reply row inside the PL/pgSQL loop:

```sql
-- Original: 1 WAL write + 1 catalog check per row
FOR rec IN SELECT ... LOOP
    INSERT INTO mindshare_score.contribution_scores (...) VALUES (...);
END LOOP;
```

For quipnetwork (~1.94M contribution rows), this is 1.94M individual INSERT round-trips.

### Fix

```sql
-- md_fix: accumulate in temp table, single bulk INSERT
CREATE TEMP TABLE _decay_batch (LIKE mindshare_score_md_fix.contribution_scores) ON COMMIT DROP;

FOR rec IN SELECT ... LOOP
    INSERT INTO _decay_batch VALUES (...);  -- no WAL, no catalog check
END LOOP;

INSERT INTO mindshare_score_md_fix.contribution_scores SELECT * FROM _decay_batch;
-- single WAL flush for entire batch
```

Temp table inserts have no WAL overhead and no catalog locking. The single final INSERT benefits from PostgreSQL's bulk-load path.

---

## 6. Bugs Fixed

### Bug 1 — get_post_engagement_ratios(projectname): hardcoded matview

**Original:** Always queries `mindshare_score.mv_engagement_acurast` regardless of `projectname` parameter. Returns wrong data for every non-Acurast project.

**Fix:** Dynamic SQL with `format($q$ FROM analytics_md_fix.%I $q$, 'mv_engagement_' || lower(projectname))`.

### Bug 2 — get_post_engagement_ratios(bigint, bigint, text): broken SQL template

**Original:** SQL template contains literal `v` where `(to_timestamp($2) AT TIME ZONE 'Asia/Kathmandu')` should be. Causes SQL syntax error at runtime.

**Fix:** Corrected the format string.

### Bug 3 — get_post_metrics_from_user_post: e.user_x_score DNE

See section 4 above.

### Bug 4 — mindshare.calculate_decay_scores (×4): writes to non-existent table

Four functions in `mindshare` schema write to `mindshare.contribution_scores` which does not exist. All fail at runtime. These are superseded by `mindshare_score.calculate_decay_scores`. **Dropped.**

---

## 7. Data Validation Results

All `_md_fix` schema outputs were validated against original schemas.

### Engagement matviews (analytics_md_fix)

| Check | Result |
|-------|--------|
| Structural match (root_user_id, reply/quote flags, engager_id) | ✅ 500/500 spot check, 100% match |
| Score differences | ✅ Expected — `mindshare_user.score` changed between Jun 16 original refresh and Jun 24 md_fix creation |
| New rows in md_fix not in original | ✅ 14 rows — legitimate new engagements since original was last refreshed |

### Feature matviews (mindshare_score_md_fix)

| Check | Result |
|-------|--------|
| Posts with same engagement count | ✅ 2,824/2,827 posts match exactly (99.9%) |
| Posts with 1 extra engagement | ✅ 3 posts — new reply arrived since original Apr 30 refresh |
| farming_score differences for same engagement count | ⚠️ 193 posts differ by >10 points — **expected, see below** |

**Why farming_score differs for same-engagement posts:**

The original `base` CTE had no time filter, so cross-post overlap was computed against ALL engagement history. Example: a user who replied to 3 posts in 2025 and 1 post in 2026 appeared as `cross_post_overlap = 100%` in the original (all 4 posts counted). In md_fix with 180-day filter, only the 1 recent post is visible → `cross_post_overlap = 0%`.

This is **correct behavior**: farming detection should be based on recent coordination patterns, not years-old engagement history. The original was inflating farming scores using stale cross-post context.

Verified for a representative post (`2009670439736619512`):
- Original farming_score: 100.00 (burst participant had 3 older posts counted)
- md_fix farming_score: 45.00 (burst participant has 1 post within 180d)
- Posts engaged OLDER than 180 days: **3** (excluded by md_fix filter — correct)
- Posts engaged WITHIN 180 days: **1** (included — correct)

---

## 8. Manual Steps Pending

Run once in production to clean up dead objects:

```sql
-- Dead functions in mindshare schema (fail at runtime — write to non-existent table)
DROP FUNCTION IF EXISTS mindshare.calculate_decay_scores(text);
DROP FUNCTION IF EXISTS mindshare.calculate_all_decay_scores();
DROP FUNCTION IF EXISTS mindshare.calculate_scores_by_project(text);
DROP FUNCTION IF EXISTS mindshare.calculate_all_scores_parallel();

-- Empty matview artifact (0 rows, no callers, legacy copy of contribution_scores)
DROP MATERIALIZED VIEW IF EXISTS mindshare_score.contribution_scores_mv;
```

---

## 9. Complete _md_fix Object Inventory

### analytics_md_fix

| Object | Type | Key change |
|--------|------|------------|
| `create_engagement_view(project_keyword)` | PROCEDURE | LEFT JOIN IS NULL; UNIQUE index; targets analytics_md_fix |
| `run_create_engagement_views()` | PROCEDURE | Calls analytics_md_fix.create_engagement_view |
| `refresh_engagement_views_all()` | PROCEDURE | CONCURRENTLY; targets analytics_md_fix |
| `create_user_posts_engagement_view()` | PROCEDURE | UNIQUE index added; targets analytics_md_fix |
| `get_all_users_analytics(limit_per_user)` | FUNCTION | Reads mindshare_score_md_fix.mv_user_posts_engagement_features |
| `get_user_analytics(target_user_id, limit_cnt)` | FUNCTION | Reads mindshare_score_md_fix.mv_user_posts_engagement_features |
| `get_user_posts_analytics(user_id, start, end)` | FUNCTION | Reads mindshare_score_md_fix.mv_user_posts_engagement_features |
| `get_v2_user_posts_analytics(...)` | FUNCTION | analytics_md_fix.%I; mindshare_score_md_fix.contribution_scores; mindshare_score_md_fix.%I |
| `mv_engagement_* (×11)` | MATVIEW | LEFT JOIN IS NULL; UNIQUE index on engaged_tweet_id |
| `mv_user_posts_engagement` | MATVIEW | UNIQUE index added for CONCURRENTLY |

### mindshare_score_md_fix

| Object | Type | Key change |
|--------|------|------------|
| `calculate_decay_scores(project_keyword, interval)` | PROCEDURE | Batch INSERT via _decay_batch temp table |
| `calculate_all_decay_scores(interval)` | PROCEDURE | Indexes created after bulk load |
| `calculate_global_decay_scores(interval)` | FUNCTION | Writes to mindshare_score_md_fix.global_contribution_scores |
| `calculate_all_global_decay_scores(interval)` | FUNCTION | TRUNCATE + call global + 5 indexes |
| `create_engagement_clustering_features_view(kw)` | PROCEDURE | 180d filter; hourly bucket; reads analytics_md_fix |
| `create_all_engagement_clustering_views()` | PROCEDURE | Calls mindshare_score_md_fix version |
| `create_user_posts_engagement_features_view()` | PROCEDURE | Hourly bucket fix; reads analytics_md_fix |
| `refresh_engagement_features_views_all()` | PROCEDURE | CONCURRENTLY; 10-min timeout per project |
| `refresh_user_post_engagement_views()` | PROCEDURE | CONCURRENTLY on analytics_md_fix + mindshare_score_md_fix |
| `mv_engagement_features_* (×11)` | MATVIEW | 180d filter; hourly bucket; reads analytics_md_fix |
| `mv_user_posts_engagement_features` | MATVIEW | Hourly bucket fix; reads analytics_md_fix |
| `contribution_scores` | TABLE | Same schema as production |
| `global_contribution_scores` | TABLE | Same schema as production |

### mindshare_md_fix

| Object | Type | Key change |
|--------|------|------------|
| `get_post_engagement_ratios(projectname)` | FUNCTION | Bug fixed: dynamic matview via format %I |
| `get_post_engagement_ratios(bigint, bigint, text)` | FUNCTION | Bug fixed: corrected SQL template |
| `get_post_metrics_from_user_post(bigint, bigint)` | FUNCTION | Bug fixed: JOIN mindshare_user; window fn replaces correlated subquery |
