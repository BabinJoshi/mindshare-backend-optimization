# Feature Pipeline — Materialized View → Incremental Table

**Scope:** the farming-score feature layer, one object per project
(`mv_engagement_features_<project>` → `features_<project>`).
**Source file:** [`Mindshare_Backend/Mindshare_score_md_fix/functions/incremental_features.sql`](../../Mindshare_Backend/Mindshare_score_md_fix/functions/incremental_features.sql)

The **scoring math did not change.** The same 12-CTE pipeline (burst windows, coordination,
cross-post overlap, farming score) produces the same numbers — proven row-for-row in
[verification.md](verification.md). What changed is **how and when the data is materialized.**

---

## 1. The old way — materialized view, full recompute every time

```
mindshare_score_md_fix.create_engagement_clustering_features_view(project)
    → DROP MATERIALIZED VIEW … CASCADE
    → CREATE MATERIALIZED VIEW mv_engagement_features_<project> AS <12-CTE pipeline over the WHOLE project>
    → CREATE UNIQUE INDEX (root_post_id)
```

How it worked:
- Every refresh re-scanned the **entire** `analytics_md_fix.mv_engagement_<project>` matview
  and recomputed every post's score from scratch — even posts that hadn't changed in weeks.
- A refresh meant `DROP` + `CREATE`, so the data **disappeared mid-refresh** (or, with
  `REFRESH`, took an exclusive lock). No way to update just the rows that moved.
- Cost was proportional to **total project size**, not to how much new data arrived.

What it cost (measured):
- quipnetwork full rebuild ≈ **172.7 s (2.9 min)** — this matches the historically reported
  "~3 minutes" for quipnetwork. **The full rebuild has NOT gotten faster** (same heavy logic).
- sleepagotchi full MV rebuild = **60.7 s**.

The only knobs were `work_mem = 512MB` (already set, avoids HashAggregate disk spill) and the
hourly-bucket / `LEFT JOIN` rewrites — all still present in the new pipeline.

---

## 2. The new way — regular table + watermark + incremental UPSERT

```
features_<project>        TABLE, PK root_post_id           ← UPSERT target, never dropped
feature_watermarks        TABLE, one row per project       ← last engagement timestamp processed
_features_pipeline_sql()  FUNCTION                         ← returns the 12-CTE SELECT, optionally scoped
build_features_full()     PROCEDURE                        ← TRUNCATE + INSERT whole pipeline
refresh_features_incremental() PROCEDURE                   ← recompute hot authors only, UPSERT
build_all_features() / refresh_all_features_incremental()  ← orchestrators over all 11 projects
```

Key idea: **most posts are "cold."** A post's farming score stabilizes after its engagement
burst (first 24–48 h). Only posts touched by recent engagement need recomputing. So instead of
recomputing 2.8M rows nightly, recompute the few thousand that actually moved.

---

## 3. Object-by-object

### 3.1 `_features_pipeline_sql(mv_name, scope_predicate)` — NEW

A single function returns the 12-CTE scoring SELECT, with a `scope_predicate` injected into the
`base` CTE. This is why the full and incremental paths can share **one** copy of the scoring
logic — no risk of the two drifting apart.

- Full path passes `scope_predicate = ''` → pipeline over the whole project.
- Incremental path passes a `WHERE root_user_id IN (hot authors)` predicate.

**What changed:** the pipeline body is identical to the old MV's inner `SELECT`. Only the source
of the SQL moved from inline-in-the-MV-DDL to a reusable function.

### 3.2 `build_features_full(project)` — replaces `create_…_features_view`

| | Old MV proc | New `build_features_full` |
|---|---|---|
| Mechanism | `DROP` + `CREATE MATERIALIZED VIEW` | `TRUNCATE` + `INSERT … SELECT` into a table |
| Data during refresh | gone / exclusive-locked | table stays queryable until TRUNCATE; fast repopulate |
| Side effect | — | sets `feature_watermarks.last_engaged_at = MAX(engaged_tweet_created_at)` |
| Indexes | unique on root_post_id | PK root_post_id + `root_user_id` + `farming_score` + `root_tweet_created_at` |
| Output | identical rows | **identical rows (verified 0 diff)** |
| Time | quip 172.7 s, sleepagotchi 60.7 s | quip 172.7 s, sleepagotchi 50 s cold / 35 s warm |

**Takeaway:** full build ≈ same speed (same logic). Its job is now the *weekly* fallback, not the
*daily* operation. The extra indexes are what make the read side fast (§3.4).

### 3.3 `refresh_features_incremental(project)` — NEW (the actual win)

Logic:
1. Read `last_engaged_at` from the watermark. If absent → fall back to full build.
2. **hot authors** = `SELECT DISTINCT root_user_id FROM analytics_md_fix.mv_engagement_<project> WHERE engaged_tweet_created_at > watermark`.
3. Run the 12-CTE pipeline scoped to **all posts by those authors**.
4. `INSERT … ON CONFLICT (root_post_id) DO UPDATE` — upsert the recomputed rows.
5. Advance the watermark to the new max.

**Why scope to whole authors, not just new posts?** `cross_post_overlap` for a post depends on
the author's *entire* post history (which engagers also engaged the author's other posts). A new
engagement can change an author's older posts' overlap. Scoping by author (not by post) keeps the
metric correct. This is the one place incremental can't be cheaper than "authors who were active."

Measured:

| Project | Full build | Incremental (1 day new data) | Hot authors / total | Speedup |
|---|---|---|---|---|
| quipnetwork | 172.7 s | **6.2 s** (re-run 2.2 s) | 6 / 45,706 | **28–80×** |
| sleepagotchi | 60.7 s (old MV) | **16.5 s** (re-run 17.4 s) | 610 / 26,454 (~33% of posts) | **3.5–3.7×** |

The spread is the honest story: incremental wins big when recent engagement is spread thin
(quip), and wins modestly when a few prolific authors dominate recent activity (sleepagotchi,
whose hot authors own ~33% of all posts). It never loses — worst case approaches full-build cost.

### 3.4 `get_engagement_clustering(start_ts, end_ts, project)` — repointed MV → table

Same signature, same output columns. Only the `FROM` changed:
`mv_engagement_features_<project>` → `features_<project>`.

The table carries a `farming_score` index, so the common dashboard query (top-N farming posts in
a date window, `ORDER BY farming_score DESC LIMIT 100`) becomes an **index-backward scan that
stops at 100 rows** instead of a parallel seq-scan + sort over the whole window.

| Backing store | Plan | Time |
|---|---|---|
| Old MV (no useful index) | parallel seq scan ~240K rows + top-N sort | 59–64 ms |
| New table (`farming_score` index) | index scan backward, stop at 100 | **0.5–1.3 ms** |

≈ **50–110×** on the realistic query. For non-selective "give me the whole window" queries the
two are comparable, but the table avoids the MV's 22 MB external sort spill (under `work_mem=4MB`).

---

## 4. Trade-offs introduced (be honest)

- **More storage:** 11 feature tables = 1.97 GB (tables + 4 indexes each) vs the MVs' single
  index. Acceptable for the read speed and incremental ability.
- **A watermark to maintain:** one row per project. Wrong watermark = stale or over-work, never
  incorrect data (a full build always re-syncs).
- **Full rebuild unchanged:** if you only ever full-rebuild, you gained the read-side index speed
  but not the refresh speed. The refresh win requires using `refresh_features_incremental`.
- **Old MVs still exist:** drop `mv_engagement_features_*` only after the app reads the table path.

See [verification.md](verification.md) to reproduce every number above and to test incremental
yourself.
