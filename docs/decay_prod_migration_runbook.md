# Deploying the Incremental Decay Pipeline to Production (`mindshare_score`)

Step-by-step runbook to replace the production full-rebuild decay functions with the **incremental**
pipeline currently proven in `test_mindshare_score`, so prod can compute `contribution_scores`
(per project) and `global_contribution_scores` incrementally.

> **Audience:** whoever deploys to the live DB. Every step that writes to production is marked
> **[PROD WRITE]**. Read §1–§3 fully before running anything.

---

## 0. TL;DR of the change

- **Today (prod):** `mindshare_score.calculate_decay_scores(project)` and
  `calculate_global_decay_scores()` do a **full rebuild** every run (INSERT-only; a re-run needs a
  manual `DELETE`/`TRUNCATE`). `calculate_all_decay_scores()` `TRUNCATE`s and rebuilds everything.
- **After migration:** a single entry point per scope —
  `calculate_decay_scores_incremental(project)` and `calculate_global_decay_scores_incremental()` —
  that **full-builds on first run** (seeding a watermark) and thereafter **recomputes only the
  repliers whose data changed** (seconds-to-minutes instead of tens of minutes), producing results
  **identical to a full rebuild**. The explicit full functions are kept for reconciliation.

The canonical DDL/source is the `backend_optimization/decay_*.sql` files (written for the test
schema). This runbook is how to deploy that same code to prod, with the required schema
adaptations and prod-safe ordering.

---

## 1. What exists in prod vs what the migration adds

Verified in prod on 2026-07-09:

| Object | In prod now? | Action |
|---|---|---|
| `mindshare.mindshare_post` (partitioned by `project_keyword`, 12 parts) | ✅ | read-only source |
| `mindshare.mindshare_user`, `mindshare.user_post` | ✅ | read-only source |
| `dblink` extension | ✅ installed | reuse |
| decay driving indexes (`ix_mindshare_post_decay_source_order`, `ix_user_post_decay_source_order`, `*_decay_original_lookup`) | ✅ | reuse (the per-replier ordered scan + parent lookup already exist) |
| `mindshare_score.contribution_scores`, `global_contribution_scores` | ✅ | reuse (verify PK/indexes — §4.1) |
| `mindshare_score.calculate_decay_scores` / `calculate_global_decay_scores` (full, tiebreak-patched) | ✅ | **replace** with refactored versions |
| **`mindshare_score.decay_run_state`** (watermark) | ❌ | **create** |
| **`mindshare_score.decay_run_log`** + **`decay_run_id_seq`** | ❌ | **create** |
| **ingest-detection indexes** `GREATEST(created_at,updated_at)` on the 3 base tables | ❌ | **create [PROD WRITE on `mindshare`]** |
| **`replied_post_id`** index on `mindshare.mindshare_post` (branch-2) | ❌ | **create** |
| `_decay_log`, `next_decay_run_id`, `get_decay_run_status` | ❌ | **create** |
| `_decay_apply_project(_tail)`, `_decay_apply_global(_tail)` cores | ❌ | **create** |
| `calculate_decay_scores_incremental`, `calculate_global_decay_scores_incremental` | ❌ | **create** |

---

## 2. Risks & prerequisites — read before deploying

1. **This writes to the live `mindshare` base tables** (new indexes) and the live `mindshare_score`
   output tables. Schedule a low-traffic window. Creating indexes on the 8M-row partitioned
   `mindshare_post` must use the **per-partition `CONCURRENTLY`** procedure in §5 to avoid locking
   ingestion.
2. **Function signatures change.** Prod today: `calculate_decay_scores(text, interval)` → `void`.
   Test/new: `calculate_decay_scores(text, interval, bigint, integer)` → `bigint`. A `CREATE OR
   REPLACE` with a new arg list creates a **second overload** instead of replacing. You must
   **`DROP` the old functions first** (§5.4) and update any caller. New args have defaults, so
   existing 2-arg calls still resolve; but the return type changes `void`→`bigint` (fine for
   `PERFORM`/ignored `SELECT`).
3. **Find the callers.** Identify what invokes decay today (backend API, cron/pg_cron, a trigger).
   After migration they should call the `_incremental` variant. Grep the app + check
   `SELECT * FROM cron.job` / triggers.
4. **dblink credentials.** `_decay_log` opens a loopback dblink connection with a connection string.
   In test it embeds `user=... password=...` in plaintext. For prod, **use a
   `postgres_fdw`/dblink foreign server + user mapping or a secret**, not an inline password. See §8.
5. **Back up first** (§4.2): dump the current prod decay functions and snapshot the contribution
   tables so you can roll back (§7).
6. **Global rebuild is heavy.** The first `calculate_global_decay_scores_incremental()` full-builds
   the entire `global_contribution_scores` (~all `user_post` replies) — run it off-peak; expect
   tens of minutes.

---

## 3. Schema-adaptation rules (test → prod)

The `backend_optimization/decay_*.sql` files target the test schemas. Produce prod copies (e.g. in
a `prod_migration/` folder) by applying these substitutions to every file:

| In the test SQL | Replace with (prod) |
|---|---|
| `test_mindshare.` (base tables) | `mindshare.` |
| `test_mindshare_score.` (output/state/functions) | `mindshare_score.` |
| `SET search_path = test_mindshare, test_mindshare_score, public` | `SET search_path = mindshare, mindshare_score, public` |
| dblink conn string `dbname=mindshare_db ...` and the `test_mindshare_score.decay_run_log` target inside `_decay_log` | keep `dbname=mindshare_db`; point the log INSERT at `mindshare_score.decay_run_log`; **replace inline password with a foreign-server/secret** |
| base-table index DDL `ON test_mindshare.<table>` | `ON mindshare.<table>` (+ use the per-partition `CONCURRENTLY` procedure in §5.3) |

> Do a careful find/replace, then diff each prod file against its test source to confirm **only**
> schema names / the dblink target / index concurrency changed — not any logic.

---

## 4. Preparation

### 4.1 [check] Verify the output tables have the keys the incremental needs
The incremental does a **tail delete** (`WHERE project_keyword=? AND replier_x_id=? AND
post_created_at >= t_min`) and **seed reads** from `contribution_scores`. Confirm these exist
(create if missing — see `backend_optimization/decay_00_tables_and_log.sql`):
```sql
-- expected: PK (project_keyword, reply_post_id) on contribution_scores; PK (reply_post_id) on global;
--           plus an index on (project_keyword, replier_x_id, post_created_at) [global: (replier_x_id, post_created_at)]
SELECT indexname, indexdef FROM pg_indexes
WHERE schemaname='mindshare_score'
  AND tablename IN ('contribution_scores','global_contribution_scores')
ORDER BY 1;
```

### 4.2 [PROD WRITE / backup] Snapshot the current state for rollback
```bash
# dump the 4 existing decay function definitions
pg_dump "$PROD_URL" -n mindshare_score \
  --function 'mindshare_score.calculate_decay_scores(text,interval)' \
  > backup_prod_decay_functions_2026-07-09.sql   # (repeat --function for global/all, or dump the schema DDL)
# OR simply: SELECT pg_get_functiondef(...) for each of the 4 functions and save the text.

# snapshot contribution tables (so you can restore counts/values if needed)
psql "$PROD_URL" -c "CREATE TABLE mindshare_score._bak_contribution_scores        AS TABLE mindshare_score.contribution_scores;"
psql "$PROD_URL" -c "CREATE TABLE mindshare_score._bak_global_contribution_scores AS TABLE mindshare_score.global_contribution_scores;"
```

> Reliability note: several migration steps (global full build, big-project rebuilds, large index
> builds) run for **many minutes**. Run them from a **direct `psql`/screen/tmux session**, not a
> tool that times out — long statements have repeatedly dropped pooled/MCP connections.

---

## 5. Deployment steps

Run in this order. Steps 5.1–5.2 and 5.5–5.8 are metadata/DDL (fast); 5.3 (base indexes) and 5.9
(bootstrap) are the long ones.

### 5.1 [PROD WRITE] State, log, and sequence objects
Apply the prod-adapted `decay_00_tables_and_log.sql` (creates in `mindshare_score`):
`decay_run_state`, `decay_run_log`, `decay_run_id_seq`, and the `ADD COLUMN IF NOT EXISTS
last_user_ingest_ts`. These are new/idempotent and don't touch existing data.

### 5.2 [check] dblink extension
Already installed (verified). If deploying to a fresh DB: `CREATE EXTENSION IF NOT EXISTS dblink;`

### 5.3 [PROD WRITE — LONG] Ingest-detection indexes on the base tables
These are what make dirty-detection index-driven. They **must** use the exact expression
`GREATEST(created_at, updated_at)`.

**Non-partitioned tables** (`mindshare_user`, `user_post`) — plain concurrent build:
```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_mu_ingest ON mindshare.mindshare_user (GREATEST(created_at, updated_at));
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_up_ingest ON mindshare.user_post      (GREATEST(created_at, updated_at));
-- branch-2 parent lookup for global already exists: ix_user_post_replied_post_id
```

**Partitioned `mindshare.mindshare_post`** — `CONCURRENTLY` is not allowed directly on a
partitioned parent, so build per partition then attach (no long parent lock):
```sql
-- 1) create an INVALID (empty) index on the parent, ONLY:
CREATE INDEX ix_mp_ingest ON ONLY mindshare.mindshare_post (GREATEST(created_at, updated_at));
CREATE INDEX ix_mp_replied ON ONLY mindshare.mindshare_post (replied_post_id) WHERE replied_post_id IS NOT NULL;

-- 2) for EACH partition (repeat; get names from the query below):
--    SELECT inhrelid::regclass FROM pg_inherits WHERE inhparent='mindshare.mindshare_post'::regclass;
CREATE INDEX CONCURRENTLY ix_mp_ingest_<part>   ON mindshare.<partition> (GREATEST(created_at, updated_at));
ALTER INDEX ix_mp_ingest   ATTACH PARTITION ix_mp_ingest_<part>;
CREATE INDEX CONCURRENTLY ix_mp_replied_<part>  ON mindshare.<partition> (replied_post_id) WHERE replied_post_id IS NOT NULL;
ALTER INDEX ix_mp_replied  ATTACH PARTITION ix_mp_replied_<part>;
-- when every partition is attached, the parent index flips to VALID automatically.
```

### 5.4 [PROD WRITE] Drop the old full functions (to allow the refactor + new signature)
```sql
-- confirm nothing depends on them first (views/triggers); then:
DROP FUNCTION IF EXISTS mindshare_score.calculate_decay_scores(text, interval);
DROP FUNCTION IF EXISTS mindshare_score.calculate_global_decay_scores(interval);
-- keep calculate_all_decay_scores? It calls calculate_decay_scores(project); update it to the new
-- signature or drop it in favour of the incremental all-projects loop (§6).
```

### 5.5 [PROD WRITE] Logging + helper functions
Apply prod-adapted `decay_01_logging.sql`: `_decay_log` (autonomous dblink upsert into
`mindshare_score.decay_run_log`), `next_decay_run_id()`, `get_decay_run_status(bigint)`.
**Set the dblink connection per §8 (no inline password).**

### 5.6 [PROD WRITE] Cores + refactored full wrappers
Apply prod-adapted `decay_02_calculate_decay_scores.sql` and `decay_03_*`: creates
`_decay_apply_project`, `_decay_apply_global`, and the refactored `calculate_decay_scores` /
`calculate_global_decay_scores` (now DELETE-then-rebuild, tiebreak `ORDER BY user_x_id,
post_created_at, post_id` — already the prod ordering).

### 5.7 [PROD WRITE] Incremental state indexes, tail cores, incremental functions
Apply prod-adapted `decay_10` (autovacuum tuning + `ANALYZE`), `decay_13` (tail cores
`_decay_apply_project_tail`, `_decay_apply_global_tail`), `decay_11` and `decay_12`
(`calculate_decay_scores_incremental`, `calculate_global_decay_scores_incremental`).

### 5.8 [PROD WRITE] Autovacuum tuning + analyze
From `decay_10`: make autovacuum aggressive on the churny score tables, and refresh base stats so
detection uses the new indexes:
```sql
ALTER TABLE mindshare_score.contribution_scores        SET (autovacuum_vacuum_scale_factor=0.02, autovacuum_analyze_scale_factor=0.02);
ALTER TABLE mindshare_score.global_contribution_scores SET (autovacuum_vacuum_scale_factor=0.02, autovacuum_analyze_scale_factor=0.02);
ANALYZE mindshare.mindshare_post;
ANALYZE mindshare.mindshare_user;
ANALYZE mindshare.user_post;
```

### 5.9 [PROD WRITE — LONG] Bootstrap: first run seeds the watermark
The first `_incremental` call per scope has no watermark → it **full-builds** and seeds
`decay_run_state`. This replaces the existing rows (the project function deletes its own project
first). Do it **per project** (each commits independently), then global:
```sql
-- per project (loop over the registry / distinct keywords). First call = full build.
SELECT format('SELECT mindshare_score.calculate_decay_scores_incremental(%L);', project_keyword)
FROM (SELECT DISTINCT project_keyword FROM mindshare.mindshare_post WHERE replied_post_id IS NOT NULL) p
ORDER BY 1 \gexec

-- global (heavy; off-peak)
SELECT mindshare_score.calculate_global_decay_scores_incremental();
```
After this, every subsequent call for the same scope is a fast **incremental delta**.

### 5.10 Cut over the scheduler / backend
Point the trigger/cron/API at the incremental entry points:
- per project each cycle: `calculate_decay_scores_incremental('<project>')`
- global each cycle: `calculate_global_decay_scores_incremental()`
- weekly reconciliation (optional, absorbs hard-deletes): clear `decay_run_state` for a scope and
  call the incremental again (→ full build), or call the explicit full function.

---

## 6. All-projects convenience (optional)
There is intentionally no single all-projects transaction. Use the `\gexec` loop above, or create a
**procedure** that commits per project:
```sql
CREATE OR REPLACE PROCEDURE mindshare_score.calculate_all_decay_scores_incremental(p_reset_interval interval DEFAULT '30 days')
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT DISTINCT project_keyword FROM mindshare.mindshare_post WHERE replied_post_id IS NOT NULL ORDER BY 1
  LOOP
    PERFORM mindshare_score.calculate_decay_scores_incremental(r.project_keyword, p_reset_interval);
    COMMIT;   -- must be called via CALL outside an explicit txn
  END LOOP;
END $$;
```

---

## 7. Verification (do this before trusting the cutover)

1. **Bootstrap sanity** — every scope has a `decay_run_state` row and a `success` log:
   ```sql
   SELECT scope, last_ingest_ts, last_user_ingest_ts, dirty_repliers, rows_written FROM mindshare_score.decay_run_state ORDER BY 1;
   SELECT run_id, scope, status, message FROM mindshare_score.decay_run_log ORDER BY run_id DESC LIMIT 30;
   ```
2. **Incremental == full-rebuild parity** (the gold standard) on one project — snapshot, force a
   full rebuild, symmetric diff:
   ```sql
   CREATE TEMP TABLE _inc AS SELECT * FROM mindshare_score.contribution_scores WHERE project_keyword='Acurast';
   SELECT mindshare_score.calculate_decay_scores('Acurast');   -- explicit full
   WITH f AS (SELECT * FROM mindshare_score.contribution_scores WHERE project_keyword='Acurast')
   SELECT (SELECT count(*) FROM (SELECT * FROM _inc EXCEPT SELECT * FROM f) a) AS inc_not_full,
          (SELECT count(*) FROM (SELECT * FROM f EXCEPT SELECT * FROM _inc) b) AS full_not_inc;   -- expect 0 / 0
   ```
3. **No-op incremental** — immediately re-run a project with no new data → `dirty_repliers=0`,
   `rows_written=0`, near-instant.
4. **Delta works** — after the next ingest cycle, an incremental run should report a small
   `dirty_repliers` and finish far faster than a full build.
5. **Detection is index-driven** — `EXPLAIN (ANALYZE, BUFFERS)` the detection query shows Index
   Scans on `ix_mp_ingest` / `ix_mu_ingest` (no Seq Scan). If Seq Scan: re-run `ANALYZE` (5.8).

Full procedure & expected numbers: `docs/decay_end_to_end_test_guide.md`.

---

## 8. dblink connection for `_decay_log` (production)
`_decay_log` writes the run log over a **separate** connection so it survives the main
transaction's rollback (failed runs stay logged). Do **not** embed a plaintext password in prod.
Preferred: a foreign server + user mapping, referenced by name:
```sql
CREATE SERVER IF NOT EXISTS decay_log_loopback FOREIGN DATA WRAPPER dblink_fdw
  OPTIONS (host '127.0.0.1', port '5432', dbname 'mindshare_db');
CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER SERVER decay_log_loopback
  OPTIONS (user 'decay_logger', password '<from-secret-store>');
-- then _decay_log uses dblink('decay_log_loopback', $sql$ ... INSERT INTO mindshare_score.decay_run_log ... $sql$);
```
⚠️ Also confirm the dblink self-deadlock rule carries over: **never `TRUNCATE
mindshare_score.decay_run_log` in the same transaction that calls a decay function** (the function
logs via dblink and will deadlock on the `TRUNCATE` lock). Use scoped `DELETE`, in a separate txn.

---

## 9. Rollback
If anything misbehaves after cutover:
1. **Point callers back** to the (backed-up) full functions.
2. **Restore the old functions** from §4.2's dump:
   ```sql
   DROP FUNCTION IF EXISTS mindshare_score.calculate_decay_scores(text,interval,bigint,integer);
   DROP FUNCTION IF EXISTS mindshare_score.calculate_global_decay_scores(interval,bigint,integer);
   \i backup_prod_decay_functions_2026-07-09.sql
   ```
3. **Restore data** if needed from the `_bak_*` snapshot tables (§4.2).
4. The new indexes and `decay_run_state`/`decay_run_log` are harmless to leave in place; drop them
   only if you fully abandon the migration.

The incremental and full functions can coexist during a trial period — run incremental, and keep a
scheduled full reconciliation, until you trust the deltas.

---

## 10. Object checklist (quick reference)

**Create in `mindshare_score`:** `decay_run_state`, `decay_run_log`, `decay_run_id_seq`,
`_decay_log`, `next_decay_run_id`, `get_decay_run_status`, `_decay_apply_project`,
`_decay_apply_project_tail`, `_decay_apply_global`, `_decay_apply_global_tail`,
`calculate_decay_scores_incremental`, `calculate_global_decay_scores_incremental`.
**Replace in `mindshare_score`:** `calculate_decay_scores`, `calculate_global_decay_scores`
(drop old signatures first).
**Create on `mindshare` base tables:** `ix_mp_ingest`, `ix_mp_replied` (partitioned → per-partition
CONCURRENTLY + attach), `ix_mu_ingest`, `ix_up_ingest`.
**Reuse (already present):** `dblink`; decay driving/lookup indexes; `contribution_scores` /
`global_contribution_scores`.
**Bootstrap:** first incremental call per project + global (= full build, seeds watermark).
**Cut over:** scheduler/API → incremental entry points.
