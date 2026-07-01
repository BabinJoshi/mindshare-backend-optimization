# Mindshare Backend — Optimization Summary & Scale Plan

**Author:** Data engineering review
**Date:** 2026-06-30
**DB:** PostgreSQL 16.11 (Debian)
**Method:** Live verification via Postgres MCP against the existing analysis docs
(`review.md`, `db-analysis/*.md`). Numbers below are what the database **actually**
reports today, not what the docs assert.

---

## 1. The Goal

Audit and optimize the `mindshare` → `analytics` → `mindshare_score` pipeline for
**faster access and scale**, without touching production objects. All fixes land in
`*_md_fix` schemas; original schemas get only non-destructive index additions. Then
verify, document, and lay out a forward plan.
"" 
---

## 2. Architecture (verified)

```
LAYER 1  mindshare          raw posts/users. mindshare_post partitioned LIST by project_keyword.
                            user_post UNPARTITIONED 2.6 GB. nucleus_post_general 3.0 GB.
   │
LAYER 2  analytics          mv_engagement_<project> × 11 + mv_user_posts_engagement (matviews)
   │
LAYER 3  mindshare_score    mv_engagement_features_<project> × 11 (farming scores)
                            contribution_scores / global_contribution_scores (decay scores)
   │
LAYER 4  mindshare_score    25 public API functions (get_v2_analytics, leaderboard, …)
```

Undocumented schemas also present and live: `raw_data`, `snapshots`, `logs`,
`alembic` (migrations), `public`, and a full **`test_*` mirror** (`test`,
`test_analytics`, `test_mindshare`, `test_mindshare_score`). The `test_mindshare_score`
schema is not dead — it holds a working **incremental decay engine** (see §5).

---

## 3. Verification — Docs vs. Live DB

The prior docs are directionally correct on *findings* but **stale on numbers and
overclaim completion**. The database has grown substantially since they were written.

| Item | Docs claim | Live DB (2026-06-30) | Verdict |
|---|---|---|---|
| `analytics.mv_engagement_quipnetwork` rows | 1.99M | **5.17M** | Docs stale (~2.6×) |
| `mindshare_score.contribution_scores` rows | 1.94M | **5.19M** | Docs stale (~2.7×) |
| `analytics_md_fix` matviews | 12, populated | 12, populated, quip count **matches** prod (5.17M) | ✅ Done |
| `mindshare_score_md_fix` feature matviews | "11 built" | **only 3** (technotainment, ironallies_, nucleus) | ❌ Overclaim — 8 missing |
| `mindshare_score_md_fix.contribution_scores` | "same as prod" | **47,898 rows — Acurast only** (12 MB) | ❌ Pilot only |
| `mindshare_score_md_fix.global_contribution_scores` | implied done | **empty** (56 kB) | ❌ Not populated |
| Index work P7/P8 (decay + replier_time) | applied | **all present** — `idx_cs_keyword_replier_time`, `idx_gcs_replier_time`, `ix_msp_<project>_decay` on all 10 partitions, `ix_user_post_decay_*` | ✅ Done |
| `mindshare_md_fix` fixed functions (Bugs 2/3/4) | 3 created | **3 present** | ✅ Done |
| Drop 4 dead `mindshare.calculate_*` funcs | manual, pending | **still present** | ⏳ Pending |
| Prod buggy funcs (hardcoded acurast / user_x_score) | fixed in md_fix | **prod still buggy** (fixes not promoted) | ⏳ By design |
| `mindshare_score.contribution_scores_mv` (empty legacy) | drop candidate | **still present** | ⏳ Pending |

### Bottom line
- **Done & verified:** all index work; `analytics_md_fix` (12 matviews, row-count parity);
  `mindshare_md_fix` bug-fix functions.
- **Partial:** `mindshare_score_md_fix` — feature matviews exist for only 3 small projects;
  the 8 large/important ones (**quipnetwork, thearcterminal, yom_official, pact_swap,
  sleepagotchi, cnpynetwork, d3lmundos, acurast**) are **not built**. Decay table holds
  Acurast only.
- **Not started / pending manual:** dropping dead functions, dropping the empty
  legacy matview, and promoting any fix to production.
- **Not in docs at all:** the `test_mindshare_score` incremental decay engine, and the
  server-level config that is the single biggest performance lever (§4).

---

## 4. The Biggest Unaddressed Win: Server Config

The analysis chased query-level rewrites but missed that the instance is configured
with near-default memory. On a DB with multiple multi-GB tables this throttles
every refresh and analytic query.

| Setting | Current | Problem | Recommended |
|---|---|---|---|
| `work_mem` | **4 MB** | Every large HashAggregate/sort spills to disk. Docs measured 348ms→85ms on acurast just by raising it. | 256–512 MB **per refresh session** via `SET LOCAL` (not global) |
| `shared_buffers` | **128 MB** | Trivial cache for a ~15 GB+ working set → constant page churn | ~25% of RAM |
| `effective_cache_size` | 4 GB | Tells planner ~12 GB OS cache exists; if box has more RAM, raise it | ~50–75% of RAM |
| `maintenance_work_mem` | 64 MB | Slow `CREATE INDEX`/`VACUUM` on multi-GB tables | 1–2 GB during maintenance |
| `max_parallel_workers_per_gather` | 2 | Large seq scans/aggregates under-parallelized | 4 (verify core count) |

**Action:** confirm host RAM, then tune `postgresql.conf` (or the managed-instance
parameter group). `SET LOCAL work_mem` inside refresh procedures is zero-risk and can
ship today. This likely yields more aggregate speedup than all the CTE rewrites combined.

Also: `last_analyze = NULL` on `contribution_scores` — **statistics have never been
manually analyzed**. Run `ANALYZE` on the big tables; autovacuum alone is letting them
drift.

---

## 5. Incremental Decay Engine (`test_mindshare_score`) — undocumented but valuable

Already prototyped and holding 2.7M rows:

- `calculate_decay_scores_incremental`, `calculate_global_decay_scores_incremental`
- `decay_run_log`, `decay_run_state` (watermark/run tracking), `get_decay_run_status`
- `_decay_apply_project` / `_decay_apply_global` (+ `_tail` variants)

This is the Layer-3 "watermark incremental" pattern the `incremental-mv-plan.md`
proposes — but built for **decay scores**, not yet for the **feature matviews**. It
should be folded into the official plan rather than left as a side experiment.

---

## 6. Forward Plan — Optimize & Scale

Ordered by ROI (effort → payoff). Ship top-down.

### Phase 0 — Config & stats (hours, zero risk, highest ROI)
1. `SET LOCAL work_mem='512MB'` (and `maintenance_work_mem`) inside every refresh/build procedure.
2. Tune `shared_buffers`, `effective_cache_size`, parallel workers at the instance level after confirming RAM.
3. `ANALYZE` all large tables; verify autovacuum thresholds on `contribution_scores`, `global_contribution_scores`, `user_post`.

### Phase 1 — Finish what's claimed (1–2 days)
4. Build the **8 missing** `mindshare_score_md_fix.mv_engagement_features_*` (run `create_all_engagement_clustering_views` with the work_mem fix).
5. Populate `mindshare_score_md_fix.contribution_scores` for **all** projects + `global_contribution_scores` (currently Acurast-only / empty).
6. Re-run the doc's verification queries and **correct the stale row counts** in `db-analysis/*.md`.

### Phase 2 — Cleanup & promotion (0.5 day, needs sign-off)
7. After caller re-verification (data has changed since the grep), drop the 4 dead `mindshare.calculate_*` functions and the empty `mindshare_score.contribution_scores_mv`.
8. **Promotion strategy** — the bug fixes deliver nothing while they sit in `md_fix`. Decide and execute: either `CREATE OR REPLACE` the 3 fixed functions into `mindshare`, or repoint the application to `mindshare_md_fix`. *(This is the gap between "fixed" and "fixed in production".)*

### Phase 3 — Incremental refresh (1 week)
9. Promote the `test_mindshare_score` incremental decay engine into the standard pipeline (watermark-driven, hourly/daily incremental + weekly full).
10. ~~Extend the watermark/UPSERT pattern to feature matviews: convert MV→table.~~ **✅ DONE — see §8 (measured: quipnetwork full 172.7s → incremental 6.2s = 28×).**
11. Pre-aggregate `mv_root_stats_<project>` so feature refresh stops re-scanning the full engagement matview.

### Phase 4 — Structural scale (2–3 weeks, when growth demands)
12. **Partition `mindshare.user_post`** (3.5M rows, 2.6 GB, unpartitioned) by `post_created_at` RANGE — enables pruning on the date-range API path.
13. **Time-slice the analytics matviews** (`_2024`/`_2025`/`_current`) so immutable history is never re-refreshed; only the current slice refreshes nightly.
14. Establish a single **orchestrated refresh DAG** enforcing layer order (raw → analytics → features/scores) with `CONCURRENTLY` throughout, replacing ad-hoc per-procedure refreshes.

---

## 7. Risks / Open Questions

- **md_fix is not production.** Every "fixed" bug is still live for end users until Phase 2.8 runs. Confirm with stakeholders whether to replace-in-place or repoint the app.
- **Dead-function drop** was verified by grep weeks ago; re-verify callers before dropping — codebase and DB both changed.
- **Three parallel contribution_scores tables** now exist (prod 5.19M, md_fix Acurast 48K, test 2.7M). Define which is canonical before promotion to avoid divergence.
- **Host RAM unknown** — Phase 0 config targets need the actual instance size to set absolute values.

---

## 8. Implemented — Feature Pipeline: MV → Incremental Table (2026-06-30)

Replaced the per-project feature **materialized views** with **regular tables +
watermark + incremental UPSERT** in `mindshare_score_md_fix`. The 12-CTE farming-score
logic is byte-for-byte the old logic — only the refresh mechanism changed.

> **Full per-object comparison, ops guide, and a copy-paste self-test runbook live in
> [`docs/comparisons/`](comparisons/README.md)** (old-vs-new per procedure/function/MV,
> how to trigger/schedule incremental, and how to verify it yourself).
>
> **quipnetwork "~3 min" — confirmed & explained:** a *full* rebuild is still ~2.9 min
> (172.7 s — same heavy logic, never the optimization target). Daily operation no longer
> needs a full rebuild: **incremental = 2.2–6.2 s (~30–80× less)**. Re-runs: sleepagotchi
> incremental 16.5→17.4 s; API top-N 0.5–1.3 ms vs MV 59–64 ms. Correctness re-confirmed
> **0 diff** vs the old MV (incl. a corruption-and-heal test).
>
> **Decay (Polars `decay.py` technique ported to SQL):** the O(n·k) PL/pgSQL loop was
> replaced by a **set-based, 2-window-pass** procedure (`calculate_decay_scores_fast`),
> validated 99.88% vs production (remainder = tied-timestamp rows, undefined in the original).
> Measured **sleepagotchi 244 s → 66 s (3.7×)**, identical row counts. Polars remains fastest
> for the heaviest full runs. See [`comparisons/decay-pipeline.md`](comparisons/decay-pipeline.md)
> and [`comparisons/inventory.md`](comparisons/inventory.md) (what changed / what's removable).

**New objects** (`Mindshare_Backend/Mindshare_score_md_fix/functions/incremental_features.sql`):

| Object | Role |
|---|---|
| `features_<project>` (table, PK `root_post_id`) | UPSERT target; replaces `mv_engagement_features_<project>` |
| `feature_watermarks` (table) | per-project last processed `engaged_tweet_created_at` |
| `_features_pipeline_sql(mv, scope)` | returns the 12-CTE SELECT; `scope` filters base CTE (shared by full + incremental — no duplicated SQL) |
| `build_features_full(project)` | `TRUNCATE` + `INSERT` whole pipeline, set watermark |
| `refresh_features_incremental(project)` | recompute only **hot authors'** posts since watermark, `ON CONFLICT … DO UPDATE` |
| `build_all_features()` / `refresh_all_features_incremental()` | orchestrators over all 11 projects |
| indexes per table | PK `root_post_id`, + `root_user_id`, `farming_score`, `root_tweet_created_at` |

**Correctness constraint honored:** `cross_post_overlap` needs an author's *full* post
history, so the incremental scope is *all posts by authors with new engagement* (not just
new posts). Proven: rewound sleepagotchi watermark 1 day, corrupted all 251,513 hot rows,
ran incremental → **0 rows still corrupt, 0 diff vs. the old MV** (`EXCEPT` both ways).
The new full-table build is also row-for-row identical to the old MV (760,154 rows, 0 diff).

### Measured benchmarks (EXPLAIN ANALYZE / `clock_timestamp`)

**Refresh — full rebuild vs. incremental (1-day watermark):**

| Project | Old full MV rebuild | New full table build | New incremental (1-day) | Incremental speedup | Hot authors / total |
|---|---|---|---|---|---|
| sleepagotchi (760K rows) | 60.7 s | 50.0 s | **16.5 s** | **3.7×** | 610 / 26,454 |
| quipnetwork (2.81M rows) | — | 172.7 s | **6.2 s** | **28×** | 6 / 45,706 |

Incremental speedup scales with how *concentrated* engagement is: quipnetwork's 6 hot
authors own few posts → 28×; sleepagotchi's prolific hot authors own ~33% of posts → 3.7×.
Either way it beats a full rebuild, and the worst case degrades gracefully to ~full-build cost.

**API query — `get_engagement_clustering`, top-100 farming posts, 2-day window:**

| Backing store | Plan | Execution time |
|---|---|---|
| Old materialized view (no time index) | parallel seq scan + sort over 240K rows | 59.3 ms |
| New table (`farming_score` index) | index-backward scan, stops at 100 | **0.54 ms** |

**~110× faster** on the realistic dashboard query. `get_engagement_clustering` was
repointed to the table. For wide "return everything" queries the table is roughly even
with the MV but avoids the MV's 22 MB external sort spill (relevant under `work_mem=4MB`).

### Base-table indexes — tested, none added
The incremental hot-author scope subquery already uses the existing
`ix_mv_engagement_<project>_eng_created` index (20.7 ms for sleepagotchi 1-day). A
`root_user_id` index on the source matview would not help — hot authors match ~33% of
rows on the worst project, so the planner correctly seq-scans. No dead index added.

### Status & rollout
- All **11** `features_<project>` tables built and populated (1.97 GB total); watermarks set.
- Build times: technotainment/cnpynetwork/acurast/d3lmundos/ironallies/nucleus (small, batched);
  pact_swap 49 s, yom_official 49 s, thearcterminal 95 s, quipnetwork 173 s.
- **Not yet done:** cron wiring (hourly incremental + weekly full via the orchestrators);
  the old `mv_engagement_features_*` MVs still exist — drop after the table path is wired
  into the app. `build_all_features()` uses per-loop `COMMIT`, so run it from psql/cron,
  **not** inside an explicit transaction.
