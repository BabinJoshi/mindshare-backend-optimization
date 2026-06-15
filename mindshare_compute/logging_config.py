"""Run-scoped console and file logging for the decay pipeline."""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from secrets import token_hex


@dataclass(frozen=True)
class RunLogContext:
    run_id: str
    run_dir: Path
    log_file: Path


def configure_logging(
    *,
    level: str = "INFO",
    log_root: Path = Path("logs"),
) -> RunLogContext:
    """Configure a unique UTC-dated log directory for one CLI invocation."""
    now = datetime.now(timezone.utc)
    run_id = f"{now.strftime('%Y%m%dT%H%M%SZ')}-{token_hex(3)}"
    run_dir = log_root / now.strftime("%Y-%m-%d") / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    log_file = run_dir / "pipeline.log"

    formatter = logging.Formatter(
        "%(asctime)sZ | %(levelname)s | %(name)s | %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    formatter.converter = time.gmtime
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)
    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setFormatter(formatter)

    root_logger = logging.getLogger()
    root_logger.handlers.clear()
    root_logger.setLevel(level.upper())
    root_logger.addHandler(console_handler)
    root_logger.addHandler(file_handler)

    return RunLogContext(run_id=run_id, run_dir=run_dir, log_file=log_file)
