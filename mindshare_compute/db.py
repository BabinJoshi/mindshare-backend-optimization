"""Memory-bounded PostgreSQL/CockroachDB reads and writes for contribution decay."""

from __future__ import annotations

import logging
import os
from collections.abc import Iterable, Iterator
from types import TracebackType
from typing import Literal
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

import polars as pl
import psycopg
from dotenv import load_dotenv
from psycopg import sql

load_dotenv()
LOGGER = logging.getLogger(__name__)

Scope = Literal["project", "global"]
Target = Literal["crdb", "pg"]
WriteMethod = Literal["multirow", "copy"]
TEST_SCORE_TABLES = {
    "project": "test_contribution_scores",
    "global": "test_global_contribution_scores",
}
COMMON_SCORE_COLUMNS = sql.SQL(
    """
    reply_post_id TEXT NOT NULL,
    replier_x_id TEXT NOT NULL,
    original_post_id TEXT NOT NULL,
    original_author_x_id TEXT NOT NULL,
    post_created_at TIMESTAMPTZ NOT NULL,
    replier_base_score DECIMAL NOT NULL,
    effective_score DECIMAL NOT NULL,
    contribution_score DECIMAL NOT NULL,
    reply_number INT4 NOT NULL,
    local_reply_count INT4 NOT NULL,
    decay_type TEXT NOT NULL
    """
)


def connection_uri(target: Target = "crdb") -> str:
    """Read a database URI from .env without putting credentials in the notebook."""
    env_name = "MINDSHARE_DB_URI" if target == "crdb" else "MINDSHARE_PG_URI"
    uri = os.getenv(env_name)
    if target == "pg":
        uri = uri or os.getenv("POSTGRES_DATABASE_URL")
    if not uri:
        raise RuntimeError(f"Set {env_name} in .env before running the workflow")
    return uri


def _retry_disable_ssl(uri: str) -> str:
    parsed = urlparse(uri)
    query = dict(parse_qsl(parsed.query, keep_blank_values=True))
    query["sslmode"] = "disable"
    return urlunparse(parsed._replace(query=urlencode(query)))


def connect_with_ssl_fallback(uri: str) -> psycopg.Connection:
    try:
        return psycopg.connect(uri)
    except psycopg.OperationalError as exc:
        message = str(exc).lower()
        if "server does not support ssl" in message or "ssl was required" in message:
            return psycopg.connect(_retry_disable_ssl(uri))
        raise


def source_schema(target: Target = "crdb") -> str:
    default = "mindshare_test" if target == "crdb" else "mindshare"
    return os.getenv(f"MINDSHARE_{target.upper()}_SOURCE_SCHEMA", default)


def score_schema(target: Target = "pg") -> str:
    default = "mindshare_score_test"
    return os.getenv(f"MINDSHARE_{target.upper()}_SCORE_SCHEMA", default)


def iter_decay_source(
    scope: Scope,
    project_keyword: str | None = None,
    *,
    target: Target = "crdb",
    batch_size: int = 100_000,
) -> Iterator[pl.DataFrame]:
    """Yield ordered source rows using a server-side cursor to bound WSL memory."""
    if scope == "project" and not project_keyword:
        raise ValueError("project_keyword is required for project scope")

    LOGGER.info(
        "Opening source stream target=%s schema=%s scope=%s project=%s batch_size=%s",
        target,
        source_schema(target),
        scope,
        project_keyword,
        batch_size,
    )
    schema = sql.Identifier(source_schema(target))
    if scope == "project":
        query = sql.SQL(
            """
            SELECT p.project_keyword, p.post_id AS reply_post_id,
                   op.post_id AS original_post_id, p.user_x_id AS replier_x_id,
                   p.post_created_at, op.user_x_id AS original_author_x_id,
                   u.score AS replier_base_score
            FROM {}.mindshare_post p
            JOIN {}.mindshare_post op
              ON p.replied_post_id = op.post_id
             AND p.project_keyword = op.project_keyword
            JOIN {}.mindshare_user u ON p.user_x_id = u.x_id
            WHERE p.is_reply = true AND p.replied_post_id IS NOT NULL
              AND p.project_keyword = %s
            ORDER BY p.user_x_id, p.post_created_at
            """
        ).format(schema, schema, schema)
        params = (project_keyword,)
    elif scope == "global":
        query = sql.SQL(
            """
            SELECT NULL::text AS project_keyword, p.post_id AS reply_post_id,
                   op.post_id AS original_post_id, p.user_x_id AS replier_x_id,
                   p.post_created_at, op.user_x_id AS original_author_x_id,
                   u.score AS replier_base_score
            FROM {}.user_post p
            JOIN {}.user_post op ON p.replied_post_id = op.post_id
            JOIN {}.mindshare_user u ON p.user_x_id = u.x_id
            WHERE p.is_reply = true AND p.replied_post_id IS NOT NULL
            ORDER BY p.user_x_id, p.post_created_at
            """
        ).format(schema, schema, schema)
        params = ()
    else:
        raise ValueError("scope must be 'project' or 'global'")

    with connect_with_ssl_fallback(connection_uri(target)) as conn:
        with conn.cursor(name=f"{scope}_decay_source") as cursor:
            cursor.execute(query, params)
            columns = [item.name for item in cursor.description]
            while records := cursor.fetchmany(batch_size):
                yield pl.DataFrame(records, schema=columns, orient="row")


class DecayResultWriter:
    """Replace and write decay results to PostgreSQL-wire test score tables.

    The writer only creates, deletes, truncates, and inserts inside the configured score
    schema. It never writes to the source ``mindshare`` schema.
    """

    def __init__(
        self,
        scope: Scope,
        project_keyword: str | None = None,
        *,
        target: Target = "crdb",
        destination_schema: str | None = None,
        write_method: WriteMethod = "multirow",
        insert_page_size: int = 4_000,
    ) -> None:
        if scope == "project" and not project_keyword:
            raise ValueError("project_keyword is required for project scope")
        if scope not in TEST_SCORE_TABLES:
            raise ValueError("scope must be 'project' or 'global'")
        if target not in ("crdb", "pg"):
            raise ValueError("target must be 'crdb' or 'pg'")
        if write_method not in ("multirow", "copy"):
            raise ValueError("write_method must be 'multirow' or 'copy'")

        self.scope = scope
        self.project_keyword = project_keyword
        self.target = target
        self.schema = destination_schema or score_schema(target)
        if self.schema == source_schema(target):
            raise ValueError("destination schema must not be the read-only source schema")
        self.table = TEST_SCORE_TABLES[scope]
        self.connection: psycopg.Connection | None = None
        self.insert_columns: list[str] | None = None
        self.prepared = False
        self.rows_written = 0
        if insert_page_size < 1:
            raise ValueError("insert_page_size must be at least 1")
        self.insert_page_size = insert_page_size
        self.write_method = write_method

    def __enter__(self) -> "DecayResultWriter":
        LOGGER.info(
            "Opening result writer target=%s schema=%s table=%s method=%s",
            self.target,
            self.schema,
            self.table,
            self.write_method,
        )
        self.connection = connect_with_ssl_fallback(connection_uri(self.target))
        self._ensure_destination_table()
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        if self.connection is not None:
            try:
                if exc_type is None and not self.prepared:
                    # A successful run with no source rows should remove stale output.
                    self._replace_existing_results()
            finally:
                self.connection.close()

    def _ensure_destination_table(self) -> None:
        """Create the test score schema, destination table, and lookup indexes."""
        assert self.connection is not None
        schema = sql.Identifier(self.schema)
        table = sql.Identifier(self.table)
        qualified_table = sql.SQL("{}.{}").format(schema, table)
        LOGGER.info("Ensuring destination table exists: %s.%s", self.schema, self.table)

        if self.scope == "project":
            columns = sql.SQL("project_keyword TEXT NOT NULL, ") + COMMON_SCORE_COLUMNS
            indexes = [
                ("idx_test_cs_keyword_author", ["project_keyword", "original_author_x_id"]),
                ("idx_test_cs_keyword_replier", ["project_keyword", "replier_x_id"]),
                ("idx_test_cs_original_post_id", ["original_post_id"]),
                ("idx_test_cs_post_created", ["post_created_at"]),
                ("idx_test_cs_reply_post_id", ["reply_post_id"]),
            ]
        else:
            columns = COMMON_SCORE_COLUMNS
            indexes = [
                ("idx_test_gcs_original_author", ["original_author_x_id"]),
                ("idx_test_gcs_original_post_id", ["original_post_id"]),
                ("idx_test_gcs_post_created", ["post_created_at"]),
                ("idx_test_gcs_replier", ["replier_x_id"]),
                ("idx_test_gcs_reply_post_id", ["reply_post_id"]),
            ]

        with self.connection.cursor() as cursor:
            cursor.execute(sql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(schema))
        self.connection.commit()

        with self.connection.cursor() as cursor:
            cursor.execute(
                sql.SQL("CREATE TABLE IF NOT EXISTS {} ({})").format(
                    qualified_table, columns
                )
            )
        self.connection.commit()

        # Separate DDL transactions also work across CockroachDB versions that
        # restrict multiple schema changes in one explicit transaction.
        for index_name, index_columns in indexes:
            with self.connection.cursor() as cursor:
                cursor.execute(
                    sql.SQL("CREATE INDEX IF NOT EXISTS {} ON {} ({})").format(
                        sql.Identifier(index_name),
                        qualified_table,
                        sql.SQL(", ").join(map(sql.Identifier, index_columns)),
                    )
                )
            self.connection.commit()

    def _replace_existing_results(self) -> None:
        """Clear only the destination rows this run will replace."""
        assert self.connection is not None
        with self.connection.cursor() as cursor:
            table = sql.SQL("{}.{}").format(
                sql.Identifier(self.schema), sql.Identifier(self.table)
            )
            if self.scope == "project":
                LOGGER.info(
                    "Deleting existing project rows from %s.%s project=%s",
                    self.schema,
                    self.table,
                    self.project_keyword,
                )
                cursor.execute(
                    sql.SQL("DELETE FROM {} WHERE project_keyword = %s").format(table),
                    (self.project_keyword,),
                )
            else:
                LOGGER.info("Truncating global destination table %s.%s", self.schema, self.table)
                cursor.execute(sql.SQL("TRUNCATE TABLE {}").format(table))
        self.connection.commit()
        self.prepared = True

    def _configure_insert(self, result: pl.DataFrame) -> None:
        """Use result columns that exist in the target and reject missing required ones."""
        assert self.connection is not None
        with self.connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT column_name, is_nullable, column_default, is_generated
                FROM information_schema.columns
                WHERE table_schema = %s AND table_name = %s
                ORDER BY ordinal_position
                """,
                (self.schema, self.table),
            )
            table_columns = cursor.fetchall()

        if not table_columns:
            raise RuntimeError(f"Destination table {self.schema}.{self.table} does not exist")

        result_columns = set(result.columns)
        missing_required = [
            name
            for name, nullable, default, generated in table_columns
            if nullable == "NO"
            and default is None
            and generated == "NEVER"
            and name not in result_columns
        ]
        if missing_required:
            missing = ", ".join(missing_required)
            raise RuntimeError(
                f"{self.schema}.{self.table} requires columns not produced by the "
                f"algorithm: {missing}. If active_multipliers is required, construct "
                "DecayComputer with include_active_multipliers=True."
            )

        self.insert_columns = [
            name for name, _, _, generated in table_columns
            if generated == "NEVER" and name in result_columns
        ]

    def write_batch(self, result: pl.DataFrame) -> int:
        """Insert one Polars result batch and commit it to the destination database."""
        if result.is_empty():
            return 0
        if self.connection is None:
            raise RuntimeError("Use DecayResultWriter as a context manager")
        if self.insert_columns is None:
            self._configure_insert(result)
        if not self.prepared:
            # Validate destination compatibility before deleting existing test rows.
            self._replace_existing_results()

        assert self.insert_columns is not None

        if self.write_method == "copy":
            return self._write_batch_copy(result)

        result_columns = set(result.columns)
        insert_prefix = sql.SQL("INSERT INTO {}.{} ({}) VALUES ").format(
            sql.Identifier(self.schema),
            sql.Identifier(self.table),
            sql.SQL(", ").join(map(sql.Identifier, self.insert_columns)),
        )
        row_placeholder = sql.SQL("({})").format(
            sql.SQL(", ").join(sql.Placeholder() for _ in self.insert_columns)
        )

        # Multi-row INSERT substantially reduces network round trips compared with
        # executemany. Pages stay small enough to avoid oversized statements.
        for page in result.iter_slices(self.insert_page_size):
            parameters = [
                value
                for row in page.iter_rows(named=True)
                for value in (
                    row[column] if column in result_columns else None
                    for column in self.insert_columns
                )
            ]
            insert = insert_prefix + sql.SQL(", ").join(
                row_placeholder for _ in range(page.height)
            )
            with self.connection.cursor() as cursor:
                cursor.execute(insert, parameters)
            self.connection.commit()

        self.rows_written += result.height
        return result.height

    def _write_batch_copy(self, result: pl.DataFrame) -> int:
        """Stream a result batch with psycopg3 COPY FROM STDIN."""
        assert self.connection is not None
        assert self.insert_columns is not None

        copy_statement = sql.SQL("COPY {}.{} ({}) FROM STDIN").format(
            sql.Identifier(self.schema),
            sql.Identifier(self.table),
            sql.SQL(", ").join(map(sql.Identifier, self.insert_columns)),
        )
        result_columns = set(result.columns)

        with self.connection.cursor() as cursor:
            with cursor.copy(copy_statement) as copy:
                for row in result.iter_rows(named=True):
                    copy.write_row(
                        tuple(
                            row[column] if column in result_columns else None
                            for column in self.insert_columns
                        )
                    )
        self.connection.commit()
        self.rows_written += result.height
        return result.height


def write_decay_results(
    scope: Scope,
    result_batches: Iterable[pl.DataFrame],
    project_keyword: str | None = None,
    *,
    target: Target = "crdb",
    destination_schema: str | None = None,
    write_method: WriteMethod = "multirow",
) -> int:
    """Replace and write an iterable of computed result batches."""
    with DecayResultWriter(
        scope,
        project_keyword,
        target=target,
        destination_schema=destination_schema,
        write_method=write_method,
    ) as writer:
        for result_batch in result_batches:
            writer.write_batch(result_batch)
        return writer.rows_written
