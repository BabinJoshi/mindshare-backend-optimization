"""Faithful, memory-bounded implementation of the PL/pgSQL decay algorithms.

The algorithm is sequential per replier, so a small state object is carried between
Polars batches. Input rows must be ordered by ``replier_x_id, post_created_at``.
"""

from __future__ import annotations

from collections import Counter, deque
from dataclasses import dataclass, field
from datetime import timedelta
from math import floor
from typing import Literal

import polars as pl

Scope = Literal["project", "global"]

def _round2(value: float) -> float:
    """Match PostgreSQL NUMERIC rounding for the non-negative scores used here."""
    return floor(value * 100.0 + 0.5) / 100.0


@dataclass
class _ReplierState:
    replier_x_id: str = ""
    base_score: float = 0.0
    min_floor: float = 0.0
    reply_number: int = 0
    # (timestamp, original author, multiplier)
    active: deque = field(default_factory=deque)
    author_counts: Counter = field(default_factory=Counter)
    half_penalties: int = 0
    ninety_penalties: int = 0

    def reset(self, replier_x_id: str, base_score: float) -> None:
        self.replier_x_id = replier_x_id
        self.base_score = base_score
        self.min_floor = _round2(base_score * 0.01)
        self.reply_number = 0
        self.active.clear()
        self.author_counts.clear()
        self.half_penalties = 0
        self.ninety_penalties = 0

    def expire(self, cutoff) -> None:
        # SQL retains entries only when penalty_time > cutoff_time.
        while self.active and self.active[0][0] <= cutoff:
            _, author, multiplier = self.active.popleft()
            self.author_counts[author] -= 1
            if self.author_counts[author] == 0:
                del self.author_counts[author]
            if multiplier == 0.5:
                self.half_penalties -= 1
            elif multiplier == 0.9:
                self.ninety_penalties -= 1

    def append(self, timestamp, author: str, multiplier: float) -> None:
        self.active.append((timestamp, author, multiplier))
        self.author_counts[author] += 1
        if multiplier == 0.5:
            self.half_penalties += 1
        elif multiplier == 0.9:
            self.ninety_penalties += 1


class DecayComputer:
    """Compute project or global decay while carrying state across input batches."""

    def __init__(
        self,
        scope: Scope,
        reset_interval: timedelta = timedelta(days=30),
        include_active_multipliers: bool = False,
    ) -> None:
        if scope not in ("project", "global"):
            raise ValueError("scope must be 'project' or 'global'")
        self.scope = scope
        self.reset_interval = reset_interval
        self.include_active_multipliers = include_active_multipliers
        self.state = _ReplierState()

    def process_batch(self, rows: pl.DataFrame) -> pl.DataFrame:
        """Compute one ordered input batch and return a Polars result batch."""
        results: list[dict] = []

        for row in rows.iter_rows(named=True):
            replier = row["replier_x_id"]
            base_score = float(row["replier_base_score"])
            if replier != self.state.replier_x_id:
                self.state.reset(replier, base_score)

            self.state.reply_number += 1
            self.state.expire(row["post_created_at"] - self.reset_interval)

            author = row["original_author_x_id"]
            local_reply_count = self.state.author_counts.get(author, 0) + 1
            active_count = len(self.state.active)

            # The SQL product contains only 0.50 and, for project scope, 0.90
            # penalties. Counting powers avoids repeatedly scanning the window.
            product = (0.5**self.state.half_penalties) * (
                0.9**self.state.ninety_penalties
            )
            effective_score = max(
                _round2(self.state.base_score * product), self.state.min_floor
            )

            if active_count == 0:
                multiplier, decay_type = 1.0, "FIRST_REPLY"
            elif local_reply_count > 1:
                multiplier, decay_type = 0.5, "LOCAL_DECAY"
            elif self.scope == "project":
                multiplier, decay_type = 0.9, "GLOBAL_DECAY"
            else:
                multiplier, decay_type = 1.0, "NEW_AUTHOR"

            contribution_score = effective_score
            if multiplier != 1.0:
                contribution_score = max(
                    _round2(effective_score * multiplier), self.state.min_floor
                )

            self.state.append(row["post_created_at"], author, multiplier)
            result = {
                "project_keyword": row.get("project_keyword"),
                "reply_post_id": row["reply_post_id"],
                "original_post_id": row["original_post_id"],
                "replier_x_id": replier,
                "original_author_x_id": author,
                "post_created_at": row["post_created_at"],
                "replier_base_score": base_score,
                "effective_score": effective_score,
                "contribution_score": contribution_score,
                "reply_number": self.state.reply_number,
                "local_reply_count": local_reply_count,
                "decay_type": decay_type,
            }
            if self.include_active_multipliers:
                result["active_multipliers"] = [
                    entry[2] for entry in self.state.active
                ]
            results.append(result)

        return pl.DataFrame(results)
