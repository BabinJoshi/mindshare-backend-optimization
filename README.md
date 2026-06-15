# Mindshare Backend Optimization

Moving Mindshare's analytical algorithms out of PostgreSQL PL/pgSQL into a
memory-bounded **Polars** compute layer.

## `mindshare_compute` package

Focused on one algorithm: **contribution decay**, computed in bounded local batches and
written to PostgreSQL or CockroachDB test score tables.

```
mindshare_compute/
  decay.py     the stateful decay algorithm (ordered Polars batch -> Polars batch)
  db.py        stream source rows and write test score batches through psycopg3
notebooks/run_decay_and_write.ipynb   compute, inspect, then benchmark test writes
```

Project runs replace only the selected project's rows in `test_contribution_scores`.
Global runs replace `test_global_contribution_scores`. The writer creates destination
tables and indexes when needed and refuses to use the configured source schema as its
destination.

### Run

```bash
uv sync --group dev
cp .env.example .env    # set MINDSHARE_PG_URI

# Run interactively:
uv run jupyter lab notebooks/run_decay_and_write.ipynb
```

`active_multipliers` is omitted because its repeated array snapshots can dominate memory
and output size.

The notebook reads PostgreSQL source tables from the read-only `mindshare` schema and writes
only to `mindshare_score_test`. PostgreSQL write benchmarks use streaming `COPY FROM STDIN`.
