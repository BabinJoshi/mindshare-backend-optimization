# Decay Pipeline — Loop vs Polars vs Set-Based SQL

Decay scoring is the sequential, per-replier contribution algorithm
(`FIRST_REPLY` / `LOCAL_DECAY` / `GLOBAL_DECAY`, 30-day rolling penalty window).
There are now **three** implementations of the same algorithm. This doc compares them and
says when to use which.

| Implementation | Where | Language | Status |
|---|---|---|---|
| PL/pgSQL loop | `mindshare_score.calculate_decay_scores` (prod) + `mindshare_score_md_fix.calculate_decay_scores` | PL/pgSQL | original |
| Polars pipeline | `mindshare_compute/` (`decay.py`, `cli.py`, `db.py`) | Python + Polars | external, fast |
| **Set-based SQL** | `mindshare_score_md_fix.calculate_decay_scores_fast` / `calculate_global_decay_scores_fast` | pure SQL | **new (this round)** |
| Incremental engine | `test_mindshare_score.*` (`calculate_decay_scores_incremental`, run-log/watermark) | PL/pgSQL | prototype — **not touched** |

---

## 1. Why the loop is slow — O(n·k)

Per reply the loop maintains three parallel arrays (`penalty_mults`, `penalty_times`,
`penalty_authors`) and, for every single row:
1. **prunes** the window by rebuilding the arrays (scan all `k` active entries),
2. **counts** same-author entries for `local_reply_count` (scan all `k`),
3. **multiplies** the active multipliers for `effective_score` (scan all `k`).

So each row costs O(k) where `k` = replies by that replier inside the 30-day window →
total **O(n·k)**. For prolific repliers `k` is large, and cost explodes.

## 2. What `decay.py` (Polars) does — O(1) per row

`mindshare_compute/decay.py` keeps the same sequential semantics but replaces the per-row
scans with **carried O(1) state** (`_ReplierState`):
- `author_counts` — a `Counter` (hashmap) → `local_reply_count` in O(1).
- `half_penalties` / `ninety_penalties` — integer counters → the multiplier product is
  `0.5^half · 0.9^ninety`, no window scan.
- `active` — a `deque`; expiry pops from the front in O(1) amortized.

It streams ordered rows from PostgreSQL via a server-side cursor (`db.py`), computes in a
tight loop, writes Parquet, then bulk-loads with `COPY`. This is the fastest option and the
reference for correctness.

## 3. The same insight in pure SQL — two window passes

The key realization (ported from `decay.py`): **the classification depends only on counts**
of prior in-window replies, and **counts are window functions.** Implemented in
`calculate_decay_scores_fast`:

- **Pass 1** — `active_count` and `local_prior` via
  `COUNT(*) OVER (… RANGE BETWEEN '30 days' PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW)`.
  These decide `FIRST_REPLY` / `LOCAL_DECAY` / `GLOBAL_DECAY` and `local_reply_count`.
- **Pass 2** — each row's multiplier is now fixed, so the active product is two conditional
  counts: `h = COUNT(*) FILTER (mult=0.5) OVER w`, `n9 = COUNT(*) FILTER (mult=0.9) OVER w`,
  and `effective_score = base · 0.5^h · 0.9^n9` (mirrors the Polars penalty-power counters).

One set-based `INSERT … SELECT` replaces the row-by-row loop — no per-row trips, no arrays.

> `active_multipliers` (a debug snapshot array) is deliberately left `NULL`: reproducing it
> needs `array_agg` over a RANGE window, which rebuilds a growing array per row — O(n·k), the
> exact cost we're removing (it inflated quipnetwork from ~400 s to ~530 s). Scalar score
> columns are unaffected.

---

## 4. Correctness — validated against production

`calculate_decay_scores_fast('Acurast')` vs `mindshare_score.contribution_scores` (Acurast,
47,898 rows):

| Column | Mismatching rows |
|---|---|
| `decay_type` | 10 |
| `effective_score` | 47 |
| `contribution_score` | 45 |
| `local_reply_count` | 56 |

All mismatches fall inside the **153 rows that share `(replier, post_created_at)`** — the
tied-timestamp zone. The original `ORDER BY p.user_x_id, p.post_created_at` has **no
tiebreak**, so its output there is non-deterministic; production, Polars, and this SQL can each
pick a different valid order. **99.88% exact match; the remainder is genuinely undefined.**
The set-based version adds a deterministic tiebreak (`post_created_at, reply_post_id`), so it is
*reproducible* — arguably more correct than the original.

Row-count cross-check (set-based vs loop, same project): sleepagotchi **711,355 = 711,355** ✓.

---

## 5. Performance — measured

| Project | Source replies | Loop (PL/pgSQL) | Set-based SQL | Speedup |
|---|---|---|---|---|
| Acurast | ~56K | 1.6 s | 1.5 s | ~1× (tiny per-replier window) |
| sleepagotchi | ~730K | **244 s** | **66 s** | **3.7×** |
| quipnetwork | ~2.8M | not run (extrapolates to many minutes) | **398 s** | large |

The speedup **grows with per-replier window size `k`**: Acurast's repliers have tiny windows
(loop ≈ set-based); sleepagotchi is 3.7×; quipnetwork's loop would be far worse than the
set-based 398 s. (Loop time on quip was not measured to avoid a long-running prod-schema job.)

### Honest ceiling
Set-based SQL beats the loop but is **not** "fractions of seconds." At quip scale it is ~6.6
min because of (a) multiple RANGE-frame window sorts over 2.5M rows, (b) per-row `numeric
power()`, and (c) index maintenance on insert. **Polars (`decay.py`) is faster still** — a
single in-memory pass with true O(1) state and bulk `COPY`, with no SQL frame/numeric overhead.

---

## 6. Which to use

- **Heaviest / full recompute of all projects + global:** the **Polars pipeline**
  (`python run_decay_pipeline.py all-projects --write`). Fastest, already built and verified,
  isolates compute from the DB.
- **Pure-in-DB, no Python dependency, scheduled from SQL/cron:** `calculate_decay_scores_fast`
  — 3–4× the loop, one stored procedure, good for mid projects and for environments that can't
  run the Python job.
- **Incremental (only changed repliers):** the `test_mindshare_score` engine is the right
  pattern (watermark + run-log); productionize it rather than re-deriving. (Left untouched per
  instruction.)
- **Retire:** the PL/pgSQL loop once one of the above is wired in (see
  [inventory.md](inventory.md)).

Base-table note: project decay already benefits from `mindshare_post` **LIST partitioning**
(scans only the project's partition). Adding more indexes does **not** speed a full recompute —
the `is_reply AND replied_post_id IS NOT NULL` predicate matches ~95% of a partition, so a seq
scan is optimal. Indexes help only selective/incremental decay. **`user_post` (global source)
is unpartitioned** — partitioning it by time is the open structural win for global decay.
