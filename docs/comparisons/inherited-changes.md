# Inherited Changes — old vs new (pre-existing `_md_fix` work)

These changes were made **before** this round (feature-pipeline → incremental). They are
documented here for completeness. **Logic** is compared from the function/view source;
**performance** figures are as reported by the prior analysis (`review.md`,
`db-analysis/*.md`) and were **not re-measured in this round** — flagged where so.

For the freshly built and freshly measured incremental work, see
[feature-pipeline.md](feature-pipeline.md) and [verification.md](verification.md).

---

## 1. analytics engagement matviews — `NOT EXISTS` → `LEFT JOIN … IS NULL`

**Objects:** `analytics.mv_engagement_<project>` (old) → `analytics_md_fix.mv_engagement_<project>` (new), ×11.

**Old logic** — the `posts_with_no_engagement` CTE found root posts with zero engagement via a
correlated subquery:
```sql
WHERE NOT EXISTS (SELECT 1 FROM engagements_with_scores e WHERE e.root_post_id = r.post_id)
```
Evaluated once per root post → O(posts × engagements) on refresh.

**New logic** — anti-join:
```sql
FROM roots r
LEFT JOIN engagements_with_scores e ON e.root_post_id = r.post_id
WHERE e.root_post_id IS NULL
```
Same result set, single hash anti-join instead of a per-row subquery.

**Status:** ✅ logic equivalent; new matviews built and row-count-matched to source
(quipnetwork 5,174,651 = source). **Perf:** prior analysis estimated ~½ the refresh I/O; not
re-measured this round.

---

## 2. decay scores — row-by-row INSERT → batch INSERT

**Objects:** `mindshare_score.calculate_decay_scores` (old) → `mindshare_score_md_fix.calculate_decay_scores` (new).

**Old logic:** one `INSERT INTO contribution_scores` per reply row inside a PL/pgSQL `FOR` loop
(~1 INSERT per reply; millions of round-trips on large projects).

**New logic:** accumulate into a temp table, then a single set-based `INSERT … SELECT`.

**Status:** procedure exists in `mindshare_score_md_fix`; the md_fix `contribution_scores` table
is currently populated for **Acurast only (47,898 rows)** — full multi-project population is
still pending (see summary.md §6 Phase 1). **Perf not re-measured this round.**

> Note: a separate, more advanced **incremental decay engine** already exists in the
> `test_mindshare_score` schema (`calculate_decay_scores_incremental`, `decay_run_log`,
> `decay_run_state`). Per instruction, that schema was **not touched**. It is the natural
> home for production decay incrementalization — see summary.md §5.

---

## 3. buggy legacy API functions — fixed in `mindshare_md_fix`

Production `mindshare.*` versions are **still buggy** (verified live this round — fixes were
never promoted out of `_md_fix`). Fixed equivalents:

| Function | Old bug (still in `mindshare.*`) | New (`mindshare_md_fix.*`) |
|---|---|---|
| `get_post_engagement_ratios(text)` | hardcoded `FROM mv_engagement_acurast` — wrong data for every non-Acurast project (confirmed: prod still references acurast) | dynamic `format('… FROM analytics_md_fix.%I …', 'mv_engagement_'||slug)` |
| `get_post_engagement_ratios(bigint,bigint,text)` | literal `v` token in the SQL template where the end-date expression belongs → runtime error | proper `< (to_timestamp($2) AT TIME ZONE 'Asia/Kathmandu')` |
| `get_post_metrics_from_user_post(bigint,bigint)` | references `user_post.user_x_score` (column absent; confirmed prod still references it) + correlated subquery for reach | JOIN `mindshare_user` for score + `SUM(...) OVER (PARTITION BY root_post_id)` window |

**Status:** ✅ fixed functions exist in `mindshare_md_fix`; ⏳ **not promoted** — production
callers still hit the buggy versions. Promotion decision is open (summary.md §7).
**Perf of the correlated-subquery → window-function fix not re-measured this round.**

---

## What was re-measured this round vs not

| Change | Logic verified | Performance re-measured |
|---|---|---|
| Feature MV → incremental table (this round) | ✅ row-for-row | ✅ fully (see verification.md) |
| analytics `NOT EXISTS`→`LEFT JOIN` | ✅ by inspection | ❌ prior estimate only |
| decay row-by-row → batch | ✅ by inspection | ❌ prior estimate only |
| buggy API functions fixed | ✅ by inspection + live prod still-buggy check | ❌ |
