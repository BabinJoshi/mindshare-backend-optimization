# Testing the incremental refresh — synthetic (SIM_) row approach

Companion to `docs/analytics_incremental_engagement.md` — read that first for how the
incremental refresh actually works. This doc covers one of the two ways to test it; see
`docs/testing_timetravel_approach.md` for the other.

Test file: `Mindshare_Backend/Analytics_md_fix/benchmark/test_sim_incremental.sql`
(covers both scopes — per-project and global — in one file).

## What it is

Insert a small number of clearly-fake, `SIM_`-prefixed posts into `mindshare.mindshare_post`
(or `mindshare.user_post` for the global scope), call the real incremental proc, check that
the row count it reports exactly matches what you inserted, then `ROLLBACK` — nothing real
is ever affected.

## When to use this (vs. the time-travel approach)

You control exactly how many rows you create, so the expected result is a known, fixed
number. Use this when you need to verify **exact algorithm behavior** — e.g. confirming the
placeholder-swap logic (§3.3 of the main doc) does exactly what it says: a root gaining its
first engagement loses its placeholder row, in the same batch that inserts the new
engagement row. That kind of precise, deterministic check is hard to get from real data,
where you don't control what's actually dirty.

For a general "does the incremental pipeline work end to end" regression check, prefer
`docs/testing_timetravel_approach.md` instead — it exercises real data and real edge cases
instead of clean synthetic rows.

## How to run it

1. **Turn auto-commit off first.** DBeaver: "Database" menu → "Transaction Mode" → "Manual
   Commit" (or the toolbar toggle). Both blocks in the test file are
   `BEGIN ... ROLLBACK` — with auto-commit on, DBeaver commits each statement individually
   and the `ROLLBACK` won't undo anything. This exact mistake is documented as a live bug in
   the main doc's §3.6 (bug #3) — don't repeat it.
2. Open `test_sim_incremental.sql` in DBeaver, select the whole file, **Execute SQL Script**
   (`Alt+X`) — not `Ctrl+Enter` one statement at a time. Run Part 1 (project) and Part 2
   (global) as separate script executions if you want to check the results in between.
3. Check the result of the `SELECT rows_inserted, ...` after each `CALL` — expected values
   are called out in comments right above each one (5 for the project case, 15 for global).
4. Flip auto-commit back on afterward if you rely on it for normal work.

## Gotchas

- **Case sensitivity, already handled.** `mindshare_post.project_keyword` is stored with
  real casing (`'Acurast'`, not `'acurast'`) — a raw `INSERT` that hardcodes the wrong case
  silently resolves `user_x_id` to `NULL` and fails with a `NOT NULL` violation. The test
  file resolves the canonical name once via `mindshare_project` before using it in any
  `INSERT`, so typing either case in the one literal at the top is safe. See main doc §3.6
  for the live bug this was found from.
- **`engagement_run_log` rows are NOT undone by `ROLLBACK`.** Logging commits through an
  autonomous `dblink` connection independent of your transaction (main doc §7) — that's
  deliberate, so a real failure's error detail survives a real rollback. Expect every test
  run here to leave a permanent row in `engagement_run_log`, even though the actual data
  changes get rolled back.
- **Don't leave the transaction open.** If you stop partway through a `BEGIN` block without
  reaching `ROLLBACK`/`COMMIT`, the session sits `idle in transaction` — any checkpoint
  writes made so far are invisible to everyone else and eventually need an explicit
  `ROLLBACK` to clear. Check `pg_stat_activity` (`state = 'idle in transaction'`) if
  something looks stuck.

## Expected results (measured on this DB, see main doc §4 / §4.1)

| Scope | Simulated rows | Expected `rows_inserted` |
|---|---|---|
| Project (`acurast`) | 1 new root + 5 replies | 5 (root gets no placeholder — it already has engagement from those same 5 replies) |
| Global (`user_posts_engagement`) | 15 replies to an existing root | 15 (no placeholder logic in this scope, §3.4) |
