# Decay Pipeline — End-to-End Test Guide (`test_mindshare_score`)

A **line-by-line, copy-pasteable** procedure to validate the decay pipeline for one project —
both the **full build** and the **incremental build** — and confirm the output matches production.
Run exactly as done for **Acurast**:

0. **(Recommended) Re-sync base data** from prod so the comparison is apples-to-apples.
1. **Clear** the score tables.
2. **Full build** (one run).
3. **Incremental build** (one run — a real delta, forced via a watermark rollback).
4. **Compare** against production `mindshare_score.contribution_scores`; classify any diffs.

> **Scope of writes:** steps 1–3 write only to `test_mindshare_score.*`. Step 0 writes only to
> `test_mindshare.*`. The `mindshare` / `mindshare_score` production schemas are **read-only** here.
>
> **Test project:** `Acurast`. To test another project, replace every `'Acurast'`. Numbers in
> "expected" are Acurast's observed values; the **pass criteria** are universal.

---

## ⚠️ Two safety rules (learned the hard way)

1. **Never `TRUNCATE test_mindshare_score.decay_run_log` in the same transaction that calls a decay
   function.** The decay functions write their run log over a **separate dblink connection**;
   `TRUNCATE` holds an ACCESS EXCLUSIVE lock that blocks that dblink write, and the function then
   waits forever on the dblink call — an undetectable **self-deadlock** (it hangs for minutes and
   blocks everything behind it). Keep the *clear* step and the *function-call* steps in
   **separate** statements / MCP calls (this guide already does).
2. **Run clear / full / incremental as separate transactions** (separate MCP `execute_sql` calls),
   not one big block. Smaller transactions also survive a dropped connection without rolling back
   completed work.

---

## Prerequisites

- Decay objects installed: `backend_optimization/decay_00_*.sql` … `decay_13_*.sql`.
- A connection. Run each SQL block in the **Postgres MCP** `execute_sql` tool, or via psql:
  `psql "postgresql://<user>:<pass>@<host>:5432/mindshare_db?sslmode=disable" -c "<sql>"`.

Confirm the connection:
```sql
SELECT 1 AS ok, current_database() AS db;
```
**Pass:** returns `ok=1`, `db=mindshare_db`.

---

## 0. (Recommended) Re-sync base data from prod

The test pipeline reads `test_mindshare.*`; production reads `mindshare.*`. If the test snapshot is
stale, the comparison in §4 shows **base-score drift** (benign but noisy). Re-syncing first makes
the comparison exact. Skip this only if you know the snapshot is already current.

`mindshare_post` is **LIST-partitioned by `project_keyword`** and has **generated columns**
(`is_post, is_quote, is_reply, is_retweet`) that must be **excluded** from the column list. Reload
**per partition** so each is its own transaction.

**0.1 — `mindshare_user`** (global, one shot):
```sql
TRUNCATE test_mindshare.mindshare_user;
INSERT INTO test_mindshare.mindshare_user
   (x_id, x_username, display_name, score, avatar_url, adjustment_config, followers_count, verified, created_at, updated_at, last_score_fetched_at)
SELECT x_id, x_username, display_name, score, avatar_url, adjustment_config, followers_count, verified, created_at, updated_at, last_score_fetched_at
FROM mindshare.mindshare_user;
```

**0.2 — one `mindshare_post` partition** (repeat per project; here Acurast). Partition name is
`mindshare_post_<projectlower>` (e.g. Acurast → `mindshare_post_acurast`):
```sql
TRUNCATE test_mindshare.mindshare_post_acurast;
INSERT INTO test_mindshare.mindshare_post
   (post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id, view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at, sentiment_score, sentiment_label, entities, content_score, latest_reply_at)
SELECT post_id, project_keyword, user_x_id, full_text, retweeted_post_id, replied_post_id, quoted_post_id, root_post_id, view_count, reply_count, retweet_count, quote_count, favorite_count, post_created_at, created_at, updated_at, sentiment_score, sentiment_label, entities, content_score, latest_reply_at
FROM mindshare.mindshare_post WHERE project_keyword='Acurast';
```
> To replace **all** partitions, repeat 0.2 for each `project_keyword`
> (`SELECT DISTINCT project_keyword FROM mindshare.mindshare_post`), one call each.

**0.3 — refresh statistics** (REQUIRED after a bulk reload, or dirty-detection falls back to seq scans):
```sql
ANALYZE test_mindshare.mindshare_user;
ANALYZE test_mindshare.mindshare_post;
```

**0.4 — verify counts match prod:**
```sql
SELECT 'user' AS tbl, (SELECT count(*) FROM mindshare.mindshare_user) AS prod, (SELECT count(*) FROM test_mindshare.mindshare_user) AS test
UNION ALL
SELECT 'post(Acurast)', (SELECT count(*) FROM mindshare.mindshare_post WHERE project_keyword='Acurast'),
                        (SELECT count(*) FROM test_mindshare.mindshare_post WHERE project_keyword='Acurast');
```
**Pass:** prod = test for each row. (Acurast: 71,457 posts; users: 376,783.)

---

## 1. Clear the score tables (its own transaction)

Full clean slate (all projects):
```sql
TRUNCATE test_mindshare_score.contribution_scores;
TRUNCATE test_mindshare_score.global_contribution_scores;
TRUNCATE test_mindshare_score.decay_run_log;
DELETE FROM test_mindshare_score.decay_run_state;
```
Or scoped to just one project (leaves other projects intact — use `DELETE`, never `TRUNCATE`, for
`decay_run_log` here):
```sql
DELETE FROM test_mindshare_score.contribution_scores WHERE project_keyword='Acurast';
DELETE FROM test_mindshare_score.decay_run_log        WHERE project_keyword='Acurast';
DELETE FROM test_mindshare_score.decay_run_state      WHERE scope='project:Acurast';
```
**Pass:** the target rows are 0. Removing the `decay_run_state` row is what makes the next run a
first-run **full build**.

---

## 2. Full build

The pipeline has **one entry point**; "full" vs "incremental" is decided by whether a watermark
row exists in `decay_run_state`. With none (after §1), the first call bootstraps a **full build**
and seeds the watermark.
```sql
SELECT test_mindshare_score.calculate_decay_scores_incremental('Acurast') AS run_id;
```
**Expected (Acurast):** returns a `run_id`; elapsed ≈ **2–3 s**.

Verify:
```sql
SELECT run_id, status, rows_processed, message
FROM test_mindshare_score.decay_run_log ORDER BY run_id DESC LIMIT 1;

SELECT count(*) AS acurast_rows,
       count(*) FILTER (WHERE decay_type='FIRST_REPLY')  AS first_reply,
       count(*) FILTER (WHERE decay_type='GLOBAL_DECAY') AS global_decay,
       count(*) FILTER (WHERE decay_type='LOCAL_DECAY')  AS local_decay
FROM test_mindshare_score.contribution_scores WHERE project_keyword='Acurast';
```
**Expected (Acurast):** message = `"Completed (full rebuild (first run)): ALL repliers recomputed,
47898 rows written"`; **47,898** rows; FIRST_REPLY 15,777 / GLOBAL_DECAY 7,651 / LOCAL_DECAY 24,470.
**Pass:** message says **"full rebuild (first run)"**, `rows_processed > 0`, all three decay types > 0.

---

## 3. Incremental build (real delta)

With no new source data, a plain incremental call is a 0-row no-op. To exercise the real delta path
(`tmp_changed` → `tmp_dirty` → tail-delete + tail-replay) **without mutating base data**, roll the
watermark **back 30 days**: the next run then treats the last 30 days of already-present data as
"changed" and recomputes only those repliers.

> Watermark background: incremental keys off `test_mindshare_score.decay_run_state`. Two columns
> drive it — **`last_ingest_ts`** (max `GREATEST(created_at, updated_at)` over the project's
> `mindshare_post`) for new/late replies, and **`last_user_ingest_ts`** (same expression over
> `mindshare_user`) for base-score changes. Both use the **ingest** timestamp, never
> `post_created_at` (tweet time), because replies often arrive days late.

```sql
UPDATE test_mindshare_score.decay_run_state
SET last_ingest_ts = last_ingest_ts - interval '30 days'
WHERE scope='project:Acurast';

SELECT test_mindshare_score.calculate_decay_scores_incremental('Acurast') AS run_id;
```
**Expected (Acurast):** elapsed ≈ **0.1–0.2 s** (≈15× faster than the full build).

Verify it took the **delta branch**:
```sql
SELECT run_id, status, rows_processed, message
FROM test_mindshare_score.decay_run_log ORDER BY run_id DESC LIMIT 1;

SELECT scope, last_ingest_ts, dirty_repliers, rows_written
FROM test_mindshare_score.decay_run_state WHERE scope='project:Acurast';
```
**Expected (Acurast):** message = `"Completed (incremental): 17 repliers recomputed, 23 rows
written"`; `dirty_repliers=17`; `last_ingest_ts` **auto-advanced back to the true max**.
**Pass (all):**
- message says **"(incremental)"** — not "full rebuild (first run)". ← delta branch ran.
- `dirty_repliers` is positive but **<** the project's total repliers. ← only a subset recomputed.
- `rows_written` **<** the full build's 47,898. ← tail-replay, not full-history replay.
- `last_ingest_ts` is back at the true max. ← watermark self-heals; the next run is a no-op.

> Choosing the rollback window: for Acurast, 7 days flags ~1 replier, 30 days ~17, 90 days ~522.
> Pick one large enough to actually rewrite rows. The final table after this step is identical to a
> full rebuild (recomputing a superset of the changed repliers is harmless), which §4 verifies.

The run log now shows exactly the two runs:
```sql
SELECT run_id, phase, message FROM test_mindshare_score.decay_run_log
WHERE project_keyword='Acurast' ORDER BY run_id;
-- 1) Completed (full rebuild (first run)): ALL repliers recomputed, 47898 rows written
-- 2) Completed (incremental): 17 repliers recomputed, 23 rows written
```

---

## 4. Compare against production (`mindshare_score.contribution_scores`)

The gold-standard validation. **If §0 re-sync was done AND the prod decay functions carry the
`post_id` tiebreak (applied 2026-07-05), the expected result is a perfect 0/0 match.**

### 4.1 Schema + row-count check
```sql
SELECT
  (SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns
     WHERE table_schema='mindshare_score'      AND table_name='contribution_scores') AS prod_cols,
  (SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns
     WHERE table_schema='test_mindshare_score' AND table_name='contribution_scores') AS test_cols;

SELECT 'prod' AS src, count(*) AS rows, count(DISTINCT replier_x_id) AS repliers
FROM mindshare_score.contribution_scores WHERE project_keyword='Acurast'
UNION ALL
SELECT 'test', count(*), count(DISTINCT replier_x_id)
FROM test_mindshare_score.contribution_scores WHERE project_keyword='Acurast';
```
**Expected (Acurast):** columns identical; both **47,898** rows / **14,803** repliers.
**Pass:** columns and counts match. (A count difference = **source drift**; re-run §0 for the project.)

### 4.2 All-columns symmetric diff (the definitive check)
```sql
WITH cols AS ( SELECT project_keyword, reply_post_id, original_post_id, replier_x_id, original_author_x_id,
                      post_created_at, replier_base_score, effective_score, contribution_score,
                      active_multipliers, reply_number, local_reply_count, decay_type ),
     t AS (SELECT project_keyword, reply_post_id, original_post_id, replier_x_id, original_author_x_id,
                  post_created_at, replier_base_score, effective_score, contribution_score,
                  active_multipliers, reply_number, local_reply_count, decay_type
           FROM test_mindshare_score.contribution_scores WHERE project_keyword='Acurast'),
     p AS (SELECT project_keyword, reply_post_id, original_post_id, replier_x_id, original_author_x_id,
                  post_created_at, replier_base_score, effective_score, contribution_score,
                  active_multipliers, reply_number, local_reply_count, decay_type
           FROM mindshare_score.contribution_scores WHERE project_keyword='Acurast')
SELECT (SELECT count(*) FROM (SELECT * FROM t EXCEPT SELECT * FROM p) a) AS in_test_not_prod,
       (SELECT count(*) FROM (SELECT * FROM p EXCEPT SELECT * FROM t) b) AS in_prod_not_test;
```
**Expected (Acurast, after §0 + prod tiebreak fix):** `0 / 0`.
**Pass:** both `0` — test and prod are byte-for-byte identical.

### 4.3 Field-by-field breakdown (only needed if 4.2 is not 0/0)
```sql
WITH t AS (SELECT reply_post_id, contribution_score, effective_score, replier_base_score,
                  decay_type, reply_number, local_reply_count
           FROM test_mindshare_score.contribution_scores WHERE project_keyword='Acurast'),
     p AS (SELECT reply_post_id, contribution_score, effective_score, replier_base_score,
                  decay_type, reply_number, local_reply_count
           FROM mindshare_score.contribution_scores WHERE project_keyword='Acurast'),
     j AS (SELECT t.reply_post_id t_key, p.reply_post_id p_key,
                  t.contribution_score t_c, p.contribution_score p_c,
                  t.replier_base_score t_b, p.replier_base_score p_b,
                  t.decay_type t_d, p.decay_type p_d,
                  t.reply_number t_rn, p.reply_number p_rn,
                  t.local_reply_count t_lrc, p.local_reply_count p_lrc
           FROM t FULL OUTER JOIN p ON t.reply_post_id = p.reply_post_id)
SELECT
  count(*) FILTER (WHERE p_key IS NULL) AS only_in_test,
  count(*) FILTER (WHERE t_key IS NULL) AS only_in_prod,
  count(*) FILTER (WHERE t_c   IS DISTINCT FROM p_c)   AS contribution_mismatch,
  count(*) FILTER (WHERE t_b   IS DISTINCT FROM p_b)   AS base_score_mismatch,
  count(*) FILTER (WHERE t_d   IS DISTINCT FROM p_d)   AS decay_type_mismatch,
  count(*) FILTER (WHERE t_rn  IS DISTINCT FROM p_rn)  AS reply_number_mismatch,
  count(*) FILTER (WHERE t_lrc IS DISTINCT FROM p_lrc) AS local_reply_count_mismatch
FROM j;
```
Use §5 to classify whatever this returns.

---

## 5. Interpreting any residual discrepancies

If §4 is **not** 0/0, every difference must fall into one of these buckets — anything else is a
real bug to investigate.

| Cause | Signature | Fix |
|---|---|---|
| **Base-score drift** | `base_score_mismatch > 0`; contribution differs **proportionally** | Test snapshot is stale vs live `mindshare_user.score`. Re-run **§0**. |
| **Tie-ordering** | base score **identical**, but `decay_type` / `reply_number` / `local_reply_count` differ; affected repliers have ≥2 replies at the **same** `post_created_at` | Prod was non-deterministic (ordered by physical `ctid`). **Already fixed** by adding the `post_id` tiebreak to `mindshare_score.calculate_decay_scores` (+ global) on 2026-07-05. If it reappears, prod is running an unpatched function. |
| **Source drift** | `only_in_test` / `only_in_prod > 0` (row count differs) | Prod ingested new rows since the snapshot. Re-run **§0** for the project. |

**Historical reference (pre-fix, Acurast 2026-07-05):** before the base re-sync and prod tiebreak
fix, the comparison showed 277 contribution diffs = 252 base-drift (70 repliers) + 25 tie-ordering
(18 tie-repliers), 0 row-presence diffs. After re-sync → base drift 0. After the prod tiebreak fix
+ prod rebuild → tie-ordering 0. **Final: 0/0, byte-for-byte identical.**

---

## 6. Reset (optional)
Clean Acurast back to empty (does not affect other projects):
```sql
DELETE FROM test_mindshare_score.contribution_scores WHERE project_keyword='Acurast';
DELETE FROM test_mindshare_score.decay_run_log        WHERE project_keyword='Acurast';
DELETE FROM test_mindshare_score.decay_run_state      WHERE scope='project:Acurast';
```

---

## Pass/fail summary

| # | Check | Pass criterion |
|---|---|---|
| 0 | Base re-sync | test counts = prod counts; `ANALYZE` run |
| 1 | Clean slate | target score rows = 0 |
| 2 | Full build | message "full rebuild (first run)", 47,898 rows, all 3 decay types > 0 |
| 3 | Incremental delta | message "(incremental)", `dirty_repliers` > 0 but < total, `rows_written` < full, watermark self-heals |
| 4.2 | Parity vs prod | all-columns symmetric diff = **0 / 0** |
| 5 | Residual diffs (if any) | only base-score drift / tie-ordering / source drift — no logic diffs |
