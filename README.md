# Mindshare Backend Optimization

Moving Mindshare's analytical algorithms out of PostgreSQL PL/pgSQL into a
memory-bounded **Polars** compute layer.

## `mindshare_compute` package

Focused on one algorithm: **contribution decay**, computed in bounded local batches and
written to CockroachDB test score tables.

```
mindshare_compute/
  decay.py     the stateful decay algorithm (ordered Polars batch -> Polars batch)
  db.py        stream source rows and write test score batches through psycopg3
notebooks/01_decay_cockroach_test.ipynb   run and time project/global test writes
```

Project runs replace only the selected project's rows in
`mindshare_score_test.test_contribution_scores`. Global runs replace
`mindshare_score_test.test_global_contribution_scores`. The writer creates the test schema,
destination table, and lookup indexes when they do not already exist.

### Run

```bash
uv sync --group dev
cp .env.example .env    # set MINDSHARE_DB_URI

# Run interactively:
uv run jupyter lab notebooks/01_decay_cockroach_test.ipynb
```

`active_multipliers` is omitted because its repeated array snapshots can dominate memory
and output size.

Results are written directly to CockroachDB using bounded multi-row inserts. Parquet output
is optional and should remain disabled when measuring the fastest compute-and-write path.
