# Incremental Decay — Simulation & Testing (test replica)

## Why simulate

`test_mindshare` is a **static copy** of `mindshare` — it is **not attached to the live
ingestion pipeline**, so no new rows arrive on their own. To exercise the incremental decay
pipeline (`test_mindshare_score.calculate_decay_scores_incremental` /
`calculate_global_decay_scores_incremental`) we **synthesize ingestion events** ourselves and
verify the result against the gold standard — a full rebuild.

**Gold standard:** for any state of the source data, the incremental result MUST equal what a
full `calculate_decay_scores` would produce. The harness asserts
`symmetric_difference(incremental, full) = 0` after every scenario.

Harness: [`backend_optimization/decay_20_incremental_simulation.sql`](../backend_optimization/decay_20_incremental_simulation.sql)
```bash
psql "$URL" -v ON_ERROR_STOP=1 -f backend_optimization/decay_20_incremental_simulation.sql
```
It is **self-contained, repeatable, and self-cleaning**: synthetic posts use the `SIM_` prefix
and are deleted at the end; any drifted base scores are restored from the source `mindshare`
schema; the watermark is reset and a clean full rebuild is run, leaving the replica pristine
(verified: `cleanup_parity_vs_baseline = 0`).

## How an ingestion event is synthesized

A reply only needs these columns (the rest default; `is_*` are generated):
`post_id, project_keyword, user_x_id, full_text, replied_post_id, view_count, reply_count,
retweet_count, quote_count, favorite_count, post_created_at`. The **ingest** timestamps
`created_at`/`updated_at` are set to `now()` — that is what the watermark keys on. The decay
math still orders by the **tweet** time `post_created_at`.

> Fixture rule learned the hard way: a synthesized/edited reply must point at a parent that
> **actually exists in the same project partition** (the decay `INNER JOIN op` drops replies
> whose parent is absent). The harness picks the parent via a join to guarantee this.

## Scenarios

| # | Simulated event | Branch exercised | Expected |
|---|---|---|---|
| S1 | INSERT a recent reply by an existing replier (`post_created_at = max+1h`, ingest `now()`) | (1) reply changed | dirty=1, parity=0 |
| S2 | INSERT a **late** reply (`post_created_at` in the *middle* of the replier's history, ingest `now()`) | (1) via ingest watermark | dirty≥1, parity=0 — proves late arrivals correct the replier's *later* rows |
| S3 | Bump an existing **parent** post's `updated_at` (reply itself unchanged) | (2) parent-late | dirty≥1, parity=0 |
| S4 | `UPDATE mindshare_user.score` for a replier | (3) base-score drift (Option B) | dirty=1, parity=0 |
| S5 | No change | — | **dirty=0** (no work) |

The harness fails loudly (`RAISE EXCEPTION`) if any parity diff ≠ 0, if any detection branch
does not fire, or if the no-op does any work.

## Results (Acurast, 47,898 baseline rows)

| Scenario | dirty repliers | parity vs full |
|---|---|---|
| S1 new recent reply | 1 | **0** |
| S2 late-arriving reply | 1 | **0** |
| S3 parent-late (branch 2) | 97 | **0** |
| S4 base-score change | 1 | **0** |
| S5 no-op | 0 | **0** |
| cleanup vs baseline | — | **0** |

Interpretation: each event recomputes only the handful of affected repliers (1, 1, 97, 1, 0)
instead of all 47,898 rows, and the output is byte-identical to a full rebuild every time.

## Bug found by the simulation (and fixed): non-deterministic tie ordering

S3 initially showed **16 differing rows**. Root cause: the decay loop is order-sensitive
(`reply_number`, the rolling penalty window), but the driving query ordered only by
`ORDER BY user_x_id, post_created_at`. When a replier has **multiple replies in the same second**,
their relative order was undefined — so a full scan and a dirty replay could order the ties
differently, yielding different `reply_number`/`decay_type`/scores. (This is latent in the
original production functions too: even full-vs-full is not guaranteed identical for tied
timestamps.)

**Fix:** add a deterministic tiebreaker — `ORDER BY user_x_id, post_created_at, post_id` — in
both cores (`_decay_apply_project`, `_decay_apply_global`). After the fix, all scenarios show
parity = 0. The differing rows were confirmed to all sit at duplicate
`(replier_x_id, post_created_at)` timestamps before the fix.

## Full vs incremental — measured compute time

Benchmark harness: [`backend_optimization/decay_21_benchmark_full_vs_incremental.sql`](../backend_optimization/decay_21_benchmark_full_vs_incremental.sql)
(clean-slates `test_mindshare_score`, then times the first incremental run = **full cold build**
and the immediately-following run = **incremental, no new data**).

Verified on the smallest projects (so the test is fast and easy to re-run). `FULL` = cold full
build of that project; `INCREMENTAL (no-op)` = re-run with nothing changed; the last row is a
single-replier change to show real incremental work.

| Project | replies | contribution rows | **Full (cold)** | **Incremental (no-op)** | Speedup |
|---|---:|---:|---:|---:|---:|
| IronAllies_ | 28,220 | 23,556 | **1.05 s** | **0.10 s** | ~10× |
| D3lMundos  | 54,583 | 41,398 | **2.62 s** | **0.12 s** | ~21× |
| Acurast    | 55,806 | 47,898 | **2.01 s** | **0.16 s** | ~13× |

Change-driven incremental (IronAllies_, one replier's base score changed):
**0.28 s**, recomputed **865 rows (1 replier)**, result **identical to a full rebuild** (parity = 0).

Reading these:
- A **no-op** incremental run costs ~0.1 s regardless of project — it is just the dirty-detection
  queries (index scans on `ix_tmp_*_ingest` + the base-score-drift comparison); it writes nothing.
- A **real** incremental run scales with the number of *changed repliers*, not table size — one
  changed replier recomputed 865 rows in 0.28 s vs 23,556 rows / 1.05 s for the full build.
- **Global** and the large projects (quipnetwork 2.7M, TheARCTERMINAL 1.45M) are far slower to
  full-build (minutes each, row-by-row) — which is exactly why the incremental path matters; the
  per-trigger incremental cost there stays in the sub-second-to-seconds range for typical deltas.
  Run `decay_21_*.sql` to benchmark the whole set (long: ~tens of minutes for the full pass).

## Extending the harness

Add a scenario by following the S1–S5 pattern: synthesize the event with `created_at/updated_at =
now()`, call the incremental function, snapshot into `sim_inc`, run the full function, and record
`pg_temp.sim_parity('Acurast')`. Add an expectation row and (optionally) a `RAISE EXCEPTION`
assertion. Ideas not yet covered: a reply whose parent and reply both arrive new in the same run;
deletion of a source reply (caught only by the weekly full reconciliation, not the watermark —
document the expectation accordingly).
