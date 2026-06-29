# Decay Scores — Operational Runbook (`test_mindshare_score`)

How to run **full** and **incremental** decay scoring for a **single project**, for **all
projects**, and for **global**. Plus reset/clean, observability, and the recommended schedule.

> Connection used in the examples (set it once):
> ```bash
> export URL="postgresql://postgres_user:postgres_pass@<host>:5432/mindshare_db?sslmode=disable"
> ```

---

## 0. The functions

| Function | Scope | Mode | Notes |
|---|---|---|---|
| `test_mindshare_score.calculate_decay_scores(project, reset_interval, run_id, log_every)` | one project | **FULL** | deletes the project's rows, replays everyone. Does **not** touch the watermark. |
| `test_mindshare_score.calculate_decay_scores_incremental(project, reset_interval, run_id, log_every)` | one project | **INCREMENTAL** (auto-full on first run) | recomputes only repliers changed since the watermark; **manages the watermark**. |
| `test_mindshare_score.calculate_global_decay_scores(reset_interval, run_id, log_every)` | global | **FULL** | global = `user_post` → `global_contribution_scores`. |
| `test_mindshare_score.calculate_global_decay_scores_incremental(reset_interval, run_id, log_every)` | global | **INCREMENTAL** | |
| `test_mindshare_score.next_decay_run_id()` → bigint | — | — | mint a run_id up front for live polling. |
| `test_mindshare_score.get_decay_run_status(run_id)` → jsonb | — | — | front-end status of a run. |

All compute functions **return the `run_id`**. Defaults: `reset_interval = '30 days'`,
`run_id = NULL` (auto-generated), `log_every = 50000` (heartbeat cadence in rows).

### The one behavior to understand: the watermark decides full vs incremental
`calculate_decay_scores_incremental` looks at `decay_run_state` for the scope:
- **No watermark row → it does a FULL build** and writes the watermark.
- **Watermark exists → it does an INCREMENTAL delta** (only repliers whose data was ingested
  since the watermark) and advances the watermark.

So the **same** incremental function bootstraps itself on first call and stays cheap afterward.
**This is the recommended entry point for everything.** The explicit `calculate_decay_scores`
(full) is for forced reconciliation — see §5.

Prerequisite: the functions/tables must be installed (apply `backend_optimization/decay_00 … decay_13`).

---

## 1. Single project

### 1a. Full build (first run, or forced rebuild)
The first incremental call with no watermark **is** a full build:
```bash
psql "$URL" -c "SELECT test_mindshare_score.calculate_decay_scores_incremental('quipnetwork');"
```
To **force** a fresh full build of a project that already has a watermark, clear its state first
(see §4), then call the same function.

### 1b. Incremental (every subsequent run)
Identical call — it now does the delta because the watermark exists:
```bash
psql "$URL" -c "SELECT test_mindshare_score.calculate_decay_scores_incremental('quipnetwork');"
```

### 1c. With a custom decay window
```bash
psql "$URL" -c "SELECT test_mindshare_score.calculate_decay_scores_incremental('quipnetwork', '45 days');"
```

### 1d. With live progress (backend/front-end)
Mint the id first so you can poll while it runs (run the compute on its own connection):
```sql
SELECT test_mindshare_score.next_decay_run_id();                 -- e.g. 1234
SELECT test_mindshare_score.calculate_decay_scores_incremental('quipnetwork', '30 days', 1234);
-- meanwhile, from another connection:
SELECT test_mindshare_score.get_decay_run_status(1234);
```

---

## 2. All projects

There is intentionally **no single all-projects transaction** (a full build of every project in
one transaction would be enormous). Instead loop over the projects, **one call per project = one
transaction** (so each commits, logs, and locks independently). The list is derived from the
data; you can swap in `mindshare_project WHERE status = true` if you prefer the registry.

### 2a. All projects — INCREMENTAL (normal per-trigger operation)
```bash
psql "$URL" -v ON_ERROR_STOP=1 <<'SQL'
SELECT format('SELECT test_mindshare_score.calculate_decay_scores_incremental(%L);', project_keyword)
FROM (SELECT DISTINCT project_keyword
      FROM test_mindshare.mindshare_post
      WHERE replied_post_id IS NOT NULL) p
ORDER BY 1
\gexec
SQL
```
`\gexec` runs each generated `SELECT calculate_…(…)` as its own statement. First run per project
= full build; afterwards = fast delta.

### 2b. All projects — FULL rebuild (reconciliation)
Clear every project's state so each call bootstraps a full build, then loop:
```bash
psql "$URL" -v ON_ERROR_STOP=1 <<'SQL'
DELETE FROM test_mindshare_score.decay_run_state WHERE scope LIKE 'project:%';
SELECT format('SELECT test_mindshare_score.calculate_decay_scores_incremental(%L);', project_keyword)
FROM (SELECT DISTINCT project_keyword
      FROM test_mindshare.mindshare_post
      WHERE replied_post_id IS NOT NULL) p
ORDER BY 1
\gexec
SQL
```
(Each project's first call after the state delete = full build, and re-seeds its watermark.)

> Run all-projects jobs in the **background** — a full rebuild of all projects is tens of
> minutes to hours. Example:
> ```bash
> nohup psql "$URL" -v ON_ERROR_STOP=1 -f all_projects_incremental.sql > decay_all.log 2>&1 &
> ```

---

## 3. Global scope (`user_post` → `global_contribution_scores`)
```bash
# first run = full build + sets watermark; subsequent = incremental
psql "$URL" -c "SELECT test_mindshare_score.calculate_global_decay_scores_incremental();"
```

---

## 4. Reset / clean (per project — does NOT affect other projects)
Everything is keyed by `project_keyword` / `scope = 'project:<kw>'`, so a project can be wiped and
recomputed in isolation:
```sql
-- clear ONE project from all three score tables
DELETE FROM test_mindshare_score.contribution_scores WHERE project_keyword = 'Acurast';
DELETE FROM test_mindshare_score.decay_run_log        WHERE project_keyword = 'Acurast';
DELETE FROM test_mindshare_score.decay_run_state      WHERE scope = 'project:Acurast';
-- then a fresh full build (first incremental call) + thereafter incremental:
SELECT test_mindshare_score.calculate_decay_scores_incremental('Acurast');
```
Global reset:
```sql
TRUNCATE test_mindshare_score.global_contribution_scores;
DELETE FROM test_mindshare_score.decay_run_log   WHERE scope = 'global';
DELETE FROM test_mindshare_score.decay_run_state WHERE scope = 'global';
SELECT test_mindshare_score.calculate_global_decay_scores_incremental();
```
Full clean of the whole schema:
```sql
TRUNCATE test_mindshare_score.contribution_scores;
TRUNCATE test_mindshare_score.global_contribution_scores;
TRUNCATE test_mindshare_score.decay_run_log;
DELETE  FROM test_mindshare_score.decay_run_state;
```

---

## 5. Forced full rebuild via the explicit FULL function (advanced)
`calculate_decay_scores('quipnetwork')` always rebuilds the whole project but **does not touch
`decay_run_state`**. So if you use it, the watermark is left stale — the next incremental run
would then either reprocess from the old watermark or (if no row) do another full build. **Prefer
§1a / §2b** (clear state + call the incremental function), which keeps the watermark correct. Use
the explicit full function only when you specifically want a rebuild without altering the
watermark bookkeeping.

---

## 6. Observability
```sql
-- watermarks + last run per scope
SELECT scope, last_ingest_ts, last_user_ingest_ts, last_run_id, dirty_repliers, rows_written, last_run_at
FROM test_mindshare_score.decay_run_state ORDER BY scope;

-- a specific run (front-end)
SELECT test_mindshare_score.get_decay_run_status(:run_id);

-- recent run history (status / phase / message; failures carry SQLSTATE + detail + context)
SELECT run_id, scope, status, phase, rows_processed, message, started_at, finished_at
FROM test_mindshare_score.decay_run_log ORDER BY run_id DESC LIMIT 20;
```
Log message tells you which mode ran: `Completed (full rebuild (first run)): …` vs
`Completed (incremental): N repliers recomputed, …`. A failed run logs `status='failed'` with
the error (and the watermark is **not** advanced, so the next run reprocesses safely).

---

## 7. Recommended schedule
- **Per ingest cycle:** all-projects + global **incremental** (§2a, §3) — seconds to low-minutes,
  scales with the delta, not the dataset.
- **Weekly:** all-projects + global **full reconciliation** (§2b) — absorbs source hard-deletes
  and any drift the watermark can't see.

## 8. Performance expectations (measured)
| Scope | Full build | Incremental (≈1 week of fresh ingest) |
|---|---|---|
| Acurast (56K posts) | ~3–15 s | ~0.2–0.8 s |
| TheARCTERMINAL (1.57M) | ~9 min | ~0.16 s |
| quipnetwork (2.84M) | ~33–40 min | ~12–27 s |

Incremental cost tracks **how much changed and how far back in tweet-time it lands** (recent
appends → tiny tails → sub-second; large back-dated backfills → larger). A one-off multi-month
backfill is the only case that approaches full-rebuild cost.
