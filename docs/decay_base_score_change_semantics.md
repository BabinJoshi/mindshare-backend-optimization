# Base-Score (KL-score) Changes — Decay Scoring Semantics

## The question
A replier's decay contribution depends on their **base score** (`mindshare_user.score`, the
"KL-score"). That score can change over time. **When it changes, what should happen to
contribution rows that were already computed with the old score?**

- Recompute **all** of the replier's history with the new score? (retroactive)
- Or **freeze** already-computed rows and only use the new score going forward? (as-of)

There is no universally correct answer — it's a product decision. This doc explains the options
with concrete numbers so the trade-off is easy to see.

---

## Background: how the base score enters the formula
For each reply:
```
effective_score  = max( round(base_score * Π(active penalty multipliers), 2), min_floor )
contribution     = max( round(effective_score * this_reply_multiplier, 2), min_floor )
min_floor        = round(base_score * 0.01, 2)
```
Two facts that matter for this discussion:

1. **`base_score` multiplies *every* one of the replier's rows** — oldest to newest. So changing
   it affects the whole history, not just recent rows.
2. **The decay *structure* is independent of `base_score`.** The multipliers (1.0 / 0.5 / 0.9),
   `reply_number`, `decay_type`, and `local_reply_count` depend only on *when* and *to whom* the
   replier replied — never on the score. Only the final magnitude scales with `base_score`.
   → A base-score change is essentially a **linear rescale** of that replier's contributions
   (modulo 2-decimal rounding and the floor).

Also note: `contribution_scores.replier_base_score` **already stores the score each row was
computed with** — so "what score was this row based on?" is always answerable per row.

### Reading the three multipliers (needed for the examples below)
For each reply, the engine looks at the replier's **own** replies in the preceding 30 days
(the `reset_interval` window) and picks one multiplier:

| `decay_type` | Multiplier | When it applies |
|---|---|---|
| **FIRST_REPLY** | ×1.0 | the 30-day window is **empty** — no replies by this replier in the last 30 days |
| **GLOBAL_DECAY** | ×0.9 | the replier **has** replied to *someone* in the window, but this is their **first** reply to *this* author within the window |
| **LOCAL_DECAY** | ×0.5 | the replier **already** replied to *this same* author within the window |

The multipliers **compound within the window**: `effective_score = base_score × Π(active
multipliers already in the window)`, then this reply's own multiplier is applied on top and also
appended to the window. Because `base_score` factors out of that whole product, a base-score
change rescales every affected row by the same ratio.

---

## The two options

| Option | Rule | History |
|---|---|---|
| **A — Frozen (as-of)** | each row keeps the score it was computed with; a score change only affects **future** replies | immutable |
| **B — Retroactive** *(current implementation)* | a score change recomputes **all** of that replier's rows with the new score | rewritten |

---

## Worked example 1 — a user's score *grows* (with real decay applied)
Replier **Alice**, `base_score = 100`, `min_floor = round(100 × 0.01) = 1`. She makes 3 replies
**close together** (all inside one 30-day window) so all three decay types fire:

| Reply | Date | Replied-to author | Window before this reply | `decay_type` | multiplier chain | contribution |
|---|---|---|---|---|---|---|
| R1 | Jan 1 | **X** | empty | **FIRST_REPLY** ×1.0 | `100 × 1.0` | **100** |
| R2 | Jan 5 | **Y** | {X} — replied to someone, but first time to Y | **GLOBAL_DECAY** ×0.9 | `100 × 1.0 × 0.9` | **90** |
| R3 | Jan 10 | **X** | {X, Y} — already replied to X | **LOCAL_DECAY** ×0.5 | `100 × (1.0×0.9) × 0.5` | **45** |
| **Total** | | | | | | **235** |

(R3: the active window product is `1.0 × 0.9 = 0.9`, so `effective_score = 100 × 0.9 = 90`, then
this reply's own LOCAL_DECAY ×0.5 → `45`.)

Now on **Apr 1** Alice's score changes **100 → 150** (ratio ×1.5) and she posts a new reply **R4**:

| Reply | `decay_type` | **B — Retroactive** (current) | **A — Frozen (as-of)** |
|---|---|---|---|
| R1 (Jan) | FIRST_REPLY | `150 × 1.0` = **150** ← rewritten | **100** ← unchanged |
| R2 (Jan) | GLOBAL_DECAY | `150 × 0.9` = **135** ← rewritten | **90** ← unchanged |
| R3 (Jan) | LOCAL_DECAY | `150 × 0.45` = **67.5** ← rewritten | **45** ← unchanged |
| R4 (Apr, new) | (its own type) | uses **150** | uses **150** |
| **Total (R1–R3)** | | **352.5** | **235** |

- **Retroactive**: every historical row is rescaled by ×1.5 — note the **decay shape is
  preserved** (100/90/45 → 150/135/67.5, still a 1.0 / 0.9 / 0.45 profile). Alice's January
  leaderboard numbers change months later.
- **Frozen**: her January rows stay exactly as earned (100 / 90 / 45); only R4 and later earn at 150.

---

## Worked example 2 — a *correction* (bot/spam flag), same decay chain
Same Alice and same three January replies (contributions **100 / 90 / 45**), but on Apr 1 she's
flagged as a bot and her score is corrected **100 → 5** (ratio ×0.05; `min_floor` becomes
`round(5 × 0.01) = 0.05`):

| Reply | `decay_type` | **B — Retroactive** | **A — Frozen** |
|---|---|---|---|
| R1 (Jan) | FIRST_REPLY | `5 × 1.0` = **5** ← corrected down | **100** ← still inflated |
| R2 (Jan) | GLOBAL_DECAY | `5 × 0.9` = **4.5** ← corrected down | **90** ← still inflated |
| R3 (Jan) | LOCAL_DECAY | `5 × 0.45` = **2.25** ← corrected down | **45** ← still inflated |
| R4 (new) | | **5** | **5** |
| **Total (R1–R3)** | | **11.75** | **235** |

- **Retroactive**: the bot's historical contributions collapse (same 1.0 / 0.9 / 0.45 shape,
  rescaled ×0.05) — the correction propagates, so known-bad scores don't keep inflating past
  totals. ✅ desirable for corrections.
- **Frozen**: the bot *keeps* all the credit (235) it accumulated while undetected. ❌ undesirable
  for corrections.

**This example is the crux:** whether retroactive is "right" depends on *why* the score changed.

---

## The deciding question: *why* do scores change?
| If a score change means… | …then prefer |
|---|---|
| **We corrected our knowledge** (bot/spam detection, reach recalibration, verification, bug fix) | **Retroactive (B)** — corrections should propagate to history |
| **The user organically evolved** (genuinely gained reach over time) | **Frozen (A)** — "at the time, it was worth X"; don't rewrite settled history |
| **A mix** (most real systems) | see recommendation below |

Second decider — **is history "settled"?** If past periods have been shown to users or had
rewards distributed, retroactively changing them is unfair/confusing → favors **freezing settled
periods**.

---

## What the current implementation does (Option B — retroactive)
The incremental pipeline currently matches the old full-rebuild: **a base-score change recomputes
that replier's entire history with the new score.**

- **Detection** ("branch 3" in `calculate_decay_scores_incremental`): a replier is marked dirty
  when their `mindshare_user` row changed since the **user watermark** `last_user_ingest_ts`
  (`GREATEST(created_at, updated_at) > last_user_ingest_ts`).
- **Scope**: for a base-score change, `t_min` = the replier's **earliest** reply → the tail
  replay covers their whole timeline → every historical row is recomputed with the new score.
- Verified: simulation scenario **S4** (bump one replier's score → full-replier recompute →
  identical to a full rebuild, parity = 0).

By contrast, a **new/late reply** (branches 1–2) sets `t_min` to that reply's time, so only the
*recent tail* is recomputed and older history is untouched.

---

## How to switch to Frozen (Option A), if you choose it
Because `replier_base_score` is already stored per row, "frozen" is mostly *not doing* the
retroactive recompute:

1. **Remove branch 3** (base-score drift) from `calculate_decay_scores_incremental` /
   `calculate_global_decay_scores_incremental`, so a score change no longer re-dirties history.
2. New/late replies (branches 1–2) still pick up the current score naturally when they're
   computed — so future activity uses the latest score with no extra work.
3. Drop the `last_user_ingest_ts` watermark bookkeeping (no longer needed).

Result: historical rows keep their original `replier_base_score`; only new replies use the new
score. This also makes the incremental **cheaper** (score changes stop triggering full-history
replays).

> Note: even if you keep **retroactive**, you don't need a full sequential replay — since
> contribution is linear in `base_score`, a score change can be applied as a cheap **rescale**
> (`UPDATE … SET contribution_score = round(contribution_score * new/old, 2)`, re-flooring),
> instead of replaying the timeline. So performance shouldn't drive the semantic choice.

---

## Recommendation — keep **fully retroactive**, and snapshot settled leaderboards

For a mindshare / KOL leaderboard, the recommendation is **fully retroactive (Option B, the
current behavior)** for `contribution_scores`, paired with **one mitigation at the output layer**.
The reasoning, specific to this system:

**1. Anti-gaming is the dominant concern in this domain.** Reply-farming and bots are rampant on
mindshare leaderboards. When you flag a bot or recalibrate reach, you *want* the correction to
walk back its historical contributions (Example 2) — otherwise a farmer keeps every point they
accumulated before detection. Frozen history permanently bakes in gamed scores. This single factor
tilts it hard toward retroactive.

**2. It matches what production already does.** The full rebuild has always used the current score
for all of a replier's history. Retroactive keeps the incremental pipeline **consistent with the
validated production behavior** — no semantic divergence, no migration, nothing new to explain to
stakeholders.

**3. Performance is a non-issue either way.** Because contribution is linear in `base_score`, a
retroactive change does **not** require a sequential replay — it can be applied as a cheap
**rescale** (`UPDATE … SET contribution_score = round(contribution_score * new/old, 2)`,
re-flooring at `round(new_score × 0.01, 2)`). So performance should not drive the choice.

**4. It's the simpler system.** One score per user, applied uniformly — no per-row "as-of"
bookkeeping to maintain (as the frozen option would require). Fewer ways to be wrong.

### The one legitimate downside — handled at the output layer, not the decay layer
The real argument for freezing is **settled fairness**: if a "Week 12" leaderboard was already
shown or rewards were paid, silently rewriting Week 12 later is unfair/confusing. The right place
to solve that is **not** by freezing the scores, but by **snapshotting the published leaderboard**
when a period/campaign closes (persist the ranked result as-of settlement). Then:

- paid/published periods are settled and immutable (fairness ✅), and
- the underlying `contribution_scores` stay a clean, self-correcting "current best estimate"
  (anti-gaming ✅).

You get both properties and keep the decay layer simple. Freezing the *scores themselves* would
buy immutability but lose the ability to correct bots — a bad trade for this domain.

### Verdict
- **Keep fully retroactive (B)** for `contribution_scores` — do **not** change branch 3 or the
  `last_user_ingest_ts` watermark in the incremental functions.
- **Snapshot leaderboards at settlement points** to make paid/published periods immutable.

**The only scenario that would flip this to frozen** is if KL-score changes are almost purely
*organic growth* with essentially **no** correction / anti-gaming component — which is unusual for
a mindshare leaderboard. If that is actually the case here, reconsider; otherwise, retroactive +
leaderboard snapshots is the cleaner, safer design.
