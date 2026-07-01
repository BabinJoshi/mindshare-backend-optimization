# Old vs New — Comparison & Operations Guide

This folder documents every changed database object: **how the old version worked, how
the new `_md_fix` version works, what changed, and the measured performance difference.**
All numbers here were measured live on PostgreSQL 16.11 (2026-06-30) and are reproducible
with the queries in [verification.md](verification.md).

## Contents

| Doc | Covers |
|---|---|
| [feature-pipeline.md](feature-pipeline.md) | Feature **materialized views → incremental tables**. Per-object breakdown of `build_features_full`, `refresh_features_incremental`, `_features_pipeline_sql`, `get_engagement_clustering`. |
| [decay-pipeline.md](decay-pipeline.md) | Decay: PL/pgSQL **loop vs Polars (`decay.py`) vs new set-based SQL**. Technique, correctness, benchmarks, which to use. |
| [inventory.md](inventory.md) | **Change inventory / changelog**: every object added, where it lives (schema + repo file), and which old objects can be removed (with SQL). |
| [scalability-maintainability.md](scalability-maintainability.md) | Coverage across all 3 schemas, scalability per layer, maintainability risks, ranked future work. |
| [inherited-changes.md](inherited-changes.md) | Pre-existing changes (analytics MV `NOT EXISTS`→`LEFT JOIN`, decay batch, bug-fix functions). Logic compared; perf as documented by prior analysis. |
| [verification.md](verification.md) | Every benchmark + correctness query, copy-paste runnable, with results. |

## Coverage at a glance — is this done for all three schemas?

**No, and intentionally not uniform** (full analysis in [scalability-maintainability.md](scalability-maintainability.md) §1):

| Layer (schema) | Optimization | Incremental? |
|---|---|---|
| `mindshare` (raw) | LIST-partitioned + downstream indexes | N/A (source) |
| `analytics` (engagement MVs) | `NOT EXISTS`→`LEFT JOIN` rewrite | ❌ still full-refresh MVs — **next gap** |
| `mindshare_score` (features) | **MV → incremental table** | ✅ done |
| `mindshare_score` (decay) | set-based SQL (3.7×+) + Polars path; incremental prototype in `test_mindshare_score` | partial |

---

## How the incremental refresh is triggered — and how you run it

**There is no database trigger.** The pipeline is **pull-based**: you (or a scheduler)
`CALL` a procedure. Nothing fires automatically on `INSERT`. This is deliberate — the
analytics matviews upstream are themselves refreshed on a schedule, so feature refresh is
chained after them, not driven by row events.

### The three things you call

```sql
-- 1. ONE-TIME / FULL: build (or fully rebuild) one project's feature table.
CALL mindshare_score_md_fix.build_features_full('quipnetwork');

-- 2. ONGOING / INCREMENTAL: recompute only the posts of authors who got new
--    engagement since the last run. Auto-falls back to a full build if never built.
CALL mindshare_score_md_fix.refresh_features_incremental('quipnetwork');

-- 3. ALL PROJECTS at once (loops every analytics_md_fix engagement matview):
CALL mindshare_score_md_fix.build_all_features();              -- full, all 11
CALL mindshare_score_md_fix.refresh_all_features_incremental();-- incremental, all 11
```

> ⚠️ `build_all_features()` / `refresh_all_features_incremental()` issue a `COMMIT` after
> each project so partial progress survives a crash. **Run them from `psql`, `pg_cron`, or
> a cron script — NOT inside an explicit `BEGIN…COMMIT` block** (you'll get
> `invalid transaction termination`). The single-project procedures are transaction-safe
> anywhere.

### The watermark — what makes "incremental" work

Each project has one row in `mindshare_score_md_fix.feature_watermarks`:

```sql
SELECT * FROM mindshare_score_md_fix.feature_watermarks;
-- project | last_engaged_at | last_refresh_at | last_mode
```

- `last_engaged_at` = the newest `engaged_tweet_created_at` already processed.
- An incremental run finds **hot authors** = authors with engagement *newer* than
  `last_engaged_at`, recomputes **all their posts** (needed for `cross_post_overlap`
  correctness), UPSERTs, then advances the watermark.
- To force a clean rebuild: `CALL build_features_full(...)` (it resets the watermark), or
  delete the project's watermark row and run incremental (it falls back to full).

### Recommended schedule (you implement this — not yet wired)

| Job | Command | Cadence |
|---|---|---|
| Incremental refresh | `CALL mindshare_score_md_fix.refresh_all_features_incremental();` | hourly or every few hours, **after** the analytics MV refresh |
| Full rebuild | `CALL mindshare_score_md_fix.build_all_features();` | weekly (off-peak), to absorb any drift |

**With `pg_cron` (if installed):**
```sql
SELECT cron.schedule('features_incremental','0 * * * *',
  $$CALL mindshare_score_md_fix.refresh_all_features_incremental()$$);
SELECT cron.schedule('features_full_weekly','0 4 * * 0',
  $$CALL mindshare_score_md_fix.build_all_features()$$);
```

**With OS cron + psql:**
```bash
0 * * * *  psql "$PG_URL" -c "CALL mindshare_score_md_fix.refresh_all_features_incremental()"
0 4 * * 0  psql "$PG_URL" -c "CALL mindshare_score_md_fix.build_all_features()"
```

Correct order each cycle: **analytics MV refresh → feature incremental refresh** (features
read from `analytics_md_fix.mv_engagement_*`).

### How the application reads results

```sql
-- via the API function (now table-backed):
SELECT * FROM mindshare_score_md_fix.get_engagement_clustering(:start_ts,:end_ts,'quipnetwork');
-- or directly:
SELECT * FROM mindshare_score_md_fix.features_quipnetwork WHERE farming_score > 70;
```

---

## Verified results (summary)

All claims below were re-run and confirmed; full evidence in [verification.md](verification.md).

### Correctness — new logic produces identical results ✅
- New full table build vs old materialized view (sleepagotchi): **760,154 rows, 0 difference** in both directions (`EXCEPT`), confirmed on two separate runs.
- Incremental refresh after deliberately corrupting all 251,513 hot-author rows: **0 rows left corrupt, 0 difference vs the old MV** — proves incremental recomputes the right rows correctly.
- After a full → incremental cycle: **0 difference** vs the old MV.

### Latency — measured (not estimated)

| What | Old | New | Speedup |
|---|---|---|---|
| sleepagotchi refresh (1-day of new data) | 60.7 s full MV rebuild | **16.5–17.4 s** incremental | **3.5–3.7×** |
| quipnetwork refresh (1-day of new data) | 172.7 s full build | **2.2–6.2 s** incremental | **28–80×** |
| `get_engagement_clustering` top-100, 2-day window | 59–64 ms (MV seq scan + sort) | **0.5–1.3 ms** (table + `farming_score` index) | **~50–110×** |
| decay refresh, sleepagotchi (~730K replies) | 244 s PL/pgSQL loop | **66 s** set-based SQL | **3.7×** (grows with per-replier window size) |

Honest caveats:
- Full-build time is cache-dependent (sleepagotchi 50 s cold / 35 s warm). Incremental time is stable.
- Incremental speedup scales with how concentrated recent engagement is. quipnetwork's 6 hot authors (of 45,706) → up to 80×; sleepagotchi's prolific hot authors own ~33% of posts → ~3.6×. Worst case degrades gracefully toward full-build cost, never worse.
- API speedup is largest for selective/top-N queries (the dashboard pattern). For "return everything sorted" the two are close, but the table still avoids the MV's 22 MB external sort spill under `work_mem = 4 MB`.
