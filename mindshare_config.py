"""Shared configuration for Mindshare local pipelines."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

DEFAULT_CONFIG_PATH = Path("config") / "mindshare.yaml"


def _config_path() -> Path:
    return DEFAULT_CONFIG_PATH


@lru_cache(maxsize=1)
def _load_config() -> dict[str, dict[str, str]]:
    """Load the simple two-level schema config from YAML.

    The parser intentionally supports only the shape used by config/mindshare.yaml:

    section:
      key: value

    Keeping it this small avoids making schema configuration depend on another
    installed package.
    """
    path = _config_path()
    if not path.exists():
        raise RuntimeError(f"Schema config file does not exist: {path}")

    config: dict[str, dict[str, str]] = {}
    current_section: str | None = None
    for line_number, raw_line in enumerate(path.read_text().splitlines(), start=1):
        line_without_comment = raw_line.split("#", 1)[0].rstrip()
        if not line_without_comment.strip():
            continue

        if not raw_line.startswith((" ", "\t")):
            if not line_without_comment.endswith(":"):
                raise RuntimeError(f"Invalid config section at {path}:{line_number}")
            current_section = line_without_comment[:-1].strip()
            config[current_section] = {}
            continue

        if current_section is None or ":" not in line_without_comment:
            raise RuntimeError(f"Invalid config value at {path}:{line_number}")

        key, value = line_without_comment.strip().split(":", 1)
        value = value.strip().strip('"').strip("'")
        if not value:
            raise RuntimeError(f"Missing config value at {path}:{line_number}")
        config[current_section][key.strip()] = value

    return config


def _schema_value(section: str, key: str) -> str:
    section_values = _load_config().get(section, {})
    value = section_values.get(key)
    if value:
        return str(value)

    raise RuntimeError(
        f"Set {section}.{key} in {_config_path()}"
    )


def pg_source_schema() -> str:
    return _schema_value("postgres", "source_schema")


def pg_score_schema() -> str:
    return _schema_value("postgres", "score_schema")


def crdb_source_schema() -> str:
    return _schema_value("cockroachdb", "source_schema")


def crdb_score_schema() -> str:
    return _schema_value("cockroachdb", "score_schema")
