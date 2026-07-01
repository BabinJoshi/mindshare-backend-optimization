# Incremental Decay Score Computation — Design & Implementation Plan

This document specifies how to convert the decay-score functions in the
`mindshare_score` schema from **full truncate-and-recompute** to **incremental
recomputation**, so a run does work proportional to *what changed* rather than
to the entire corpus.

- **Analyzed on:** 2026-06-24, against the live `mindshare_db` database.
- **Scope:** the four PL/pgSQL functions
  `mindshare_score.calculate_decay_scores`,
  `mindshare_score.calculate_all_decay_scores`,
  `mindshare_score.calculate_global_decay_scores`,
  `mindshare_score.calculate_all_global_decay_scores`,
  and the tables `mindshare_score.contribution_scores` /
  `mindshare_score.global_contribution_scores`.
- **Status:** design proposal. No schema or data changed during analysis.

> Cross-reference: source-read indexes live in
> [Mindshare_Backend/Mindshare_score/Indexes/decay_source_read_indexes.sql](../Mindshare_Backend/Mindshare_score/Indexes/decay_source_read_indexes.sql);
> measured query timings in
> [postgres_efficiency_optimization.md](postgres_efficiency_optimization.md).

---

## 1. Executive summary

| | Today (full recompute) | Proposed (incremental) |
|---|---|---|
| Trigger | `TRUNCATE` + replay **every** reply | Replay only repliers with **new/changed** activity |
| Project work unit | 6.02 M replies, 10 projects, every run | ~the replies ingested since last run + their window tail |
| Global work unit | 3.19 M replies, every run | same idea, globally |
| Output tables | rebuilt from empty | mutated in place (delete-tail + insert) |

**The user's premise is correct — with one critical qualification.** A reply's
decay score depends **only** on the *same replier's* earlier replies (within a
rolling 30-day window) plus that replier's base score. It never depends on
anything that happens later. So newly-arriving replies do not change *correctly
computed* past scores — they only need the existing window state to score
themselves.

**The qualification:** "new" must mean *newly ingested*, not *newly tweeted*.
**24 % of replies are ingested more than a day after they were tweeted, and
~572 k (9.5 %) more than 30 days late** (§3). A late-arriving reply carries an
*old* `post_created_at` that can land **before** rows we already scored for that
replier — and that *does* invalidate those later rows. Therefore the safe
incremental unit is **"recompute an affected replier from the earliest changed
tweet-time forward,"** not "append rows newer than a global watermark." A naive
watermark-on-tweet-time append would silently corrupt scores.

This is entirely tractable because repliers are independent of one another, so
only repliers with new activity are touched.

---

## 2. How the current algorithm works

Both `calculate_decay_scores(project, interval)` and
`calculate_global_decay_scores(interval)` are the **same algorithm** over
different sources:

| | Project function | Global function |
|---|---|---|
| Source | `mindshare.mindshare_post` | `mindshare.user_post` |
| Reply→parent join | on `replied_post_id` **and** `project_keyword` | on `replied_post_id` only |
| Output | `contribution_scores` (incl. `project_keyword`) | `global_contribution_scores` |
| Decay branches | identical | identical |

The loop reads replies `ORDER BY user_x_id, post_created_at` and keeps a small
**rolling penalty log** (parallel arrays `mult / time / author`) per replier. For
each reply at time `T`:

1. **Reset on new replier.** When `replier_x_id` changes, clear all state and set
   `base_score = mindshare_user.score`, `min_floor = round(base * 0.01, 2)`.
2. **Prune the window.** Drop penalty entries with `time <= T - interval`
   (default `interval = 30 days`). Each penalty expires individually.
3. **Local count.** `local_seq = (# of surviving entries whose author == this
   reply's original author) + 1`.
4. **Effective score.** `effective = max(round(base * Π(surviving mults), 2),
   min_floor)`.
5. **Apply this reply's multiplier:**
   - window empty → `FIRST_REPLY`, mult `1.00` (no penalty)
   - else if `local_seq > 1` → `LOCAL_DECAY`, mult `0.50`
   - else → `GLOBAL_DECAY`, mult `0.90`
   `contribution = max(round(effective * mult, 2), min_floor)`.
6. **Append** `(mult, T, original_author)` to the log and **insert** the row.
   `active_multipliers` is stored as the **post-append snapshot of the surviving
   window** — so its *last element is always this reply's own multiplier*.

`calculate_all_decay_scores` wraps this: `TRUNCATE contribution_scores`, loop
over `DISTINCT project_keyword`, then rebuild indexes.
`calculate_all_global_decay_scores` does the same for the single global table.

### 2.1 The dependency structure (why incremental is sound)

Two facts fall straight out of the loop:

- **Repliers are independent.** State resets per `replier_x_id`; no replier reads
  another's data. *(Project table: independent per `(project_keyword,
  replier_x_id)`.)*
- **Within a replier, dependencies point only forward in tweet-time.** A reply at
  `T` is computed from entries in `(T − interval, T)` and `base_score`. So a reply
  at `T` can only affect replies in `(T, T + interval]` for the same replier.

**Consequence:** to correctly absorb a change at tweet-time `T_min` for one
replier, recompute that replier's rows with `post_created_at ≥ T_min`, seeded by
the (unchanged) rows in `(T_min − interval, T_min)`. Everything else — all other
repliers, and that replier's rows before `T_min` — is provably untouched.

### 2.2 State is fully reconstructable from the output table

The seed window for any replier can be rebuilt from existing rows alone — no
re-derivation from source needed. For each kept row `r`:

```
mult   = r.active_multipliers[array_upper(r.active_multipliers, 1)]  -- last element
time   = r.post_created_at
author = r.original_author_x_id
```

Ordered by `post_created_at`, these exactly reproduce the penalty log the full
run would hold at `T_min`. `reply_number` seeds from the count of that replier's
kept rows (it is cumulative, never pruned).

---

## 3. Measured facts that shape the design

All from live `mindshare_db` on 2026-06-24.

| Metric | Value |
|---|---|
| `mindshare_post` replies (`is_reply`) | **6,022,850** across **10** projects |
| `user_post` replies | **3,192,347** |
| `contribution_scores` rows / distinct repliers | 1,926,961 / **124,905** |
| `global_contribution_scores` rows / distinct repliers | 2,112,439 / **74,434** |
| Max scored `post_created_at` (project) vs source | 2026-06-16 vs **2026-06-24** (~8-day backlog) |

**Ingestion lag (`created_at − post_created_at`) for project replies:**

| Late by > | Replies | % of 6.02 M |
|---|---|---|
| 1 hour | 5,904,693 | 98 % |
| 1 day | 1,443,815 | 24 % |
| 7 days | 878,104 | 14.6 % |
| 30 days | 572,419 | **9.5 %** |

The >30-day bucket is the decisive number: ~1 in 10 replies arrives *after* its
own 30-day decay window has already closed. The design must treat out-of-order
arrival as the **normal case**, not an edge case.

**Constraints / keys (current):**

- Output tables have **no primary key or unique index** — only the non-unique
  btree indexes created by the functions.
- `reply_post_id` is **not** unique in `contribution_scores` (same post id appears
  across projects) but **`(project_keyword, reply_post_id)` is unique** (0 dups).
- `reply_post_id` **is** unique in `global_contribution_scores` (0 dups).
- `mindshare_post` carries both `post_created_at` (tweet time), `created_at`
  (ingest time) and `updated_at` — the latter two are the watermark signals.

---

## 4. Schema changes required

Incremental needs an upsert/delete key and an efficient per-replier window read.

```sql
-- 4.1 Uniqueness (also dedups defensively; verified 0 conflicts today)
ALTER TABLE mindshare_score.contribution_scores
    ADD CONSTRAINT pk_cs PRIMARY KEY (project_keyword, reply_post_id);

ALTER TABLE mindshare_score.global_contribution_scores
    ADD CONSTRAINT pk_gcs PRIMARY KEY (reply_post_id);

-- 4.2 Per-replier, time-ordered access for seed-read + delete-range
CREATE INDEX IF NOT EXISTS idx_cs_replier_time
    ON mindshare_score.contribution_scores (project_keyword, replier_x_id, post_created_at);
CREATE INDEX IF NOT EXISTS idx_gcs_replier_time
    ON mindshare_score.global_contribution_scores (replier_x_id, post_created_at);

-- 4.3 Bookkeeping: last successful run watermark (ingest-time based)
CREATE TABLE IF NOT EXISTS mindshare_score.decay_run_state (
    scope          text PRIMARY KEY,           -- 'project:<kw>' or 'global'
    last_ingest_ts timestamptz NOT NULL,        -- max(greatest(created_at,updated_at)) processed
    last_run_at    timestamptz NOT NULL DEFAULT now(),
    rows_written   bigint
);
```

Source-side, the change-detection scan benefits from an index on the ingest
watermark (in addition to the existing tweet-time read indexes):

```sql
CREATE INDEX IF NOT EXISTS ix_mindshare_post_ingest
    ON mindshare.mindshare_post (greatest(created_at, updated_at))
    WHERE is_reply = true AND replied_post_id IS NOT NULL;
-- analogous ix_user_post_ingest on mindshare.user_post
```

---

## 5. Change-detection — what counts as "new work"

Run with a watermark `p_since = decay_run_state.last_ingest_ts`. A replier must be
recomputed if **any** of these changed since `p_since`:

1. **A reply was inserted or updated** — `greatest(reply.created_at,
   reply.updated_at) > p_since`.
2. **The reply's parent post arrived/changed late** — a reply may become scorable
   only once its parent exists (the inner join). Include replies where
   `greatest(parent.created_at, parent.updated_at) > p_since`.
3. **The replier's base score changed** — `mindshare_user.score` updated since
   `p_since` (see §6; multiplies every row, so it must trigger a recompute).

For each affected replier, compute the **earliest affected tweet time**:

```sql
-- Project scope; collect (replier, T_min) to recompute
SELECT p.user_x_id AS replier_x_id,
       min(p.post_created_at) AS t_min
FROM mindshare.mindshare_post p
JOIN mindshare.mindshare_post op
     ON p.replied_post_id = op.post_id
    AND p.project_keyword = op.project_keyword
WHERE p.is_reply = true
  AND p.replied_post_id IS NOT NULL
  AND p.project_keyword = p_project_keyword
  AND ( greatest(p.created_at,  p.updated_at)  > p_since
     OR greatest(op.created_at, op.updated_at) > p_since )
GROUP BY p.user_x_id;
```

(Add base-score-changed repliers with their full `min(post_created_at)` so they
recompute entirely.) In the steady state this set is small — only repliers active
since the last run — which is the whole point.

---

## 6. The `base_score` decision (must be made explicitly)

`base_score` is read from `mindshare_user.score` **at run time** and multiplies
every output for that replier. Full recompute reprices *all* history at the
current score. Incremental only reprices the recomputed tail.

- **Option A — freeze history (cheapest).** Old rows keep the score they were
  computed with; only the tail (`≥ T_min`) uses the current score. Matches the
  "new records don't touch the past" intuition, but a leaderboard can show two
  scores from the same base era if a user's score later changed. Reconcile with a
  periodic full rebuild (§9).
- **Option B — recompute the replier when their score changes (recommended).**
  Treat a `mindshare_user.score` change as `T_min = (that replier's earliest
  reply)`, i.e. recompute the replier in full. Keeps exact parity with a full
  rebuild at the cost of re-replaying that replier. Cost is bounded because score
  changes are far rarer than new replies.

Recommendation: **Option B.** Detect by comparing the latest stored
`replier_base_score` for the replier against the current `mindshare_user.score`.

---

## 7. Proposed functions

Keep the inner decay logic **single-sourced** to avoid drift between full and
incremental paths. Factor the per-replier replay into one routine that both call.

### 7.1 `recompute_replier_decay(project, replier, from_time, interval)`

```text
function recompute_replier_decay(p_project, p_replier, p_from, p_interval):
    base := current mindshare_user.score for p_replier
    min_floor := round(base * 0.01, 2)

    -- seed window + reply counter from existing, still-valid rows
    seed := rows of contribution_scores for (p_project, p_replier)
            with post_created_at in (p_from - p_interval, p_from), ordered by time
    penalty_log := [ (active_multipliers[last], post_created_at, original_author_x_id)
                     for each seed row ]
    reply_seq := count of rows for (p_project, p_replier) with post_created_at < p_from

    -- replace the tail
    DELETE FROM contribution_scores
     WHERE project_keyword=p_project AND replier_x_id=p_replier
       AND post_created_at >= p_from

    for rec in replies for (p_project, p_replier) with post_created_at >= p_from
               ORDER BY post_created_at:          -- same body as today
        reply_seq += 1
        prune penalty_log to time > rec.post_created_at - p_interval
        local_seq := count(author == rec.original_author) + 1
        effective := max(round(base * Π(mults), 2), min_floor)
        (mult, dtype) := FIRST_REPLY/ LOCAL_DECAY(0.50)/ GLOBAL_DECAY(0.90)   -- §2 step 5
        contribution := max(round(effective * mult, 2), min_floor)
        append (mult, rec.post_created_at, rec.original_author) to penalty_log
        INSERT row (… same columns as today …)
```

This body is **byte-for-byte the existing loop**; only the *bounds* (one replier,
`post_created_at >= from_time`) and the *seed* differ. The global variant is
identical without `project_keyword`.

### 7.2 `calculate_decay_scores_incremental(interval, p_since DEFAULT NULL)`

```text
function calculate_decay_scores_incremental(p_interval, p_since):
    pg_advisory_xact_lock(<decay-project>)            -- no overlap with full run
    p_since := COALESCE(p_since, decay_run_state['project:*'].last_ingest_ts, '-infinity')
    for each project_keyword:
        affected := change-detection query (§5) → {(replier, t_min)}
        affected += base-score-changed repliers (t_min = their first reply)   -- Option B
        for (replier, t_min) in affected:
            recompute_replier_decay(project_keyword, replier, t_min, p_interval)
        decay_run_state['project:'||kw] :=
            max(greatest(created_at,updated_at)) just processed
```

`calculate_global_decay_scores_incremental` is the same with the global source,
no project loop, and the global table.

The existing `calculate_all_*` functions are **retained unchanged** as the
periodic full-rebuild / disaster-recovery path (§9).

---

## 8. Worked correctness examples

- **In-order new reply (steady state).** Replier R's newest scored reply is at
  day 100; a new reply arrives at day 101. Change-detection yields
  `T_min = day 101`. Seed = R's rows in (day 71, day 101). Delete tail `≥ 101`
  (none). Append one row. → identical to a full run. ✅
- **Late arrival inside an open window.** R has scored replies at days 100, 110,
  120. A reply tweeted at day 105 is ingested today. `T_min = 105`. We delete R's
  rows `≥ 105` (the 110 and 120 rows), seed from (75, 105), and replay 105 → 110 →
  120. The 110/120 rows are re-derived with the day-105 penalty now in window —
  exactly what a full run would produce. ✅ (A tweet-time watermark append would
  have inserted only day-105 and left 110/120 wrong. ✗)
- **Late arrival past the window.** Reply tweeted 40 days ago, ingested today.
  `T_min` = 40 days ago; but the prune step immediately discards any seed entry
  older than `T_min − 30d`, and no *existing* row within 30 days after it is
  affected unless it actually shares the window. Replay handles it uniformly. ✅

---

## 9. Validation & rollout

1. **Add schema objects (§4)** — `CONCURRENTLY` where possible; verify the
   uniqueness assumptions still hold before adding the PKs (they did at analysis
   time: 0 conflicts).
2. **Parity harness.** Snapshot current `contribution_scores` /
   `global_contribution_scores` into `*_full_baseline`. Run the incremental path
   against a controlled `p_since`. For every affected replier, assert
   `contribution_score, effective_score, decay_type, reply_number,
   local_reply_count` match the full-rebuild output **exactly** (the arithmetic is
   deterministic and the loop body is shared, so divergence = a bug). Spot-check
   with the late-arrival scenarios in §8.
3. **Shadow run.** Schedule incremental on the real ingest cadence while still
   doing a nightly full rebuild; diff the two outputs for a few days.
4. **Cut over.** Make incremental the per-ingest job; keep a **weekly full
   rebuild** (`calculate_all_*`) as reconciliation — it re-prices any frozen
   base-score drift (if Option A) and is the recovery path if the watermark is
   ever lost or a backfill bypasses `created_at`/`updated_at`.

---

## 10. Edge cases & operational notes

- **Watermark must be ingest-time** (`greatest(created_at, updated_at)`), never
  `post_created_at` — that is the entire late-arrival safeguard (§3).
- **Parent-after-child:** included via condition 2 in §5; don't drop it.
- **Hard deletes in source** are not caught by a watermark. If replies can be
  deleted, either soft-delete (bump `updated_at`) or rely on the weekly full
  rebuild to clean orphans. Document which.
- **Concurrency:** guard with `pg_advisory_xact_lock` so incremental and full runs
  never interleave on the same table.
- **Indexes stay live** (no `TRUNCATE`), so inserts pay index-maintenance cost —
  acceptable and desired; the per-run row count is tiny vs. a full rebuild.
- **Idempotency:** delete-tail + insert keyed on the new PK means re-running the
  same `p_since` is safe (it reproduces the same rows).
- **Cost model:** work ≈ `Σ_affected_repliers (their replies with
  post_created_at ≥ T_min)` + seed reads, instead of all 6.02 M / 3.19 M rows. In
  steady state this is a small fraction of the corpus; measure and record actual
  timings the way [postgres_efficiency_optimization.md](postgres_efficiency_optimization.md)
  does before/after.
```
