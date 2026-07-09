# Why the Frozen (As-Of) Base-Score Approach Is Not Incremental-Friendly

> **TL;DR** — The incremental pipeline recomputes a replier's **tail** by re-reading the base
> tables, which only ever hold the **current** KL-score (there is no score history). This has three
> consequences that make "frozen" (as-of) semantics a bad fit:
> 1. **Late arrivals silently un-freeze history** — an unrelated late reply rescales already-settled
>    rows to the current score, so a row's "frozen" value depends on late-arrival timing
>    (non-deterministic, unauditable).
> 2. **Frozen breaks the incremental ↔ full-rebuild parity guarantee** — a full rebuild can only
>    ever use current scores (it's inherently retroactive), so under frozen the weekly
>    reconciliation would silently overwrite frozen history and the parity/correctness test would
>    fail *by design*.
> 3. **Frozen isn't even reconstructable** — with no score-history table, nothing can recompute what
>    a past score was.
>
> Retroactive (Option B, the current implementation) has none of these problems because the
> tail-replay already uses the current score for everything. This doc shows why, with numbers.
>
> See also: [decay_base_score_change_semantics.md](decay_base_score_change_semantics.md) (the
> frozen-vs-retroactive product decision) and
> [decay_end_to_end_test_guide.md](decay_end_to_end_test_guide.md) (the parity test this breaks).

---

## 1. The two semantics (one-line recap)
When a replier's `mindshare_user.score` (KL-score) changes:

- **Retroactive (B, current):** recompute all of that replier's rows with the new score.
- **Frozen (A):** already-computed rows keep the score they were computed with; only *new* replies
  use the new score.

Frozen sounds cheaper for incremental ("a score change dirties nobody → drop branch 3"). The rest
of this doc shows why that intuition is wrong.

---

## 2. Three facts about the pipeline that cause the problem

**Fact 1 — the incremental uses tail-replay.** A late-arriving reply lands in the *middle* of a
replier's tweet-time-ordered history and changes the 30-day penalty window (and `reply_number`,
`decay_type`, `local_reply_count`) of every reply *after* it. So the incremental must **delete and
recompute that replier's tail** (`post_created_at >= t_min`), not just append. This is
non-negotiable — it's the whole reason the incremental exists and is correct.

**Fact 2 — the replay reads the CURRENT score.** The tail-core rebuilds rows by reading the base
tables: `... JOIN mindshare_user u ON ... (u.score AS replier_base_score)`. `mindshare_user` holds
only the **current** score. The old per-row `replier_base_score` values are on the *deleted*
contribution rows, which the replay does not consult.

**Fact 3 — a full rebuild is inherently retroactive.** `calculate_decay_scores` reads the same
current `u.score` for every reply. It has **no way** to know that an old row was "as-of" a
different score. So a full rebuild can *only* ever produce retroactive results.

These three facts are what make frozen fight the design.

---

## 3. Problem A — late arrivals silently un-freeze settled history

### Setup
Replier **Alice**, KL-score **100**, `reset_interval = 30 days`. Two replies, both inside one
30-day window:

| Reply | Tweet date | Replied-to | `decay_type` | contribution (base 100) |
|---|---|---|---|---|
| R1 | Jan 1 | author **X** | FIRST_REPLY ×1.0 | `100 × 1.0` = **100** |
| R2 | Jan 20 | author **Y** | GLOBAL_DECAY ×0.9 | `100 × 1.0 × 0.9` = **90** |

On **Feb 1**, Alice's score changes **100 → 200**.
**Frozen intent:** R1 stays **100**, R2 stays **90**; only replies after Feb 1 use 200.

### Now an unrelated late reply arrives
**R1.5** — tweeted **Jan 10** (to a third author **Z**), but **ingested Feb 5** (16 days late,
which is the common case — ~85% of replies arrive >1 day late). In tweet-time order Alice's
timeline is now **R1 (Jan 1) → R1.5 (Jan 10) → R2 (Jan 20)**.

R1.5 sits *before* R2, so it changes R2's window — R2 **must** be recomputed for correctness
(that part is legitimate under any semantics). The incremental tail-replays Alice from
`t_min = Jan 10`, seeding the window from R1 (before Jan 10), and **reads the current score, 200**:

| Reply | replayed? | base used | window product | own mult | contribution |
|---|---|---|---|---|---|
| R1 (Jan 1) | no (before `t_min`) | 100 (kept) | — | ×1.0 | **100** |
| R1.5 (Jan 10, Z) | new | **200** | 1.0 | GLOBAL ×0.9 | `200×1.0×0.9` = **180** |
| R2 (Jan 20, Y) | **yes** | **200** ← re-read | 1.0×0.9 = 0.9 | GLOBAL ×0.9 | `200×0.9×0.9` = **162** |

### The damage: R2 has four different possible values
| Scenario | R2 `replier_base_score` | R2 contribution |
|---|---|---|
| Original frozen (before the late reply) | 100 | **90** |
| **Correct** frozen (after R1.5, base kept at 100) | 100 | `100×0.9×0.9` = **81** |
| **Naive incremental "frozen"** (just drop branch 3) after R1.5 | **200** | **162** |
| Full rebuild (retroactive) | 200 | **162** |

Two things to notice:

1. **The naive "frozen" incremental (162) equals the retroactive answer, not any frozen answer.**
   Removing branch 3 does **not** give you frozen — it gives you retroactive *for any replier who
   happens to get a late reply*, and frozen for everyone else. That's an **accidental hybrid**.
2. **R2's frozen value is timing-dependent.** If R1.5 never arrives, R2 stays 90. If it arrives,
   R2 jumps to 162. Same underlying facts (Alice tweeted R2 on Jan 20), but the stored value now
   depends on *when an unrelated reply happened to be ingested*. That is **non-deterministic and
   unauditable** — the opposite of what "frozen for fairness/stability" is supposed to buy you.

With ~85% of replies arriving late, this un-freezing would fire constantly, not as a rare edge.

---

## 4. Problem B — frozen breaks the incremental ↔ full-rebuild parity guarantee (the decisive one)

The entire correctness story of this project is **"incremental produces the same result as a full
rebuild"** — that's the parity test (`EXCEPT` = 0/0) used throughout
[decay_end_to_end_test_guide.md](decay_end_to_end_test_guide.md), and the weekly full rebuild is
the reconciliation safety net.

Frozen destroys this, because of **Fact 3**: a full rebuild can only use current scores.

Take Alice after the score change (ignore late arrivals for a moment):

| Row | Frozen incremental | Full rebuild (only knows current score 200) |
|---|---|---|
| R1 | 100 (as-of) | `200 × 1.0` = 200 |
| R2 | 90 (as-of) | `200 × 0.9` = 180 |

- **Incremental-frozen ≠ full-rebuild.** The parity test would report differences on **every**
  replier whose score ever changed — permanently. You could no longer tell "real bug" from
  "expected frozen divergence."
- **The weekly full-rebuild reconciliation would wipe out all frozen history**, silently rewriting
  every as-of row to the current score. So frozen values wouldn't even survive normal operations —
  the next reconciliation converts the whole table back to retroactive.

In other words, under frozen the system loses both its **verification mechanism** (parity) and its
**self-healing mechanism** (full-rebuild reconciliation). That alone disqualifies it for this
architecture.

---

## 5. Problem C — "frozen" isn't reconstructable at all

Frozen is only well-defined if you can answer *"what was the score when this row was computed?"* for
any row, at any time. Today the only place that lives is `contribution_scores.replier_base_score` —
i.e. **inside the output the pipeline is free to delete and rebuild**. There is **no score-history
table** on `mindshare_user`. So:

- After a tail-replay deletes a row, its old score is gone.
- A full rebuild (or a fresh environment, or a disaster-recovery rebuild) cannot reproduce the
  frozen values — it has nothing to read them from.

Frozen therefore isn't a pure function of the base data; it's an artifact of incremental
append-history that can't be regenerated. Retroactive, by contrast, is a pure function of the
current base data — any rebuild reproduces it exactly.

---

## 6. What it would cost to make frozen actually correct

Frozen *can* be implemented, but not for free — you'd need one of:

**Option 1 — capture-and-reuse per-row base scores.** Before deleting a tail, snapshot each
existing row's `replier_base_score`; change the tail-core to apply a **per-reply** base score (the
captured old score for rows that already existed, the current score only for genuinely new replies)
instead of one current `u.score` per replier. This means separating the base factor from the
multiplier structure inside the core loop. Non-trivial refactor — **and it still fails Problem B**
(a full rebuild has nothing to capture, so parity/reconciliation stays broken) unless you also add:

**Option 2 — a temporal score table.** A `mindshare_user_score_history(x_id, score, valid_from,
valid_to)` so *both* the incremental *and* the full rebuild can look up the as-of score for each
reply's timestamp. This restores parity, but adds:
- an ingest-time change to record every score change with validity ranges,
- a new join in both decay cores (per-reply temporal lookup instead of a single current score),
- careful handling of "as-of *what* time — tweet time or ingest time?" (tweet time reopens the
  late-arrival can of worms; ingest time is defensible but must be recorded).

Either way it's materially more machinery than the current design, for a semantic the recommendation
argues against anyway.

---

## 7. Why retroactive is the natural fit (for contrast)

Retroactive needs **none** of the above:

- **Fact 2 works *for* it:** the tail-replay already reads the current score, so new/late replies
  are handled correctly with zero extra work.
- **Score-only changes** are caught by **branch 3** (a cheap watermarked lookup on the small
  `mindshare_user` table via `last_user_ingest_ts`) which replays that replier's timeline at the
  current score.
- **Parity holds:** every row, every run, is `current_score × multiplier_structure`, identical to a
  full rebuild → the `EXCEPT` = 0/0 guarantee stands, and reconciliation is a no-op.
- **It's a pure function of current base data** → reproducible anywhere, no history table needed.
- Because contribution is *linear* in the base score, a score change is even cheap to apply as a
  bulk **rescale** if you ever want to skip the replay.

---

## 8. Conclusion

Frozen (as-of) is not merely "a different product choice" here — under the incremental + full-rebuild
architecture it is **actively hostile**:

- it produces **non-deterministic, timing-dependent** history (Problem A),
- it **breaks the parity guarantee and the reconciliation safety net** (Problem B), and
- it **cannot be reconstructed** without new infrastructure (Problem C).

Making it correct requires a per-row base-capture refactor **and** a temporal score-history table.
Retroactive, the current implementation, aligns with the tail-replay for free and preserves every
correctness property the pipeline depends on. **Recommendation: stay retroactive**; if immutable
history is ever required for settled periods, do it by snapshotting the published leaderboard at
settlement (output layer), not by freezing the base score in the decay layer.
