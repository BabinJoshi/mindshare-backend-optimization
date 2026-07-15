# Testing the incremental refresh — checkpoint rewind + real write-cost approach

Companion to `docs/analytics_incremental_engagement.md` — read that first for how the
incremental refresh actually works. This doc covers how to test it against real data.

All SQL for this approach is inline below — no separate `.sql` file, copy the block you
need straight into DBeaver.

## What it is

Rewind the **real** checkpoint's watermark backward by an interval, delete the
**target** table's own rows for that window (source table untouched), then call the
real incremental proc. It finds those rows both dirty (checkpoint rewound) *and*
genuinely missing from the target (just deleted) — a real `INSERT` happens, giving an
actual write-cost measurement instead of a scan-only one. `ROLLBACK` then restores
everything — checkpoint, deleted rows, re-inserted rows — to exactly the pre-test state.

**Why the delete step matters:** rewinding the checkpoint alone isn't enough to measure
write cost. Tried that first — rewound `quipnetwork`'s (6.5M rows) and the global scope's
(4.2M rows) checkpoints by 30 days and called the incremental proc with no delete step.
Measured on this DB (2026-07-12): `quipnetwork` scanned 970,225 dirty rows in 21,582 ms,
global scanned 1,699,486 in 46,739 ms — both wrote **0** rows. Both scopes had just been
fully rebuilt minutes earlier (`run_engagement_all_parallel('full', 4)`), so the rewound
window was already 100% covered — there was nothing new to write. That number is real
(it's the cost of scanning and joining a large dirty-set even when nothing changes), but
it isn't a write-cost measurement. Deleting the target's own rows for that window first
is what makes the backlog genuinely real, so the subsequent `CALL` does actual work.

## How to run it

1. **Turn auto-commit off first** (DBeaver: "Database" menu → "Transaction Mode" →
   "Manual Commit"). Everything below is `BEGIN...ROLLBACK` — with auto-commit on,
   DBeaver commits each statement individually and nothing gets undone. This exact
   mistake is documented as a real bug hit live — main doc §3.6 bug #3.
2. **Run the dry-run `SELECT` first**, before the `BEGIN` block — read-only, tells you
   how many real rows are about to become dirty for the window/scope you picked.
3. If that count is much bigger than expected, shrink the interval before running the
   `BEGIN...ROLLBACK` block.
4. Run `BEGIN` through `ROLLBACK` as one script (`Alt+X`), not statement-by-statement.
5. Row counts are captured before the delete, after the delete, and after the re-`CALL`
   — `after_reinsert` should equal `before` exactly, confirming the incremental really
   rewrote what was removed rather than silently skipping it (which is exactly what
   `ON CONFLICT DO NOTHING` would do if the target rows *hadn't* been deleted first).
6. Flip auto-commit back on afterward.

### Per-project scope (example: `Acurast`, 7-day window)

```sql
-- dry run: how many rows would this pick up?
SELECT count(*) AS rows_that_would_be_picked_up
FROM mindshare.mindshare_post
WHERE project_keyword = 'Acurast'
  AND NOT is_retweet
  AND GREATEST(created_at, updated_at) > (
      SELECT last_ingest_ts - interval '7 days'
      FROM analytics_md_fix.engagement_refresh_state
      WHERE scope_key = 'project:acurast'
  );

SELECT count(*) AS rowcount_before FROM analytics_md_fix.mv_engagement_acurast;

BEGIN;

UPDATE analytics_md_fix.engagement_refresh_state
SET last_ingest_ts = last_ingest_ts - interval '7 days'
WHERE scope_key = 'project:acurast';

-- delete the TARGET's rows for the rewound window only (source table untouched) —
-- both real engagement rows and placeholders for roots whose activity falls here.
--
-- Materialize the dirty set into a real, indexed temp table and delete in TWO plain
-- equi-joins instead of one DELETE with `x IN (...) OR (y IN (...) AND ...)`. That
-- combined-OR shape is a real trap: Postgres can't hash both uncorrelated subqueries
-- together under default work_mem, so it falls back to re-scanning the CTE once per
-- outer row — on a large project (e.g. quipnetwork, 6.5M rows) that produced a cost
-- estimate of 146 BILLION (confirmed via EXPLAIN on this DB, §3.6 bug #4) and the
-- query never finished. The two-DELETE version below gets clean Hash Joins instead —
-- verified via EXPLAIN at a tiny fraction of that cost, and safe at any project size.
SET LOCAL work_mem = '64MB';

CREATE TEMP TABLE _tt_dirty ON COMMIT DROP AS
SELECT post_id FROM mindshare.mindshare_post
WHERE project_keyword = 'Acurast' AND NOT is_retweet
  AND GREATEST(created_at, updated_at) > (
      SELECT last_ingest_ts FROM analytics_md_fix.engagement_refresh_state
      WHERE scope_key = 'project:acurast'
  );
CREATE INDEX ON _tt_dirty (post_id);
ANALYZE _tt_dirty;

DELETE FROM analytics_md_fix.mv_engagement_acurast t
USING _tt_dirty d
WHERE t.engaged_tweet_id = d.post_id;

DELETE FROM analytics_md_fix.mv_engagement_acurast t
USING _tt_dirty d
WHERE t.root_post_id = d.post_id AND t.engaged_tweet_id IS NULL;

SELECT count(*) AS rowcount_after_delete FROM analytics_md_fix.mv_engagement_acurast;

CREATE TEMP TABLE _rw_project (ms numeric);
DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    CALL analytics_md_fix.refresh_engagement_incremental('Acurast');
    INSERT INTO _rw_project VALUES (extract(epoch FROM (clock_timestamp()-t0))*1000);
END $$;

SELECT ms AS realwrite_ms FROM _rw_project;
SELECT rows_inserted, placeholders_removed, placeholders_inserted, last_ingest_ts
FROM analytics_md_fix.engagement_refresh_state WHERE scope_key = 'project:acurast';

-- should equal rowcount_before — proves the reinsert fully restored the table
SELECT count(*) AS rowcount_after_reinsert FROM analytics_md_fix.mv_engagement_acurast;

ROLLBACK; -- undoes the checkpoint rewind, the DELETE, and the re-INSERT — no lasting effect
```

Swap `'Acurast'` / `mv_engagement_acurast` / `'project:acurast'` and the
`interval '7 days'` for whatever project/window you want to test (`interval '1 day'` for a
daily-cadence test, `interval '30 days'` for a monthly-backlog test) — check the dry-run
count first either way, especially at 30 days on a large scope.

### Global scope (`mv_user_posts_engagement`, 7-day window)

No placeholder logic in this scope (§3.4 of the main doc), so only `engaged_tweet_id`
rows need deleting:

```sql
SELECT count(*) AS rows_that_would_be_picked_up
FROM mindshare.user_post
WHERE GREATEST(created_at, updated_at) > (
      SELECT last_ingest_ts - interval '7 days'
      FROM analytics_md_fix.engagement_refresh_state
      WHERE scope_key = 'user_posts_engagement'
  )
  AND (
      replied_post_id IS NOT NULL OR quoted_post_id IS NOT NULL OR retweeted_post_id IS NOT NULL
      OR ((is_post OR is_quote) AND NOT is_reply AND NOT is_retweet)
  );

SELECT count(*) AS rowcount_before FROM analytics_md_fix.mv_user_posts_engagement;

BEGIN;

UPDATE analytics_md_fix.engagement_refresh_state
SET last_ingest_ts = last_ingest_ts - interval '7 days'
WHERE scope_key = 'user_posts_engagement';

-- same temp-table + equi-join pattern as the project scope (see the comment there) —
-- only one DELETE needed here since there's no OR/placeholder condition, but the
-- indexed temp table still avoids depending on work_mem being large enough to hash a
-- ~1.7M-row set on the fly.
SET LOCAL work_mem = '64MB';

CREATE TEMP TABLE _tt_dirty_global ON COMMIT DROP AS
SELECT post_id FROM mindshare.user_post
WHERE GREATEST(created_at, updated_at) > (
    SELECT last_ingest_ts FROM analytics_md_fix.engagement_refresh_state
    WHERE scope_key = 'user_posts_engagement'
);
CREATE INDEX ON _tt_dirty_global (post_id);
ANALYZE _tt_dirty_global;

DELETE FROM analytics_md_fix.mv_user_posts_engagement t
USING _tt_dirty_global d
WHERE t.engaged_tweet_id = d.post_id;

SELECT count(*) AS rowcount_after_delete FROM analytics_md_fix.mv_user_posts_engagement;

CREATE TEMP TABLE _rw_global (ms numeric);
DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    CALL analytics_md_fix.refresh_user_posts_engagement_incremental();
    INSERT INTO _rw_global VALUES (extract(epoch FROM (clock_timestamp()-t0))*1000);
END $$;

SELECT ms AS realwrite_ms FROM _rw_global;
SELECT rows_inserted, last_ingest_ts
FROM analytics_md_fix.engagement_refresh_state WHERE scope_key = 'user_posts_engagement';

-- should equal rowcount_before
SELECT count(*) AS rowcount_after_reinsert FROM analytics_md_fix.mv_user_posts_engagement;

ROLLBACK;
```

## Measured results — all projects, full build vs weekly vs daily incremental (2026-07-12 baseline)

Run one project at a time (same `BEGIN...ROLLBACK` pattern above, 7-day and 1-day
real-write windows), 2026-07-12. Full-build timing pulled from `engagement_run_log`'s
existing real numbers (all from the same recent `run_engagement_all_parallel('full', 4)`
batch, so directly comparable). Weekly/daily numbers are fresh, real writes (not
scan-only) — every row deleted from the target was genuinely reinserted by the
unmodified `refresh_engagement_incremental` proc, then `ROLLBACK`ed. Every project's
final row count was confirmed to match its pre-test count exactly.

> The 13-project table below is the original 2026-07-12 benchmark, kept as-is for
> reference. `Acurast` and the global scope were **re-verified on 2026-07-14** with the
> current dual-watermark procs and an added 30-day window — see
> "[Re-verified 2026-07-14](#re-verified-2026-07-14--example-project--global-with-a-30-day-window)"
> below. The global numbers changed materially; the project story did not.

| Project | Full build (ms) | Weekly (7d) real-write (ms) | Weekly speedup | Daily (1d) real-write (ms) | Daily speedup |
|---|---|---|---|---|---|
| Acurast | 1,832 | 57 | 32x | 29 | 63x |
| IronAllies_ | 2,649 | 61 | 43x | 29 | 92x |
| D3lMundos | 3,611 | 80 | 45x | 18 | 201x |
| EthraShip | 5,505 | 2,848 | 1.9x | 84 | 66x |
| test11 | 102 | 19 | 5.5x | 12 | 8.5x |
| NucleusCodes | 13,957 | 3,937 | 3.5x | 275 | 51x |
| _technotainment | 14,779 | 40 | 371x | 17 | 874x |
| Pact_Swap | 32,384 | 228 | 142x | 19 | 1,725x |
| YOM_Official | 37,832 | 148 | 256x | 27 | 1,399x |
| CNPYNetwork | 56,314 | 7,296 | 7.7x | 96 | 584x |
| TheARCTERMINAL | 80,832 | 6,037 | 13.4x | 81 | 1,004x |
| sleepagotchi | 82,243 | 6,906 | 11.9x | 138 | 596x |
| quipnetwork | 167,049 | 6,460 | 26x | 170 | 985x |

`quipnetwork` is the same query shape that hung for 18+ minutes before the temp-table +
equi-join fix (§3.6 bug #4 in the main doc) — ran clean here (6,460 ms weekly, 170 ms
daily), confirming the fix holds at the largest project's scale.

**Speedup varies a lot by project**, and that's a real, expected finding — not noise.
`EthraShip`'s weekly speedup is only 1.9x because 89,503 of its 170,351 rows (over half
the table) were ingested in the last 7 days — a genuinely bursty/recent-heavy project, so
"weekly" isn't really a small incremental for it right now. Compare that to
`_technotainment` (371x weekly speedup) or `YOM_Official` (256x) — low recent-ingestion
projects where the incremental path does almost nothing, as designed. The daily window is
consistently a much bigger win (51x-1,725x) across every project, since one day of
backlog is a small fraction of any of these tables.

Global scope (`user_posts_engagement`, 4.2M rows), measured 2026-07-12 (run by hand in
DBeaver — tool-call access was blocked mid-session). **Superseded by the 2026-07-14
re-verification below** — kept only to show the change:

| Scope | Full build (ms) | Weekly (7d) real-write (ms) | Weekly speedup | Daily (1d) real-write (ms) | Daily speedup |
|---|---|---|---|---|---|
| global (2026-07-12, pre-dual-watermark) | 34,892 | 18,446 | 1.9x | 9,238 | 3.8x |

## Re-verified 2026-07-14 — example project + global, with a 30-day window

Re-ran the example project (`Acurast`) and the global scope on 2026-07-14 with the
current **dual-watermark** procs, adding a 30-day window. Full-build timings are fresh
`BEGIN...ROLLBACK` runs of the same procs (not pulled from the log). Every run's
`after_reinsert` row count matched its pre-test count exactly.

| Scope | Rows | Full build (ms) | 30d real-write (ms / speedup) | 7d real-write (ms / speedup) | 1d real-write (ms / speedup) |
|---|---|---|---|---|---|
| Acurast (project) | 114,576 | 1,784 | 42 / **43x** | 24 / **74x** | 20 / **90x** |
| global | 4,218,967 | 45,723 | 82,559 / **0.55x** | 29,900 / **1.5x** | 36,911 / **1.2x** |

Rows actually reinserted per window (real writes, then rolled back): Acurast 105 / 13 / 12;
global 1,659,905 / 533,893 / 238,391.

**Project scope stays a large win at every window** (43x–90x for Acurast). Each project's
dirty-scan only touches its own partition, so cost tracks the (tiny) recent-ingestion
volume — the same story as the 2026-07-12 table.

**Global scope is now marginal-to-net-loss for any rewound window — the honest result, not
a correctness regression.** Two compounding, data-shape-specific reasons:

1. **Burst day.** Global `user_post` ingestion stops at `2026-07-06`, and `07-06` was the
   single densest day in the dataset (244,282 rows vs 35k–52k the days before). So even a
   1-day rewind reprocesses that entire burst (~238k rows), not a typical small day.
2. **Fixed root-resolution scan floor.** The global re-insert resolves every dirty engaged
   tweet back to its root via a self-join against the full 4.2M-row `user_post` table, plus
   two joins to `mindshare_user` for live score/username. That cost is largely *fixed*
   regardless of dirty-set size — which is why all three windows cluster at ~30–37s and
   don't scale cleanly with row count (1d 36.9s actually came in *slower* than 7d 29.9s:
   noise around a fixed floor). At 30d the 1.66M reinserts push past that floor to 82.6s,
   comfortably beyond the 45.7s full rebuild — so for a large global backlog, **a full
   rebuild is simply the better tool.**

These global numbers **supersede** the 2026-07-12 figures (1d 9.2s/3.8x, 7d 18.4s/1.9x),
which were measured on the older single-watermark proc. The current proc does more work per
reinserted row (the two `mindshare_user` LEFT JOINs the dual-watermark design added), and
the fixed self-join floor dominates.

**Framing — this is worst-case backlog catch-up, not the steady-state daily tick.** The
time-travel test deletes and reinserts an entire N-day window in one shot. In production,
global runs once per real ingest and processes only genuinely-new rows since the last
watermark; on a normal (non-burst) day that is a small fraction of a day's data and
finishes fast. The `07-06` burst is exactly the pathological case that makes any windowed
rewind look bad.

**Candidate optimization (observation, not yet done):** global's dominant cost is that the
re-insert rescans all 4.2M `user_post` rows to resolve roots on every run. Restricting that
join to only the roots reachable from the dirty set (e.g. an indexed temp table of the
dirty engaged tweets' `COALESCE(replied,quoted,retweeted)_post_id` values, joined to
`user_post` by `post_id`) would drop the fixed floor to track dirty-set size like the
per-project scope already does. Worth doing only if global's per-run latency becomes a
production concern.

## Caveats

- **Volume varies wildly and isn't in your control.** Real observed ingestion, checked
  live on this DB (2026-07-12):

  | Scope | Day | Rows ingested that day |
  |---|---|---|
  | `Acurast` (project) | 2026-07-10 | 7 |
  | `Acurast` (project) | 2026-07-09 | 1 |
  | `Acurast` (project) | 2026-07-05 | 3 |
  | global (`user_post`) | 2026-07-06 | 244,282 |
  | global (`user_post`) | 2026-07-05 | 38,943 |
  | global (`user_post`) | 2026-07-02 | 51,967 |

  A 1-day window on a small project is a handful of rows and finishes instantly. The
  same 1-day window on the global scope or a large project can mean tens of thousands to
  ~1M rows. Always run the dry-run count first, and shrink the window if it's bigger
  than you want.
- **`engagement_run_log` rows are NOT undone by `ROLLBACK`.** Logging commits through an
  autonomous `dblink` connection independent of your transaction (main doc §7). Every
  test run here leaves a permanent row in `engagement_run_log`.
- **This is real reprocessing, not a simulation, until `ROLLBACK` runs.** Don't kill the
  session or disconnect between `BEGIN` and `ROLLBACK` — that leaves the transaction
  `idle in transaction` indefinitely, holding the advisory lock for that scope (blocking
  any other refresh of the same project/global scope) and leaving the target table
  missing real rows until it's cleared. If you suspect this happened, check:
  ```sql
  SELECT pid, state, xact_start, now() - xact_start AS age, query
  FROM pg_stat_activity
  WHERE state = 'idle in transaction';
  ```
  and `ROLLBACK` (or ask whoever owns that connection to) before retrying.
