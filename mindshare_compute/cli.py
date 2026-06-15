"""Command-line workflow for computing, inspecting, and writing decay results."""

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path
from time import perf_counter
from typing import Any

import polars as pl
from psycopg import sql

from .db import (
    DecayResultWriter,
    TEST_SCORE_TABLES,
    connect_with_ssl_fallback,
    connection_uri,
    iter_decay_source,
    source_schema,
)
from .decay import DecayComputer
from .logging_config import configure_logging

DEFAULT_OUTPUT_ROOT = Path("output")
POSTGRES_SCORE_SCHEMA = "mindshare_score_test"
LOGGER = logging.getLogger("mindshare_compute.pipeline")


def _positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("value must be at least 1")
    return number


def _project_arg(args: argparse.Namespace) -> str | None:
    if args.scope == "project" and not args.project:
        raise ValueError("--project is required when --scope=project")
    return args.project if args.scope == "project" else None


def _default_output_dir(scope: str, project: str | None, run_id: str) -> Path:
    label = project if scope == "project" else "global"
    return DEFAULT_OUTPUT_ROOT / f"{scope}_{label}_{run_id}"


def _output_dir(args: argparse.Namespace, *, require_existing: bool = False) -> Path:
    path = Path(args.output_dir) if args.output_dir else _default_output_dir(
        args.scope, _project_arg(args), args.run_id
    )
    if require_existing and not path.exists():
        raise FileNotFoundError(f"Output directory does not exist: {path}")
    return path


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, default=str) + "\n")


def _run_metadata(args: argparse.Namespace) -> dict[str, str]:
    return {
        "run_id": args.run_id,
        "log_file": str(args.log_file),
    }


def compute(args: argparse.Namespace) -> tuple[Path, dict[str, Any]]:
    """Read PostgreSQL source rows, compute decay, and persist Parquet parts."""
    project = _project_arg(args)
    output_dir = _output_dir(args)
    existing_parts = list(output_dir.glob("part-*.parquet")) if output_dir.exists() else []
    if existing_parts and not args.overwrite_output:
        raise RuntimeError(
            f"{output_dir} already contains Parquet parts. Use --overwrite-output "
            "or choose another --output-dir."
        )
    if args.overwrite_output:
        for part in existing_parts:
            part.unlink()
    output_dir.mkdir(parents=True, exist_ok=True)
    LOGGER.info(
        "Starting compute stage scope=%s project=%s output_dir=%s source_batch_size=%s",
        args.scope,
        project,
        output_dir,
        args.source_batch_size,
    )

    computer = DecayComputer(
        args.scope,
        include_active_multipliers=args.include_active_multipliers,
    )
    source = iter(
        iter_decay_source(
            args.scope,
            project,
            target="pg",
            batch_size=args.source_batch_size,
        )
    )

    rows_computed = 0
    parts_written = 0
    database_read_seconds = 0.0
    algorithm_compute_seconds = 0.0
    parquet_write_seconds = 0.0
    wall_start = perf_counter()

    while True:
        started = perf_counter()
        try:
            source_batch = next(source)
        except StopIteration:
            database_read_seconds += perf_counter() - started
            break
        database_read_seconds += perf_counter() - started

        started = perf_counter()
        result_batch = computer.process_batch(source_batch)
        algorithm_compute_seconds += perf_counter() - started

        started = perf_counter()
        result_batch.write_parquet(output_dir / f"part-{parts_written:05d}.parquet")
        parquet_write_seconds += perf_counter() - started

        rows_computed += result_batch.height
        parts_written += 1
        LOGGER.info(
            "Computed part=%05d part_rows=%s total_rows=%s",
            parts_written - 1,
            result_batch.height,
            rows_computed,
        )

    summary = {
        **_run_metadata(args),
        "stage": "compute",
        "source_target": "pg",
        "source_schema": source_schema("pg"),
        "scope": args.scope,
        "project_keyword": project,
        "output_dir": str(output_dir),
        "rows_computed": rows_computed,
        "parquet_parts": parts_written,
        "database_read_seconds": database_read_seconds,
        "algorithm_compute_seconds": algorithm_compute_seconds,
        "parquet_write_seconds": parquet_write_seconds,
        "compute_wall_seconds": perf_counter() - wall_start,
    }
    _write_json(output_dir / "compute_summary.json", summary)
    LOGGER.info("Compute summary:\n%s", json.dumps(summary, indent=2))
    return output_dir, summary


def inspect_results(args: argparse.Namespace) -> dict[str, Any]:
    """Print useful summaries from computed Parquet parts without database writes."""
    output_dir = _output_dir(args, require_existing=True)
    parts = list(output_dir.glob("part-*.parquet"))
    if not parts:
        raise RuntimeError(f"No Parquet parts found in {output_dir}")
    LOGGER.info(
        "Inspecting Parquet results scope=%s project=%s output_dir=%s parts=%s",
        args.scope,
        _project_arg(args),
        output_dir,
        len(parts),
    )

    scan = pl.scan_parquet(output_dir / "part-*.parquet")
    summary = (
        scan.group_by("decay_type")
        .agg(
            pl.len().alias("rows"),
            pl.col("contribution_score").min().alias("min_score"),
            pl.col("contribution_score").mean().alias("mean_score"),
            pl.col("contribution_score").max().alias("max_score"),
        )
        .sort("decay_type")
        .collect()
    )
    LOGGER.info("Decay-type summary:\n%s", summary)

    verification = scan
    if args.replier:
        verification = verification.filter(pl.col("replier_x_id") == args.replier)
    if args.original_author:
        verification = verification.filter(
            pl.col("original_author_x_id") == args.original_author
        )
    preview = verification.sort("replier_x_id", "post_created_at").head(args.limit).collect()
    LOGGER.info("Verification preview:\n%s", preview)
    return {
        **_run_metadata(args),
        "output_dir": str(output_dir),
        "parquet_parts": len(parts),
    }


def _destination_row_count(scope: str, project: str | None) -> int:
    table = TEST_SCORE_TABLES[scope]
    query = sql.SQL("SELECT count(*) FROM {}.{}").format(
        sql.Identifier(POSTGRES_SCORE_SCHEMA), sql.Identifier(table)
    )
    params: tuple[Any, ...] = ()
    if scope == "project":
        query += sql.SQL(" WHERE project_keyword = %s")
        params = (project,)

    with connect_with_ssl_fallback(connection_uri("pg")) as connection:
        with connection.cursor() as cursor:
            cursor.execute(query, params)
            return cursor.fetchone()[0]


def write_results(args: argparse.Namespace) -> dict[str, Any]:
    """Stream verified Parquet results into PostgreSQL mindshare_score_test."""
    if not args.write:
        raise RuntimeError(
            "Database writes are disabled. Add --write after verifying the Parquet output."
        )

    project = _project_arg(args)
    output_dir = _output_dir(args, require_existing=True)
    parts = list(output_dir.glob("part-*.parquet"))
    if not parts:
        raise RuntimeError(f"No Parquet parts found in {output_dir}")
    LOGGER.info(
        "Starting write stage scope=%s project=%s output_dir=%s method=%s",
        args.scope,
        project,
        output_dir,
        args.write_method,
    )

    parquet_batches = pl.scan_parquet(output_dir / "part-*.parquet").collect_batches(
        chunk_size=args.write_batch_size,
        maintain_order=True,
    )
    rows_written = 0
    write_seconds = 0.0
    wall_start = perf_counter()

    with DecayResultWriter(
        args.scope,
        project,
        target="pg",
        destination_schema=POSTGRES_SCORE_SCHEMA,
        write_method=args.write_method,
        insert_page_size=args.insert_page_size,
    ) as writer:
        for batch_number, result_batch in enumerate(parquet_batches):
            started = perf_counter()
            rows_written += writer.write_batch(result_batch)
            write_seconds += perf_counter() - started
            LOGGER.info(
                "Wrote batch=%05d batch_rows=%s total_rows=%s",
                batch_number,
                result_batch.height,
                rows_written,
            )

    destination_rows = _destination_row_count(args.scope, project)
    summary = {
        **_run_metadata(args),
        "stage": "write",
        "write_target": "pg",
        "destination_schema": POSTGRES_SCORE_SCHEMA,
        "destination_table": TEST_SCORE_TABLES[args.scope],
        "scope": args.scope,
        "project_keyword": project,
        "output_dir": str(output_dir),
        "write_method": args.write_method,
        "rows_written": rows_written,
        "destination_rows_after_write": destination_rows,
        "postgres_write_seconds": write_seconds,
        "write_wall_seconds": perf_counter() - wall_start,
    }
    _write_json(output_dir / "write_summary.json", summary)
    LOGGER.info("Write summary:\n%s", json.dumps(summary, indent=2))
    if rows_written != destination_rows:
        raise RuntimeError(
            f"Post-write row-count mismatch: wrote {rows_written}, found {destination_rows}"
        )
    return summary


def run(args: argparse.Namespace) -> None:
    """Run compute and, only with --write, write the generated results."""
    if not args.write:
        raise RuntimeError("The end-to-end run command requires the explicit --write flag.")
    output_dir, _ = compute(args)
    args.output_dir = str(output_dir)
    inspect_results(args)
    write_results(args)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Compute decay from read-only PostgreSQL mindshare tables and optionally "
            "write verified results to PostgreSQL mindshare_score_test."
        )
    )
    parser.add_argument(
        "--log-level",
        choices=("DEBUG", "INFO", "WARNING", "ERROR"),
        default="INFO",
    )
    parser.add_argument("--log-root", default="logs", help="Root directory for run logs")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common(
        subparser: argparse.ArgumentParser, *, require_output_dir: bool = False
    ) -> None:
        subparser.add_argument("--scope", choices=("project", "global"), required=True)
        subparser.add_argument("--project", help="Required for project scope")
        subparser.add_argument(
            "--output-dir",
            required=require_output_dir,
            help="Parquet result directory",
        )

    compute_parser = subparsers.add_parser("compute", help="Compute results to Parquet only")
    add_common(compute_parser)
    compute_parser.add_argument("--source-batch-size", type=_positive_int, default=100_000)
    compute_parser.add_argument("--include-active-multipliers", action="store_true")
    compute_parser.add_argument("--overwrite-output", action="store_true")
    compute_parser.set_defaults(func=compute)

    inspect_parser = subparsers.add_parser("inspect", help="Inspect computed Parquet results")
    add_common(inspect_parser, require_output_dir=True)
    inspect_parser.add_argument("--replier")
    inspect_parser.add_argument("--original-author")
    inspect_parser.add_argument("--limit", type=_positive_int, default=100)
    inspect_parser.set_defaults(func=inspect_results)

    write_parser = subparsers.add_parser("write", help="Write verified Parquet to PostgreSQL")
    add_common(write_parser, require_output_dir=True)
    write_parser.add_argument("--write", action="store_true", help="Explicitly enable writes")
    write_parser.add_argument("--write-method", choices=("copy", "multirow"), default="copy")
    write_parser.add_argument("--write-batch-size", type=_positive_int, default=100_000)
    write_parser.add_argument("--insert-page-size", type=_positive_int, default=4_000)
    write_parser.set_defaults(func=write_results)

    run_parser = subparsers.add_parser("run", help="Compute, inspect, and write end to end")
    add_common(run_parser)
    run_parser.add_argument("--source-batch-size", type=_positive_int, default=100_000)
    run_parser.add_argument("--include-active-multipliers", action="store_true")
    run_parser.add_argument("--overwrite-output", action="store_true")
    run_parser.add_argument("--write", action="store_true", help="Required to run end to end")
    run_parser.add_argument("--write-method", choices=("copy", "multirow"), default="copy")
    run_parser.add_argument("--write-batch-size", type=_positive_int, default=100_000)
    run_parser.add_argument("--insert-page-size", type=_positive_int, default=4_000)
    run_parser.add_argument("--replier")
    run_parser.add_argument("--original-author")
    run_parser.add_argument("--limit", type=_positive_int, default=20)
    run_parser.set_defaults(func=run)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    log_context = configure_logging(level=args.log_level, log_root=Path(args.log_root))
    args.run_id = log_context.run_id
    args.log_file = log_context.log_file
    LOGGER.info(
        "Started run_id=%s command=%s log_file=%s",
        args.run_id,
        args.command,
        args.log_file,
    )
    try:
        args.func(args)
    except (ValueError, RuntimeError, FileNotFoundError) as exc:
        LOGGER.error("%s", exc)
        parser.error(str(exc))
    except Exception:
        LOGGER.exception("Pipeline failed with an unexpected error")
        raise
    else:
        LOGGER.info("Completed run_id=%s command=%s", args.run_id, args.command)


if __name__ == "__main__":
    main()
