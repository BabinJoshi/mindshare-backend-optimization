"""Streaming CockroachDB/PostgreSQL reads for the decay notebook."""

from __future__ import annotations

import os
from collections.abc import Iterator
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

import polars as pl
import psycopg
from dotenv import load_dotenv
from psycopg import sql

load_dotenv()


def connection_uri(target: str = "crdb") -> str:
    """Read a database URI from .env without putting credentials in the notebook."""
    env_name = "MINDSHARE_DB_URI" if target == "crdb" else "MINDSHARE_PG_URI"
    uri = os.getenv(env_name)
    if target == "pg":
        uri = uri or os.getenv("POSTGRES_DATABASE_URL")
    if not uri:
        raise RuntimeError(f"Set {env_name} in .env before running the notebook")
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


def source_schema(target: str = "crdb") -> str:
    default = "mindshare_test" if target == "crdb" else "mindshare"
    return os.getenv(f"MINDSHARE_{target.upper()}_SOURCE_SCHEMA", default)


def score_schema(target: str = "pg") -> str:
    default = "mindshare_score_test" if target == "crdb" else "mindshare_score"
    return os.getenv(f"MINDSHARE_{target.upper()}_SCORE_SCHEMA", default)


def iter_decay_source(
    scope: str,
    project_keyword: str | None = None,
    *,
    target: str = "crdb",
    batch_size: int = 100_000,
) -> Iterator[pl.DataFrame]:
    """Yield ordered source rows using a server-side cursor to bound WSL memory."""
    if scope == "project" and not project_keyword:
        raise ValueError("project_keyword is required for project scope")

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


def read_golden_scores(
    scope: str, project_keyword: str | None = None, *, target: str = "pg"
) -> pl.DataFrame:
    """Read existing SQL-computed rows for parity checks on a manageable sample."""
    table = "contribution_scores" if scope == "project" else "global_contribution_scores"
    query = sql.SQL(
        """
        SELECT reply_post_id, effective_score, contribution_score,
               reply_number, local_reply_count, decay_type
        FROM {}.{}
        """
    ).format(sql.Identifier(score_schema(target)), sql.Identifier(table))
    params = ()
    if scope == "project":
        query += sql.SQL(" WHERE project_keyword = %s")
        params = (project_keyword,)

    with connect_with_ssl_fallback(connection_uri(target)) as conn:
        with conn.cursor() as cursor:
            cursor.execute(query, params)
            columns = [item.name for item in cursor.description]
            return pl.DataFrame(cursor.fetchall(), schema=columns, orient="row")
