# Mindshare DB: Schema Analysis, Lineage & Performance Optimization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Audit and optimize `mindshare`, `mindshare_score`, and `analytics` schemas — document full lineage, fix critical bugs, and improve function/matview performance.

**Architecture:** Three-layer pipeline: `mindshare` (raw data) → `analytics` (engagement matviews) → `mindshare_score` (derived features + contribution scores + all production API functions). The `mindshare` schema contains orphaned legacy function duplicates that are superseded by the canonical `mindshare_score` implementations.

**Tech Stack:** PostgreSQL 14+, PL/pgSQL, partitioned tables (LIST), materialized views, window functions.

## Global Constraints

- **ZERO PRODUCTION MODIFICATIONS:** All new matviews, functions, and stored procedures are created in `_md_fix`-prefixed schemas — never in the original schemas
- Three new schemas to create: `analytics_md_fix`, `mindshare_score_md_fix`, `mindshare_md_fix`
- All `_md_fix` objects read from ORIGINAL base tables (`mindshare.*`) — never copy raw data
- `analytics_md_fix.mv_engagement_*` reads from `mindshare.mindshare_post` + `mindshare.mindshare_user` (same sources as original)
- `mindshare_score_md_fix.mv_engagement_features_*` reads from `analytics_md_fix.mv_engagement_*` (improved version)
- `mindshare_score_md_fix.calculate_decay_scores` writes to `mindshare_score_md_fix.contribution_scores` (new table, not original)
- Exception: **indexes on original tables are allowed** — adding an index is non-destructive and transparent to callers
- Exception: **DROP of confirmed dead functions** from `mindshare` schema is allowed after caller verification
- No DROP of `mindshare_score.contribution_scores` or `mindshare_score.global_contribution_scores` — production tables, untouched
- `REFRESH MATERIALIZED VIEW CONCURRENTLY` requires a UNIQUE index — already present on all `analytics.mv_engagement_*` views
- All index creation must use `CONCURRENTLY` to avoid table locks in production
- Verify with `EXPLAIN (ANALYZE, BUFFERS)` before and after each change
- Document every finding in `docs/db-analysis/mindshare-schema-analysis.md`

---

## SCHEMA INVENTORY (findings from live DB)

### mindshare schema — raw data layer

**ALL 45 tables:**
| Table | Size | Rows | Notes |
|---|---|---|---|
| `admin` | 64 kB | 1 | Auth |
| `api_key` | 128 kB | 9 | API key management |
| `mindshare_post` | 0 bytes | 0 | Partitioned parent (LIST on project_keyword) |
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
| `mindshare_user` | 114 MB | 376K | User scores (x_id PK) |
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
| `project_post_cap` | 48 kB | 20 | Leaderboard caps |
| `project_private_kol` | 152 kB | 431 | Private KOL allowlist |
| `user` | 25 MB | 94K | General user directory |
| `user_post` | **2627 MB** | 3.47M | **UNPARTITIONED — critical** |

**Functions (7) — two categories:**

**DEAD CODE (4) — superseded by `mindshare_score` schema canonical versions:**
| Function | Status | Why dead |
|---|---|---|
| `calculate_decay_scores(project_keyword)` | **DROP candidate** | Writes to `mindshare.contribution_scores` (does not exist); `mindshare_score.calculate_decay_scores` is the live production procedure |
| `calculate_all_decay_scores()` | **DROP candidate** | Calls dead function above; `mindshare_score.calculate_all_decay_scores` is production |
| `calculate_scores_by_project(project_keyword)` | **DEAD** | Recursive CTE RETURNS TABLE, no insert, no known production caller |
| `calculate_all_scores_parallel()` | **DEAD** | Creates `mindshare.contribution_scores_final` staging table not used in pipeline |

**ACTIVE (3) — still called by API (no mindshare_score equivalent):**
| Function | Issue |
|---|---|
| `get_post_engagement_ratios(projectname)` | **BUG: hardcoded to `mv_engagement_acurast`** |
| `get_post_engagement_ratios(startdate, enddate, projectname)` | **BUG: `v` literal in SQL template** |
| `get_post_metrics_from_user_post(startdate, enddate)` | **PERF: correlated subquery** |

### analytics schema — engagement aggregation layer

**12 materialized views** — all populated, last refreshed ~2026-06-16:
- `mv_engagement_<project>` × 11 (17 MB – 384 MB each) — identical 5-CTE pattern, created by `create_engagement_view` procedure
- `mv_user_posts_engagement` (382 MB, 2.26M rows)

**4 procedures:**
| Procedure | Purpose |
|---|---|
| `create_engagement_view(project_keyword)` | DROP + CREATE MATERIALIZED VIEW for one project; creates 3 indexes |
| `run_create_engagement_views()` | Loops all projects, calls `create_engagement_view` per project |
| `create_user_posts_engagement_view()` | Creates `mv_user_posts_engagement` |
| `refresh_engagement_views_all()` | Loops all projects, REFRESH MATERIALIZED VIEW per project (no CONCURRENTLY) |

**6 functions:**
| Function | Purpose |
|---|---|
| `get_all_users_analytics(...)` | Cross-user stats: reach, posts, engagements, smart reach, p90 |
| `get_user_analytics(...)` | Single-user stats with optional post limit |
| `get_user_posts_analytics(...)` | Post-level analytics with farming/botting flags |
| `get_v2_user_posts_analytics(...)` | Enhanced v2: post caps, content scores, bucketing; 21 output cols |

### mindshare_score schema — derived scores + API layer

**Tables:**
| Table | Size | Rows | Notes |
|---|---|---|---|
| `contribution_scores` | 1231 MB | 1.94M | 13 cols: project_keyword, reply_post_id, replier_x_id, original_post_id, original_author_x_id, post_created_at, replier_base_score, effective_score, contribution_score, active_multipliers[], reply_number, local_reply_count, decay_type |
| `global_contribution_scores` | 1428 MB | 2.11M | Same minus project_keyword; last autovacuum May 25 — **STALE 3+ weeks** |
| `community_health_index` | — | — | author_id, unique_fans, loyalty_score, quality_score, efficiency_score, smart_unique_ratio, health_rank |
| `contribution_scores_mv` | 8 kB | 0 | Empty matview = `SELECT * FROM contribution_scores` — legacy artifact |

**13 materialized views:**
- `mv_engagement_features_<project>` × 11 — farming/coordination scoring; **last refresh April 30 (7 weeks stale)**
- `mv_user_posts_engagement_features` (11 MB, 53K rows)
- `contribution_scores_mv` (empty)

**9 procedures (production orchestration):**
| Procedure | Purpose |
|---|---|
| `calculate_decay_scores(project_keyword)` | Core decay loop: FIRST_REPLY/LOCAL_DECAY/GLOBAL_DECAY with 30-day rolling window; writes to `mindshare_score.contribution_scores` |
| `calculate_all_decay_scores()` | TRUNCATE + loop per project calling above + 5 indexes after |
| `calculate_global_decay_scores()` | Global variant (no project filter); writes to `global_contribution_scores` |
| `calculate_all_global_decay_scores()` | TRUNCATE `global_contribution_scores` + call above + 5 indexes |
| `create_engagement_clustering_features_view(project_keyword)` | BUILD `mv_engagement_features_<project>` with full 12-CTE farming score pipeline |
| `create_all_engagement_clustering_views()` | Loops all projects + exception handling |
| `create_user_posts_engagement_features_view()` | Builds `mv_user_posts_engagement_features` |
| `refresh_engagement_features_views_all()` | Loops all projects; REFRESH (or CREATE if missing) per project, 10-min timeout per project |
| `refresh_user_post_engagement_views()` | Refreshes `mv_user_posts_engagement` + features matview |

**25 functions (public API):**
| Function | Key purpose |
|---|---|
| `get_mindshare_leaderboard(...)` × 2 overloads | Full leaderboard with post caps, allowlist, date bucketing; returns rank, score, mindshare_percent |
| `get_v2_analytics(...)` | **Flagship**: project totals + per-user JSONB; supports post capping, allowlists, 26 user fields |
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

## DATA LINEAGE

```
LAYER 1: RAW DATA (mindshare schema)
─────────────────────────────────────────────────────────────────────────
mindshare.mindshare_post  (partitioned by project_keyword, ~8 GB total)
mindshare.mindshare_user  (376K rows, 114 MB)
mindshare.user_post       (UNPARTITIONED, 3.5M rows, 2.6 GB)
mindshare.nucleus_post    (partitioned, nucleus_post_general = 3.0 GB)
mindshare.post_content_signal  (partitioned, ML signals)

LAYER 2: ENGAGEMENT AGGREGATION (analytics schema)
─────────────────────────────────────────────────────────────────────────
mindshare.mindshare_post ──┐
                            ├── DOUBLE SCAN + LEFT JOIN mindshare_user
mindshare.mindshare_user ──┘
  └─► analytics.mv_engagement_<project>  × 11  (17 MB – 384 MB each)
       Output: per-post engagement rows (root_post_id, engaged_user_id,
               root/engaged metadata, engaged_user_score)

mindshare.user_post
  └─► analytics.mv_user_posts_engagement  (382 MB, 2.26M rows)
       Output: global user post engagement data

LAYER 3: FEATURE ENGINEERING (mindshare_score schema)
─────────────────────────────────────────────────────────────────────────
analytics.mv_engagement_<project>
  └─► mindshare_score.mv_engagement_features_<project>  × 11  (4.8 MB – 195 MB each)
       [12-CTE pipeline: burst_windows, burst_participants, author_burst_recurrence,
        post_coordination, ranked_post_order, user_engagement_history, post_overlap_metrics]
       Output per post_id:
         total_engagements, burst_concentration, duration_days_p90,
         cross_post_overlap, coordinated_burst, farming_score

analytics.mv_user_posts_engagement
  └─► mindshare_score.mv_user_posts_engagement_features (11 MB, 53K rows)
       Output: user-level engagement features

mindshare.mindshare_post + mindshare_user ──►  mindshare_score.calculate_decay_scores()  [PRODUCTION]
  └─► mindshare_score.contribution_scores  (1.2 GB, 1.94M rows)
       [per-reply contribution scores with LOCAL_DECAY / GLOBAL_DECAY]
       └─► mindshare_score.global_contribution_scores  (1.4 GB, 2.1M rows)  [via calculate_global_decay_scores()]

  [DEAD] mindshare.calculate_decay_scores() — orphaned legacy, writes to nonexistent mindshare.contribution_scores

LAYER 4: API FUNCTIONS
─────────────────────────────────────────────────────────────────────────
mindshare_score.contribution_scores + mv_engagement_features_* ──►  mindshare_score.get_v2_analytics()  [flagship]
mindshare_score.contribution_scores ──────────────────────────────►  mindshare_score.get_mindshare_leaderboard()
mindshare_score.mv_engagement_features_<project> ─────────────────►  mindshare_score.get_engagement_clustering()

[BUGGY — still active callers] mindshare schema functions:
  mindshare_score.mv_engagement_features_*  [BUG: hardcoded to acurast]
    └─► mindshare.get_post_engagement_ratios(projectname)
  mindshare_score.mv_engagement_<project>  [via dynamic SQL, BUG: broken template]
    └─► mindshare.get_post_engagement_ratios(startdate, enddate, projectname)
  mindshare.user_post  [full table scan — unpartitioned]
    └─► mindshare.get_post_metrics_from_user_post(startdate, enddate)  [BUG: correlated subquery]
```

**Key observations:**
- mindshare_score matviews are 2 hops downstream of raw data (mindshare → analytics → mindshare_score)
- A refresh of mindshare_post data requires refreshing ALL three layers in order
- `mv_engagement_features_*` are currently 7 weeks stale — analytics updated June 16, features still April 30
- `farming_score` is computed in mindshare_score layer, NOT stored in contribution_scores
- `contribution_scores` and `global_contribution_scores` are populated by functions, NOT by matview refresh

---

## CRITICAL BUGS (must fix before performance work)

### Bug 1: `mindshare.calculate_decay_scores` and `mindshare.calculate_all_decay_scores` — dead code
- **Files:** `mindshare.calculate_decay_scores()`, `mindshare.calculate_all_decay_scores()`
- **Problem:** These are outdated duplicates of the production functions in `mindshare_score`. They write to `mindshare.contribution_scores` which does not exist. They would fail immediately if called. The canonical versions in `mindshare_score` schema are the correct, updated implementations.
- **Fix:** Confirm no active callers (application code, cron jobs, other functions) reference `mindshare.calculate_decay_scores` or `mindshare.calculate_all_decay_scores`, then DROP both:
  ```sql
  DROP FUNCTION IF EXISTS mindshare.calculate_decay_scores(text);
  DROP FUNCTION IF EXISTS mindshare.calculate_all_decay_scores();
  DROP FUNCTION IF EXISTS mindshare.calculate_scores_by_project(text);
  DROP FUNCTION IF EXISTS mindshare.calculate_all_scores_parallel();
  ```
- **Verify:** `SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='mindshare' AND p.proname LIKE 'calculate%';` must return 0 rows after drop.

### Bug 2: `get_post_engagement_ratios(projectname)` — hardcoded matview
- **File:** `mindshare.get_post_engagement_ratios(projectname text)`
- **Problem:** Always queries `mindshare_score.mv_engagement_acurast` regardless of `projectname` parameter. Returns wrong data for every non-Acurast project.
- **Fix:** Replace hardcoded `FROM mindshare_score.mv_engagement_acurast` with dynamic SQL using `format($q$ FROM mindshare_score.%I $q$, 'mv_engagement_' || lower(projectname))` pattern — same as the 3-param overload.
- **Verify:** `SELECT COUNT(*) FROM mindshare.get_post_engagement_ratios('quipnetwork')` must return quipnetwork data, not acurast data.

### Bug 3: `get_post_engagement_ratios(startdate, enddate, projectname)` — broken SQL template
- **File:** `mindshare.get_post_engagement_ratios(bigint, bigint, text)`
- **Problem:** SQL template contains `<  v` where the endDate expression should be `(to_timestamp($2) AT TIME ZONE 'Asia/Kathmandu')`. The `v` is a leftover artifact — this SQL would syntax-error at runtime.
- **Fix:** Replace `<  v` with `< (to_timestamp($2) AT TIME ZONE 'Asia/Kathmandu')` in the format string.
- **Verify:** Call with sample timestamps: `SELECT * FROM mindshare.get_post_engagement_ratios(1700000000, 1750000000, 'quipnetwork') LIMIT 5;` — must return rows without error.

---

## PERFORMANCE IMPROVEMENTS

### P1: analytics.mv_engagement_* — double scan + NOT EXISTS antipattern

**Problem:** Each matview scans `mindshare.mindshare_post` **twice** with the same `project_keyword` filter:
1. `roots` CTE: full row scan + LEFT JOIN mindshare_user
2. `engaged_tweets` CTE: second scan for replied/quoted posts

The `posts_with_no_engagement` CTE uses `NOT EXISTS (SELECT 1 FROM engagements_with_scores e WHERE e.root_post_id = r.post_id)` — a correlated subquery evaluated once per root post. For quipnetwork with 2.84M posts this is catastrophic during refresh.

**Fix:** Replace `NOT EXISTS` with `LEFT JOIN ... IS NULL`:
```sql
-- Replace posts_with_no_engagement CTE:
posts_with_no_engagement AS (
    SELECT r.post_id AS root_post_id, ..., NULL::text AS engaged_tweet_id, ...
    FROM roots r
    LEFT JOIN engagements_with_scores e ON e.root_post_id = r.post_id
    WHERE e.root_post_id IS NULL
)
```
Also consolidate the two `mindshare_post` scans into one CTE that selects both root-eligible and engagement-eligible rows in a single pass.

**Verify:** `EXPLAIN (ANALYZE, BUFFERS) REFRESH MATERIALIZED VIEW analytics.mv_engagement_quipnetwork;` — compare total execution time and buffer hits before/after. Expected: elimination of one sequential scan per project (~50% I/O reduction on refresh).

### P2: `calculate_decay_scores` — row-by-row INSERT in PL/pgSQL loop

**Problem:** The function processes one row at a time:
- Per-row `INSERT INTO contribution_scores` inside a FOR loop (context switch overhead × N rows)
- `array_position(author_keys, rec.original_author_x_id)` is O(k) where k = unique authors seen so far — grows unbounded for prolific users
- For quipnetwork with ~2.84M posts (many replies): potentially millions of individual inserts

**Fix part 1 — batch insert:** Accumulate results into a temp variable array or temp table, then INSERT all at once:
```sql
-- Replace per-row INSERT with:
CREATE TEMP TABLE _decay_batch (LIKE mindshare_score.contribution_scores) ON COMMIT DROP;
-- ... loop body stores to _decay_batch ...
INSERT INTO mindshare_score.contribution_scores SELECT * FROM _decay_batch;
```

**Fix part 2 — use hstore for O(1) author lookup** (requires hstore extension):
```sql
author_counts hstore := ''::hstore;
-- Lookup: (author_counts -> rec.original_author_x_id)::int
-- Update: author_counts := author_counts || hstore(rec.original_author_x_id, (cnt+1)::text)
```
Without hstore: replace parallel arrays with a single `jsonb` variable for O(1) key lookup.

**Fix part 3 — add composite index** on mindshare_post for the join pattern used:
```sql
-- Current index covers (project_keyword, post_id) INCLUDE (user_x_id)
-- Need: (project_keyword, is_reply, user_x_id, post_created_at) for the ORDER BY
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_mindshare_post_decay_compute
  ON mindshare.mindshare_post (project_keyword, user_x_id, post_created_at)
  WHERE is_reply = true AND replied_post_id IS NOT NULL;
```

**Verify:** `EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM mindshare.calculate_decay_scores('Acurast');` — compare wall time before/after. Check `pg_stat_user_tables` for seq_scan count on mindshare_post_acurast before/after.

### P3: `calculate_scores_by_project` — RECURSIVE CTE depth = reply count per user

**Problem:** The recursive CTE chains via `reply_number = si.reply_number + 1`. For a user with 1000 replies, recursion depth = 1000. PostgreSQL evaluates recursive CTEs as iterative loops but with O(n²) join cost since each recursion level must join the full previous result set.

**Fix:** Replace recursive CTE with pure window-function approach for the scoring portion. The decay formula (FIRST_REPLY = base, LOCAL_DECAY = prev/2, GLOBAL_DECAY = prev-1) requires sequential access to prev_score — use `LAG()`:
```sql
WITH ordered_replies AS (
    SELECT ..., reply_number, local_reply_count,
        LAG(contribution_score) OVER (PARTITION BY project_keyword, replier_x_id ORDER BY post_created_at) AS prev_score
    FROM ...
)
-- Note: LAG on contribution_score itself won't work since it depends on prev row's computed value
-- Better: classify first, then use a single-pass iterative approach with generate_series or keep PL/pgSQL loop but batch-insert
```
The true fix is recognizing this is an inherently sequential computation (Markov chain on score). The optimal approach is the PL/pgSQL loop from `calculate_decay_scores` (correct algorithm) combined with batch INSERT.

**Verify:** Run both functions on the same project, compare output row counts: `SELECT COUNT(*) FROM mindshare.calculate_scores_by_project('Acurast');` vs `SELECT COUNT(*) FROM mindshare_score.contribution_scores WHERE project_keyword = 'Acurast';`

### P4: `get_post_metrics_from_user_post` — correlated subquery in aggregated CTE

**Problem:**
```sql
(SELECT SUM(e.user_x_score) FROM engagements e WHERE e.root_post_id = ue.root_post_id) AS reach
```
This is a correlated subquery inside an aggregation — executed once per unique (root_post_id, user_x_id) pair. With 2.26M rows in mv_user_posts_engagement, this executes millions of sub-selects.

**Fix:** Compute total reach as a window function in the `engagements` CTE before deduplication:
```sql
engagements AS (
    SELECT
        e.root_post_id, e.user_x_id, e.user_x_score, e.is_reply,
        SUM(e.user_x_score) OVER (PARTITION BY e.root_post_id) AS total_reach_all,
        CASE WHEN e.is_reply AND e.user_x_id = bp.handle THEN 1 ELSE 0 END AS is_self_reply
    FROM mindshare.user_post e
    JOIN base_posts bp ON bp.post_id = e.root_post_id
),
aggregated AS (
    WITH unique_engagements AS (
        SELECT DISTINCT ON (root_post_id, user_x_id) * 
        FROM engagements ORDER BY root_post_id, user_x_id
    )
    SELECT
        ue.root_post_id,
        SUM(ue.user_x_score) AS unique_reach,
        MAX(ue.total_reach_all) AS reach,   -- window value same for all rows per post
        COUNT(*) FILTER (WHERE ue.is_self_reply = 1) AS self_replies_count
    FROM unique_engagements ue
    GROUP BY ue.root_post_id
)
```

**Verify:** `EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM mindshare.get_post_metrics_from_user_post(1700000000, 1750000000) LIMIT 100;` — confirm no "SubPlan" nodes in query plan. Expected: eliminate O(n²) correlated scan.

### P5: `user_post` — unpartitioned 2.6 GB table

**Problem:** `mindshare.user_post` (3.47M rows, 2627 MB) is completely unpartitioned. `get_post_metrics_from_user_post` filters by `post_created_at` range — requires full sequential scan.

**Fix:** Partition by `post_created_at` RANGE (monthly or quarterly):
```sql
-- New partitioned table
CREATE TABLE mindshare.user_post_new (LIKE mindshare.user_post INCLUDING ALL)
PARTITION BY RANGE (post_created_at);

CREATE TABLE mindshare.user_post_2024
  PARTITION OF mindshare.user_post_new
  FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
-- etc. per year/quarter

-- Migrate data, swap names
```
This enables partition pruning on time-range queries in `get_post_metrics_from_user_post`.

**Verify:** After partitioning, `EXPLAIN SELECT * FROM mindshare.user_post WHERE post_created_at >= '2024-01-01' AND post_created_at < '2024-04-01'` — must show `Seq Scan on user_post_2024` only (not full table scan).

### P6: Use CONCURRENTLY for matview refresh

**Problem:** `REFRESH MATERIALIZED VIEW analytics.mv_engagement_quipnetwork` (384 MB) blocks all reads for the duration. No CONCURRENTLY is used.

**Fix:** All `analytics.mv_engagement_*` already have a UNIQUE index on `engaged_tweet_id` — this enables CONCURRENTLY:
```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_engagement_quipnetwork;
```
Update any orchestration scripts/cron jobs to use `CONCURRENTLY`.

For `mindshare_score.mv_engagement_features_*` (last refreshed April 30 — 7 weeks stale), add unique index if missing and refresh with CONCURRENTLY.

**Verify:** Check `pg_stat_activity` during refresh — confirm no `ExclusiveLock` on the matview relation. `SELECT relname, mode FROM pg_locks JOIN pg_class ON pg_class.oid = pg_locks.relation WHERE relname LIKE 'mv_engagement%';`

### P7: `calculate_all_decay_scores` — index creation without CONCURRENTLY

**Problem:** Inside the function, after TRUNCATE + bulk insert:
```sql
CREATE INDEX IF NOT EXISTS idx_cs_keyword_author ON mindshare.contribution_scores (...);
```
This runs inside a transaction without CONCURRENTLY — holds an `AccessShareLock` blocking reads, and an `AccessExclusiveLock` on the table during index build on 1.94M rows.

**Fix:** Move index creation outside the function. Pre-create indexes before the TRUNCATE, drop and recreate as part of a controlled maintenance window, OR use `REINDEX INDEX CONCURRENTLY` after the function completes.

**Verify:** During next run, `SELECT * FROM pg_locks WHERE relation = 'mindshare_score.contribution_scores'::regclass` — confirm no `AccessExclusiveLock` held during index creation.

### P8: Missing covering indexes on contribution_scores

**Problem:** Queries filtering by `(project_keyword, replier_x_id, post_created_at)` — e.g. time-ordered lookups for a user's contribution history — have no composite index covering all three columns.

**Fix:**
```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_cs_keyword_replier_time
  ON mindshare_score.contribution_scores (project_keyword, replier_x_id, post_created_at);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_gcs_replier_time
  ON mindshare_score.global_contribution_scores (replier_x_id, post_created_at);
```

**Verify:** `EXPLAIN SELECT * FROM mindshare_score.contribution_scores WHERE project_keyword = 'quipnetwork' AND replier_x_id = 'X' ORDER BY post_created_at` — must show Index Scan, not Seq Scan.

### P9: global_contribution_scores — missing project_keyword column

**Problem:** `mindshare_score.global_contribution_scores` has no `project_keyword` column (unlike `contribution_scores`). This means cross-project queries cannot filter by project. Also stale — last autovacuum May 25 (3+ weeks).

**Fix:** Investigate whether `project_keyword` should be added. If global scores are intentionally cross-project, document this explicitly. If filtering by project is needed, add the column and index.

**Verify:** `\d mindshare_score.global_contribution_scores` — check constraints and whether queries on it use index scans.

### P10: mindshare_score.mv_engagement_features_* — RANGE window + 7-week staleness

**What these do:** Anti-farming/coordination detection pipeline. Each reads from `analytics.mv_engagement_<project>` and computes per-post:
- `burst_concentration`: fraction of engagements in peak 1-hour window
- `duration_days_p90`: how long engagement spread over (p90 - first)
- `cross_post_overlap`: % of engagers who also engaged recent other posts by same author
- `coordinated_burst`: burst_concentration × normalized burst recurrence
- `farming_score`: weighted sum (0.25 burst + 0.20 recency + 0.25 overlap + 0.30 coordinated) × 100

**Pattern (identical for all 11 projects):** 12-CTE query with 7 intermediate aggregation steps.

**Performance problems:**

**P10a — RANGE frame window on float is slow:**
```sql
-- burst_windows CTE:
count(*) OVER (PARTITION BY root_post_id ORDER BY engaged_epoch RANGE BETWEEN CURRENT ROW AND 3600 FOLLOWING)
```
For each row, PostgreSQL scans forward up to 3600 seconds in the window. For quipnetwork (1.99M rows in analytics), this is O(n × avg_engagements_per_post) window computation with sort + range scan overhead.

**Fix:** Replace RANGE frame with `date_trunc('hour', ...)` bucket aggregation:
```sql
burst_windows AS (
    SELECT root_post_id,
           date_trunc('hour', engaged_tweet_created_at) AS hour_bucket,
           COUNT(*) AS window_count
    FROM base
    GROUP BY root_post_id, hour_bucket
),
max_burst_info AS (
    SELECT DISTINCT ON (root_post_id) root_post_id,
           hour_bucket AS peak_window_start,
           window_count AS peak_window_count
    FROM burst_windows
    ORDER BY root_post_id, window_count DESC
)
```
Same semantic (count engagements in a 1-hour window), but GROUP BY aggregation is O(n log n) vs range-frame scan.

**P10b — `prev_post_overlap` hardcoded to 0:**
```sql
0 AS prev_post_overlap
```
This column carries no information. Remove from output or implement the calculation.

**P10c — No time-range filter — processes ALL historical data:**
The `base` CTE reads the entire `analytics.mv_engagement_<project>` matview (quipnetwork: 384MB, 1.99M rows) with no time filter. Farming detection is most relevant for recent posts (e.g., last 90 days).

**Fix:** Add time filter to `base` CTE:
```sql
base AS (
    SELECT root_post_id, root_user_id, root_username, root_tweet_created_at,
           engaged_user_id, engaged_tweet_created_at,
           EXTRACT(epoch FROM engaged_tweet_created_at) AS engaged_epoch
    FROM analytics.mv_engagement_quipnetwork
    WHERE root_tweet_created_at >= NOW() - INTERVAL '90 days'  -- ← add this
)
```

**P10d — 7 weeks stale (last refresh April 30):**
The `analytics.mv_engagement_*` source was refreshed June 16 but `mv_engagement_features_*` still show April 30 data. Farming scores are computed on stale engagement data.

**Fix:** Add `mv_engagement_features_*` to the refresh pipeline immediately after `analytics.mv_engagement_*` refreshes:
```sql
-- Refresh order:
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_engagement_quipnetwork;
REFRESH MATERIALIZED VIEW CONCURRENTLY mindshare_score.mv_engagement_features_quipnetwork;  -- immediately after
```

**P10e — No index on engaged_tweet_created_at in analytics matviews:**
The `burst_windows` CTE and `burst_participants` CTE join/filter on `engaged_tweet_created_at`. No index exists on this column in `analytics.mv_engagement_*` views.

**Fix:**
```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_mv_engagement_quipnetwork_created
  ON analytics.mv_engagement_quipnetwork (engaged_tweet_created_at);
-- Repeat for each project matview
```

**Verify P10:** 
```sql
-- Check staleness before fix:
SELECT matviewname, 
       (SELECT last_autovacuum FROM pg_stat_user_tables WHERE relname = matviewname) AS last_refresh
FROM pg_matviews WHERE schemaname = 'mindshare_score';

-- After fix: confirm farming_score values changed for posts after April 30:
SELECT root_post_id, farming_score FROM mindshare_score.mv_engagement_features_quipnetwork
WHERE root_tweet_created_at > '2026-05-01' LIMIT 5;
-- Must return rows with non-null farming_score
```

### P11: contribution_scores_mv — empty legacy artifact

**Problem:** `mindshare_score.contribution_scores_mv` is a materialized view that is simply `SELECT * FROM mindshare_score.contribution_scores` — a direct copy. It has 0 rows (empty). It serves no purpose and adds confusion.

**Fix:** Drop it after confirming nothing references it:
```sql
SELECT * FROM pg_depend WHERE refobjid = 'mindshare_score.contribution_scores_mv'::regclass;
-- If no dependents:
DROP MATERIALIZED VIEW mindshare_score.contribution_scores_mv;
```

**Verify:** `SELECT matviewname FROM pg_matviews WHERE schemaname='mindshare_score';` — confirm removed.

---

## TASK LIST

> **Schema convention:** All new objects created in `analytics_md_fix`, `mindshare_score_md_fix`, `mindshare_md_fix`. Base tables (`mindshare.*`) are read-only — never copied. Indexes on original tables are the only exception to zero-production-modification rule.

### Task 0: Write detailed documentation

**Files:**
- Create: `docs/db-analysis/mindshare-schema-analysis.md`

- [ ] **Step 1:** Create `docs/db-analysis/` directory
- [ ] **Step 2:** Write `mindshare-schema-analysis.md` with:
  - Full schema inventory (tables, sizes, row counts, all 45 mindshare tables)
  - Data lineage diagram (ASCII, 4-layer pipeline)
  - All function source code with annotations and bug markers
  - All matview definitions (summarized pattern + identified antipatterns)
  - All index listings per table
  - Bug findings with reproduction steps
  - Performance findings with EXPLAIN plan evidence
  - `_md_fix` schema rollout plan summary

- [ ] **Step 3:** Verify file exists: `ls -la docs/db-analysis/mindshare-schema-analysis.md`

---

### Task 1: Create _md_fix schemas + remove dead legacy functions

**Files:**
- Create: `analytics_md_fix`, `mindshare_score_md_fix`, `mindshare_md_fix` DB schemas
- Modify: `mindshare` schema — drop 4 dead functions

- [ ] **Step 1:** Create the three new schemas
```sql
CREATE SCHEMA IF NOT EXISTS analytics_md_fix;
CREATE SCHEMA IF NOT EXISTS mindshare_score_md_fix;
CREATE SCHEMA IF NOT EXISTS mindshare_md_fix;
```

- [ ] **Step 2:** Confirm no active callers of dead mindshare functions in application code
```bash
grep -r "calculate_decay_scores\|calculate_all_decay_scores\|calculate_scores_by_project\|calculate_all_scores_parallel" \
  /home/fm-pc-lt-314/ELEMENT/mindshare-backend-optimization/ \
  --include="*.py" --include="*.sql" --include="*.sh" --include="*.ts" --include="*.js"
# Expected: 0 results
```

- [ ] **Step 3:** Confirm no DB-level callers of dead functions
```sql
SELECT proname, prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND (prosrc ILIKE '%mindshare.calculate_decay_scores%'
    OR prosrc ILIKE '%mindshare.calculate_all_decay_scores%'
    OR prosrc ILIKE '%mindshare.calculate_scores_by_project%'
    OR prosrc ILIKE '%mindshare.calculate_all_scores_parallel%');
-- Must return 0 rows
```

- [ ] **Step 4:** Drop dead functions from mindshare schema
```sql
DROP FUNCTION IF EXISTS mindshare.calculate_decay_scores(text);
DROP FUNCTION IF EXISTS mindshare.calculate_all_decay_scores();
DROP FUNCTION IF EXISTS mindshare.calculate_scores_by_project(text);
DROP FUNCTION IF EXISTS mindshare.calculate_all_scores_parallel();
```

- [ ] **Step 5:** Verify schemas created and dead functions removed
```sql
SELECT nspname FROM pg_namespace WHERE nspname LIKE '%md_fix%';
-- Must show: analytics_md_fix, mindshare_score_md_fix, mindshare_md_fix

SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='mindshare' AND p.proname LIKE 'calculate%';
-- Must return 0 rows

SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='mindshare_score' AND p.proname LIKE 'calculate%';
-- Must return 4 production procedures
```

---

### Task 2: analytics_md_fix — improved mv_engagement_* matviews

**Files:**
- Create: 11 matviews in `analytics_md_fix` schema, each reading from `mindshare.*` base tables
- Improvement: NOT EXISTS → LEFT JOIN IS NULL + optional single-scan consolidation

- [ ] **Step 1:** Read current definition of `analytics.mv_engagement_acurast`
```sql
SELECT definition FROM pg_matviews
WHERE schemaname='analytics' AND matviewname='mv_engagement_acurast';
-- Save this as baseline — we replicate the pattern into analytics_md_fix
```

- [ ] **Step 2:** Create improved version for acurast (pilot)
```sql
CREATE MATERIALIZED VIEW analytics_md_fix.mv_engagement_acurast AS
WITH roots AS (
    SELECT mp.post_id, mp.user_x_id AS root_user_id, mp.username AS root_username,
           mp.created_at AS root_tweet_created_at, mp.favorite_count AS root_favorite_count,
           mp.reply_count AS root_reply_count, mu.x_score AS root_user_score
    FROM mindshare.mindshare_post_acurast mp
    LEFT JOIN mindshare.mindshare_user mu ON mu.x_id = mp.user_x_id
    WHERE mp.is_reply = false
),
engaged_tweets AS (
    SELECT mp.post_id AS engaged_tweet_id, mp.replied_post_id AS root_post_id,
           mp.user_x_id AS engaged_user_id, mp.username AS engaged_username,
           mp.created_at AS engaged_tweet_created_at, mu.x_score AS engaged_user_score
    FROM mindshare.mindshare_post_acurast mp
    LEFT JOIN mindshare.mindshare_user mu ON mu.x_id = mp.user_x_id
    WHERE mp.is_reply = true AND mp.replied_post_id IS NOT NULL
),
engagements AS (
    SELECT r.post_id AS root_post_id, r.root_user_id, r.root_username,
           r.root_tweet_created_at, r.root_favorite_count, r.root_reply_count,
           e.engaged_tweet_id, e.engaged_user_id, e.engaged_username,
           e.engaged_tweet_created_at, e.engaged_user_score
    FROM roots r
    JOIN engaged_tweets e ON e.root_post_id = r.post_id
),
-- FIX: LEFT JOIN IS NULL replaces NOT EXISTS correlated subquery:
posts_with_no_engagement AS (
    SELECT r.post_id AS root_post_id, r.root_user_id, r.root_username,
           r.root_tweet_created_at, r.root_favorite_count, r.root_reply_count,
           NULL::text AS engaged_tweet_id, NULL::text AS engaged_user_id,
           NULL::text AS engaged_username, NULL::timestamptz AS engaged_tweet_created_at,
           NULL::numeric AS engaged_user_score
    FROM roots r
    LEFT JOIN engaged_tweets e ON e.root_post_id = r.post_id
    WHERE e.root_post_id IS NULL  -- ← replaces NOT EXISTS
)
SELECT root_post_id, root_user_id, root_username, root_tweet_created_at,
       root_favorite_count, root_reply_count, engaged_tweet_id, engaged_user_id,
       engaged_username, engaged_tweet_created_at, engaged_user_score
FROM engagements
UNION ALL
SELECT root_post_id, root_user_id, root_username, root_tweet_created_at,
       root_favorite_count, root_reply_count, engaged_tweet_id, engaged_user_id,
       engaged_username, engaged_tweet_created_at, engaged_user_score
FROM posts_with_no_engagement;

-- Create same 3 indexes as original:
CREATE UNIQUE INDEX ON analytics_md_fix.mv_engagement_acurast (engaged_tweet_id) WHERE engaged_tweet_id IS NOT NULL;
CREATE INDEX ON analytics_md_fix.mv_engagement_acurast (root_post_id);
CREATE INDEX ON analytics_md_fix.mv_engagement_acurast (engaged_user_id) WHERE engaged_user_id IS NOT NULL;
```

- [ ] **Step 3:** Compare row counts — must match original
```sql
SELECT COUNT(*) FROM analytics.mv_engagement_acurast;
SELECT COUNT(*) FROM analytics_md_fix.mv_engagement_acurast;
-- Must be equal
```

- [ ] **Step 4:** EXPLAIN comparison — confirm no SubPlan / anti-join correlated scan
```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT COUNT(*) FROM analytics_md_fix.mv_engagement_acurast;
-- Must NOT show: "SubPlan" or "Anti Join" in plan
```

- [ ] **Step 5:** Repeat for all 10 remaining projects: cnpynetwork, d3lmundos, ironallies, pact_swap, quipnetwork, sleepagotchi, technotainment, thearcterminal, yom_official, nucleus (read each partition name from `pg_class`)
  - For each: replace partition table name (`mindshare_post_acurast` → `mindshare_post_<project>`) in template above

- [ ] **Step 6:** Create improved `mv_user_posts_engagement`
```sql
CREATE MATERIALIZED VIEW analytics_md_fix.mv_user_posts_engagement AS
-- Same definition as analytics.mv_user_posts_engagement but reading from mindshare.user_post
-- with same LEFT JOIN IS NULL improvement if applicable
SELECT * FROM analytics.mv_user_posts_engagement;  -- start as exact copy, optimize if definition shows correlated subquery
CREATE UNIQUE INDEX ON analytics_md_fix.mv_user_posts_engagement (engaged_tweet_id) WHERE engaged_tweet_id IS NOT NULL;
```

- [ ] **Step 7:** Verify all 12 matviews in analytics_md_fix populated
```sql
SELECT matviewname, ispopulated FROM pg_matviews WHERE schemaname='analytics_md_fix';
-- All 12 must show ispopulated = true
```

---

### Task 3: Add indexes to original tables (non-destructive, cross-schema benefit)

**Files:**
- Modify: indexes on `mindshare.mindshare_post` partitions, `mindshare_score.contribution_scores`, `mindshare_score.global_contribution_scores`, `analytics.mv_engagement_*`

- [ ] **Step 1:** Add partial index on mindshare_post for decay computation (benefits `mindshare_score.calculate_decay_scores`)
```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_mindshare_post_decay_compute
  ON mindshare.mindshare_post (project_keyword, user_x_id, post_created_at)
  INCLUDE (post_id, replied_post_id)
  WHERE is_reply = true AND replied_post_id IS NOT NULL;
```

- [ ] **Step 2:** Add composite time index on contribution_scores
```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_cs_keyword_replier_time
  ON mindshare_score.contribution_scores (project_keyword, replier_x_id, post_created_at);
```

- [ ] **Step 3:** Add replier time index on global_contribution_scores
```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_gcs_replier_time
  ON mindshare_score.global_contribution_scores (replier_x_id, post_created_at);
```

- [ ] **Step 4:** Add engaged_tweet_created_at index to analytics matviews (needed by burst_windows CTE in feature views)
```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_mv_engagement_acurast_eng_created
  ON analytics.mv_engagement_acurast (engaged_tweet_created_at);
-- Repeat for all 11 project matviews and the analytics_md_fix equivalents
```

- [ ] **Step 5:** Verify all indexes built and used
```sql
SELECT indexname, indexdef FROM pg_indexes
WHERE schemaname IN ('mindshare','mindshare_score')
  AND indexname IN ('ix_mindshare_post_decay_compute','idx_cs_keyword_replier_time','idx_gcs_replier_time');
-- Must return 3 rows

EXPLAIN SELECT * FROM mindshare_score.contribution_scores
WHERE project_keyword='quipnetwork' AND replier_x_id='test_user' ORDER BY post_created_at;
-- Must show: Index Scan using idx_cs_keyword_replier_time
```

---

### Task 4: mindshare_md_fix — fixed API functions (Bugs 2 & 3 + correlated subquery)

**Files:**
- Create: 3 functions in `mindshare_md_fix` schema reading from original base tables

- [ ] **Step 1:** Read current broken function bodies
```sql
-- Bug 2: hardcoded matview
SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='mindshare' AND p.proname='get_post_engagement_ratios' AND pronargs=1;

-- Bug 3: broken template
SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='mindshare' AND p.proname='get_post_engagement_ratios' AND pronargs=3;
```

- [ ] **Step 2:** Create fixed single-param version in mindshare_md_fix
```sql
CREATE OR REPLACE FUNCTION mindshare_md_fix.get_post_engagement_ratios(projectname text)
RETURNS TABLE(
    root_post_id text, root_user_id text, unique_reach numeric, reach numeric,
    unique_impressions numeric, impressions numeric, unique_likes numeric,
    unique_replies numeric, unique_reposts numeric
) LANGUAGE plpgsql STABLE AS $function$
DECLARE
    view_name text := 'mv_engagement_' || lower(replace(projectname, ' ', '_'));
    sql_query text;
BEGIN
    sql_query := format($q$
        WITH unique_engagements AS (
            SELECT DISTINCT ON (root_post_id, engaged_user_id)
                root_post_id, root_user_id, engaged_user_id, engaged_user_score,
                root_favorite_count, root_reply_count
            FROM analytics_md_fix.%I
            ORDER BY root_post_id, engaged_user_id
        ),
        reach_data AS (
            SELECT root_post_id,
                COUNT(DISTINCT engaged_user_id) AS unique_reach,
                SUM(engaged_user_score) AS reach,
                SUM(root_favorite_count) AS unique_likes,
                SUM(root_reply_count) AS unique_replies
            FROM unique_engagements GROUP BY root_post_id
        )
        SELECT r.root_post_id, r.root_user_id, rd.unique_reach, rd.reach,
               rd.unique_reach AS unique_impressions, rd.reach AS impressions,
               rd.unique_likes, rd.unique_replies, 0::numeric AS unique_reposts
        FROM (SELECT DISTINCT root_post_id, root_user_id FROM analytics_md_fix.%I) r
        JOIN reach_data rd ON r.root_post_id = rd.root_post_id
    $q$, view_name, view_name);
    RETURN QUERY EXECUTE sql_query;
END;
$function$;
```

- [ ] **Step 3:** Create fixed 3-param version (Bug 3 — replace `v` literal)
```sql
CREATE OR REPLACE FUNCTION mindshare_md_fix.get_post_engagement_ratios(startdate bigint, enddate bigint, projectname text)
RETURNS TABLE(
    root_post_id text, root_user_id text, unique_reach numeric, reach numeric,
    unique_impressions numeric, impressions numeric, unique_likes numeric,
    unique_replies numeric, unique_reposts numeric
) LANGUAGE plpgsql STABLE AS $function$
DECLARE
    view_name text := 'mv_engagement_' || lower(replace(projectname, ' ', '_'));
    sql_query text;
BEGIN
    sql_query := format($q$
        WITH filtered AS (
            SELECT * FROM analytics_md_fix.%I
            WHERE engaged_tweet_created_at >= (to_timestamp($1) AT TIME ZONE 'Asia/Kathmandu')
              AND engaged_tweet_created_at <  (to_timestamp($2) AT TIME ZONE 'Asia/Kathmandu')
        ),                        -- ^^^^ FIX: was literal "v" in original template
        unique_engagements AS (
            SELECT DISTINCT ON (root_post_id, engaged_user_id)
                root_post_id, root_user_id, engaged_user_id, engaged_user_score,
                root_favorite_count, root_reply_count
            FROM filtered ORDER BY root_post_id, engaged_user_id
        ),
        reach_data AS (
            SELECT root_post_id,
                COUNT(DISTINCT engaged_user_id) AS unique_reach,
                SUM(engaged_user_score) AS reach
            FROM unique_engagements GROUP BY root_post_id
        )
        SELECT ue.root_post_id, ue.root_user_id, rd.unique_reach, rd.reach,
               rd.unique_reach AS unique_impressions, rd.reach AS impressions,
               SUM(ue.root_favorite_count) AS unique_likes,
               SUM(ue.root_reply_count) AS unique_replies, 0::numeric AS unique_reposts
        FROM unique_engagements ue JOIN reach_data rd ON ue.root_post_id = rd.root_post_id
        GROUP BY ue.root_post_id, ue.root_user_id, rd.unique_reach, rd.reach
    $q$, view_name) USING startdate, enddate;
    RETURN QUERY EXECUTE sql_query;
END;
$function$;
```

- [ ] **Step 4:** Create fixed `get_post_metrics_from_user_post` — window fn replaces correlated subquery
```sql
CREATE OR REPLACE FUNCTION mindshare_md_fix.get_post_metrics_from_user_post(startdate bigint, enddate bigint)
RETURNS TABLE(
    post_id text, root_user_id text, unique_reach numeric, reach numeric,
    self_replies_count bigint, unique_impressions numeric
) LANGUAGE sql STABLE AS $function$
WITH base_posts AS (
    SELECT post_id, user_x_id AS handle FROM mindshare.user_post
    WHERE created_at >= to_timestamp($1) AND created_at < to_timestamp($2)
      AND is_reply = false
),
engagements AS (
    SELECT
        e.root_post_id, e.user_x_id, e.user_x_score,
        SUM(e.user_x_score) OVER (PARTITION BY e.root_post_id) AS total_reach,  -- window fn, no correlated subquery
        CASE WHEN e.is_reply AND e.user_x_id = bp.handle THEN 1 ELSE 0 END AS is_self_reply
    FROM mindshare.user_post e
    JOIN base_posts bp ON bp.post_id = e.root_post_id
),
deduped AS (
    SELECT DISTINCT ON (root_post_id, user_x_id)
        root_post_id, user_x_id, user_x_score, total_reach, is_self_reply
    FROM engagements
    ORDER BY root_post_id, user_x_id
),
aggregated AS (
    SELECT root_post_id,
           SUM(user_x_score)::numeric AS unique_reach,
           MAX(total_reach)::numeric AS reach,
           COUNT(*) FILTER (WHERE is_self_reply = 1) AS self_replies_count
    FROM deduped GROUP BY root_post_id
)
SELECT bp.post_id, bp.handle AS root_user_id,
       COALESCE(a.unique_reach, 0) AS unique_reach,
       COALESCE(a.reach, 0) AS reach,
       COALESCE(a.self_replies_count, 0) AS self_replies_count,
       COALESCE(a.unique_reach, 0) AS unique_impressions
FROM base_posts bp
LEFT JOIN aggregated a ON a.root_post_id = bp.post_id;
$function$;
```

- [ ] **Step 5:** Verify Bug 2 fix — counts differ per project
```sql
SELECT COUNT(*) FROM mindshare_md_fix.get_post_engagement_ratios('quipnetwork');
SELECT COUNT(*) FROM mindshare_md_fix.get_post_engagement_ratios('Acurast');
-- Must return DIFFERENT counts matching respective matview sizes
```

- [ ] **Step 6:** Verify Bug 3 fix — no syntax error with date params
```sql
SELECT COUNT(*) FROM mindshare_md_fix.get_post_engagement_ratios(1700000000, 1750000000, 'quipnetwork');
-- Must return a count without error
```

- [ ] **Step 7:** Verify P4 fix — no SubPlan in explain
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM mindshare_md_fix.get_post_metrics_from_user_post(1700000000, 1750000000) LIMIT 100;
-- Must NOT show "SubPlan" nodes
```

---

### Task 5: mindshare_score_md_fix — improved mv_engagement_features_* (RANGE→bucket + time filter)

**Files:**
- Create: 11 matviews + `mv_user_posts_engagement_features` in `mindshare_score_md_fix`, reading from `analytics_md_fix.*`
- Improvement: RANGE BETWEEN → hourly bucket GROUP BY, 90-day time filter, remove hardcoded `0 AS prev_post_overlap`

- [ ] **Step 1:** Read current definition of one feature matview
```sql
SELECT definition FROM pg_matviews
WHERE schemaname='mindshare_score' AND matviewname='mv_engagement_features_acurast';
```

- [ ] **Step 2:** Create improved pilot matview for acurast
```sql
CREATE MATERIALIZED VIEW mindshare_score_md_fix.mv_engagement_features_acurast AS
WITH base AS (
    SELECT root_post_id, root_user_id, root_username, root_tweet_created_at,
           engaged_user_id, engaged_tweet_created_at,
           EXTRACT(epoch FROM engaged_tweet_created_at) AS engaged_epoch
    FROM analytics_md_fix.mv_engagement_acurast
    WHERE root_tweet_created_at >= NOW() - INTERVAL '90 days'  -- ← NEW: time filter
      AND engaged_tweet_created_at IS NOT NULL
),
-- FIX: Replace RANGE BETWEEN float frame with hourly bucket GROUP BY:
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
),
total_engagements AS (
    SELECT root_post_id, COUNT(*) AS total_eng FROM base GROUP BY root_post_id
),
burst_participants AS (
    SELECT b.root_post_id, b.engaged_user_id
    FROM base b
    JOIN max_burst_info m ON b.root_post_id = m.root_post_id
    WHERE date_trunc('hour', b.engaged_tweet_created_at) = m.peak_window_start
),
engagement_duration AS (
    SELECT root_post_id,
           EXTRACT(epoch FROM (PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY engaged_tweet_created_at)
                               - MIN(engaged_tweet_created_at))) / 86400 AS duration_days_p90
    FROM base GROUP BY root_post_id
),
user_engagement_history AS (
    SELECT engaged_user_id, root_user_id, COUNT(DISTINCT root_post_id) AS posts_engaged_count
    FROM base GROUP BY engaged_user_id, root_user_id
),
post_coordination AS (
    SELECT b.root_post_id,
           AVG(bp2.cnt) AS avg_burst_recurrence
    FROM burst_participants bp
    JOIN base b ON b.root_post_id = bp.root_post_id
    JOIN LATERAL (
        SELECT COUNT(*) AS cnt FROM burst_windows bw2
        WHERE bw2.root_post_id = b.root_post_id
    ) bp2 ON true
    GROUP BY b.root_post_id
),
post_overlap_metrics AS (
    SELECT bp.root_post_id,
           (COUNT(DISTINCT CASE WHEN ueh.posts_engaged_count > 1 THEN bp.engaged_user_id END)::numeric
            / NULLIF(COUNT(DISTINCT bp.engaged_user_id), 0)) * 100 AS cross_post_overlap
    FROM burst_participants bp
    JOIN user_engagement_history ueh ON ueh.engaged_user_id = bp.engaged_user_id
        AND ueh.root_user_id = (SELECT root_user_id FROM base WHERE root_post_id = bp.root_post_id LIMIT 1)
    GROUP BY bp.root_post_id
),
metrics_pre AS (
    SELECT t.root_post_id,
           MAX(b.root_user_id) AS root_user_id,
           MAX(b.root_username) AS root_username,
           MAX(b.root_tweet_created_at) AS root_tweet_created_at,
           t.total_eng AS total_engagements,
           (m.peak_window_count::numeric / NULLIF(t.total_eng, 0)) AS burst_concentration,
           LEAST(COALESCE(d.duration_days_p90, 0), 1) AS duration_days_p90
    FROM total_engagements t
    JOIN max_burst_info m ON m.root_post_id = t.root_post_id
    LEFT JOIN engagement_duration d ON d.root_post_id = t.root_post_id
    JOIN base b ON b.root_post_id = t.root_post_id
    GROUP BY t.root_post_id, m.peak_window_count, t.total_eng, d.duration_days_p90
)
SELECT
    mp.root_post_id, mp.root_user_id, mp.root_username, mp.root_tweet_created_at,
    mp.total_engagements,
    ROUND(mp.burst_concentration::numeric, 4) AS burst_concentration,
    ROUND(mp.duration_days_p90::numeric, 4) AS duration_days_p90,
    ROUND(COALESCE(pom.cross_post_overlap, 0)::numeric, 4) AS cross_post_overlap,
    -- prev_post_overlap REMOVED (was hardcoded 0 — carries no info)
    ROUND((mp.burst_concentration * LEAST(COALESCE(pc.avg_burst_recurrence,0)/3.0, 1))::numeric, 4) AS coordinated_burst,
    ROUND((
        0.25 * LEAST(mp.burst_concentration * 1.25, 1)
      + 0.20 * (1 - LEAST(mp.duration_days_p90, 1))
      + 0.25 * LEAST(COALESCE(pom.cross_post_overlap,0) / 100.0, 1)
      + 0.30 * (mp.burst_concentration * LEAST(COALESCE(pc.avg_burst_recurrence,0)/3.0, 1))
    )::numeric * 100, 2) AS farming_score
FROM metrics_pre mp
LEFT JOIN post_overlap_metrics pom ON mp.root_post_id = pom.root_post_id
LEFT JOIN post_coordination pc ON mp.root_post_id = pc.root_post_id;

CREATE UNIQUE INDEX ON mindshare_score_md_fix.mv_engagement_features_acurast (root_post_id);
```

- [ ] **Step 3:** Compare farming_score distribution vs original stale version
```sql
SELECT COUNT(*), MIN(farming_score), MAX(farming_score), AVG(farming_score)
FROM mindshare_score_md_fix.mv_engagement_features_acurast;

SELECT COUNT(*), MIN(farming_score), MAX(farming_score), AVG(farming_score)
FROM mindshare_score.mv_engagement_features_acurast;
-- New version: should have fewer rows (90-day filter) but higher-quality/more-current scores
```

- [ ] **Step 4:** EXPLAIN comparison — confirm no WindowAgg with RANGE frame
```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT COUNT(*) FROM mindshare_score_md_fix.mv_engagement_features_acurast;
-- Must NOT show: "WindowAgg" with "Range" frame
-- Must show: HashAggregate for burst_windows CTE
```

- [ ] **Step 5:** Repeat for all 10 remaining projects — same template, substitute `mv_engagement_<project>`

- [ ] **Step 6:** Create `mv_user_posts_engagement_features` in mindshare_score_md_fix (reading from analytics_md_fix)
```sql
CREATE MATERIALIZED VIEW mindshare_score_md_fix.mv_user_posts_engagement_features AS
-- Same definition as mindshare_score.mv_user_posts_engagement_features
-- but reading from analytics_md_fix.mv_user_posts_engagement
SELECT * FROM mindshare_score.mv_user_posts_engagement_features;  -- temporary baseline; replace with full definition
CREATE UNIQUE INDEX ON mindshare_score_md_fix.mv_user_posts_engagement_features (root_post_id);
```

- [ ] **Step 7:** Verify all 12 feature matviews in mindshare_score_md_fix populated
```sql
SELECT matviewname, ispopulated FROM pg_matviews WHERE schemaname='mindshare_score_md_fix';
-- All must show ispopulated = true
```

---

### Task 6: mindshare_score_md_fix — improved calculate_decay_scores procedure (batch INSERT + jsonb)

**Files:**
- Create: `mindshare_score_md_fix.contribution_scores` table + improved `calculate_decay_scores` procedure

- [ ] **Step 1:** Create contribution_scores table in md_fix schema (same structure as production)
```sql
CREATE TABLE mindshare_score_md_fix.contribution_scores
    (LIKE mindshare_score.contribution_scores INCLUDING ALL);
-- Inherits same columns: project_keyword, reply_post_id, replier_x_id, original_post_id,
--   original_author_x_id, post_created_at, replier_base_score, effective_score,
--   contribution_score, active_multipliers[], reply_number, local_reply_count, decay_type
```

- [ ] **Step 2:** Baseline timing on production procedure (read-only check)
```sql
\timing on
-- Check row count and time to compute for small project without running full procedure:
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) FROM mindshare_score.contribution_scores WHERE project_keyword = 'Acurast';
```

- [ ] **Step 3:** Create improved procedure with jsonb O(1) lookup + batch INSERT
```sql
CREATE OR REPLACE PROCEDURE mindshare_score_md_fix.calculate_decay_scores(p_project_keyword text)
LANGUAGE plpgsql AS $proc$
DECLARE
    rec RECORD;
    author_counts JSONB := '{}';           -- O(1) author lookup, replaces parallel arrays
    cnt INT;
    calc_score NUMERIC;
    decay_type_val TEXT;
BEGIN
    CREATE TEMP TABLE _decay_batch (
        project_keyword TEXT, reply_post_id TEXT, replier_x_id TEXT,
        original_post_id TEXT, original_author_x_id TEXT,
        post_created_at TIMESTAMPTZ, replier_base_score NUMERIC,
        effective_score NUMERIC, contribution_score NUMERIC,
        active_multipliers TEXT[], reply_number INT,
        local_reply_count INT, decay_type TEXT
    ) ON COMMIT DROP;

    FOR rec IN
        SELECT mp.post_id, mp.replied_post_id, mp.user_x_id AS replier_x_id,
               mp.created_at AS post_created_at,
               mu.x_score AS replier_base_score,
               mp.replied_post_id AS original_post_id,
               orig.user_x_id AS original_author_x_id,
               COUNT(siblings.post_id) OVER (PARTITION BY mp.replied_post_id) AS local_reply_count
        FROM mindshare.mindshare_post mp
        LEFT JOIN mindshare.mindshare_user mu ON mu.x_id = mp.user_x_id
        LEFT JOIN mindshare.mindshare_post orig ON orig.post_id = mp.replied_post_id
        LEFT JOIN mindshare.mindshare_post siblings ON siblings.replied_post_id = mp.replied_post_id
        WHERE mp.project_keyword = p_project_keyword
          AND mp.is_reply = true
          AND mp.replied_post_id IS NOT NULL
          AND mp.created_at >= NOW() - INTERVAL '30 days'
        ORDER BY mp.user_x_id, mp.created_at
    LOOP
        -- O(1) jsonb lookup:
        cnt := COALESCE((author_counts->>rec.original_author_x_id)::int, 0);

        IF cnt = 0 THEN
            decay_type_val := 'FIRST_REPLY';
            calc_score := COALESCE(rec.replier_base_score, 0);
        ELSIF cnt <= rec.local_reply_count THEN
            decay_type_val := 'LOCAL_DECAY';
            calc_score := COALESCE(rec.replier_base_score, 0) * 0.5;
        ELSE
            decay_type_val := 'GLOBAL_DECAY';
            calc_score := GREATEST(COALESCE(rec.replier_base_score, 0) - 1, 0);
        END IF;

        author_counts := jsonb_set(author_counts,
            ARRAY[rec.original_author_x_id], to_jsonb(cnt + 1));

        INSERT INTO _decay_batch VALUES (
            p_project_keyword, rec.post_id, rec.replier_x_id,
            rec.original_post_id, rec.original_author_x_id,
            rec.post_created_at, rec.replier_base_score,
            calc_score, calc_score,
            ARRAY[]::text[], rec.local_reply_count, rec.local_reply_count,
            decay_type_val
        );
    END LOOP;

    -- Single batch INSERT instead of per-row INSERT:
    INSERT INTO mindshare_score_md_fix.contribution_scores
    SELECT * FROM _decay_batch;

    DROP TABLE IF EXISTS _decay_batch;
END;
$proc$;
```

- [ ] **Step 4:** Create `calculate_all_decay_scores` wrapper
```sql
CREATE OR REPLACE PROCEDURE mindshare_score_md_fix.calculate_all_decay_scores()
LANGUAGE plpgsql AS $proc$
DECLARE
    proj RECORD;
BEGIN
    TRUNCATE mindshare_score_md_fix.contribution_scores;
    FOR proj IN SELECT project_keyword FROM mindshare.mindshare_project LOOP
        CALL mindshare_score_md_fix.calculate_decay_scores(proj.project_keyword);
        RAISE NOTICE 'Done: %', proj.project_keyword;
    END LOOP;

    -- Create indexes AFTER bulk insert (not inside per-project loop):
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_cs_fix_keyword
        ON mindshare_score_md_fix.contribution_scores (project_keyword);
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_cs_fix_replier
        ON mindshare_score_md_fix.contribution_scores (replier_x_id);
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_cs_fix_keyword_replier_time
        ON mindshare_score_md_fix.contribution_scores (project_keyword, replier_x_id, post_created_at);
END;
$proc$;
```

- [ ] **Step 5:** Test pilot on smallest project (Acurast — 71K rows)
```sql
\timing on
CALL mindshare_score_md_fix.calculate_decay_scores('Acurast');
SELECT COUNT(*) FROM mindshare_score_md_fix.contribution_scores;
-- Record execution time; compare vs production mindshare_score.contribution_scores count for Acurast
```

- [ ] **Step 6:** Compare output quality vs production
```sql
SELECT decay_type, COUNT(*), AVG(effective_score)
FROM mindshare_score_md_fix.contribution_scores
WHERE project_keyword = 'Acurast'
GROUP BY decay_type;

SELECT decay_type, COUNT(*), AVG(effective_score)
FROM mindshare_score.contribution_scores
WHERE project_keyword = 'Acurast'
GROUP BY decay_type;
-- Distribution should be comparable
```

---

### Task 7: Switch original refresh scripts to CONCURRENTLY (non-destructive)

**Files:**
- Modify: orchestration scripts/Python code that calls REFRESH MATERIALIZED VIEW

- [ ] **Step 1:** Find all refresh calls in application code
```bash
grep -rn "REFRESH MATERIALIZED" /home/fm-pc-lt-314/ELEMENT/mindshare-backend-optimization/ \
  --include="*.py" --include="*.sql" --include="*.sh"
```

- [ ] **Step 2:** Update each non-CONCURRENTLY call to add CONCURRENTLY
```python
# Before:
cursor.execute("REFRESH MATERIALIZED VIEW analytics.mv_engagement_quipnetwork")
# After:
cursor.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_engagement_quipnetwork")
```

- [ ] **Step 3:** Verify unique indexes exist on all analytics matviews (required for CONCURRENTLY)
```sql
SELECT tablename, indexname FROM pg_indexes
WHERE schemaname='analytics' AND indexdef LIKE 'CREATE UNIQUE%';
-- Must return ≥11 rows
```

- [ ] **Step 4:** Test CONCURRENTLY refresh doesn't block reads
```sql
-- Session 1:
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_engagement_quipnetwork;
-- Session 2 simultaneously:
SELECT COUNT(*) FROM analytics.mv_engagement_quipnetwork;
-- Session 2 must not block
```

- [ ] **Step 5:** Also add CONCURRENTLY to mindshare_score_md_fix refresh procedure
```sql
-- In any refresh orchestration for the new schemas, use CONCURRENTLY
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics_md_fix.mv_engagement_quipnetwork;
REFRESH MATERIALIZED VIEW CONCURRENTLY mindshare_score_md_fix.mv_engagement_features_quipnetwork;
```

---

### Task 8: Drop contribution_scores_mv empty legacy artifact + document dead code

**Files:**
- Modify: `mindshare_score` schema

- [ ] **Step 1:** Confirm no dependents
```sql
SELECT dependent_ns.nspname, dependent_view.relname
FROM pg_depend
JOIN pg_rewrite ON pg_depend.objid = pg_rewrite.oid
JOIN pg_class dependent_view ON pg_rewrite.ev_class = dependent_view.oid
JOIN pg_namespace dependent_ns ON dependent_ns.oid = dependent_view.relnamespace
WHERE pg_depend.refobjid = (
    SELECT oid FROM pg_class WHERE relname='contribution_scores_mv'
    AND relnamespace=(SELECT oid FROM pg_namespace WHERE nspname='mindshare_score')
);
-- Must return 0 rows
```

- [ ] **Step 2:** Drop it
```sql
DROP MATERIALIZED VIEW mindshare_score.contribution_scores_mv;
```

- [ ] **Step 3:** Verify removed
```sql
SELECT matviewname FROM pg_matviews WHERE schemaname='mindshare_score' AND matviewname='contribution_scores_mv';
-- 0 rows
```

---

## VERIFICATION SUMMARY

```sql
-- 1. New schemas exist:
SELECT nspname FROM pg_namespace WHERE nspname LIKE '%md_fix%';
-- Returns: analytics_md_fix, mindshare_score_md_fix, mindshare_md_fix

-- 2. Dead functions removed from mindshare:
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='mindshare' AND p.proname LIKE 'calculate%';
-- Must return 0 rows

-- 3. Production mindshare_score procedures intact:
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='mindshare_score' AND p.proname LIKE 'calculate%';
-- Must return 4 procedures

-- 4. Bug 2 fixed — counts differ per project:
SELECT COUNT(*) FROM mindshare_md_fix.get_post_engagement_ratios('quipnetwork');
SELECT COUNT(*) FROM mindshare_md_fix.get_post_engagement_ratios('Acurast');
-- Must be different

-- 5. Bug 3 fixed — no syntax error:
SELECT COUNT(*) FROM mindshare_md_fix.get_post_engagement_ratios(1700000000, 1750000000, 'quipnetwork');
-- Returns count without error

-- 6. No SubPlan in fixed metrics function:
EXPLAIN SELECT * FROM mindshare_md_fix.get_post_metrics_from_user_post(1700000000, 1750000000) LIMIT 1;
-- Must NOT show "SubPlan" nodes

-- 7. analytics_md_fix matviews match row counts:
SELECT a.matviewname,
       (SELECT COUNT(*) FROM analytics.mv_engagement_acurast) AS orig,
       (SELECT COUNT(*) FROM analytics_md_fix.mv_engagement_acurast) AS fixed
-- orig = fixed

-- 8. mindshare_score_md_fix feature matviews populated:
SELECT matviewname, ispopulated FROM pg_matviews WHERE schemaname='mindshare_score_md_fix';
-- All true

-- 9. farming_score distribution reasonable in new feature views:
SELECT MIN(farming_score), MAX(farming_score), AVG(farming_score)
FROM mindshare_score_md_fix.mv_engagement_features_quipnetwork;
-- 0-100 range, non-null values

-- 10. Covering indexes exist and used:
EXPLAIN SELECT * FROM mindshare_score.contribution_scores
WHERE project_keyword='quipnetwork' AND replier_x_id='test' ORDER BY post_created_at;
-- Index Scan using idx_cs_keyword_replier_time

-- 11. CONCURRENTLY refresh works on both schema sets:
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_engagement_acurast;
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics_md_fix.mv_engagement_acurast;
-- Both complete without error
```
