# Mindshare Backend Optimization

Moving Mindshare's analytical algorithms out of PostgreSQL PL/pgSQL into a
memory-bounded **Polars** compute layer.

## `mindshare_compute` package

Focused on one algorithm: **contribution decay**, with optional validation against the
existing PostgreSQL-computed `contribution_scores` tables.

```
mindshare_compute/
  decay.py     the stateful decay algorithm (ordered Polars batch -> Polars batch)
  db.py        read source rows / golden scores via psycopg3 (pg + crdb targets)
notebooks/01_decay_prototype.ipynb   drive + validate against Postgres
```

The golden `contribution_scores` live in the **live Postgres** system; CockroachDB currently
has only the base tables. The notebook computes from CockroachDB source rows and optionally
compares the result with the Postgres golden output.

### Run

```bash
uv sync --group dev
cp .env.example .env    # set MINDSHARE_DB_URI; set MINDSHARE_PG_URI for validation

# Run interactively:
uv run jupyter lab notebooks/01_decay_prototype.ipynb
```

Structural columns (`decay_type`, `reply_number`, `local_reply_count`) must match the PG
output exactly; scores match within one cent (f64 vs PG `NUMERIC`; see `_round2` in
`decay.py`). `active_multipliers` is omitted by default because its repeated array snapshots
can dominate memory and output size. Enable it only when that SQL-compatible field is needed.
