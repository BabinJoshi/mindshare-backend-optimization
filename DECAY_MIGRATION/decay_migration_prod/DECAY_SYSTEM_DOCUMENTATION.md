# Decay Score System — Complete Documentation

**File documented:** `MIGRATION_EXECUTE_ALL.sql` (production version)
**Schema:** `mindshare_score`
**Source data:** `mindshare.mindshare_post`, `mindshare.user_post`, `mindshare.mindshare_user`

---

## 0. Glossary (read this first)

| Term | What it means in plain words |
|---|---|
| **Base score** | The replier's personal worth, stored in `mindshare_user.score`. Think of it as "how loud their voice is". |
| **Multiplier** | A penalty ratio attached to each reply: 1.0 (no penalty), 0.90 (small), 0.50 (heavy). |
| **Penalty history** | The list of multipliers from a user's replies in the **last 30 days**. These are the "ghosts" that haunt their next reply. |
| **Effective score** | Base score × all the multipliers in the penalty history. "What their voice is worth *right now*, after past penalties." |
| **Contribution score** | Effective score × *this reply's own* multiplier. **The final stored number.** |
| **Reset window / reset interval** | 30 days (configurable). Penalties older than this expire and stop counting. |
| **Floor** | 1% of base score. A contribution can never drop below this — spam decays toward nothing but never reaches zero. |
| **Watermark / bookmark** | A saved timestamp meaning "everything up to here is already processed". This is what makes incremental runs fast. |
| **Scope** | Which ledger we're talking about: one project (`project:Acurast`) or everything combined (`global`). |

---

## 1. What This System Does (Plain English)

Imagine a community where people earn points for replying to other people's posts.
Every user has a **base score**. When they reply to someone's post, they
"contribute" some of that value to the post.

But there's a catch — we don't want people to farm points by spamming replies.
So every reply a user makes **weakens their next replies** for the next 30 days:

- Reply to **someone new** → small penalty going forward (×0.90)
- Reply to the **same person again** → heavy penalty (×0.50), because that looks like spam
- After 30 days, old penalties **expire** and their power recovers

The system keeps two independent ledgers:

| Ledger | Scope | Output table | Source of replies |
|---|---|---|---|
| **Project decay** | Replies within one project (e.g. "Acurast") | `contribution_scores` | `mindshare_post` |
| **Global decay** | All replies across every project | `global_contribution_scores` | `user_post` |

> ⚠️ **The same reply gets scored twice — once in each ledger — and the two
> results can differ**, because each ledger only "sees" its own history.
> Worked example in Scenario 8.

And it runs in two modes:

| Mode | When | What it does |
|---|---|---|
| **Full rebuild** | Very first run for a scope | Wipes and recalculates everything from scratch |
| **Incremental** | Every run after | Scores **only new replies** since the last bookmark |

The golden rule of the whole design:

> **Rows are write-once.** A score is computed exactly once — when the reply is
> first seen — and is never updated afterwards. History is a ledger of facts,
> not a spreadsheet that gets recalculated.

---

## 2. The Building Blocks (Tables & Objects)

### 2.1 Output tables — where scores live

**`mindshare_score.contribution_scores`** — one row per reply, per project.

| Column | Meaning (layman) |
|---|---|
| `project_keyword` | Which project this reply belongs to |
| `reply_post_id` | The reply itself (with project_keyword: the primary key) |
| `original_post_id` | The post that was replied to |
| `replier_x_id` | Who wrote the reply |
| `original_author_x_id` | Who wrote the post being replied to |
| `post_created_at` | When the reply was made |
| `replier_base_score` | The replier's base score **at the moment this row was calculated** — a snapshot, not a live link |
| `effective_score` | Base score after past penalties (see glossary) |
| `contribution_score` | **The final number** — what this reply is worth |
| `active_multipliers` | The penalties that were in effect, plus this reply's own multiplier at the end (audit trail — the last element is what future calculations read back) |
| `reply_number` | "This was the user's Nth scored reply in this ledger" |
| `local_reply_count` | "Nth reply *to this same author* within the window" |
| `decay_type` | `FIRST_REPLY`, `GLOBAL_DECAY`, or `LOCAL_DECAY` |

**`mindshare_score.global_contribution_scores`** — identical shape, minus
`project_keyword` (primary key is just `reply_post_id`), fed by `user_post`.

**The life of one row:** Rita replies to Aman's post on June 3 → the next run
detects it → computes 90.00 using her history → inserts one row → that row is
now frozen forever. If Rita's base score triples next week, this row still says
90.00 and `replier_base_score = 100`, because that is what was true on June 3.

### 2.2 Bookkeeping tables — how the system remembers where it left off

**`mindshare_score.decay_run_state`** — the "bookmark" table. One row per scope
(`project:Acurast`, `global`, ...):

- `last_ingest_ts` — "every post created/updated up to this moment is processed."
- `last_user_ingest_ts` — same watermark for the user table.
- Stats about the last run (run id, rows written, when).

> **No bookmark row → the system assumes it never ran → full rebuild.**
> This is why the cleanup script must delete these rows when dropping tables;
> otherwise the next run takes the incremental path over the entire history.

**`mindshare_score.decay_run_log`** — the "diary". Every run logs: started,
computing, "N rows written…", success, or the exact error with stack context.

**`mindshare_score.decay_run_id_seq`** — hands out a unique ID to every run.

### 2.3 Indexes — why lookups are fast

On the score tables:
- `(project_keyword, replier_x_id, post_created_at)` — "this user's recent scored
  replies" — powers the penalty-history load in incremental runs.
- `(project_keyword, original_post_id, replier_x_id, post_created_at)` — reporting.
- Global table: same two, minus `project_keyword`.

On the source tables:
- `GREATEST(created_at, updated_at) DESC` expression indexes on all three source
  tables — make "what changed since the bookmark?" instant.
- Partial index on `mindshare_post(replied_post_id)` — "find replies to this post".

---

## 3. Function Hierarchy (Who Calls Whom)

```
 YOU (manually or via cron)
 │
 ├── calculate_all_decay_scores_incremental()          ← "do every project"
 │      │  loops over every project_keyword
 │      ▼
 │   calculate_decay_scores_incremental(project)       ← ENTRY POINT (one project)
 │      │
 │      ├── first run?  ──► _decay_apply_project()             [full rebuild engine]
 │      │
 │      └── later runs ──► _decay_apply_project_new_replies()  [incremental engine]
 │
 ├── calculate_all_global_decay_scores_incremental()   ← "do global"
 │      ▼
 │   calculate_global_decay_scores_incremental()       ← ENTRY POINT (global)
 │      │
 │      ├── first run?  ──► _decay_apply_global()              [full rebuild engine]
 │      │
 │      └── later runs ──► _decay_apply_global_new_replies()   [incremental engine]
 │
 │   (every function above also calls...)
 └── _decay_log()                                      ← writes the diary
     next_decay_run_id()                               ← hands out run IDs

 Repair tools (defined but NOT part of the normal flow):
     _decay_apply_project_tail()   ← replays one user's history from a point in time
     _decay_apply_global_tail()    ← same, for the global ledger
```

**Dependency rules that follow:**
- Wrappers depend on entry points; entry points depend on engines + bookkeeping.
- Engines depend on the source tables, score tables, and their indexes.
- Everything logs through `_decay_log`, but a logging failure never breaks a run.

---

## 4. Every Function Explained

### 4.1 `_decay_log(run_id, scope, project, status, phase, message, ...)`
**The diary writer.** Writes progress into `decay_run_log` through **dblink** — a
separate mini-connection to the same database. Why? If the main run crashes and
rolls back, normal INSERTs would vanish with it. The dblink connection commits
independently, so the diary survives crashes — you can always see what a failed
run was doing. If logging itself fails, it is silently ignored: a broken diary
must never break the actual work.

### 4.2 `next_decay_run_id()`
One-liner returning the next number from the sequence.

### 4.3 `_decay_apply_project(project, interval, run_id, only_dirty, log_every)`
**The full-rebuild engine for one project.** The heart of the algorithm.

1. Pulls **every reply** in the project (joined to the replied-to post and the
   replier's user record), sorted by `(replier, time)` — each user's replies are
   processed chronologically, one user after another.
2. Keeps three in-memory lists (the penalty history) for the current user:
   multipliers, timestamps, and target authors.
3. For each reply: **prune** entries older than 30 days → **multiply** what's
   left into the effective score → **classify** (FIRST / LOCAL / GLOBAL) →
   apply the **floor** → **insert** the row → append this reply's multiplier to
   the history.
4. New user in the loop → history resets to empty.

Single pass, zero queries inside the loop → hundreds of thousands of rows per minute.

*`only_dirty`* restricts the pass to users in a temp table — a leftover from the
older design; the current flow always passes `false`.

### 4.4 `_decay_apply_global(interval, run_id, only_dirty, log_every)`
Same as 4.3, but reads `user_post` (all projects) and writes
`global_contribution_scores`. A user's penalty history here spans *everything*
they do, across all projects.

### 4.5 `_decay_apply_project_new_replies(project, interval, run_id, log_every)`
**The incremental engine — the reason daily runs take seconds.**

Expects `tmp_new_replies` (built by the entry point) with only unscored replies.

1. Sorts them by `(replier, time)` — grouped per user.
2. On reaching a **new user** (this grouping is the optimization):
   - **One query** loads their penalty history from stored scores in the last
     30 days — each stored row's own multiplier is the *last element* of its
     `active_multipliers` array.
   - **One query** fetches their max `reply_number` so numbering continues.
3. Each of the user's new replies is then scored **in memory** with the exact
   same math as the full rebuild, and appends itself to the in-memory history so
   back-to-back new replies see each other.

> Why grouping matters: the naive version ran those 2 queries *per reply* —
> 100,000 replies = 200,000 round trips = 40+ minutes. Grouped per user it's
> 2 queries per *user*, then pure arithmetic.

### 4.6 `_decay_apply_global_new_replies(interval, run_id, log_every)`
Same as 4.5 for the global ledger.

### 4.7 / 4.8 `_decay_apply_project_tail(...)`, `_decay_apply_global_tail(...)` — repair tools
Replay **one user's history from a chosen point in time** (`t_min`): seed the
penalty history from stored rows just before t_min, recompute everything after.
They expect a `tmp_dirty` temp table and prior deletion of the affected rows.
Not called by the normal flow anymore — kept for surgical repairs (fix one
user's scores without touching anyone else).

### 4.9 `calculate_decay_scores_incremental(project, interval, run_id, log_every)` — ENTRY POINT
**The brain for one project.**

1. **Advisory lock** — two runs for the same scope can never overlap; the second
   waits for the first.
2. **Read the bookmark** for `project:<name>` from `decay_run_state`.
3. **Find the newest data timestamp** in `mindshare_post` for the project.
4. **Decide:**
   - **No bookmark → full rebuild:** delete the project's scores, run 4.3.
   - **Bookmark → incremental:**
     - `tmp_changed` ← posts created/updated after the bookmark.
     - `tmp_new_replies` ← (a) changed posts that are replies, **plus**
       (b) replies *to* changed posts — minus anything that already has a score
       (LEFT JOIN anti-join). `UNION` deduplicates branches (a) and (b).
     - Run 4.5 on the result.
5. **Advance the bookmark** (upsert into `decay_run_state`).
6. **Log success**, or log the exact error and re-raise.

Everything happens in **one transaction**: if anything fails, the rows *and* the
bookmark roll back together — a failed run leaves no half-finished state, and
rerunning is always safe.

### 4.10 `calculate_global_decay_scores_incremental(interval, run_id, log_every)` — ENTRY POINT
Mirror of 4.9 for the global ledger (`user_post` → `global_contribution_scores`,
scope `global`; first run truncates the global table).

### 4.11 `calculate_all_decay_scores_incremental(interval, log_every)` — WRAPPER
Loops over every project with replies and calls 4.9 for each, printing per-project
timing and totals as NOTICEs. One call covers all projects (global is separate).

### 4.12 `calculate_all_global_decay_scores_incremental(interval, log_every)` — WRAPPER
Thin timing wrapper around 4.10. Kept separate so the (much larger) global pass
can be scheduled independently.

---

## 5. The Two Lifecycles

### First run ever (per scope)
```
calculate_decay_scores_incremental('Acurast')
  → no bookmark found
  → DELETE existing 'Acurast' scores (none)
  → _decay_apply_project('Acurast')     ← full rebuild, every reply scored
  → bookmark saved: "processed up to 2026-07-19 10:00"
```

### Every run after
```
calculate_decay_scores_incremental('Acurast')
  → bookmark: 2026-07-19 10:00
  → tmp_changed:      42 posts touched since then
  → tmp_new_replies:  17 of them are unscored replies
  → _decay_apply_project_new_replies()  ← scores exactly those 17
  → bookmark saved: "processed up to 2026-07-20 10:00"
Duration: seconds.
```

### What does NOT trigger recalculation
- A user's profile or **base score changing** — the new base applies to *future*
  replies only (Scenario 7 shows this in detail).
- A reply's **text** being edited — it already has a score; the anti-join skips it.
- **Re-running** the function — the second run finds nothing new, writes 0 rows.
- A reply being **deleted** from the source — its score row simply remains
  (insert-only ledger).

---

## 6. Monitoring Cheat-Sheet

```sql
-- Watch a run live
SELECT run_id, scope, project_keyword, status, phase, message, rows_processed, updated_at
FROM mindshare_score.decay_run_log
ORDER BY run_id DESC LIMIT 10;

-- Where is every bookmark right now?
SELECT scope, last_ingest_ts, last_run_at, rows_written
FROM mindshare_score.decay_run_state
ORDER BY scope;

-- Did anything fail?
SELECT run_id, scope, error_message, error_detail
FROM mindshare_score.decay_run_log
WHERE status = 'failed'
ORDER BY run_id DESC;
```

---

## 7. THE ALGORITHM — A Complete Worked Example (with real dates)

Meet **Rita**. Her base score is **100**, so her floor is **1.00** (1% of base).
The reset window is **30 days**. She replies to posts by **Aman**, **Bela**, and
**Chen**. Every reply looks back exactly 30 days *from its own date*.

The recipe, applied to every single reply:

```
1. WINDOW   Collect Rita's reply-multipliers from the last 30 days.
2. MULTIPLY effective = 100 × (product of those multipliers)
3. CLASSIFY window empty            → FIRST_REPLY  ×1.0
            this author in window   → LOCAL_DECAY  ×0.50
            otherwise               → GLOBAL_DECAY ×0.90
4. FLOOR    contribution = effective × own multiplier, never below 1.00
5. REMEMBER this reply's multiplier joins the history for 30 days.
```

### Scenario 1 — June 1: first reply ever (`FIRST_REPLY`)

**Rita replies to Aman.**
```
Window checked:   May 2 → June 1        (30 days back from June 1)
History found:    — (empty)
Effective:        100
Classify:         window empty → FIRST_REPLY ×1.0
CONTRIBUTION:     100.00                 ✅ full value
History now:      [1.0→Aman @Jun 1]
```

### Scenario 2 — June 3: reply to a different person (`GLOBAL_DECAY`)

**Rita replies to Bela.**
```
Window checked:   May 4 → June 3
History found:    Jun 1 (1.0, Aman)
Effective:        100 × 1.0 = 100
Classify:         Bela not in window → GLOBAL_DECAY ×0.90
CONTRIBUTION:     90.00
History now:      [1.0→Aman @Jun1,  0.90→Bela @Jun3]
```
*Being active is fine — spreading replies around costs only 10% each time.*

### Scenario 3 — June 5: reply to the SAME person again (`LOCAL_DECAY`)

**Rita replies to Aman again.**
```
Window checked:   May 6 → June 5
History found:    Jun 1 (1.0, Aman),  Jun 3 (0.90, Bela)
Effective:        100 × 1.0 × 0.90 = 90
Classify:         Aman IS in window → LOCAL_DECAY ×0.50   ⚠️
CONTRIBUTION:     45.00     ← less than half her first reply
History now:      [1.0→Aman, 0.90→Bela, 0.50→Aman]
```
*Repeatedly replying to the same person looks like farming and is punished hard.*

### Scenario 4 — June 10: penalties compound

**Rita replies to Chen (someone completely new).**
```
Window checked:   May 11 → June 10
History found:    Jun 1 (1.0),  Jun 3 (0.90),  Jun 5 (0.50)   ← all still active
Effective:        100 × 1.0 × 0.90 × 0.50 = 45   ← past sins stack up!
Classify:         Chen not in window → GLOBAL_DECAY ×0.90
CONTRIBUTION:     40.50
History now:      [1.0→Aman, 0.90→Bela, 0.50→Aman, 0.90→Chen]
```
*Even a reply to a brand-new person earns only 40.50 now — the June 5 spam
penalty still weighs her down.*

### Scenario 5 — July 8: penalties EXPIRE (the 30-day reset)

**Rita replies to Aman.** June 1, 3, 5 are now more than 30 days ago.
```
Window checked:   June 8 → July 8
                  Jun 1  ✗ expired      Jun 3  ✗ expired      Jun 5  ✗ expired
History found:    Jun 10 (0.90, Chen) only
Effective:        100 × 0.90 = 90        ← recovered from 45!
Classify:         Aman in window? NO — his entries aged out → GLOBAL_DECAY ×0.90
CONTRIBUTION:     81.00
History now:      [0.90→Chen @Jun10,  0.90→Aman @Jul8]
```
*Two things happened at once: her old penalties vanished (effective score bounced
from 45 back to 90), AND replying to Aman is no longer "local" spam, because her
old replies to him aged out of the window.*

### Scenario 6 — the floor: spam can never go below 1% of base

**Sam** (base 10, floor 0.10) replies to the **same author every day**:

| Date | Window multipliers (product) | Effective | Type | Contribution |
|---|---|---|---|---|
| Jul 1 | — (empty) | 10.00 | FIRST_REPLY ×1.0 | **10.00** |
| Jul 2 | [1.0] = 1.0 | 10.00 | LOCAL ×0.5 | **5.00** |
| Jul 3 | [1.0, 0.5] = 0.5 | 5.00 | LOCAL ×0.5 | **2.50** |
| Jul 4 | [1.0, 0.5, 0.5] = 0.25 | 2.50 | LOCAL ×0.5 | **1.25** |
| Jul 5 | product = 0.125 | 1.25 | LOCAL ×0.5 | **0.63** |
| Jul 6 | product = 0.0625 | 0.63 | LOCAL ×0.5 | **0.32** |
| Jul 7 | product ≈ 0.031 | 0.31 | LOCAL ×0.5 | **0.16** |
| Jul 8 | product ≈ 0.016 | 0.16 | LOCAL ×0.5 | **0.10** ← floor kicks in |
| Jul 9+ | keeps shrinking | 0.10 (floored) | LOCAL ×0.5 | **0.10** forever |

**Recovery:** if Sam stops on July 8 and returns on **August 8**, everything from
Jul 1–8 has expired → empty window → his next reply is a fresh `FIRST_REPLY`
worth the full **10.00** again. The system forgives — after 30 quiet days.

### Scenario 7 — ⭐ the base score CHANGES inside the reset window

This is the subtlest case. Rewind to Rita's timeline after Scenario 4
(her window contains Jun 1, 3, 5, 10 — effective score dragged down to 45).

**June 20: an admin recalculation raises Rita's base score from 100 → 150.**

What happens immediately? **Nothing.**
```
contribution_scores (unchanged, frozen forever):
  Jun 1  → 100.00   (replier_base_score = 100)
  Jun 3  →  90.00   (replier_base_score = 100)
  Jun 5  →  45.00   (replier_base_score = 100)
  Jun 10 →  40.50   (replier_base_score = 100)
```
No recalculation, no update, no run is triggered. The old rows honestly record
what her replies were worth *when she made them*.

**June 25: Rita replies to Bela** (still inside the same 30-day window!):
```
Window checked:   May 26 → June 25
History found:    Jun 1 (1.0), Jun 3 (0.90), Jun 5 (0.50), Jun 10 (0.90)
                  ← the SAME penalty history as before the base change.
                    Multipliers are ratios — they don't care what the base was.

Effective:        150 × 1.0 × 0.90 × 0.50 × 0.90 = 60.75
                  ↑ NEW base            ↑ OLD penalties — both apply!
New floor:        1.50   (1% of the NEW base 150)
Classify:         Bela in window? YES (Jun 3) → LOCAL_DECAY ×0.50
CONTRIBUTION:     30.38   (60.75 × 0.50, rounded)
```

Three takeaways, in plain words:

1. **The new base score applies instantly to new replies** — no waiting for the
   window to reset. Her voice got louder the moment the admin changed it.
2. **Her past penalties still count.** A raise doesn't wipe the slate — the
   multipliers earned under the old base (1.0, 0.90, 0.50, 0.90) still discount
   her, because they are *ratios*, not amounts. That's why the history survives
   a base change without any correction.
3. **Old rows are never touched.** June 3's row says 90.00 forever; it does NOT
   become 135.00. If you need "what would this be worth at today's base score",
   that's a question for the reporting layer, not this ledger.

(The same logic applies to a score *decrease* — if her base dropped to 50 on
June 20, the June 25 reply would use 50 × 0.405 = 20.25 effective, floor 0.50.)

### Scenario 8 — one reply, TWO ledgers (project vs global)

Fresh start, August. Rita (base 100, empty windows everywhere).

**Aug 1: Rita replies to Aman in project "Acurast".**
```
PROJECT ledger (Acurast):  Acurast history empty → FIRST_REPLY → 100.00
GLOBAL ledger:             global history empty  → FIRST_REPLY → 100.00
```

**Aug 2: Rita replies to Bela in project "D3lMundos"** (different project):
```
PROJECT ledger (D3lMundos): D3lMundos history empty → FIRST_REPLY → 100.00
GLOBAL ledger:              Aug 1 entry exists (1.0) → product 1.0, effective 100
                            Bela not in global window → GLOBAL_DECAY ×0.90 → 90.00
```

Same physical reply, two different scores — and both are correct:
- The **project ledger** asks *"is Rita spamming within this project?"* — no.
- The **global ledger** asks *"is Rita spamming across the platform?"* — a little.

### Scenario 9 — one post, MANY repliers

**Aug 5: Aman posts. Rita, Sam, and Tina all reply to it.**

Each reply is its own row, scored against **its own author's history only**:

| replier | their own window | decay_type | contribution |
|---|---|---|---|
| Rita (base 100) | has Aug 1–2 entries (product 0.90) | GLOBAL ×0.90 | 81.00 |
| Sam (base 10) | deep in spam penalties | LOCAL ×0.50 | 0.10 (floored) |
| Tina (base 50) | empty — first reply ever | FIRST_REPLY ×1.0 | 50.00 |

Repliers never affect each other. Rita's penalties are hers alone; Tina replying
one minute later starts from her own clean slate. A post's total received value
is simply the sum of the independent rows pointing at its `original_post_id`.

### Scenario 10 — how the INCREMENTAL run scores a new reply (ties everything together)

It's **July 20**. The nightly run fires. The bookmark says *"processed through
July 19, 22:00."* Rita (base 100) replied to Bela on **July 20 at 09:14**.

```
1. DETECT    tmp_changed: the Jul 20 reply is newer than the bookmark.
2. FILTER    anti-join: contribution_scores has no row for it → genuinely new.
3. LOAD      engine reaches Rita (first of hers in this batch):
             ONE query pulls her stored rows from Jun 20 → Jul 20:
               Jul 8 row → own multiplier 0.90 (last element of its
                            active_multipliers array), author Aman
               Jun 10 row ✗ expired (before Jun 20)
             ONE query: her max reply_number = 5 → this becomes reply #6
4. SCORE     effective = 100 × 0.90 = 90
             Bela in window? No → GLOBAL_DECAY ×0.90
             CONTRIBUTION = 81.00
5. WRITE     one INSERT. Bookmark advances to Jul 20. Done in milliseconds.
```

The result is **identical** to what a full rebuild would compute — but instead of
replaying six weeks of history, the run read one stored row. That is the entire
trick of the incremental design: **old rows are facts; new rows are computed
from those facts.**

### Quick-reference: all decay types

| Situation (within the 30-day window) | decay_type | Multiplier |
|---|---|---|
| No prior replies in window | `FIRST_REPLY` | ×1.0 (full value) |
| Prior replies exist, none to this author | `GLOBAL_DECAY` | ×0.90 |
| Already replied to this author in window | `LOCAL_DECAY` | ×0.50 |
| Any result below 1% of base score | — | clamped up to the floor |

---

## 8. "What Happens If…" — FAQ

**…a user's base score changes?**
Nothing immediately. Old rows keep their snapshot. The user's *next* reply uses
the new base with their existing penalty history (Scenario 7).

**…someone edits the text of an already-scored reply?**
The edit bumps `updated_at`, so the post shows up in `tmp_changed` — but the
anti-join sees its score already exists and skips it. Score unchanged.

**…a run crashes halfway?**
The whole run is one transaction: inserted rows AND the bookmark roll back
together. The diary (written via dblink) survives, so you can read the exact
error. Just rerun — it starts from the same bookmark as if the crash never happened.

**…you run it twice in a row?**
The second run finds zero unscored replies and writes zero rows. Harmless.

**…two runs start at the same time for the same scope?**
The advisory lock serializes them — the second waits until the first commits,
then finds nothing to do.

**…a reply is deleted from the source table?**
Its score row remains (insert-only ledger). If that matters for reporting, filter
at query time by joining back to the source.

**…a reply arrives late** (e.g., ingested today but its `post_created_at` is last week)?
It is detected (ingestion sets `created_at`/`updated_at`, which the bookmark
comparison uses) and scored correctly against the history *before its post time*.
One accepted trade-off: replies of the same user that were already scored *after*
that timestamp are not revised — the write-once ledger favors speed and
stability over retroactive perfection. The `_tail` repair functions exist for
the rare case where that needs fixing.

**…you drop the test/production score tables to start over?**
You MUST also delete the matching rows from `decay_run_state` (the cleanup script
does this). Otherwise the next run sees a bookmark, skips the fast full-rebuild
path, and crawls through the entire history as "new replies".

**…a whole new project appears?**
The all-projects wrapper picks it up automatically; its first run is a full
rebuild for that project only, then it joins the incremental rhythm.
