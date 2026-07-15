# Analytics Incremental Engagement Tables — How It Works & How To Test

Audience: engineer with no prior context on this change. Covers what changed, why it's
faster, and exact steps to verify it yourself.

Scope: `analytics_md_fix` schema only — the engagement pipeline (`mv_engagement_<project>`
per-project, `mv_user_posts_engagement` global). Decay/`mindshare_score` is untouched and
unrelated.

See also — companion doc for testing: `docs/testing_timetravel_approach.md` (real-data
checkpoint rewind, all SQL inline, no separate file needed).

---

## 1. The problem

`analytics_md_fix.mv_engagement_<project>` was a **materialized view**. Every refresh —
even to pick up one new reply — did `DROP MATERIALIZED VIEW` + `CREATE MATERIALIZED VIEW`,
recomputing the entire project from scratch by rescanning `mindshare.mindshare_post` and
`mindshare.mindshare_user`.

Measured cost of that full recompute, on quipnetwork (real numbers, this DB, 2026-07-09):

| Version | Time |
|---|---|
| `analytics.mv_engagement_quipnetwork` full refresh (original) | 231,357 ms (~3m51s) |
| `analytics_md_fix.mv_engagement_quipnetwork` full rebuild (single-pass optimized, pre-existing fix) | 136,070 ms (~2m16s) |

That single-pass optimization (one scan of `mindshare_post` instead of two — see
`docs/db-analysis/performance-comparison.md` §2) was already done before this change. It
made full rebuilds 1.7x faster. It did **not** make refreshes incremental — every refresh
was still a full rebuild, no matter how small the actual change.

## 2. What changed

`mv_engagement_<project>` and `mv_user_posts_engagement` are now **regular tables**, not
matviews, with a checkpoint (watermark) table tracking how far each one has been built.
Refreshing now means: read only the rows ingested since the watermark, write only what
changed, move the watermark forward. No full rescan unless nothing has been built yet.

**Object names were kept identical** (`mv_engagement_<project>`, `mv_user_posts_engagement`)
even though they're tables now — not a naming cleanup. `analytics_md_fix.get_v2_user_posts_analytics`
(and callers `mindshare_score.get_v2_analytics`, `public.get_v2_analytics_optimized`,
`mindshare_score.get_mindshare_leaderboard`) reference `mv_engagement_<project>` by name via
dynamic SQL (`format('... analytics_md_fix.%I ...', 'mv_engagement_' || project)`). Renaming
would have silently broken all four without touching their source, which isn't in this repo.

### Files (`Mindshare_Backend/Analytics_md_fix/`)

| File | Purpose |
|---|---|
| `00_drop_old_mv_and_procs.sql` | One-time cutover: drops the old matviews + old build/refresh procs. Leaves the 4 `get_*_analytics` read functions alone. |
| `tables/engagement_refresh_state.sql` | The checkpoint table. One row per scope, overwritten (not appended) — see §3.1. |
| `tables/engagement_run_log.sql` | Append-only run history, separate concern from the checkpoint — see §7. |
| `functions/create_engagement_table_full.sql` | Full (re)build of one project's table. Same query the old matview used, but `CREATE TABLE` instead of `CREATE MATERIALIZED VIEW`, plus seeds the checkpoint. Logs every run — see §7. |
| `functions/refresh_engagement_incremental.sql` | The actual incremental logic — see §3. |
| `functions/create_user_posts_engagement_table_full.sql` | Full build for the global (cross-project) table. |
| `functions/refresh_user_posts_engagement_incremental.sql` | Incremental refresh for the global table. Simpler — no placeholder logic (see §3.4). |
| `functions/engagement_logging.sql` | Autonomous run-logging helpers (`_log_engagement_run`, `next_engagement_run_id`, `get_engagement_run_status`, `get_recent_engagement_failures`) — see §7. |
| `functions/parallel_engine.sql` | The dblink-based concurrent scheduler + its two wrapper functions — see §6. |
| `functions/run_engagement_all.sql` | Sequential orchestrator, all projects + global, `mode := 'full' \| 'incremental'`. |
| `functions/run_engagement_all_parallel.sql` | Concurrent version of the above — see §6. |
| `benchmark/bench_full_vs_incremental.sql` | Runnable SQL script (DBeaver-friendly) — full build, no-op, simulated delta, all timed. |
| *(none — SQL is inline)* | Checkpoint-rewind + real-write-cost test, both scopes — fully inline in `docs/testing_timetravel_approach.md`, no separate file. |

## 3. How the incremental refresh works

### 3.1 The checkpoint table

```sql
analytics_md_fix.engagement_refresh_state (
    scope_key              text PRIMARY KEY,  -- 'project:<lower_keyword>' or 'user_posts_engagement'
    last_ingest_ts         timestamptz,       -- watermark: high-water mark of what's been processed
    last_run_at            timestamptz,
    rows_inserted          bigint,            -- observability: what the last run actually did
    placeholders_removed   bigint,
    placeholders_inserted  bigint
)
```

No row for a scope means "never built." Both incremental procs check this first and fall
back to a full build if it's missing — so the very first call for any project is
automatically a full build that also seeds the checkpoint. Every call after that is
incremental.

### 3.2 The watermark is ingest time, not tweet time

```sql
GREATEST(mp.created_at, mp.updated_at) > v_watermark
```

Not `post_created_at`. `post_created_at` is when the tweet was posted on X; `created_at`/
`updated_at` is when our pipeline ingested/touched the row. Watermarking on ingest time
means a tweet that was posted last week but only scraped into our DB just now still gets
picked up on the very next incremental run — watermarking on tweet time would silently
miss it forever (it would look "older" than the watermark even though we just saw it for
the first time).

### 3.3 Per-project refresh — the tricky part: placeholder rows

The engagement table intentionally includes root posts with **zero** engagement (so
consumers can count total posts, not just engaged ones). Those rows have
`engaged_tweet_id IS NULL`. This is the one thing that makes the per-project refresh more
than a plain append:

1. Find dirty rows: non-retweet posts for this project ingested since the watermark.
2. Split them by role:
   - **A reply/quote to some root** → resolve the root (may be an old, already-stored post,
     or itself brand-new in this same batch) → this becomes a real engagement row.
   - **Everything dirty is also a root candidate** — including replies themselves, since a
     reply can have its own children later.
3. Before inserting new engagement rows: **delete the placeholder** for any root that's
   getting its first-ever engagement right now (`DELETE ... WHERE engaged_tweet_id IS NULL
   AND root_post_id IN (roots gaining engagement this run)`).
4. Insert the new engagement rows (`ON CONFLICT (engaged_tweet_id) DO NOTHING` — safety net,
   engagement rows are immutable once created).
5. Insert placeholders for any dirty root that got **no** engagement in this batch and
   doesn't already have a row in the table.
6. Advance the watermark to `MAX(ingest_ts)` of everything just processed.

Locking: `pg_advisory_xact_lock(hashtext('analytics_engagement:' || scope))` per scope, so
two concurrent refreshes of the same project can't race each other.

### 3.4 Global refresh — simpler, no placeholders

`mv_user_posts_engagement`'s roots are restricted to top-level posts/quotes (not replies,
not retweets), joined with `INNER JOIN`. A root with zero engagement is simply **absent**
from the table — that's the original design (`analytics.create_user_posts_engagement_view`
has no "posts with no engagement" branch at all). So the incremental version is pure
append: find new replies/quotes/retweets since the watermark, resolve each to its root,
`INSERT ... ON CONFLICT DO NOTHING`. No delete/placeholder dance needed.

### 3.5 Keeping user-derived columns fresh — the dual watermark

Earlier versions of this pipeline snapshotted `root_favorite_count`, `root_reply_count`,
and `engaged_user_score` at insert time and never touched them again — the same tradeoff
`docs/db-analysis/performance-comparison.md` §7 already accepted for scores ("Score
differences ... Expected"). Confirmed live this was a real, visible problem: rebuilt
`CNPYNetwork`'s old matview from scratch and compared it against the incremental table —
row counts matched exactly, but `EXCEPT ALL` showed 6,188 rows differing, 100% of it
`engaged_user_score` drift (favorite/reply counts happened to be stable in that sample,
but were never actually protected either). Root cause: `engaged_user_score` comes from
`mindshare_user.score`, which is recalculated by a completely separate process on its own
schedule — it keeps moving regardless of whether the tweet itself is still active.

**Fixed with a second, independent watermark.** `engagement_refresh_state` now tracks two
columns:
- `last_ingest_ts` — unchanged, drives new/edited posts (§3.2).
- `last_user_ts` — new. Drives `mindshare_user` changes (score recalculated, or renamed).

Every incremental call now does two dirty-scans instead of one. Anything dirty by
`last_ingest_ts` still gets inserted as before, **plus** any existing row whose *root
post* is in that dirty set gets `root_favorite_count`/`root_reply_count` refreshed via a
plain `UPDATE` (previously these were silently left stale on old rows — the "OK, but
scores got refreshed, why wasn't the post itself?" gap). Anything dirty by `last_user_ts`
triggers an `UPDATE` on every existing row referencing that user — `engaged_user_score`
for rows where they're the engager, `root_username` for rows where they're the root
poster.

This works because user changes are genuinely sparse: checked live on this DB, only
~400-2,400 users/day get touched out of 414,810 total (~0.1-0.6%) — nowhere near "touch
almost every row," which is what made this feasible to add without turning the
incremental path back into a full rebuild.

**Verified live, all 13 projects + global, after deploying the fix (2026-07-14):**

| Scope | First catch-up run | Rows refreshed | `EXCEPT ALL` after (both directions) |
|---|---|---|---|
| test11 | 334 ms | 0 | 0, 0 (0 rows — empty project) |
| IronAllies_ | 2,760 ms | 248 | 0, 0 (52,311 rows) |
| D3lMundos | 3,092 ms | 94 | 0, 0 (88,952 rows) |
| Acurast | 3,314 ms | 149 | 0, 0 (114,576 rows) |
| EthraShip | 4,275 ms | 1,042 | *(no old matview to compare — never existed for this project)* |
| NucleusCodes | 6,598 ms | 4,489 | *(same — no old matview)* |
| _technotainment | 6,399 ms | 1,418 | 0, 0 (425,516 rows) |
| YOM_Official | 8,482 ms | 1,069 | 0, 0 (1,271,412 rows) |
| Pact_Swap | 9,751 ms | 10,203 | 0, 0 (1,198,438 rows) |
| CNPYNetwork | 13,027 ms | 13,329 | 0, 0 (1,768,573 rows — was 6,188 rows differing *before* this fix) |
| sleepagotchi | 20,101 ms | 12,122 | 0, 0 (2,591,896 rows) |
| TheARCTERMINAL | 34,560 ms | 16,838 | 0, 0 (3,658,727 rows) |
| quipnetwork | 62,179 ms | 32,317 | 0, 0 (6,529,096 rows) |
| global | 31,187 ms | 31,800 | 0, 0 (4,218,967 rows) |

12 of 14 scopes independently verified byte-for-byte against a freshly `REFRESH`ed old
matview — zero differences across every column, from empty projects up to 6.5M rows.
`EthraShip`/`NucleusCodes` have no old matview in `analytics` to compare against (never
existed for those two projects), so those two ran the identical code path successfully
but weren't independently cross-checked.

The "first catch-up run" is a one-time cost per scope — it's the first call after
deploying this fix, so it's catching up *all* historical drift at once (`last_user_ts`
starts at `-infinity` for any scope built before this change). Every call after that only
processes users who changed since the *previous* call, back to the cheap steady state
measured elsewhere in this doc.

### 3.6 Four bugs found during rollout (live, on this DB)

**Bug 1 — case-sensitivity silently built an empty table.**
`CALL create_engagement_table_full('acurast')` (lowercase) ran in milliseconds and left
`mv_engagement_acurast` empty. Root cause: `mindshare.mindshare_post.project_keyword` is
stored with real casing (`'Acurast'`), and the original code filtered
`WHERE project_keyword = p_project_keyword` — an exact, case-sensitive match against
whatever casing the caller passed in. Lowercase input matched zero rows, "succeeded"
instantly, and built nothing. Fixed by resolving the canonical name first, in both
`create_engagement_table_full` and `refresh_engagement_incremental`:

```sql
SELECT project_name INTO v_project_keyword
FROM mindshare.mindshare_project
WHERE lower(project_name) = lower(p_project_keyword)
LIMIT 1;

IF NOT FOUND THEN
    RAISE EXCEPTION 'No project found matching % (case-insensitive) in mindshare.mindshare_project', p_project_keyword;
END IF;
```

Every call now resolves the real casing regardless of what you type, and a genuinely
nonexistent project fails loudly instead of silently building nothing.

**Bug 2 — stale checkpoint self-heal.**
`CALL refresh_engagement_incremental('IronAllies_')` after the table had been dropped did
**not** rebuild it — the incremental path just no-op'd forever. Root cause: the proc only
checked whether a checkpoint *row* existed before deciding to skip bootstrap, not whether
the underlying *table* still existed. A checkpoint row surviving a dropped table meant the
watermark looked "already caught up" and the dirty-row scan correctly found nothing new —
it just never noticed the table itself was gone. Fixed by checking both:

```sql
IF NOT FOUND OR NOT EXISTS (
    SELECT 1 FROM pg_tables WHERE schemaname = 'analytics_md_fix' AND tablename = v_table
) THEN
    CALL analytics_md_fix.create_engagement_table_full(v_project_keyword);
    RETURN;
END IF;
```

Verified live: dropped the table again, called the incremental proc, confirmed it
self-healed via a delegated full build (visible in `engagement_run_log` as two linked
rows — `delegated_to_full_build` immediately followed by the full build's own `success`
row).

**Bug 3 — manual-commit trap: checkpoint writes silently discarded, full rebuild every
call.** `refresh_user_posts_engagement_incremental()` rebuilt the entire table from
scratch on every single call instead of going incremental after the first. Root cause
wasn't in the proc at all: the DBeaver session was left in manual-commit mode (turned on
for an earlier `BEGIN...ROLLBACK` sim test, §5) and nothing ever ran `COMMIT`. Each `CALL`
genuinely succeeded and wrote a real checkpoint row — but that write sat inside an
uncommitted transaction, invisible to the next `CALL` (a fresh, separate transaction),
which saw no checkpoint, concluded "never built," and delegated to a full rebuild again.
Confirmed via `engagement_run_log` (multiple `full` builds logged back to back, minutes
apart, each one legitimately reporting success) cross-checked against
`pg_stat_activity`:

```sql
SELECT pid, state, xact_start, now() - xact_start AS age, query
FROM pg_stat_activity WHERE state = 'idle in transaction';
-- found a session open since before the first "full" build, still uncommitted
```

Fix is operational, not code: run `COMMIT;` in that session, then turn auto-commit back
on unless deliberately running a wrapped sim test. `engagement_run_log` itself was never
affected by this — it commits via an autonomous `dblink` connection independent of the
caller's transaction (§7) — which is exactly what made this diagnosable: the log showed
the truth (repeated real full builds) while the checkpoint table showed stale data,
and that mismatch was the tell.

**Bug 4 — `OR`-combined subqueries in a test `DELETE` produced a 146-billion-cost query
plan.** Part of the real-write-cost time-travel test (§4.2,
`docs/testing_timetravel_approach.md`) needed to delete a project's own dirty-window rows
from `mv_engagement_quipnetwork` before letting the incremental proc reinsert them for
real. First version:

```sql
WITH dirty AS ( SELECT post_id FROM mindshare.mindshare_post WHERE ... )
DELETE FROM analytics_md_fix.mv_engagement_quipnetwork t
WHERE t.engaged_tweet_id IN (SELECT post_id FROM dirty)
   OR (t.root_post_id IN (SELECT post_id FROM dirty) AND t.engaged_tweet_id IS NULL);
```

Ran for 18+ minutes with no result. `EXPLAIN` showed why: cost estimate
**146,387,460,654**. Postgres couldn't hash both uncorrelated `IN` subqueries together
under default `work_mem` (the ~1M-row dirty set didn't fit), so it fell back to
re-scanning the `dirty` CTE **once per outer row** of the 6.5M-row target table — roughly
4M × 1M row-equivalents of work. Cancelled via `pg_cancel_backend`; a second attempt hit
the identical plan and was cancelled again.

Fixed by materializing `dirty` into a real, indexed temp table and splitting the `OR`
into two plain equi-join deletes:

```sql
CREATE TEMP TABLE _tt_dirty ON COMMIT DROP AS SELECT post_id FROM mindshare.mindshare_post WHERE ...;
CREATE INDEX ON _tt_dirty (post_id);
ANALYZE _tt_dirty;

DELETE FROM analytics_md_fix.mv_engagement_quipnetwork t USING _tt_dirty d WHERE t.engaged_tweet_id = d.post_id;
DELETE FROM analytics_md_fix.mv_engagement_quipnetwork t USING _tt_dirty d WHERE t.root_post_id = d.post_id AND t.engaged_tweet_id IS NULL;
```

`EXPLAIN` on the fixed version: two clean Hash Joins, cost ~240k and ~250k combined —
roughly 600,000x cheaper. This only affects the *test* SQL in
`docs/testing_timetravel_approach.md`, not any production function —
`create_engagement_table_full`/`refresh_engagement_incremental` were never at risk (they
already use temp tables + `SET LOCAL work_mem` for their own joins, which is exactly the
pattern this fix brings the test SQL in line with). Lesson: an `OR` across two
uncorrelated subqueries is a real Postgres planner trap at scale — prefer a real indexed
temp table and separate statements over combining conditions with `OR` when either side
could return a large row set.

## 4. Performance — measured, this DB, quipnetwork (~6.5M rows, the largest project)

All numbers below are real, captured via `clock_timestamp()` around each operation,
2026-07-09, against `mindshare_db`.

| Operation | Time | Notes |
|---|---|---|
| `analytics.mv_engagement_quipnetwork` full refresh (original matview) | 231,357 ms | baseline |
| `analytics_md_fix.mv_engagement_quipnetwork` full build (new, bootstrap) | 136,070 ms | 1.7x — same win as the pre-existing single-pass fix, now on a table |
| Incremental, no-op (nothing changed since watermark) | 1,480 ms | **92x faster than full build** |
| Incremental, simulated delta (21 new posts) | 2,390 ms | wrote exactly 40 rows (see §5.3 for why 40, not 21) |

**Data correctness**, not just row count — full bidirectional diff, not a sample (see §6
for why a sample wasn't needed here):

```sql
SELECT * FROM analytics.mv_engagement_quipnetwork
EXCEPT ALL
SELECT * FROM analytics_md_fix.mv_engagement_quipnetwork;
-- 0 rows

SELECT * FROM analytics_md_fix.mv_engagement_quipnetwork
EXCEPT ALL
SELECT * FROM analytics.mv_engagement_quipnetwork;
-- 0 rows
```

Both directions: **zero rows differ**, across all 6,508,841 rows × 16 columns. Row counts
also match exactly (6,508,841 = 6,508,841). Runtime for the full diff: 199,434 ms (~3m19s).

### Known gap

The no-op case (1,480 ms) is dominated by the dirty-check scan — finding "nothing changed"
still means scanning `mindshare.mindshare_post` for this project's rows filtered on
`GREATEST(created_at,updated_at) > watermark`, and there's no index supporting that
expression yet. `backend_optimization`'s decay pipeline solved the identical problem with
an expression index (`ix_tmp_mp_ingest` on `GREATEST(created_at,updated_at)` — see
`backend_optimization/decay_10_incremental_state_and_indexes.sql`). Adding the equivalent
here would likely take the no-op case from ~1.5s toward sub-100ms. Not done yet — next
lever, not a silent gap.

### 4.1 Global scope (`mv_user_posts_engagement`) — measured, 4,218,967 rows

Same real-DB measurement, same date, for the global (cross-project) table:

| Operation | Time | Notes |
|---|---|---|
| `analytics.mv_user_posts_engagement` full refresh (original matview) | 53,275 ms | |
| `analytics_md_fix.mv_user_posts_engagement` full build (new, bootstrap) | 48,058 ms | 1.1x — smaller win than the per-project table's 1.7x, because this global view never got the single-pass rewrite; it's still the original two-scan query shape, just table instead of matview |
| Incremental, no-op | 1,829 ms | 26x faster than full build |
| Incremental, simulated delta (15 new replies to an existing root) | 994 ms | wrote exactly 15 rows — no placeholder logic in this scope (§3.4), so no surprise row-count math like the per-project case |

Data correctness, full bidirectional diff (not sampled):

```sql
SELECT * FROM analytics.mv_user_posts_engagement
EXCEPT ALL
SELECT * FROM analytics_md_fix.mv_user_posts_engagement;
-- 0 rows

SELECT * FROM analytics_md_fix.mv_user_posts_engagement
EXCEPT ALL
SELECT * FROM analytics.mv_user_posts_engagement;
-- 0 rows
```

Zero rows differ either direction, across all 4,218,967 rows × 15 columns. Row counts also
match exactly. Runtime for the full diff: 144,678 ms (~2m25s).

### 4.2 Time-travel test at scale — checkpoint rewind + real write cost (2026-07-12)

The simulated-delta numbers above (§4, §4.1) use a handful of synthetic rows — good for
proving the algorithm, but too small to show what the incremental path costs against a
real, large backlog. `docs/testing_timetravel_approach.md` covers the real-data approach
in full (all SQL inline there, no separate file): rewind the checkpoint watermark, delete
the **target** table's own rows for that window (source table untouched), then let the
incremental proc reconcile it back for real — genuine `INSERT`s, not just a scan. No
change to `create_engagement_table_full`/`refresh_engagement_incremental` — both used
exactly as-is; the target is simply made to temporarily lag, then the same incremental
call catches it back up. Still wrapped in `BEGIN...ROLLBACK`, since these tables are read
by live consumers (`get_v2_user_posts_analytics`, etc.) — the wrapper guarantees no other
session ever sees the momentarily-incomplete table, not just that the gap is short.

**Why the delete step exists — an earlier attempt without it (rewind-only, measured on
this DB):**

| Scope | Dirty rows scanned | Time | `rows_inserted` |
|---|---|---|---|
| `quipnetwork` (project, 6.5M rows, the largest) | 970,225 | 21,582 ms | 0 |
| global (`user_posts_engagement`, 4.2M rows) | 1,699,486 | 46,739 ms | 0 |

Both wrote 0 rows because both scopes had just been fully rebuilt minutes earlier
(§6.2's `run_engagement_all_parallel('full', 4)` run) — the rewound window was already
covered, so there was nothing new to write. That's real scan cost (970k-1.7M rows
scanned in 22-47s), but not a write-cost measurement — which is why the delete step was
added.

The real-write version has since been run for all 13 projects + global. For **project
scope** it's consistently a large win — weekly (7-day) speedups ranged 1.9x-371x and daily
(1-day) 3.8x-1,725x depending on how bursty each project's recent ingestion is (re-verified
for `Acurast` on 2026-07-14: 30d 43x, 7d 74x, 1d 90x). For **global scope** the honest
result is different: re-verified 2026-07-14 with the current dual-watermark proc, a rewound
window is only marginal-to-net-loss (1d 1.2x, 7d 1.5x, 30d **0.55x** — i.e. slower than a
full rebuild), because global's only ingested day is a 244k-row burst and the re-insert has
a near-fixed ~30s floor from rescanning all 4.2M `user_post` rows to resolve roots. That's
a worst-case *backlog catch-up* cost, not the steady-state daily tick. Full results table,
per-project breakdown, and the global analysis (plus a candidate optimization) are in
`docs/testing_timetravel_approach.md`.

## 5. Step-by-step: test this yourself (DBeaver)

You need a DBeaver connection to `mindshare_db` (or any SQL client — nothing below is
psql-specific). Everything is plain SQL: open each file, select all, run as a script
(DBeaver: **Execute SQL Script**, `Alt+X` — not the single-statement `Ctrl+Enter`, since
several files contain multiple statements DBeaver needs to run in order).

**One setting to change first:** for §5.4's delta tests, turn **auto-commit off**
(DBeaver: bottom status bar of the SQL editor tab, or the auto-commit icon in the toolbar).
Those tests wrap simulated inserts/checkpoint rewinds in `BEGIN ... ROLLBACK` — with
auto-commit on, DBeaver
commits each statement individually and the rollback won't undo anything. Turn it back on
afterward if you rely on it elsewhere.

### 5.1 One-time setup (already done on this DB — needed once per environment)

Open and run each file below, in order, in a DBeaver SQL editor connected to `mindshare_db`
(auto-commit can stay on for these — no rollback needed):

```
Mindshare_Backend/Analytics_md_fix/00_drop_old_mv_and_procs.sql
Mindshare_Backend/Analytics_md_fix/tables/engagement_refresh_state.sql
Mindshare_Backend/Analytics_md_fix/tables/engagement_run_log.sql
Mindshare_Backend/Analytics_md_fix/functions/engagement_logging.sql
Mindshare_Backend/Analytics_md_fix/functions/create_engagement_table_full.sql
Mindshare_Backend/Analytics_md_fix/functions/refresh_engagement_incremental.sql
Mindshare_Backend/Analytics_md_fix/functions/create_user_posts_engagement_table_full.sql
Mindshare_Backend/Analytics_md_fix/functions/refresh_user_posts_engagement_incremental.sql
Mindshare_Backend/Analytics_md_fix/functions/parallel_engine.sql
Mindshare_Backend/Analytics_md_fix/functions/run_engagement_all.sql
Mindshare_Backend/Analytics_md_fix/functions/run_engagement_all_parallel.sql
```

`engagement_logging.sql` and `parallel_engine.sql` both need the `dblink` extension —
already installed on this DB (`CREATE EXTENSION IF NOT EXISTS dblink;` if setting up fresh
elsewhere).

Check what's left in the schema (should be 2 tables, and 13 functions/procedures — see
§6.5 for what each one is; only 4 of those, `get_*_analytics`, predate this work):

```sql
SELECT matviewname AS name, 'matview' AS kind FROM pg_matviews WHERE schemaname='analytics_md_fix'
UNION ALL SELECT tablename, 'table' FROM pg_tables WHERE schemaname='analytics_md_fix'
UNION ALL SELECT p.proname, CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='analytics_md_fix'
ORDER BY 2,1;
```

### 5.1.1 Known projects (13, as of 2026-07-12)

Every project currently covered by `mv_engagement_<project>` (plus the global
`mv_user_posts_engagement`, not project-scoped):

```
D3lMundos          Pact_Swap          _technotainment    TheARCTERMINAL
CNPYNetwork        Acurast            YOM_Official       quipnetwork
sleepagotchi       IronAllies_        test11             EthraShip
NucleusCodes
```

Sizes vary enormously — `test11` and `IronAllies_` finish in ~2s (§6.2's real timing
table), `quipnetwork` is the largest and takes minutes for a full build (§4). Pick a small
one (`acurast`, `test11`, `IronAllies_`) for fast iteration while testing; use
`run_engagement_all_parallel` (§6) to hit all 13 + global at once.

### 5.2 Bootstrap one project (first call = full build)

Pick a small project first — `acurast` is the smallest, good for a fast sanity check
before touching something like `quipnetwork` (multi-minute build).

```sql
CALL analytics_md_fix.create_engagement_table_full('acurast');
```

DBeaver shows how long that took in the results/log panel (bottom of the SQL editor) —
no `\timing` needed, it's on by default. If you want the number captured in a query result
instead of read off the log, use this instead of the bare `CALL`:

```sql
Drop table if exists _t;
CREATE TEMP TABLE _t (ms numeric);
DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    CALL analytics_md_fix.create_engagement_table_full('acurast');
    INSERT INTO _t VALUES (extract(epoch FROM (clock_timestamp()-t0))*1000);
END $$;
SELECT ms AS full_build_ms FROM _t;
```

Confirm the checkpoint was seeded:

```sql
SELECT * FROM analytics_md_fix.engagement_refresh_state WHERE scope_key = 'project:acurast';
-- expect: last_ingest_ts populated, rows_inserted = row count of mv_engagement_acurast
```

### 5.3 Prove the no-op case is fast

Nothing has changed since the build above, so this should be near-instant:

```sql
CALL analytics_md_fix.refresh_engagement_incremental('acurast');
```

Expect a `NOTICE` like `no-op incremental (0 dirty rows)` (DBeaver shows notices in the
Output/Log tab of the SQL editor) and elapsed time in the milliseconds-to-low-seconds
range, nowhere near the full-build time. Use the same `DO $$ ... $$` timing wrapper as
above (swap the `CALL`) if you want the number in a result set.

### 5.4 Prove the delta case only touches new rows

This is the important one: confirm the incremental run only writes what actually changed,
without touching real data. Full step-by-step and all SQL (inline, no separate file):
`docs/testing_timetravel_approach.md`. Short version: rewind the checkpoint watermark,
delete the target table's own rows for that window (source table untouched), let the
incremental proc reconcile it back for real, then `ROLLBACK` — checkpoint, deleted rows,
and re-inserted rows all revert to exactly the pre-test state.

**Auto-commit must be off** (DBeaver: "Database" menu → "Transaction Mode" → "Manual
Commit"), and the whole `BEGIN...ROLLBACK` block must run as one script (`Alt+X`), not
statement-by-statement, or the `ROLLBACK` won't undo anything. This exact mistake —
leaving auto-commit on, or leaving a `BEGIN` block open without ever reaching
`ROLLBACK`/`COMMIT` — is documented as a real bug hit live, §3.6 bug #3.

`docs/testing_timetravel_approach.md` also covers a gotcha already fixed in its SQL:
`mindshare_post.project_keyword` is case-sensitive (`'Acurast'`, not `'acurast'`) — a raw
`INSERT`/`SELECT` against the source tables doesn't get the same case-insensitive
resolution the procs have internally (§3.6 bug #1), so the test SQL resolves the
canonical name first.

Compare the resulting `rows_inserted` against how many rows a full rebuild would have
touched (the entire project/table). That gap is the point of this whole change.

### 5.5 Verify data correctness against the original, at whatever scale you're comfortable with

Row count first (cheap):

```sql
SELECT
    (SELECT count(*) FROM analytics.mv_engagement_acurast)         AS analytics_rows,
    (SELECT count(*) FROM analytics_md_fix.mv_engagement_acurast)  AS md_fix_rows;
```

Then full data equality, server-side, no data leaves the DB:

```sql
SELECT * FROM analytics.mv_engagement_acurast
EXCEPT ALL
SELECT * FROM analytics_md_fix.mv_engagement_acurast;
-- expect 0 rows

SELECT * FROM analytics_md_fix.mv_engagement_acurast
EXCEPT ALL
SELECT * FROM analytics.mv_engagement_acurast;
-- expect 0 rows
```

**Gotcha — this only stays at 0 rows immediately after both sides were built together.**
`EXCEPT ALL` compares every column. If you `REFRESH MATERIALIZED VIEW analytics.mv_engagement_<project>`
days after `analytics_md_fix`'s table was last built, expect real differences — that's
§3.5's snapshot tradeoff showing up, not a bug. `REFRESH MATERIALIZED VIEW` recomputes
`root_favorite_count`/`root_reply_count`/`engaged_user_score` live, from whatever
`mindshare_post`/`mindshare_user` say *right now*; `analytics_md_fix`'s already-inserted
rows keep whatever those values were at insert time. Confirmed live on `CNPYNetwork`
(2026-07-13): row *identity* matched exactly (0 rows only-in-old, 0 rows only-in-new, via
the query below), and every differing row was `engaged_user_score` drift — that score is
recalculated elsewhere in the system on its own schedule, unrelated to this pipeline.

To check identity only (ignores the volatile snapshot columns, so it stays 0 regardless
of how much time has passed):

```sql
WITH a_keys AS (SELECT root_post_id, engaged_tweet_id FROM analytics.mv_engagement_acurast),
     m_keys AS (SELECT root_post_id, engaged_tweet_id FROM analytics_md_fix.mv_engagement_acurast)
SELECT
  (SELECT count(*) FROM a_keys EXCEPT ALL SELECT * FROM m_keys) AS keys_only_in_old,
  (SELECT count(*) FROM m_keys EXCEPT ALL SELECT * FROM a_keys) AS keys_only_in_new;
-- expect 0, 0 — this is the real correctness check once any time has passed
```

If `keys_only_in_old`/`keys_only_in_new` are both 0 but the full `EXCEPT ALL` above shows
rows, the pipeline is correct — you're just seeing score/count drift, not a defect. If
either key-only count is non-zero, that's a real bug (a row is genuinely missing or
extra) — worth investigating for real.

If the project is too large to `EXCEPT ALL` comfortably (quipnetwork's full diff took
~3m19s here — that's real, ran to completion, no sampling was needed even at 6.5M rows —
but if you want a faster sanity check on something even bigger), sample instead of
comparing everything:

```sql
-- random 1% sample comparison
WITH sample_ids AS (
    SELECT engaged_tweet_id FROM analytics.mv_engagement_<project>
    WHERE engaged_tweet_id IS NOT NULL
    ORDER BY random() LIMIT 10000
)
SELECT s.engaged_tweet_id
FROM sample_ids s
JOIN analytics.mv_engagement_<project> a USING (engaged_tweet_id)
JOIN analytics_md_fix.mv_engagement_<project> m USING (engaged_tweet_id)
WHERE a IS DISTINCT FROM m;
-- expect 0 rows
```

Same `EXCEPT ALL` pattern works for the global table too (swap `mv_engagement_<project>`
for `mv_user_posts_engagement`, drop the project qualifier) — that's exactly what was run
for real in §4.1: 0 rows differ across all 4,218,967 rows, no sampling needed.

### 5.6 Refresh everything at once

Once you've spot-checked a couple of projects, the orchestrator does all of them (each
bootstraps on first call, incremental after):

```sql
CALL analytics_md_fix.run_engagement_all('incremental');   -- sequential, one project at a time
```

Or run it concurrently — see §6.

## 6. Running everything in parallel

### 6.1 Why dblink, not a bare loop

A plpgsql `FOR ... LOOP CALL ...` runs every project one after another in a single
backend, no matter how it's written — one Postgres connection is one process, one thread
of execution. Real concurrency means multiple backend processes, i.e. multiple
connections. `parallel_engine.sql` opens N loopback connections via `dblink` (the same
extension `backend_optimization/decay_01_logging.sql` already uses in this repo) and runs
a sliding-window scheduler: the instant one project's build finishes, the next queued
project is dispatched to that same connection — no waiting for a whole batch to drain
before starting the next one.

### 6.2 The function to actually call

```sql
SELECT * FROM analytics_md_fix.run_engagement_all_parallel('incremental', 4) ORDER BY ms DESC;
-- mode: 'incremental' (default) or 'full'
-- 4 = max concurrent connections; ~13 projects today, plenty of headroom on this DB (max_connections=100)
```

Returns one row per project + `__global__` as each finishes — `label`, `ms`, `ok`, `err`.
Real run against this DB, all 13 projects + global, `mode='full'` (forces a rebuild of
everything, not just what's stale):

| label | ms | ok |
|---|---|---|
| quipnetwork | 200,838 | true |
| TheARCTERMINAL | 125,928 | true |
| sleepagotchi | 80,377 | true |
| __global__ | 75,830 | true |
| CNPYNetwork | 50,319 | true |
| YOM_Official | 46,662 | true |
| Pact_Swap | 35,550 | true |
| NucleusCodes | 13,750 | true |
| _technotainment | 11,921 | true |
| EthraShip | 4,664 | true |
| Acurast | 3,843 | true |
| D3lMundos | 3,633 | true |
| IronAllies_ | 2,031 | true |
| test11 | 202 | true |

Sequential-equivalent sum ≈ 655s; wall-clock at concurrency 4 was bounded by quipnetwork
alone (the longest single task, ~201s) — roughly **3x** faster than running it as a plain
loop, and it can't go faster than the single biggest project without splitting that
project's own work up too. Note quipnetwork itself ran slower here (200,838 ms) than solo
in §4 (136,070 ms) — 4 heavy builds sharing CPU/I/O genuinely contend with each other;
that's a real, expected cost of concurrency, not a measurement error.

For routine scheduling, use `mode='incremental'` instead — same function, and once
everything is bootstrapped it's all no-ops in ~200ms each regardless of concurrency.

### 6.3 How it's built (only matters if you're modifying it)

```
run_engagement_all_parallel(mode, concurrency)
  → builds a label[] + query[] pair (one per project + one for global)
  → each query is `SELECT * FROM analytics_md_fix._run_build_full(<project>)`
                or `SELECT * FROM analytics_md_fix._run_refresh_incremental(<project>)`
    (project = NULL routes to the global scope — one wrapper covers both cases)
  → hands both arrays to _run_queries_parallel(labels, queries, concurrency)
      → opens `concurrency` dblink connections
      → sliding-window dispatch: free slot + task left → dblink_send_query immediately
      → polls dblink_is_busy; on completion, dblink_get_result and RETURN NEXT
```

The wrapper functions (`_run_build_full`, `_run_refresh_incremental`) exist because a bare
`CALL some_procedure()` has **zero output columns** — `dblink_get_result` needs a declared
column shape to parse a `SETOF RECORD`, and zero columns isn't valid SQL. Each wrapper
returns exactly one `(ok boolean, err text)` row, catching any exception internally so one
project's failure surfaces as a row in the results, not a crash that kills the whole batch.

### 6.4 A real bug this surfaced (fixed)

First version of the scheduler defaulted `ok := true` before checking whether
`dblink_get_result` actually returned a row. A `dblink_send_query` that silently failed
(connection not fully drained from a previous task) meant `dblink_is_busy` immediately
reported "not busy" for a query that was never actually sent — and the optimistic default
reported **false success** for 3 of 14 projects in one run (their tables genuinely didn't
exist, despite `ok=true`). Fixed two ways:
1. The collector now defaults to `ok := false, err := 'no result row returned'` and only
   flips to true if a real row comes back.
2. `dblink_send_query`'s return value is checked; a failed send reconnects that slot and
   retries the same task next pass instead of marking it busy for nothing.

Lesson: **don't trust an async orchestrator's own success report** — always cross-check
independently (table exists? checkpoint exists? row count sane?) before believing a batch
run succeeded. Both re-runs after this fix were independently verified (table + checkpoint
existence checked for all 13 projects, plus row-count and full data diffs against
`analytics` for the previously-broken ones) before being trusted.

### 6.5 Function reference — what's actually needed vs. plumbing

For the complete list of every function/procedure in the schema, including the logging
helpers, see §9.

**Public API you'll actually call (5 functions):**

| Function | What it does | When to use it |
|---|---|---|
| `refresh_engagement_incremental(project)` | Smart refresh for **one** project — bootstraps (full build) automatically on first-ever call, incremental every call after | Your day-to-day call for a single project |
| `refresh_user_posts_engagement_incremental()` | Same, for the global table | Day-to-day call for the global scope |
| `run_engagement_all_parallel(mode, concurrency)` | All projects + global at once, dispatched concurrently. `mode := 'incremental'` (default) or `'full'` | The one to schedule/run routinely — the "trigger everything" function |
| `run_engagement_all(mode)` | Same as above, but plain sequential, zero dblink dependency | Fallback if dblink ever misbehaves, or for debugging one-at-a-time |
| `create_engagement_table_full(project)` / `create_user_posts_engagement_table_full()` | Force a full rebuild even if already built | Deliberate resync only — you almost never call these directly, `refresh_*_incremental` already calls them automatically the first time |

**Internal plumbing — never call these directly** (prefixed `_`, exist only to support the
parallel path):
- `_run_build_full(project)` / `_run_refresh_incremental(project)` — one wrapper each
  (merged from separate project/global variants), `project = NULL` means "the global scope"
- `_run_queries_parallel(...)` — the actual dblink scheduler, reused by both `mode`s
  instead of being duplicated across two near-identical orchestrators

**Pre-existing, not part of this work — don't touch:**
`get_all_users_analytics`, `get_user_analytics`, `get_user_posts_analytics`,
`get_v2_user_posts_analytics` — read-side consumers of these tables.

## 7. Observability — debugging a run

Two tables, two different jobs, deliberately not conflated:

- `engagement_refresh_state` — the **checkpoint**. One row per scope, overwritten every
  run. Its only job is "where do I resume from next time" — see §3.1. Appending history
  here would be actively worse: finding "the latest" would need `ORDER BY ... LIMIT 1`
  instead of a direct PK lookup, and the table would grow unboundedly for zero
  algorithmic benefit — same reasoning `backend_optimization`'s `decay_run_state` already
  follows (single row per scope, overwritten).
- `engagement_run_log` — the **history**. Append-only, one row per run, keyed by `run_id`,
  mirroring `backend_optimization`'s `decay_run_log` pattern exactly. Written via an
  **autonomous dblink commit** (`_log_engagement_run`, in `engagement_logging.sql`) — a
  plain `INSERT` from inside the procedure would roll back together with a failed run,
  which is exactly the case you most want logged. The dblink loopback commits
  independently, so the `'failed'` row with full `SQLSTATE`/message/detail/context
  survives even though the run's own transaction rolled back.

```sql
-- everything logged, most recent first
SELECT run_id, scope, project_keyword, mode, status, phase, message, error_message
FROM analytics_md_fix.engagement_run_log
ORDER BY run_id DESC LIMIT 20;

-- one specific run, as JSON
SELECT analytics_md_fix.get_engagement_run_status(<run_id>);

-- what's failed recently
SELECT * FROM analytics_md_fix.get_recent_engagement_failures(20);
```

`status` is `'running' | 'success' | 'failed'`; `phase` narrows it further
(`resolving_project | building | scanning_dirty | done | delegated_to_full_build | error`).
A `delegated_to_full_build` row means the incremental call found no checkpoint or a
missing table and handed off — check the *next* `run_id` for the full-build proc's own
row (they're linked by being consecutive, not by a foreign key). Every one of
`create_engagement_table_full`, `refresh_engagement_incremental`,
`create_user_posts_engagement_table_full`, and `refresh_user_posts_engagement_incremental`
logs this way — a failure anywhere in the pipeline leaves a row with the real
`SQLSTATE`/`SQLERRM`/detail/context, not just a silent rollback.

## 8. Column reference

### `engagement_refresh_state` — the checkpoint (one row per scope, overwritten)

| Column | Type | Meaning |
|---|---|---|
| `scope_key` | `text` (PK) | Identifies the scope: `'project:<lower_keyword>'` for per-project (e.g. `'project:acurast'`), or the literal `'user_posts_engagement'` for the global scope. |
| `last_ingest_ts` | `timestamptz` | The **post** watermark — `MAX(GREATEST(created_at, updated_at))` from `mindshare_post`/`user_post`, of everything processed so far. Drives new/edited posts. See §3.2 for why ingest time, not tweet time. |
| `last_user_ts` | `timestamptz` | The **user** watermark (added with the dual-watermark fix, §3.5) — `MAX(GREATEST(created_at, updated_at))` from `mindshare_user`, of every user whose score/username has been reconciled into existing rows so far. Independent of `last_ingest_ts` — a user's score can change without them posting anything new. Defaults to `-infinity` for any scope built before this column existed, so its first post-upgrade run does a one-time catch-up of all historical drift. |
| `last_run_at` | `timestamptz` | When this scope was last refreshed (any outcome — including a 0-row no-op). Purely informational, not used in any query logic. |
| `rows_inserted` | `bigint` | Rows written by the last run — full build: total table row count; incremental: new engagement rows + new placeholders. |
| `placeholders_removed` | `bigint` | Placeholder rows (`engaged_tweet_id IS NULL`) deleted by the last run because their root gained its first engagement (§3.3 step 3). Always `0` for the global scope (§3.4, no placeholders there). |
| `placeholders_inserted` | `bigint` | New placeholder rows added by the last run, for dirty roots that got zero engagement in that batch (§3.3 step 5). Always `0` for the global scope. |
| `rows_updated` | `bigint` | Existing rows refreshed in place by the last run (§3.5) — `root_favorite_count`/`root_reply_count` from a dirty root post, plus `engaged_user_score`/`root_username` from a dirty user. `0` on a full build (nothing "existing" to update — everything's freshly written). |

No row for a scope means "never built" — both incremental procs treat this the same as a
missing table (§3.6 bug #2) and delegate to a full build.

## 9. Function reference — every function/procedure in `analytics_md_fix`

### Public API — day-to-day calls

| Function/Procedure | Signature | What it does | Notes |
|---|---|---|---|
| `create_engagement_table_full` | `(p_project_keyword text)` | Full (re)build of one project's `mv_engagement_<project>` table from scratch — drops and recreates it, seeds both checkpoints (`last_ingest_ts` from posts, `last_user_ts` from `clock_timestamp()` at proc entry). | Resolves case-insensitively (§3.6 bug #1). Called automatically by the incremental proc on first-ever call or a missing table — you rarely call this directly except for a deliberate resync. |
| `refresh_engagement_incremental` | `(p_project_keyword text)` | The day-to-day call for one project: bootstraps via a full build if there's no checkpoint or the table's missing, otherwise processes new/edited posts (§3.3) **and** refreshes existing rows for any post/user that changed since each watermark (§3.5 — post metrics + user score/username). | This is what you `CALL` in normal operation. |
| `create_user_posts_engagement_table_full` | `()` | Same as above, for the global `mv_user_posts_engagement` table. No project param — it's one table covering every project. | |
| `refresh_user_posts_engagement_incremental` | `()` | Day-to-day incremental call for the global scope — new engagement is pure append (§3.4), plus the same dual-watermark existing-row refresh as the per-project version (§3.5). | |
| `run_engagement_all` | `(p_mode text DEFAULT 'incremental')` | Loops every known project + the global scope, sequentially, calling either the full-build or incremental proc per `p_mode`. | Zero `dblink` dependency — use this if the parallel path is ever misbehaving, or when debugging one scope at a time matters more than speed. |
| `run_engagement_all_parallel` | `(p_mode text DEFAULT 'incremental', p_max_concurrency int DEFAULT 4)` | Same coverage as `run_engagement_all`, dispatched concurrently via `dblink` (§6). Returns one row per scope: `(label, ms, ok, err)`. | The one to actually schedule routinely — see §6.2 for a real timing run. |

### Observability — safe to call anytime, read-only or self-contained writes

| Function | Signature | What it does |
|---|---|---|
| `get_engagement_run_status` | `(p_run_id bigint) RETURNS json` | Fetches one `engagement_run_log` row as JSON, by `run_id`. |
| `get_recent_engagement_failures` | `(p_limit int DEFAULT 20)` | Returns the most recent rows from `engagement_run_log` where `status = 'failed'`. |
| `next_engagement_run_id` | `() RETURNS bigint` | Pulls the next value from `engagement_run_id_seq`. Called once at the top of every build/refresh proc to tag that run's log rows. |

### Internal plumbing — prefixed `_`, never call these directly

| Function | Signature | What it does |
|---|---|---|
| `_log_engagement_run` | `(...)` | Writes one row to `engagement_run_log` via an autonomous `dblink` loopback connection, so it commits independent of the caller's transaction (§7). Swallows its own errors — a logging failure must never break the actual refresh. |
| `_run_build_full` | `(p_project text DEFAULT NULL)` | Thin wrapper around `create_engagement_table_full`/`create_user_posts_engagement_table_full` (NULL project = global) returning exactly `(ok boolean, err text)` — the shape `dblink_get_result` needs, since a bare `CALL` has zero output columns. |
| `_run_refresh_incremental` | `(p_project text DEFAULT NULL)` | Same wrapper shape, for the incremental procs. |
| `_run_queries_parallel` | `(p_labels text[], p_queries text[], p_max_concurrency int DEFAULT 4)` | The actual dblink sliding-window scheduler — opens N loopback connections, dispatches queued queries as slots free up (§6.3). |

### Pre-existing — not part of this work, don't touch

`get_all_users_analytics`, `get_user_analytics`, `get_user_posts_analytics`,
`get_v2_user_posts_analytics` — read-side consumers of `mv_engagement_<project>` /
`mv_user_posts_engagement`. These predate the incremental rework and reference the tables
by name only — unaffected by the table-vs-matview change (§2).

## 10. Rollback

If something's wrong and you need the old matview-based pipeline back: the original
`analytics.*` schema was never touched by any of this — it's still the old matview,
unaffected. Only `analytics_md_fix` changed. To revert `analytics_md_fix` specifically,
you'd need to re-run its old `create_engagement_view`/`refresh_engagement_views_all`
procedure definitions (see `Mindshare_Backend/Analytics_md_fix/functions/create_engagement_view.sql`,
still in the repo, un-deleted) and drop the new tables — there's no automated rollback
script, this is a deliberate one-way cutover per the task's instructions.
