from datetime import datetime, timedelta, timezone

import polars as pl

from mindshare_compute.decay import DecayComputer


def _source() -> pl.DataFrame:
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    return pl.DataFrame(
        {
            "project_keyword": ["demo"] * 4,
            "reply_post_id": ["r1", "r2", "r3", "r4"],
            "original_post_id": ["p1", "p1", "p2", "p1"],
            "replier_x_id": ["u1"] * 4,
            "original_author_x_id": ["a1", "a1", "a2", "a1"],
            "post_created_at": [
                start,
                start + timedelta(days=1),
                start + timedelta(days=2),
                start + timedelta(days=40),
            ],
            "replier_base_score": [100.0] * 4,
        }
    )


def test_project_decay_across_batches():
    computer = DecayComputer("project")
    result = pl.concat(
        [computer.process_batch(_source().head(2)), computer.process_batch(_source().tail(2))]
    )

    assert result["decay_type"].to_list() == [
        "FIRST_REPLY",
        "LOCAL_DECAY",
        "GLOBAL_DECAY",
        "FIRST_REPLY",
    ]
    assert result["contribution_score"].to_list() == [100.0, 50.0, 45.0, 100.0]


def test_global_new_author_has_no_decay():
    result = DecayComputer("global").process_batch(_source().head(3))

    assert result["decay_type"].to_list() == [
        "FIRST_REPLY",
        "LOCAL_DECAY",
        "NEW_AUTHOR",
    ]
    assert result["contribution_score"].to_list() == [100.0, 50.0, 50.0]
