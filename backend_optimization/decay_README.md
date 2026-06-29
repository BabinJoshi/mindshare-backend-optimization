# Decay pipeline (test) — `test_mindshare_score`

Replica of `mindshare_score.calculate_decay_scores` / `calculate_global_decay_scores`, adapted
for the test pipeline and instrumented so a **backend API / front-end can see when and how a run
fails** — even when the run itself fails and rolls back.

## Files (apply in order)

| File | Contents |
|---|---|
| `decay_00_tables_and_log.sql` | Destination score tables (`contribution_scores`, `global_contribution_scores`) + their indexes, and the **`decay_run_log`** observability table + `decay_run_id_seq`. |
| `decay_01_logging.sql` | `dblink` extension, the **autonomous logger** `_decay_log(...)`, `next_decay_run_id()`, and the front-end accessor `get_decay_run_status(run_id)`. |
| `decay_02_calculate_decay_scores.sql` | Project decay: shared core `_decay_apply_project` + **full** `calculate_decay_scores`. |
| `decay_03_calculate_global_decay_scores.sql` | Global decay: shared core `_decay_apply_global` + **full** `calculate_global_decay_scores`. |
| `decay_10_incremental_state_and_indexes.sql` | `decay_run_state` watermark table + source ingest indexes + autovacuum tuning. |
| `decay_11_calculate_decay_scores_incremental.sql` | **Incremental** project decay. |
| `decay_12_calculate_global_decay_scores_incremental.sql` | **Incremental** global decay. |
| `decay_20_incremental_simulation.sql` | **Simulation + parity test harness** (the replica has no live ingestion, so we synthesize events and assert incremental == full). See [`docs/decay_incremental_simulation_and_testing.md`](../docs/decay_incremental_simulation_and_testing.md). |

```bash
for f in decay_00_tables_and_log decay_01_logging \
         decay_02_calculate_decay_scores decay_03_calculate_global_decay_scores \
         decay_10_incremental_state_and_indexes \
         decay_11_calculate_decay_scores_incremental \
         decay_12_calculate_global_decay_scores_incremental; do
  psql "$URL" -v ON_ERROR_STOP=1 -f backend_optimization/$f.sql
done
```

## How the failure-visible logging works

A plain `INSERT` into a log table from inside the decay function would **roll back together with
the function** when it fails — so the front-end would see nothing. Instead, `_decay_log()` writes
through **`dblink` over a loopback connection**, i.e. a *separate* session that **commits
independently**. Consequences:

- **Progress heartbeats** (every `p_log_every` rows, default 50k) are visible to a polling
  front-end *while the run is still in flight* (the main transaction hasn't committed yet).
- The **`failed` row with full error info survives** after the run's own transaction rolls back.

On error the function captures `SQLSTATE`, `SQLERRM`, and `GET STACKED DIAGNOSTICS`
(`PG_EXCEPTION_DETAIL`, `PG_EXCEPTION_CONTEXT`), writes the `failed` row autonomously, then
**re-raises** so the API also receives the exception.

## API / front-end contract

```sql
-- 1) Backend mints a run_id up front (so it can poll while the call runs)
SELECT test_mindshare_score.next_decay_run_id();        -- e.g. 42

-- 2) Backend starts the run (ideally async / its own connection), passing that id
SELECT test_mindshare_score.calculate_decay_scores('quipnetwork', '30 days', 42);
-- global:
SELECT test_mindshare_score.calculate_global_decay_scores('30 days', 42);

-- 3) Front-end polls status (one JSON object) until status <> 'running'
SELECT test_mindshare_score.get_decay_run_status(42);
```

`get_decay_run_status` returns, e.g. on failure:
```json
{
  "run_id": 42, "scope": "project", "project_keyword": "quipnetwork",
  "status": "failed", "phase": "error", "rows_processed": 15,
  "error_sqlstate": "23514",
  "error_message": "new row ... violates check constraint ...",
  "error_detail":  "Failing row contains (...)",
  "error_context": "SQL statement \"INSERT INTO ...\" PL/pgSQL function ... line 119",
  "started_at": "...", "updated_at": "...", "finished_at": "..."
}
```
`status` ∈ `running | success | failed`; `phase` ∈ `init | clearing | computing | writing | done | error`.

> Passing the `run_id` is what makes failure-tracking reliable: on failure the function raises
> (no return value), so the backend must already know the id to fetch the `failed` row. If you
> omit it, one is generated and returned on success, but you lose mid-run polling.

## Function signatures

```
calculate_decay_scores(p_project_keyword text,
                        p_reset_interval interval DEFAULT '30 days',
                        p_run_id bigint DEFAULT NULL,        -- pass from next_decay_run_id()
                        p_log_every integer DEFAULT 50000)   -- heartbeat cadence (rows)
        RETURNS bigint                                       -- the run_id

calculate_global_decay_scores(p_reset_interval interval DEFAULT '30 days',
                              p_run_id bigint DEFAULT NULL,
                              p_log_every integer DEFAULT 50000)
        RETURNS bigint
```

## Incremental decay (the fast path)

The decay score of a reply depends **only on the same replier's own replies in the preceding
30-day window** (+ that replier's base score) — never on other repliers, never on future replies.
So between runs we only need to recompute the repliers whose data actually changed. The
incremental functions do exactly that and produce results **identical to a full rebuild**.

### Two timestamps — do not confuse them
| Purpose | Column |
|---|---|
| **Detect what changed** since last run (the watermark) | **ingest** `GREATEST(created_at, updated_at)` |
| **The decay math** (ordering + 30-day window) | **tweet** `post_created_at` |

"New" means newly **ingested/updated**, *not* newly tweeted — ~85% of replies are ingested >1 day
after the tweet (up to ~9.5% over 30 days late), so a tweet-time watermark would miss late
arrivals and corrupt scores.

### A replier is recomputed ("dirty") if any of:
1. one of **their replies** was ingested/updated since the watermark, OR
2. a **parent post** they replied to was ingested/updated since the watermark (the reply only
   produces a row once its parent exists — INNER JOIN), OR
3. their **base score** drifted — current `mindshare_user.score` ≠ the `replier_base_score`
   stored in their existing rows (Option B; recompute the whole replier).

For each dirty replier: **DELETE all their rows** from the output table and **replay their entire
timeline** from the read-only base tables (cheap — ~20–64 replies/replier). Untouched repliers
are left as-is. The whole run is one transaction; the `decay_run_state` watermark advances **only
on success** (a failure rolls it back → next run reprocesses), while the `failed` log row still
persists via the autonomous logger.

### Functions & API
```
calculate_decay_scores_incremental(p_project_keyword, p_reset_interval DEFAULT '30 days',
                                   p_run_id DEFAULT NULL, p_log_every DEFAULT 50000) RETURNS bigint
calculate_global_decay_scores_incremental(p_reset_interval DEFAULT '30 days',
                                          p_run_id DEFAULT NULL, p_log_every DEFAULT 50000) RETURNS bigint
```
Same `run_id`/poll contract as the full functions. First run for a scope (no `decay_run_state`
row) automatically does a full build and seeds the watermark. `pg_advisory_xact_lock` serializes
runs per scope.

### Operational model
- **Per-ingest trigger:** call the `*_incremental` functions (fast — touches only changed repliers).
- **Weekly reconciliation:** run the full `calculate_decay_scores` / `calculate_global_decay_scores`
  to absorb hard-deletes in source and any drift (the incremental watermark does not see hard deletes).

### Verified
| Check | Result |
|---|---|
| Incremental first-run == full rebuild (Acurast) | 0 rows differ |
| No-op incremental, no changes (Acurast) | **0 dirty repliers, 0 rows** |
| No-op incremental, no changes (global, 3.08M rows) | **0 dirty repliers, 0 rows** |
| Base-score drift on 1 replier (Acurast) | **1 dirty replier, 373 rows** recomputed |
| Incremental == full rebuild after a change (Acurast) | **0 rows differ** |
| Dirty detection plan | Index Scan on `ix_tmp_*_ingest` (ingest expression index), partition-pruned |
| Forced failure mid-run | `failed` logged; **watermark did NOT advance** |

**Detection performance:** dirty detection is an index scan on `ix_tmp_*_ingest` that scales with
the *watermark window*, not the table size — **provided `ANALYZE` has run** so the
`GREATEST(created_at, updated_at)` expression has statistics (done in `decay_10_*.sql`; without it
the planner mis-estimates and seq-scans). A very large gap (first run / long outage) may still
seq-scan — fine, since that is a large job anyway.

## Differences from the production functions (intentional)

- **Reads from `test_mindshare`** base tables (which carry the new indexes); **writes to
  `test_mindshare_score`**.
- **Planner settings baked in** per function (`SET random_page_cost = 1.1`, `SET work_mem =
  '256MB'`) so the decay scan goes index-only regardless of the server default.
- **Dropped the redundant `is_reply = true` predicate** (it is a generated column equal to
  `replied_post_id IS NOT NULL`); keeping only `replied_post_id IS NOT NULL` lets the partial
  index `ix_tmp_mp_replier_time` / `ix_tmp_up_replier_time` apply.
- **Project function is idempotent** (`DELETE` for that project first); **global truncates**
  `global_contribution_scores` (mirrors prod).
- Decay math itself is **identical** to production, with one determinism fix found by the
  simulation: the driving query orders by `(user_x_id, post_created_at, post_id)` — the `post_id`
  tiebreaker. Without it, replies sharing the same `(replier, post_created_at)` second order
  non-deterministically, so a full scan and a dirty replay can disagree on `reply_number`/decay
  (incremental ≠ full). This is latent in the production functions too.

## Verified

| Test | Result |
|---|---|
| Project decay `Acurast` (success) | 47,898 rows in **2.15 s**; log `status=success`, `phase=done`. |
| Forced failure mid-run | Function raised to caller; log row persisted `status=failed`, `sqlstate=23514`, `rows_processed=15`, with detail+context; `contribution_scores` **unchanged** (run rolled back) — proving the log committed independently. |

## Security note

`_decay_log()` embeds a loopback connection string (incl. password) for `dblink` — acceptable for
a test schema. **For production, replace it with a `dblink` FOREIGN SERVER + USER MAPPING** (or a
secret-managed DSN) so no password lives in the function body, and consider `SECURITY DEFINER`
with a locked-down `search_path`.
