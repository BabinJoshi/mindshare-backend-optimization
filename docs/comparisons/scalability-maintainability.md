# Scalability, Maintainability & Future Prospects

A deep look at how the three layers (`mindshare` → `analytics` → `mindshare_score`) behave as
data grows, how maintainable the current `_md_fix` design is, and where to invest next.

---

## 1. Coverage today — is incrementalization done for all three schemas?

**No — and it shouldn't be uniform.** Each layer has a different nature:

| Layer | Schema | What it is | Incremental status |
|---|---|---|---|
| Raw | `mindshare` | source tables (partitioned by project; `user_post` not partitioned) | N/A — it's the input. Indexed for downstream joins. |
| Aggregation | `analytics` | `mv_engagement_*` materialized views | rewritten (`NOT EXISTS`→`LEFT JOIN`) but **still full-refresh MVs** — no watermark |
| Features | `mindshare_score` | farming-score per post | ✅ **incremental tables** (`features_<project>`) |
| Decay | `mindshare_score` | per-reply contribution scores | set-based SQL (✅ faster) + incremental prototype in `test_mindshare_score` |
| API | `mindshare_score` / `mindshare_md_fix` | 25+ read functions | clustering fn repointed to table; others read MVs/tables directly |

So: **features = incremental tables; decay = set-based (and an untouched incremental
prototype); analytics = still MVs; raw = indexed/partitioned source.** The next structural gap
is the **analytics layer** (§4).

---

## 2. Scalability analysis per layer

### 2.1 Raw `mindshare`
- `mindshare_post` is **LIST-partitioned by project_keyword** — this is the single most
  important scalability property: every project-scoped job (engagement MV, decay, features)
  prunes to one partition. Verified: project decay scans only `mindshare_post_<project>`.
- **Bottleneck:** `user_post` (3.5M rows, 2.6 GB, **unpartitioned**). Global decay and
  `get_post_metrics_from_user_post` must scan the whole table. As it grows this degrades
  linearly with no pruning. **Fix:** RANGE-partition by `post_created_at`.
- Indexes: the `is_reply AND replied_post_id IS NOT NULL` predicate selects ~95% of a project
  partition, so a **seq scan is optimal for full recompute** — extra indexes don't help there.
  They help only selective/incremental access (a single replier, a date slice).

### 2.2 Aggregation `analytics`
- Each `mv_engagement_<project>` refresh re-scans the whole project partition. Cost scales with
  **total project size**, not new data. quipnetwork is already 681 MB / 5.2M rows.
- The `LEFT JOIN IS NULL` rewrite removed the O(n²) anti-join, so refresh is now linear — but
  still a **full rebuild**. This is the next thing to make incremental (§4).

### 2.3 Features `mindshare_score` (done)
- Incremental tables scale with **new engagement**, not project size. quipnetwork incremental =
  2–6 s vs 173 s full. The one non-linearity is the `cross_post_overlap` author-scope: a hot
  prolific author drags in all their posts. Worst case → full-build cost, never worse.
- Read path: `farming_score` + `root_tweet_created_at` indexes make top-N dashboard queries
  O(log n) instead of full-scan-and-sort.

### 2.4 Decay `mindshare_score`
- Set-based SQL is O(n log n) (sorts) vs the loop's O(n·k). It scales far better as repliers get
  prolific, but RANGE-frame windows + per-row `numeric` keep a constant factor that Polars
  avoids. For the heaviest full runs, Polars (`decay.py`) remains fastest.
- True scalability answer for decay = **incremental** (only repliers with new replies): the
  `test_mindshare_score` engine already prototypes this. Set-based is the best *full-recompute*
  in-DB option; incremental is the best *steady-state* option.

---

## 3. Maintainability

### Strengths of the current design
- **Single source of scoring logic.** `_features_pipeline_sql(mv, scope)` returns the 12-CTE
  body used by both full and incremental paths — they can't drift. Same idea keeps the decay
  classification in one place.
- **Production untouched.** Everything is in `_md_fix`; rollback = drop the schema. Zero risk to
  live tables.
- **Replayable.** Every change is in an idempotent `.sql` file (`CREATE OR REPLACE`,
  `IF NOT EXISTS`) kept in sync with the DB; see [inventory.md](inventory.md).
- **Self-verifying.** `_bench_log` + the runbook in [verification.md](verification.md) make
  every claim reproducible.

### Risks / debts
- **Three decay implementations** (loop, Polars, set-based) + a 4th prototype. That's a
  maintenance smell — pick one steady-state engine and retire the loop (inventory.md §C).
- **Naming drift in source data:** matviews like `mv_engagement_ironallies_` and
  `mv_engagement__technotainment` carry trailing/leading separators from raw keywords. The slug
  logic handles them, but they're a readability tax and a footgun for anyone hand-writing names.
- **Two `*_md_fix` worlds vs `test_*` world.** `test_mindshare_score` holds the best decay
  incremental engine but lives outside the `_md_fix` convention. Decide one home.
- **`_md_fix` is not production.** None of this helps end users until promoted. The longer the
  fork lives, the more prod and `_md_fix` can diverge (prod data already grew ~2.6× since the
  first analysis). Promotion is the real outstanding decision.
- **`active_multipliers` is NULL** in set-based decay. If any consumer reads it, they need the
  loop/Polars output or an added (cheaper) reconstruction.

---

## 4. Future prospects — ranked by value

1. **Make `analytics.mv_engagement_*` incremental** (same watermark/UPSERT pattern as features).
   Today a feature incremental still depends on a *fully refreshed* analytics MV upstream, so the
   analytics full-rebuild is the next ceiling. Convert to `engagement_<project>` tables fed by
   "new posts/replies since watermark." Biggest end-to-end win.
2. **Partition `user_post` by time.** Unblocks pruning for global decay and user-post metrics;
   prerequisite for global incremental decay.
3. **Productionize ONE decay engine.** Promote the `test_mindshare_score` incremental engine (or
   the set-based proc for full runs) into `mindshare_score_md_fix`, retire the loop, and wire a
   watermark so daily decay is seconds not minutes.
4. **Promote `_md_fix` to production** behind a switch (rename-in-place or repoint the app), with
   the verification runbook as the gate. Until this happens the gains are theoretical for users.
5. **One orchestrated refresh DAG** enforcing layer order (raw → analytics → features/decay) with
   `CONCURRENTLY`/incremental throughout, replacing ad-hoc per-procedure calls. Add freshness
   monitoring (watermark age per layer) so staleness (the original 7-week-stale bug) can't recur.
6. **Config baseline** (summary.md §4): `work_mem`, `shared_buffers`, `maintenance_work_mem` are
   near-default; raising them lifts *every* job, including these. Cheapest global win.
7. **Consider a columnar/OLAP path** for the heaviest analytics if it keeps growing — the Polars
   approach already hints the compute is better done outside row-store PL/pgSQL. A materialized
   columnar export (Parquet/`pg_analytics`/external engine) for farming + decay at full scale is
   a credible long-term direction.

---

## 5. One-paragraph verdict

The pipeline is now **partition-pruned at the source, linear at the aggregation layer,
incremental at the feature layer, and set-based (3.7×+) at decay**, with a faster external
Polars path available for the heaviest decay runs. The dominant remaining scaling limits are
**(a) full-rebuild analytics MVs** and **(b) the unpartitioned `user_post`** — both structural,
both with a clear path. The dominant *organizational* risk is that all of this still lives in
`_md_fix`: the highest-leverage next action is not more optimization but **promotion + a single
orchestrated, watermarked refresh path** with freshness monitoring.
