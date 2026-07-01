# Mindshare DB — Detailed Design / Change Plan

<< just the plan >>> 

Companion to the JIRA epic. Grounded in the actual prod (UAT) schema dump. Answers: **what runs
today, what changes, what becomes a table, and what becomes incremental.**

---

## TL;DR answers to your two questions

- **Are we replacing MVs with tables?** **Yes — selectively, not all.**
  - `mv_engagement_*` (raw engagement) → **convert to an incremental partitioned table.**
  - `mv_engagement_features_*` (aggregated farming/coordination) → **convert to an incremental table.**
  - `contribution_scores` / `global_contribution_scores` → **already tables**, but stop the
    TRUNCATE+rebuild → make them **incremental upsert** tables.
  - `snapshots.*` (78 leaderboard MVs) → **collapse into ONE partitioned table**
    `snapshots.leaderboard(project_keyword, window, …)` populated on a tiered cadence.
  - We keep the *concept* of MVs only where a thing is cheap and fully derived; the heavy ones become
    tables we maintain ourselves.
- **Are we doing anything incremental?** **Yes — this is the core of the redesign.** Today
  *everything* is full-recompute (TRUNCATE + row-by-row PL/pgSQL, full-history `REFRESH`). Target:
  process only **new/changed posts since a cursor** each hour. Decay becomes incremental in Python;
  engagement + features become delta upserts; leaderboards become tiered (short windows hourly, long
  windows daily).

---

## 1. What is currently being done (real pipeline, bottom→top)

The whole system is **batch full-recompute**, triggered manually / on demand. There are **no triggers**
and `updated_at` is only a column DEFAULT (not auto-bumped), so nothing is event-driven today.

**Layer 0 — Ingestion**
- Tweets land in `raw_data.raw_post*` → `mindshare.mindshare_post` (LIST-partitioned by
  `project_keyword`, PK `(project_keyword, post_created_at, post_id)`) and the global
  `mindshare.user_post`. Users in `mindshare.mindshare_user` (PK `x_id`, has `last_score_fetched_at`).
- `is_post/is_reply/is_quote/is_retweet` are **GENERATED STORED** columns.

**Layer 1 — Engagement MVs** (`analytics.mv_engagement_<proj>`, built by
`analytics.create_engagement_view(keyword)`)
- Row-per-engagement: matches replies/quotes to their root post, joins engager `score`, `UNION ALL`
  posts-with-no-engagement. **No time-window filter — scans full project history every refresh.**
- Global twin `analytics.mv_user_posts_engagement` adds a 3rd **retweet** branch, sourced from
  `user_post`.
- Refreshed by `analytics.refresh_engagement_views_all()`.

**Layer 2 — Feature MVs** (`mindshare_score.mv_engagement_features_<proj>`, built by
`mindshare_score.create_engagement_clustering_features_view(keyword)`)
- Built **on top of** Layer 1. `GROUP BY root_post_id` → one row per root post. Computes
  `burst_concentration, duration_days_p90, cross_post_overlap, coordinated_burst, farming_score`
  using 60-min RANGE window functions + `percentile_cont(0.90)` + `LAG`.
- Refreshed by `mindshare_score.refresh_engagement_features_views_all()` which does
  `REFRESH … CONCURRENTLY` per project with a 10-min `statement_timeout`.

**Layer 3 — Decay / contribution scoring** (`mindshare_score.calculate_decay_scores(project, '30 days')`)
- **The biggest cost.** PL/pgSQL **iterates every reply for the project**, ordered
  `(user_x_id, post_created_at)`, maintaining a rolling 30-day "paintbrush" penalty via 3 parallel
  arrays. Multipliers: `FIRST_REPLY=1.0`, `LOCAL_DECAY=0.5`, `GLOBAL_DECAY=0.9`,
  `min_floor = base*0.01`. Writes `mindshare_score.contribution_scores`.
- `calculate_all_decay_scores()` = **`TRUNCATE contribution_scores`** → loop all projects → rebuild 5
  indexes. **Full rebuild, row-by-row, no upper date bound.** Global twin writes
  `global_contribution_scores` (non-local branch = `NEW_AUTHOR`, mult 1.0).
- `contribution_scores` has **no PK, no `updated_at`, no flags** → only a truncate-rebuild model works
  today, and the table is empty mid-rebuild (readers see nothing).

**Layer 4 — Leaderboard aggregation** (`mindshare_score.get_mindshare_leaderboard(start,end,project,…)`)
- STABLE function: filters `mv_engagement_<proj>` by `root_tweet_created_at BETWEEN start AND end`,
  joins windowed `contribution_scores`, applies per-user **post cap** (top-N by smart_reach per
  day/week/month from `project_post_cap`), computes:
  `mindshare_score = user_post_score + post_count*score + reply_count*score/100`,
  `mindshare_percent = score*100 / SUM(score) OVER ()`.

**Layer 5 — Snapshot leaderboards** (`snapshots.<proj>_{24hr,7d,30d,3m,6m,1yr}`, built by
`snapshots.create_mindshare_leaderboard_snapshot_mv(project)`)
- Each MV is a thin `SELECT * FROM get_mindshare_leaderboard(now()-<interval>, now(), project)`.
- **The only difference between the 6 windows is the start interval.** **78 MVs**, **none have any
  index.** Refreshing `_6m`/`_1yr` re-runs the full leaderboard over a 6-month/1-year window.

---

## 2. Core problems (concrete, not generic)

- **Full-history recompute everywhere.** Layer 1/2 `REFRESH` and Layer 3 `TRUNCATE`+row-by-row both
  scale with *total history × projects*, not new data. This is the "slow on 6mo/1yr" + "analytics lag".
- **Decay is row-by-row PL/pgSQL over all replies** and **truncates the table** each run — slowest
  component, and it makes scores briefly disappear.
- **78 snapshot MVs, no indexes, each re-runs the whole leaderboard function.** +6 MVs per new
  project. Long windows re-scanned every refresh. This is the worst scaling wall.
- **CONCURRENTLY is fragile**: `mv_engagement_nucleus`/`_sleepagotchi` and **all** feature MVs and
  **all** snapshot MVs have **no unique index** in the dump → `REFRESH … CONCURRENTLY` can't run on
  them (the features refresh proc assumes it can — likely silently failing or blocking).
- **No incremental hooks**: no triggers; `updated_at` is insert-time only; `contribution_scores` has
  no key/cursor. Nothing today can answer "what changed since the last run?"

---

## 3. Target architecture — MV→table decisions

| Object today | Type today | Target | Refresh model target |
|---|---|---|---|
| `analytics.mv_engagement_*` | MV, full history | **Partitioned TABLE** `mindshare.engagement` (by `project_keyword`) | Incremental upsert of new engagement rows |
| `analytics.mv_user_posts_engagement` | MV | **TABLE** (global engagement) | Incremental upsert |
| `mindshare_score.mv_engagement_features_*` | MV, GROUP BY root | **TABLE** `mindshare_score.engagement_features` | Recompute only root posts touched this hour |
| `mindshare_score.contribution_scores` | TABLE, TRUNCATE+rebuild | **TABLE (keep)** + PK + cursor | **Incremental upsert** (decay in Python) |
| `global_contribution_scores` | TABLE, TRUNCATE+rebuild | **TABLE (keep)** + PK + cursor | Incremental upsert |
| `snapshots.<proj>_<window>` ×78 | 78 MVs, no index | **ONE TABLE** `snapshots.leaderboard(project_keyword, window, …)` | Tiered: short windows hourly, long windows daily |

Rule of thumb applied: **anything that today does a full-history scan on every refresh becomes a
table we maintain by delta.** Cheap, fully-derived helpers can stay functions/MVs.

---

## 4. Per-layer change plan (the details)

### 4.1 Incremental foundation — flags & cursors (prereq for everything)
- Add a **watermark/cursor** per (project, stage), e.g. a small table
  `mindshare.pipeline_cursor(project_keyword, stage, last_post_created_at, last_run_at)`.
- Add **`needs_rescore boolean`** + **`scored_at timestamptz`** on `mindshare_post` (and `nucleus_post`
  already has `is_reply_fetched`). Ingestion sets `needs_rescore=true`; the hourly job clears it.
- Because `updated_at` is **not** auto-bumped (no triggers), drive deltas off
  `post_created_at > cursor` **and/or** `needs_rescore`, **not** `updated_at`. (Optionally add a
  `set_updated_at` trigger if we want reliable change tracking — decision below.)
- Add **`location`** to `mindshare.user` per the ticket (orthogonal to the pipeline).

### 4.2 Engagement layer → incremental table
- Create `mindshare.engagement` (partitioned by `project_keyword`) with the exact output columns of
  `mv_engagement_*` + a **UNIQUE key on `(project_keyword, engaged_tweet_id)`** (root-only rows keyed
  by `root_post_id`) and an `updated_at`.
- Hourly: for posts with `post_created_at > cursor` (new roots **and** new engagements), recompute the
  reply/quote/retweet matches **only for affected root posts** and **upsert**. Old engagement rows are
  immutable once their root ages out → no full rescan.
- Backfill once from the existing MV; parity-diff; switch readers; drop the MV.
- This replaces `create_engagement_view` / `refresh_engagement_views_all`.

### 4.3 Feature layer → incremental table
- Create `mindshare_score.engagement_features` (one row per root post, UNIQUE on
  `(project_keyword, root_post_id)`).
- Hourly: recompute features **only for `root_post_id`s whose engagement changed this hour** (driven by
  4.2's upserts), then upsert. The window functions (burst, p90, coordination) run per-root-post group,
  so per-affected-post recompute is cheap and correct.
- Keeps the same `farming_score` formula — **logic unchanged, execution scope changed.**

### 4.4 Decay / contribution scoring → incremental in Python
- **Stop `TRUNCATE` + row-by-row PL/pgSQL.** Add PK **`(project_keyword, reply_post_id)`** to
  `contribution_scores` (and `(reply_post_id)` to global) so we can `UPSERT` and refresh without
  emptying the table.
- Port the decay algorithm to a Python (Huey) worker that keeps **per-user rolling-window state**
  (the 30-day paintbrush arrays + last-processed reply timestamp) persisted between runs:
  - Hourly: load **only replies with `post_created_at > cursor`** per user, advance the rolling 30-day
    window (prune entries older than `reply_time - 30d`), apply the same `FIRST_REPLY/LOCAL_DECAY/
    GLOBAL_DECAY` multipliers + `min_floor`, **upsert** the affected rows.
  - Keep the existing SQL `calculate_decay_scores` as the **reference oracle** for a parity test, then
    deprecate it (and the `*_test` clones).
- Result: decay cost becomes **O(new replies + their users' windows)** instead of O(all replies), and
  scores never disappear mid-run.
- **Decision needed:** confirm the decay constants (0.50 / 0.90 / 30-day reset / 1% floor) carry over
  unchanged — Python will reproduce them exactly.

### 4.5 Leaderboard + snapshots → one table, tiered cadence
- Replace the **78 snapshot MVs** with a single partitioned table:
  `snapshots.leaderboard(project_keyword, window, rank, x_user_id, x_username, x_display_name,
  x_avatar_url, mindshare_score, mindshare_percent, computed_at)`, partitioned by `project_keyword`
  (sub-key `window`), UNIQUE `(project_keyword, window, x_user_id)`.
- A worker calls `get_mindshare_leaderboard(now()-interval, now(), project)` per (project, window) and
  **upserts** into the table. New project = new partition, **no new MV** (solves O(projects) growth).
- **Tiered freshness (the cheap, big win):**
  - `24hr`, `7d`, `30d` → **hourly**.
  - `3m`, `6m`, `1yr` → **daily** (they barely move hour-to-hour; this removes the most expensive
    scans from the hourly path).
- Keep `get_mindshare_leaderboard` as the compute function (optimised per ticket `-4`); only its
  *invocation cadence* and *output target* change.
- **Stretch / later:** make long windows truly incremental via rolling daily-bucket aggregates so even
  `1yr` is a sum of buckets, not a full scan.

### 4.6 Concurrency & settings
- Add the **missing UNIQUE indexes** (engagement, features, leaderboard) so non-blocking refresh/upsert
  works and readers are never blocked.
- Run independent per-project work in parallel via the Huey pool, bounded to leave CPU for ingest.
- Tune `work_mem`/`maintenance_work_mem`/parallel workers/autovacuum for the partitioned tables;
  right-size the box (4 vCPU was the Cockroach pain point).

---

## 5. What gets removed / deprecated
- Procedures superseded by incremental workers: `calculate_all_decay_scores`,
  `calculate_all_global_decay_scores`, `refresh_engagement_views_all`,
  `refresh_engagement_features_views_all`, `create_*_view` builders, `create_all_snapshots_views`
  (keep the *compute* logic, drop the *full-rebuild orchestration*).
- `*_test` schemas + `test_*` function clones + `test_*contribution_scores`.
- Dead tables: `contamination_cleanup_20260526`, stray `public.mindshare_user`.
- The 78 `snapshots.*` MVs (after the table cutover) and the engagement/feature MVs (after table cutover).

## 6. New hourly flow (target)
```
cursor = last_run_watermark(project)
1. ingest new raw_post → mindshare_post (sets needs_rescore / post_created_at)
2. engagement upsert      : affected root posts since cursor → mindshare.engagement
3. features upsert         : changed root_post_ids → mindshare_score.engagement_features
4. decay (Python)          : new replies since cursor → contribution_scores (upsert, rolling state)
5. leaderboard upsert      : per project → snapshots.leaderboard  (24hr/7d/30d hourly; 3m/6m/1yr daily)
6. advance cursor, clear needs_rescore, emit metrics
```
Target: full hourly cycle < 20 min; long-window leaderboards off the hourly critical path.

## 7. Open decisions (need Saurav)
1. **Decay constants** — confirm 0.50/0.90/30-day/1% floor reproduced as-is in Python.
2. **Change-tracking** — add `updated_at` bump triggers, or rely on `post_created_at`+`needs_rescore`
   cursor only? (Recommend cursor + flag; no triggers, to keep writes cheap.)
3. **Snapshot tiering** — confirm 24hr/7d/30d hourly, 3m/6m/1yr daily.
4. **Leaderboard table grain** — store full leaderboard (≤1100 rows/window) or top-N only?
5. **Box sizing** for UAT (vCPU/RAM) given the new parallel hourly load.
