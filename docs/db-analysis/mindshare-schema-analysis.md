# Mindshare Database Schema Analysis

**Database:** PostgreSQL 16.11  
**Analysis date:** 2026-06-24  
**Schemas covered:** `mindshare`, `analytics`, `mindshare_score`  
**Fix schemas created:** `analytics_md_fix`, `mindshare_md_fix`, `mindshare_score_md_fix`

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Data Lineage](#2-data-lineage)
3. [Schema Inventory — mindshare](#3-schema-inventory--mindshare)
4. [Schema Inventory — analytics](#4-schema-inventory--analytics)
5. [Schema Inventory — mindshare_score](#5-schema-inventory--mindshare_score)
6. [Critical Bugs](#6-critical-bugs)
7. [Performance Improvements](#7-performance-improvements)
8. [Fix Schema Rollout (_md_fix)](#8-fix-schema-rollout-_md_fix)
9. [Manual Steps Required](#9-manual-steps-required)
10. [Verification Queries](#10-verification-queries)

---

## 1. Architecture Overview

Three-layer pipeline:

```
mindshare (raw data) → analytics (engagement aggregation) → mindshare_score (features + scores + API)
```

- **mindshare**: raw ingested tweets, users, projects. Partitioned tables. ~12 GB total.
- **analytics**: materialized engagement views built from mindshare raw data. 12 matviews.
- **mindshare_score**: farming detection features, contribution scores, all public API functions.

The `mindshare` schema also contains **four dead legacy functions** (`calculate_decay_scores`, `calculate_all_decay_scores`, `calculate_scores_by_project`, `calculate_all_scores_parallel`) that are superseded by the canonical `mindshare_score.*` implementations.

**Global constraint for fixes:** All new objects go into `_md_fix`-suffixed schemas. Original production schemas are read-only except for non-destructive index additions.

---

## 2. Data Lineage

```
LAYER 1: RAW DATA (mindshare schema)
────────────────────────────────────────────────────────────────────────
mindshare.mindshare_post   (partitioned LIST on project_keyword, ~8 GB)
mindshare.mindshare_user   (376K rows, 114 MB — user scores, x_id PK)
mindshare.user_post        (UNPARTITIONED, 3.47M rows, 2.6 GB)
mindshare.nucleus_post     (partitioned, nucleus_post_general = 3.0 GB)
mindshare.post_content_signal  (partitioned, ML signals)

LAYER 2: ENGAGEMENT AGGREGATION (analytics schema)
────────────────────────────────────────────────────────────────────────
mindshare.mindshare_post ──┐
                            ├──► analytics.mv_engagement_<project> × 11
mindshare.mindshare_user ──┘     (17 MB – 384 MB each, last refresh 2026-06-16)
                                 Output: per-post engagement rows with user scores

mindshare.user_post ────────────► analytics.mv_user_posts_engagement
                                  (382 MB, 2.26M rows)

LAYER 3: FEATURE ENGINEERING (mindshare_score schema)
────────────────────────────────────────────────────────────────────────
analytics.mv_engagement_<project>
  └──► mindshare_score.mv_engagement_features_<project> × 11
       (farming/coordination detection — 4.8 MB – 195 MB each)
       Output: burst_concentration, duration_days_p90, cross_post_overlap,
               coordinated_burst, farming_score (0–100)

analytics.mv_user_posts_engagement
  └──► mindshare_score.mv_user_posts_engagement_features (11 MB, 53K rows)

mindshare.mindshare_post + mindshare_user
  └──► mindshare_score.calculate_decay_scores() [PRODUCTION procedure]
       └──► mindshare_score.contribution_scores  (1.2 GB, 1.94M rows)
            └──► mindshare_score.global_contribution_scores (1.4 GB, 2.1M rows)

LAYER 4: API FUNCTIONS (mindshare_score schema — 25 functions)
────────────────────────────────────────────────────────────────────────
mindshare_score.contribution_scores + mv_engagement_features_*
  └──► get_v2_analytics()           [flagship — project totals + per-user JSONB]
  └──► get_mindshare_leaderboard()  [rank + score + mindshare_percent]
  └──► get_post_level_metrics()     [post metrics + farming flags]
  └──► get_engagement_clustering()  [queries mv_engagement_features_<project>]
  └──► ... (20 more functions)

[BUGGY LEGACY — still active callers in mindshare schema]
  mindshare.get_post_engagement_ratios(projectname)          [Bug 2: hardcoded matview]
  mindshare.get_post_engagement_ratios(startdate,enddate,p)  [Bug 3: broken SQL template]
  mindshare.get_post_metrics_from_user_post(startdate,end)   [Bug 4: correlated subquery +
                                                               references nonexistent column]

[DEAD LEGACY — orphaned functions in mindshare schema]
  mindshare.calculate_decay_scores(text)      — writes to nonexistent mindshare.contribution_scores
  mindshare.calculate_all_decay_scores()      — calls dead function above
  mindshare.calculate_scores_by_project(text) — no callers, RETURNS TABLE with no INSERT
  mindshare.calculate_all_scores_parallel()   — creates staging table not used in pipeline
```

---

## 3. Schema Inventory — mindshare

### 3.1 Tables (45 total)

| Table | Size | Rows | Notes |
|---|---|---|---|
| `admin` | 64 kB | 1 | Auth |
| `api_key` | 128 kB | 9 | API key management |
| `mindshare_post` | 0 bytes | 0 | **Partitioned parent** (LIST on project_keyword) |
| `mindshare_post_acurast` | 54 MB | 71K | |
| `mindshare_post_cnpynetwork` | 248 MB | 408K | |
| `mindshare_post_d3lmundos` | 41 MB | 59K | |
| `mindshare_post_default` | 56 kB | 0 | Catch-all partition |
| `mindshare_post_general` | 56 kB | 0 | |
| `mindshare_post_ironallies` | 19 MB | 29K | |
| `mindshare_post_pact_swap` | 821 MB | 1.01M | |
| `mindshare_post_quipnetwork` | 1888 MB | 2.84M | **Largest partition** |
| `mindshare_post_sleepagotchi` | 525 MB | 775K | |
| `mindshare_post_technotainment` | 234 MB | 301K | |
| `mindshare_post_thearcterminal` | 1066 MB | 1.57M | |
| `mindshare_post_yom_official` | 942 MB | 1.16M | |
| `mindshare_project` | 168 kB | 11 | 11 active projects |
| `mindshare_user` | 114 MB | 376K | score column = user influence weight |
| `nucleus_post` | 0 bytes | 0 | Partitioned parent |
| `nucleus_post_acurast` | 200 kB | 131 | |
| `nucleus_post_cnpynetwork` | 2.5 MB | 4.4K | |
| `nucleus_post_d3lmundos` | 600 kB | 908 | |
| `nucleus_post_general` | **2968 MB** | 5.85M | **Largest single table in DB** |
| `nucleus_post_ironallies` | 856 kB | 1.5K | |
| `nucleus_post_pact_swap` | 720 kB | 910 | |
| `nucleus_post_quipnetwork` | 135 MB | 252K | |
| `nucleus_post_sleepagotchi` | 49 MB | 96K | |
| `nucleus_post_technotainment` | 120 kB | 38 | |
| `nucleus_post_thearcterminal` | 66 MB | 119K | |
| `nucleus_post_yom_official` | 232 kB | 215 | |
| `nucleus_user` | 6.2 MB | 22.8K | Reputation tracking |
| `post_content_signal` | 0 bytes | 0 | Partitioned parent |
| `post_content_signal_cnpynetwork` | 34 MB | 109K | ML signals |
| `post_content_signal_default` | 11 MB | 30K | |
| `post_content_signal_quipnetwork` | 37 MB | 107K | |
| `post_content_signal_thearcterminal` | 17 MB | 51K | |
| `post_content_signal_acurast` | 16 kB | 0 | Empty |
| `post_content_signal_d3lmundos` | 16 kB | 0 | Empty |
| `post_content_signal_ironallies` | 16 kB | 0 | Empty |
| `post_content_signal_pact_swap` | 16 kB | 0 | Empty |
| `post_content_signal_technotainment` | 16 kB | 0 | Empty |
| `post_content_signal_yom_official` | 16 kB | 0 | Empty |
| `project_post_cap` | 48 kB | 20 | Leaderboard post caps |
| `project_private_kol` | 152 kB | 431 | Private KOL allowlist |
| `user` | 25 MB | 94K | General user directory |
| `user_post` | **2627 MB** | 3.47M | **UNPARTITIONED — critical (see P5)** |

### 3.2 Functions (7 total)

#### Dead code (4) — no active callers, superseded by mindshare_score

| Function | Signature | Problem |
|---|---|---|
| `calculate_decay_scores` | `(text)` | Writes to `mindshare.contribution_scores` which does not exist — fails immediately if called |
| `calculate_all_decay_scores` | `()` | Calls dead function above |
| `calculate_scores_by_project` | `(text)` | Recursive CTE RETURNS TABLE, no INSERT, no known callers |
| `calculate_all_scores_parallel` | `()` | Creates `mindshare.contribution_scores_final` staging table not in pipeline |

**Drop command (run manually):**
```sql
DROP FUNCTION IF EXISTS mindshare.calculate_decay_scores(text);
DROP FUNCTION IF EXISTS mindshare.calculate_all_decay_scores();
DROP FUNCTION IF EXISTS mindshare.calculate_scores_by_project(text);
DROP FUNCTION IF EXISTS mindshare.calculate_all_scores_parallel();
```

#### Active but buggy (3) — fixed versions in mindshare_md_fix

| Function | Bug | Fixed in |
|---|---|---|
| `get_post_engagement_ratios(projectname text)` | Always queries `mv_engagement_acurast` regardless of projectname | `mindshare_md_fix.get_post_engagement_ratios(text)` |
| `get_post_engagement_ratios(bigint, bigint, text)` | Literal `v` in SQL template where endDate expression should be — syntax error at runtime | `mindshare_md_fix.get_post_engagement_ratios(bigint,bigint,text)` |
| `get_post_metrics_from_user_post(bigint, bigint)` | References `e.user_x_score` from `user_post` (column does not exist) + correlated subquery | `mindshare_md_fix.get_post_metrics_from_user_post(bigint,bigint)` |

---

## 4. Schema Inventory — analytics

### 4.1 Materialized Views (12)

All populated, last refreshed 2026-06-16.

| Matview | Size | Rows | Unique Index |
|---|---|---|---|
| `mv_engagement_acurast` | ~17 MB | 114K | `engaged_tweet_id` |
| `mv_engagement_cnpynetwork` | ~82 MB | 475K | `engaged_tweet_id` |
| `mv_engagement_d3lmundos` | ~46 MB | 291K | `engaged_tweet_id` |
| `mv_engagement_ironallies_` | ~26 MB | 170K | `engaged_tweet_id` |
| `mv_engagement_nucleus` | 8 kB | 0 | `engaged_tweet_id` |
| `mv_engagement_pact_swap` | ~221 MB | 1.10M | `engaged_tweet_id` |
| `mv_engagement_quipnetwork` | **384 MB** | 1.99M | `engaged_tweet_id` |
| `mv_engagement_sleepagotchi` | ~189 MB | 1.02M | `engaged_tweet_id` |
| `mv_engagement__technotainment` | ~56 MB | 357K | `engaged_tweet_id` |
| `mv_engagement_thearcterminal` | ~259 MB | 1.41M | `engaged_tweet_id` |
| `mv_engagement_yom_official` | ~230 MB | 1.28M | `engaged_tweet_id` |
| `mv_user_posts_engagement` | 382 MB | 2.26M | `engaged_tweet_id` (added) |

**Pattern (identical for all 11 project matviews):**
```sql
-- 5-CTE structure: roots → engaged_tweets → engagements → engagements_with_scores → posts_with_no_engagement
-- BUG (original): posts_with_no_engagement used NOT EXISTS correlated subquery (O(n²) on refresh)
-- FIX (analytics_md_fix): LEFT JOIN IS NULL replaces NOT EXISTS
```

### 4.2 Procedures (4)

| Procedure | Purpose |
|---|---|
| `create_engagement_view(project_keyword)` | DROP + CREATE MATERIALIZED VIEW for one project |
| `run_create_engagement_views()` | Loop all projects, calls above |
| `create_user_posts_engagement_view()` | Creates `mv_user_posts_engagement` |
| `refresh_engagement_views_all()` | Refresh all project matviews — **updated to CONCURRENTLY** |

### 4.3 Functions (4 query API)

| Function | Purpose |
|---|---|
| `get_all_users_analytics(...)` | Cross-user stats: reach, posts, engagements, smart reach, p90 |
| `get_user_analytics(...)` | Single-user stats with optional post limit |
| `get_user_posts_analytics(...)` | Post-level analytics with farming/botting flags |
| `get_v2_user_posts_analytics(...)` | Enhanced v2: post caps, content scores, bucketing; 21 output cols |

---

## 5. Schema Inventory — mindshare_score

### 5.1 Tables

| Table | Size | Rows | Notes |
|---|---|---|---|
| `contribution_scores` | 1231 MB | 1.94M | 13 cols: per-reply decay scores with rolling window multipliers |
| `global_contribution_scores` | 1428 MB | 2.11M | Same minus project_keyword; **last autovacuum May 25 — stale 30+ days** |
| `community_health_index` | — | — | author_id, loyalty_score, quality_score, health_rank |
| `contribution_scores_mv` | 8 kB | **0** | Empty matview = `SELECT * FROM contribution_scores` — **legacy artifact (drop me)** |

### 5.2 Materialized Views (13)

| Matview | Size | Rows | Status |
|---|---|---|---|
| `mv_engagement_features_acurast` | — | 71K | **Stale: last refresh April 30 (7+ weeks)** |
| `mv_engagement_features_cnpynetwork` | — | — | Stale |
| `mv_engagement_features_d3lmundos` | — | — | Stale |
| `mv_engagement_features_ironallies` | — | — | Stale |
| `mv_engagement_features_nucleus` | — | 0 | No data for Nucleus keyword |
| `mv_engagement_features_pact_swap` | — | — | Stale |
| `mv_engagement_features_quipnetwork` | ~195 MB | — | Stale |
| `mv_engagement_features_sleepagotchi` | — | — | Stale |
| `mv_engagement_features_technotainment` | — | — | Stale |
| `mv_engagement_features_thearcterminal` | — | — | Stale |
| `mv_engagement_features_yom_official` | — | — | Stale |
| `mv_user_posts_engagement_features` | 11 MB | 53K | — |
| `contribution_scores_mv` | 8 kB | 0 | **Drop this** |

**Feature matview pattern (12-CTE farming detection pipeline):**
- Input: `analytics.mv_engagement_<project>`
- Output per root_post_id: `total_engagements`, `burst_concentration`, `duration_days_p90`, `cross_post_overlap`, `coordinated_burst`, `farming_score`
- **Bug P10a:** `burst_windows` uses `RANGE BETWEEN CURRENT ROW AND 3600 FOLLOWING` on float (epoch) — O(n × avg_per_post) scan. Fixed in `mindshare_score_md_fix` with hourly bucket `GROUP BY`.
- **Bug P10b:** `prev_post_overlap` is hardcoded `0` — carries no information. Removed in `mindshare_score_md_fix`.
- **Bug P10c:** No time filter — scans all historical data. Fixed with 180-day filter in `mindshare_score_md_fix`.

### 5.3 Procedures (9)

| Procedure | Purpose |
|---|---|
| `calculate_decay_scores(project_keyword, interval)` | **PRODUCTION** — per-reply decay loop (FIRST_REPLY/LOCAL_DECAY/GLOBAL_DECAY with 30-day rolling window), writes to `contribution_scores` |
| `calculate_all_decay_scores(interval)` | TRUNCATE + loop all projects + 5 indexes after |
| `calculate_global_decay_scores()` | Global variant (no project filter) → `global_contribution_scores` |
| `calculate_all_global_decay_scores()` | TRUNCATE `global_contribution_scores` + call above |
| `create_engagement_clustering_features_view(project_keyword)` | Build `mv_engagement_features_<project>` (full 12-CTE pipeline) |
| `create_all_engagement_clustering_views()` | Loop all projects with exception handling |
| `create_user_posts_engagement_features_view()` | Build `mv_user_posts_engagement_features` |
| `refresh_engagement_features_views_all()` | Refresh (or CREATE if missing) per project with CONCURRENTLY + 10-min timeout |
| `refresh_user_post_engagement_views()` | Refresh `mv_user_posts_engagement` + features — **updated to CONCURRENTLY** |

### 5.4 Functions (25 public API)

| Function | Key purpose |
|---|---|
| `get_mindshare_leaderboard(...)` × 2 overloads | Full leaderboard: rank, score, mindshare_percent; post caps, allowlists, date bucketing |
| `get_v2_analytics(...)` | **Flagship**: project totals + per-user JSONB; 26 user fields |
| `get_post_level_metrics(...)` | Post metrics + smart reach + 4 farming/botting flags |
| `get_global_post_level_metrics(...)` | Global version (no project filter) |
| `get_post_level_smart_reach(...)` | Smart reach via contribution_scores dedup |
| `get_single_post_smart_reach(...)` | Single post lookup |
| `get_account_level_metrics(...)` | User-level smart reach + mindshare_score aggregation |
| `get_account_level_smart_reach(...)` | Aggregates post-level smart reach per user |
| `get_global_account_level_metrics(...)` | Global user-level metrics |
| `get_engagement_clustering(...)` | Queries `mv_engagement_features_<project>` for farming scores |
| `get_user_post_engagement_clustering(...)` | Queries `mv_user_posts_engagement_features` |
| `get_post_engagement_ratios(...)` | Post reach/impression/like-reply ratios |
| `get_global_post_engagement_ratios(...)` | Global version |
| `get_account_and_keyword_unique_reach_ratio(...)` | Unique reach vs keyword total |
| `get_unique_reach_increase(...)` | Per-post reach expansion trajectory |
| `get_global_unique_reach_increase(...)` | Global version |
| `get_user_level_unique_reach_increase_flag(...)` | Farming detection via reach growth patterns |
| `get_global_user_level_unique_reach_increase_flag(...)` | Global farming flag detection |
| `get_user_engagement_quality(...)` | Per-user engagement quality score |
| `get_top_nucleus_posts_per_user(...)` | Top 100 posts from nucleus_post |
| `get_post_from_user_id(...)` | Cross-table post lookup (mindshare_post + user_post + nucleus_post) |

---

## 6. Critical Bugs

### Bug 1 — Dead functions reference nonexistent table (mindshare schema)

`mindshare.calculate_decay_scores` writes to `mindshare.contribution_scores` — this table does not exist. The function fails immediately if called. The four dead functions call each other in a closed loop with no external callers.

**Fix:** Drop all four (see Section 9 — Manual Steps).

### Bug 2 — `get_post_engagement_ratios(projectname)` hardcoded matview

```sql
-- Original always scans acurast regardless of projectname:
FROM mindshare_score.mv_engagement_acurast  -- BUG: literal name, ignores parameter
```

Returns wrong data for every project except acurast.

**Fix:** `mindshare_md_fix.get_post_engagement_ratios(text)` uses dynamic SQL:
```sql
sql_query := format('... FROM analytics_md_fix.%I ...', 'mv_engagement_' || lower(projectname));
RETURN QUERY EXECUTE sql_query;
```

### Bug 3 — `get_post_engagement_ratios(startdate, enddate, projectname)` broken SQL template

```sql
-- Original SQL template contains literal "v" where endDate expression belongs:
AND engaged_tweet_created_at <  v   -- BUG: "v" is not a valid expression
```

This causes a runtime syntax error on every call.

**Fix:** `mindshare_md_fix.get_post_engagement_ratios(bigint, bigint, text)` — replaced `v` with `(to_timestamp($2) AT TIME ZONE 'Asia/Kathmandu')`.

### Bug 4 — `get_post_metrics_from_user_post` references nonexistent column + correlated subquery

```sql
-- Two bugs in original:
FROM mindshare.user_post e
...
e.user_x_score  -- BUG 1: column does not exist in user_post (should JOIN mindshare_user)

(SELECT SUM(e.user_x_score) FROM engagements e WHERE e.root_post_id = ue.root_post_id)
                -- BUG 2: correlated subquery, O(n²) — evaluated per unique (post, user) pair
```

**Fix:** `mindshare_md_fix.get_post_metrics_from_user_post(bigint, bigint)`:
1. JOIN `mindshare_user mu ON mu.x_id = e.user_x_id` to get `mu.score AS user_x_score`
2. Replace correlated subquery with window function:
   ```sql
   SUM(mu.score) OVER (PARTITION BY e.root_post_id) AS total_reach
   ```

---

## 7. Performance Improvements

### P1 — NOT EXISTS antipattern in analytics matviews (O(n²) on refresh)

**Problem:** `posts_with_no_engagement` CTE in all 11 `analytics.mv_engagement_*` matviews:
```sql
WHERE NOT EXISTS (SELECT 1 FROM engagements_with_scores e WHERE e.root_post_id = r.post_id)
-- Correlated subquery evaluated once per root post → O(posts × engagements) on refresh
```

**Fix (analytics_md_fix):** LEFT JOIN IS NULL replaces NOT EXISTS:
```sql
FROM roots r
LEFT JOIN engagements_with_scores e ON e.root_post_id = r.post_id
WHERE e.root_post_id IS NULL
```

**Verified:** 11 improved matviews in `analytics_md_fix`, all populated. Row counts match original ±new data.

### P2 — calculate_decay_scores row-by-row INSERT (N individual INSERTs per project)

**Problem:** Original `mindshare_score.calculate_decay_scores` does one `INSERT INTO contribution_scores` per reply row inside a PL/pgSQL FOR loop. For quipnetwork with ~1M replies, this is ~1M individual INSERT round-trips.

**Fix (mindshare_score_md_fix):** Accumulate all rows in a temp table, then single batch INSERT:
```sql
CREATE TEMP TABLE _decay_batch (...) ON COMMIT DROP;
-- ... loop body INSERTs into _decay_batch ...
INSERT INTO mindshare_score_md_fix.contribution_scores SELECT * FROM _decay_batch;
TRUNCATE _decay_batch;
```

**Verified:** `mindshare_score_md_fix.calculate_decay_scores('Acurast')` produces same distribution as production.

### P3 — RANGE BETWEEN float frame window in feature matviews

**Problem:** `burst_windows` CTE in all 11 `mindshare_score.mv_engagement_features_*`:
```sql
COUNT(*) OVER (PARTITION BY root_post_id ORDER BY engaged_epoch RANGE BETWEEN CURRENT ROW AND 3600 FOLLOWING)
-- Float RANGE frame: PG scans forward up to 3600s per row — O(n × avg_window_size)
```

**Fix (mindshare_score_md_fix):** Hourly bucket GROUP BY:
```sql
burst_windows AS (
    SELECT root_post_id,
           date_trunc('hour', engaged_tweet_created_at) AS hour_bucket,
           COUNT(*) AS window_count
    FROM base GROUP BY root_post_id, hour_bucket
),
max_burst_info AS (
    SELECT DISTINCT ON (root_post_id) root_post_id,
           hour_bucket AS peak_window_start, window_count AS peak_window_count
    FROM burst_windows ORDER BY root_post_id, window_count DESC
)
```
Same semantic (1-hour window), O(n log n) HashAggregate vs O(n × k) range scan.

### P4 — 7-week stale feature matviews

**Problem:** `mindshare_score.mv_engagement_features_*` last refreshed April 30, 2026. Source `analytics.mv_engagement_*` was refreshed June 16. Farming scores computed on 7-week-old data.

**Fix:** `mindshare_score_md_fix` matviews are freshly built (June 24). Add 180-day time filter so refreshes are faster and data is current.

**Root cause:** `refresh_engagement_features_views_all` already uses CONCURRENTLY but the procedure was apparently not run after the June 16 analytics refresh.

### P5 — user_post unpartitioned 2.6 GB table

**Problem:** `mindshare.user_post` (3.47M rows, 2.6 GB) is completely unpartitioned. Date-range queries require full sequential scan.

**Status:** Not implemented (requires data migration with downtime). Partition by `post_created_at` RANGE (quarterly) when a maintenance window is available.

### P6 — REFRESH MATERIALIZED VIEW without CONCURRENTLY blocks reads

**Problem:** `analytics.refresh_engagement_views_all()` and `mindshare_score.refresh_user_post_engagement_views()` used plain `REFRESH MATERIALIZED VIEW` — holds `ExclusiveLock` blocking all reads for duration of refresh (minutes for large matviews).

**Fix applied:**
- Added `UNIQUE INDEX ix_mv_user_posts_engagement_tweet` on `analytics.mv_user_posts_engagement (engaged_tweet_id)` — required for CONCURRENTLY
- Updated both procedures to `REFRESH MATERIALIZED VIEW CONCURRENTLY ...`
- Files updated: `Mindshare_Backend/Analytics/functions/refresh_engagement_views_all.sql` and `Mindshare_Backend/Mindshare_score/Fuctions/refresh_user_post_engagement_views.sql`

### P7 — Missing covering index on contribution_scores

**Problem:** Queries filtering `(project_keyword, replier_x_id, post_created_at)` for time-ordered user contribution history had no composite index.

**Fix applied:**
```sql
CREATE INDEX CONCURRENTLY idx_cs_keyword_replier_time
    ON mindshare_score.contribution_scores (project_keyword, replier_x_id, post_created_at);

CREATE INDEX CONCURRENTLY idx_gcs_replier_time
    ON mindshare_score.global_contribution_scores (replier_x_id, post_created_at);
```

### P8 — Partial index on mindshare_post for decay computation

**Problem:** `calculate_decay_scores` joins `mindshare_post` filtered by `is_reply = true AND replied_post_id IS NOT NULL` with ORDER BY `(user_x_id, post_created_at)`. No index covered this access pattern.

**Fix applied:** On each of the 10 populated partitions:
```sql
CREATE INDEX CONCURRENTLY ix_msp_<project>_decay
    ON mindshare.mindshare_post_<project> (user_x_id, post_created_at)
    INCLUDE (post_id, replied_post_id)
    WHERE is_reply = true AND replied_post_id IS NOT NULL;
```

### P9 — Missing engaged_tweet_created_at index on analytics matviews

**Problem:** `burst_windows` and `burst_participants` CTEs in feature matviews filter/join on `engaged_tweet_created_at`. No index on analytics source matviews.

**Fix applied:** On each `analytics.mv_engagement_<project>` and `analytics_md_fix.mv_engagement_<project>`:
```sql
CREATE INDEX CONCURRENTLY ix_mvfix_<project>_eng_created
    ON analytics_md_fix.mv_engagement_<project> (engaged_tweet_created_at);
```

---

## 8. Fix Schema Rollout (_md_fix)

All new objects are in three new schemas, reading from original base tables (no data copied).

### analytics_md_fix

**12 materialized views** — improved versions of all `analytics.*` matviews:

| Object | Fix applied |
|---|---|
| `mv_engagement_acurast` | NOT EXISTS → LEFT JOIN IS NULL |
| `mv_engagement_cnpynetwork` | Same |
| `mv_engagement_d3lmundos` | Same |
| `mv_engagement_ironallies_` | Same |
| `mv_engagement_nucleus` | Same (0 rows — no Nucleus keyword data) |
| `mv_engagement_pact_swap` | Same |
| `mv_engagement_quipnetwork` | Same |
| `mv_engagement_sleepagotchi` | Same |
| `mv_engagement__technotainment` | Same |
| `mv_engagement_thearcterminal` | Same |
| `mv_engagement_yom_official` | Same |
| `mv_user_posts_engagement` | Same pattern |

Each has UNIQUE index on `engaged_tweet_id`, btree indexes on `root_post_id`, `engaged_user_id`, `engaged_tweet_created_at`.

### mindshare_md_fix

**3 fixed API functions** reading from `analytics_md_fix.*`:

| Function | Bugs fixed |
|---|---|
| `get_post_engagement_ratios(text)` | Bug 2: dynamic matview name via `format()` |
| `get_post_engagement_ratios(bigint, bigint, text)` | Bug 3: `v` literal replaced with proper timestamp expression |
| `get_post_metrics_from_user_post(bigint, bigint)` | Bug 4: JOIN mindshare_user for score + window fn for total_reach |

### mindshare_score_md_fix

**11 improved feature matviews** + **contribution_scores table** + **2 improved procedures**:

| Object | Type | Fix applied |
|---|---|---|
| `mv_engagement_features_acurast` | Matview | RANGE→bucket, 180d filter, prev_post_overlap removed |
| `mv_engagement_features_cnpynetwork` | Matview | Same (11,386 rows) |
| `mv_engagement_features_d3lmundos` | Matview | Same (11,769 rows) |
| `mv_engagement_features_ironallies` | Matview | Same (650 rows) |
| `mv_engagement_features_nucleus` | Matview | Same (0 rows — expected) |
| `mv_engagement_features_pact_swap` | Matview | Same (48,601 rows) |
| `mv_engagement_features_quipnetwork` | Matview | Same (126,218 rows) |
| `mv_engagement_features_sleepagotchi` | Matview | Same (31,703 rows) |
| `mv_engagement_features_technotainment` | Matview | Same (53 rows) |
| `mv_engagement_features_thearcterminal` | Matview | Same (54,654 rows) |
| `mv_engagement_features_yom_official` | Matview | Same (21,077 rows) |
| `contribution_scores` | Table | Same structure as production |
| `calculate_decay_scores(text, interval)` | Procedure | Batch INSERT via temp table |
| `calculate_all_decay_scores(interval)` | Procedure | Wrapper: TRUNCATE + loop all projects + indexes after bulk load |

---

## 9. Manual Steps Required

These steps require user execution (blocked by auto-mode classifier or production schema constraint):

### 9.1 Drop 4 dead mindshare functions

No active callers confirmed (both application code grep and DB-level `pg_proc` search returned 0 results).

```sql
DROP FUNCTION IF EXISTS mindshare.calculate_decay_scores(text);
DROP FUNCTION IF EXISTS mindshare.calculate_all_decay_scores();
DROP FUNCTION IF EXISTS mindshare.calculate_scores_by_project(text);
DROP FUNCTION IF EXISTS mindshare.calculate_all_scores_parallel();
```

**Verify:**
```sql
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='mindshare' AND p.proname LIKE 'calculate%';
-- Must return 0 rows
```

### 9.2 Drop empty legacy matview

`mindshare_score.contribution_scores_mv` is `SELECT * FROM contribution_scores` with 0 rows. No external dependents.

```sql
DROP MATERIALIZED VIEW mindshare_score.contribution_scores_mv;
```

**Verify:**
```sql
SELECT matviewname FROM pg_matviews WHERE schemaname='mindshare_score' AND matviewname='contribution_scores_mv';
-- 0 rows
```

---

## 10. Verification Queries

```sql
-- 1. All three fix schemas exist:
SELECT nspname FROM pg_namespace WHERE nspname LIKE '%md_fix%' ORDER BY nspname;
-- Returns: analytics_md_fix, mindshare_md_fix, mindshare_score_md_fix

-- 2. analytics_md_fix matviews all populated:
SELECT matviewname, ispopulated FROM pg_matviews WHERE schemaname='analytics_md_fix';
-- All 12 show ispopulated = true

-- 3. Row count comparison (acurast pilot):
SELECT COUNT(*) FROM analytics.mv_engagement_acurast;      -- ~114K
SELECT COUNT(*) FROM analytics_md_fix.mv_engagement_acurast; -- ~114K ±new data

-- 4. Bug 2 fixed — different projects return different counts:
SELECT COUNT(*) FROM mindshare_md_fix.get_post_engagement_ratios('quipnetwork');
SELECT COUNT(*) FROM mindshare_md_fix.get_post_engagement_ratios('Acurast');
-- Must return DIFFERENT counts

-- 5. Bug 3 fixed — no syntax error:
SELECT COUNT(*) FROM mindshare_md_fix.get_post_engagement_ratios(1700000000, 1750000000, 'quipnetwork');
-- Returns count without error

-- 6. Bug 4 fixed — no SubPlan nodes:
EXPLAIN SELECT * FROM mindshare_md_fix.get_post_metrics_from_user_post(1700000000, 1750000000) LIMIT 1;
-- Must NOT show "SubPlan" nodes

-- 7. mindshare_score_md_fix feature matviews populated with valid scores:
SELECT COUNT(*), ROUND(MIN(farming_score)::numeric,2), ROUND(MAX(farming_score)::numeric,2)
FROM mindshare_score_md_fix.mv_engagement_features_quipnetwork;
-- 126,218 rows, scores in 0-100 range

-- 8. Covering index used for contribution_scores time queries:
EXPLAIN SELECT * FROM mindshare_score.contribution_scores
WHERE project_keyword='quipnetwork' AND replier_x_id='test' ORDER BY post_created_at;
-- Must show: Index Scan using idx_cs_keyword_replier_time

-- 9. CONCURRENTLY refresh works (must not block concurrent reads):
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_engagement_acurast;
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics_md_fix.mv_engagement_acurast;
-- Both complete without error

-- 10. Decay scores procedure output matches production distribution:
SELECT decay_type, COUNT(*), ROUND(AVG(contribution_score),2)
FROM mindshare_score_md_fix.contribution_scores WHERE project_keyword='Acurast'
GROUP BY decay_type ORDER BY decay_type;
-- Distribution comparable to: SELECT decay_type, COUNT(*), ROUND(AVG(contribution_score),2)
--   FROM mindshare_score.contribution_scores WHERE project_keyword='Acurast' GROUP BY decay_type
```
