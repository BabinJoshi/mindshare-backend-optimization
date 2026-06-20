# Mindshare Decay Compute Pipeline

This project moves the contribution-decay algorithms out of PostgreSQL PL/pgSQL
and computes them locally with Polars.

The production-style test workflow:

1. Reads base data from the PostgreSQL `mindshare` schema.
2. Computes project or global decay in memory-bounded batches.
3. Saves computed results as Parquet parts for manual inspection.
4. Writes verified results only to the configured PostgreSQL score schema.

The workflow never writes to the read-only `mindshare` source schema.

## Database Documentation

PostgreSQL object and performance documentation lives in:

- [Database Object Dependencies](docs/database_object_dependencies.md)
- [PostgreSQL Performance Improvements](docs/postgres_performance_improvements.md)

The database docs reflect the current split: decay computation runs in Polars,
while analytics materialized views and query functions remain in PostgreSQL.

## Project Structure

From `/home/babin411/Nucleus/mindshare-backend-optimization`, the current
directory structure is:

The tree omits `.git/`, `.venv/`, `__pycache__/`, and `.pytest_cache/` because
they are generated tooling directories rather than project source.

```text
mindshare-backend-optimization/
├── .agents/                 # Local agent/workspace configuration
├── .codex/                  # Local Codex workspace configuration
├── .env                     # Local credentials; ignored by Git
├── .env.example
├── .gitignore
├── .python-version
├── Mindshare_Backend/       # Existing PostgreSQL SQL definitions
│   ├── Analytics/
│   │   ├── functions/
│   │   └── materialized views/
│   ├── Mindshare/
│   │   └── Tables/
│   └── Mindshare_score/
│       ├── Fuctions/
│       └── Tables/
├── config/
│   └── mindshare.yaml       # Shared schema configuration for local pipelines
├── mindshare_compute/
│   ├── __init__.py
│   ├── cli.py               # Shared CLI implementation and pipeline orchestration
│   ├── db.py                # Memory-bounded database reads and result writes
│   ├── decay.py             # Stateful contribution-decay algorithm
│   └── logging_config.py    # Console and run-scoped file logging
├── notebooks/
│   ├── output/              # Existing notebook-generated result directories
│   └── run_decay_and_write.ipynb
├── run_decay_pipeline.py    # Direct executable wrapper around cli.main()
├── pyproject.toml
├── README.md
└── uv.lock
```

The CLI may generate these ignored directories from the repository root:

```text
mindshare-backend-optimization/
├── output/                  # CLI-generated Parquet parts and summary JSON files
└── logs/                    # CLI-generated run logs
```

`notebooks/output/` belongs to interactive notebook runs. The CLI commands below
run from the repository root and therefore use root-level `output/` and `logs/`.

`run_decay_pipeline.py` is the repository's canonical executable. It delegates
directly to the package implementation:

```text
run_decay_pipeline.py -> mindshare_compute.cli.main()
```

The optional installed `mindshare-decay` alias points to that same
`mindshare_compute.cli.main()` function.

## Tables

Project scope reads:

- `mindshare.mindshare_post`
- `mindshare.mindshare_user`

Project scope writes:

- `test_mindshare_score.test_contribution_scores`

Global scope reads:

- `mindshare.user_post`
- `mindshare.mindshare_user`

Global scope writes:

- `test_mindshare_score.test_global_contribution_scores`

The destination schema, table, and indexes are created automatically when they do
not exist. The writer refuses to use the configured source schema as its destination.

## Setup

Python 3.12 or newer and `uv` are required.

```bash
uv sync --group dev
cp .env.example .env
```

Configure the PostgreSQL connection in `.env`:

```env
MINDSHARE_PG_URI=postgresql://user:password@host:5432/database?sslmode=require
```

Configure schemas in `config/mindshare.yaml`:

```yaml
postgres:
  source_schema: mindshare
  score_schema: test_mindshare_score

cockroachdb:
  source_schema: mindshare_test
  score_schema: test_mindshare_score
```

Schema names are read only from this config file. They are not read from `.env`.

The database user needs:

- `SELECT` permission on the required tables in `mindshare`.
- `CREATE` and `USAGE` permission on `test_mindshare_score`.
- Permission to create, delete, truncate, and insert into the test score tables.

## CLI

Run commands from the repository root:

```bash
cd /home/babin411/Nucleus/mindshare-backend-optimization
uv run python ./run_decay_pipeline.py --help
```

With the existing `.venv`, the direct equivalent is:

```bash
./.venv/bin/python ./run_decay_pipeline.py --help
```

After `uv sync`, the optional installed alias is also equivalent:

```bash
uv run mindshare-decay --help
```

### CLI Modes

The CLI provides five modes:

| Mode | Reads PostgreSQL source tables | Computes algorithm | Reads/writes Parquet | Writes PostgreSQL results |
|---|---:|---:|---:|---:|
| `compute` | Yes | Yes | Writes | No |
| `inspect` | No | No | Reads | No |
| `write` | No | No | Reads | Yes, requires `--write` |
| `run` | Yes | Yes | Writes and reads | Yes, requires `--write` |
| `all-projects` | Yes | Yes | Writes and reads | Yes, requires `--write` |

#### `compute`: Compute Results Without Database Writes

Use `compute` to run the decay algorithm and save its output for manual
verification.

It will:

- Read the required base tables from the read-only PostgreSQL `mindshare` schema.
- Process source rows in bounded batches.
- Compute project or global decay scores.
- Write result batches as Parquet files.
- Write `compute_summary.json` with separate database-read, algorithm, Parquet,
  and total wall-clock timings.
- Never create, delete, truncate, or insert database records.

Project example:

```bash
uv run python ./run_decay_pipeline.py compute \
  --scope project \
  --project quipnetwork \
  --output-dir output/quipnetwork_test
```

Global example:

```bash
uv run python ./run_decay_pipeline.py compute \
  --scope global \
  --output-dir output/global_test
```

If `--output-dir` is omitted, a unique directory containing the run ID is
created under `output/`.

#### `inspect`: Manually Verify Computed Parquet Results

Use `inspect` after `compute` and before any database write.

It will:

- Read existing Parquet parts from `--output-dir`.
- Print counts and score statistics grouped by `decay_type`.
- Print an ordered verification preview.
- Optionally filter the preview by replier or original author.
- Never connect to or modify PostgreSQL.

```bash
uv run python ./run_decay_pipeline.py inspect \
  --scope project \
  --project quipnetwork \
  --output-dir output/quipnetwork_test \
  --replier 1000466366451933185 \
  --limit 200
```

Useful options:

```text
--replier <x_id>          Show one replier's ordered results
--original-author <x_id>  Show replies targeting one author
--limit <rows>            Limit the verification preview
```

#### `write`: Write Previously Verified Results

Use `write` only after manually verifying an existing Parquet result directory.

It will:

- Read result batches from `--output-dir`.
- Create the destination schema, table, and indexes if they do not exist.
- Refuse to use the read-only source schema as its destination.
- Write only to the configured PostgreSQL score schema.
- Write `write_summary.json` containing timing and row-count validation.
- Require the explicit `--write` safety flag.

Project scope:

- Deletes only the selected project's existing rows.
- Writes to `test_mindshare_score.test_contribution_scores`.

Global scope:

- Truncates the global test result table.
- Writes to `test_mindshare_score.test_global_contribution_scores`.

```bash
uv run python ./run_decay_pipeline.py write \
  --scope project \
  --project quipnetwork \
  --output-dir output/quipnetwork_test \
  --write
```

Without `--write`, the command exits without modifying PostgreSQL.

#### `run`: Complete End-to-End Execution

Use `run` for an automated end-to-end test after the staged workflow has already
been validated.

It executes these modes sequentially:

```text
compute -> inspect -> write
```

It will:

- Read source rows from PostgreSQL `mindshare`.
- Compute and save Parquet result parts.
- Print an inspection summary and preview.
- Write results to the configured PostgreSQL score schema.
- Validate the final destination row count.
- Require the explicit `--write` safety flag before computation begins.

```bash
uv run python ./run_decay_pipeline.py run \
  --scope project \
  --project quipnetwork \
  --output-dir output/quipnetwork_e2e \
  --write
```

Use the staged `compute`, `inspect`, and `write` commands when human approval is
required between computation and database writing. Use `run` when one automated
end-to-end execution is desired.

#### `all-projects`: Run Every Enabled Project

Use `all-projects` to run project decay for every enabled project in:

```sql
mindshare.mindshare_project
```

The command discovers enabled projects with:

```sql
SELECT project_name
FROM mindshare.mindshare_project
WHERE status = true
ORDER BY project_name;
```

For each enabled `project_name`, it runs the same per-project sequence used by
`run`:

```text
compute -> inspect -> write
```

It will:

- Read the enabled project list from `mindshare.mindshare_project`.
- Skip projects where `status` is `false`.
- Compute each enabled project separately.
- Write each project's Parquet output under its own directory.
- Delete and replace only that project's rows in
  `test_mindshare_score.test_contribution_scores`.
- Continue with later projects if one project fails.
- Write `all_projects_summary.json` under the output root with succeeded and
  failed project lists.
- Require the explicit `--write` safety flag before project discovery starts.

```bash
uv run python ./run_decay_pipeline.py all-projects \
  --output-root output/all_projects_e2e \
  --write
```

The output layout is:

```text
output/all_projects_e2e/
├── Acurast/
│   ├── part-00000.parquet
│   ├── compute_summary.json
│   └── write_summary.json
├── quipnetwork/
│   ├── part-00000.parquet
│   ├── ...
│   ├── compute_summary.json
│   └── write_summary.json
└── all_projects_summary.json
```

When `--output-root` is omitted, the generated directory includes the same run
ID used by the log directory.

## Logging

Every CLI invocation logs to both the terminal and a unique file:

```text
logs/
└── 2026-06-15/
    ├── 20260615T081500Z-a1b2c3/
    │   └── pipeline.log
    └── 20260615T093010Z-d4e5f6/
        └── pipeline.log
```

- The day directory uses the UTC date.
- Every invocation receives a unique run ID.
- Separate runs on the same day never share a log file.
- Compute and write summary JSON files include the run ID and log-file path.
- `logs/` is excluded from Git.

Set the console and file log level before the subcommand:

```bash
uv run python ./run_decay_pipeline.py --log-level DEBUG compute \
  --scope project \
  --project quipnetwork \
  --output-dir output/quipnetwork_test
```

Use another log root when needed:

```bash
uv run python ./run_decay_pipeline.py --log-root /tmp/mindshare-logs inspect \
  --scope project \
  --project quipnetwork \
  --output-dir output/quipnetwork_test
```

### Recommended staged project test

First compute the algorithm and persist the results without database writes:

```bash
uv run python ./run_decay_pipeline.py compute \
  --scope project \
  --project quipnetwork \
  --output-dir output/quipnetwork_test
```

This creates:

```text
output/quipnetwork_test/
  part-00000.parquet
  part-00001.parquet
  ...
  compute_summary.json
```

Inspect the complete result and optionally filter one replier:

```bash
uv run python ./run_decay_pipeline.py inspect \
  --scope project \
  --project quipnetwork \
  --output-dir output/quipnetwork_test

uv run python ./run_decay_pipeline.py inspect \
  --scope project \
  --project quipnetwork \
  --output-dir output/quipnetwork_test \
  --replier 1000466366451933185 \
  --limit 200
```

After manually verifying the Parquet results, write them to PostgreSQL:

```bash
uv run python ./run_decay_pipeline.py write \
  --scope project \
  --project quipnetwork \
  --output-dir output/quipnetwork_test \
  --write
```

Before writing project results, the writer deletes only:

```sql
DELETE FROM test_mindshare_score.test_contribution_scores
WHERE project_keyword = 'quipnetwork';
```

It then streams the verified Parquet parts into PostgreSQL using `COPY FROM STDIN`.

### Full project end-to-end test

The `run` command computes, prints an inspection summary, and writes the result:

```bash
uv run python ./run_decay_pipeline.py run \
  --scope project \
  --project quipnetwork \
  --output-dir output/quipnetwork_e2e \
  --write
```

`--write` is mandatory. Without it, the command exits before computation starts.

When `--output-dir` is omitted for `compute` or `run`, the generated output
directory includes the same run ID used by the log directory.

### All Enabled Projects End-to-End Test

Run every project whose `mindshare.mindshare_project.status` is `true`:

```bash
uv run python ./run_decay_pipeline.py all-projects \
  --output-root output/all_projects_e2e \
  --write
```

Each project is processed independently. If one project fails, the command logs
that failure, records it in `all_projects_summary.json`, and continues with the
remaining projects. After all enabled projects have been attempted, the command
exits with an error if any project failed. Rerun with `--overwrite-output` after
fixing the issue if you want to recompute already-created Parquet parts.

### Global test

Compute and inspect global results:

```bash
uv run python ./run_decay_pipeline.py compute \
  --scope global \
  --output-dir output/global_test

uv run python ./run_decay_pipeline.py inspect \
  --scope global \
  --output-dir output/global_test
```

Write global results:

```bash
uv run python ./run_decay_pipeline.py write \
  --scope global \
  --output-dir output/global_test \
  --write
```

Global writes truncate only:

```sql
TRUNCATE TABLE test_mindshare_score.test_global_contribution_scores;
```

## Performance Options

Source rows and Parquet results are streamed in bounded batches:

```bash
--source-batch-size 100000
--write-batch-size 100000
```

If `database_read_seconds` dominates the compute summary, the bottleneck is the
PostgreSQL source query rather than the Polars decay algorithm. The source query
filters reply rows, joins each reply to its original post, and orders by
`user_x_id, post_created_at`. Add the supporting indexes in:

```text
Mindshare_Backend/Mindshare_score/Indexes/decay_source_read_indexes.sql
```

Those indexes are especially important for large projects because the current
query shape needs fast access to:

- reply rows for one `project_keyword` in `user_x_id, post_created_at` order
- original posts by `(project_keyword, post_id)`

After creating the indexes, run the same project again and compare
`database_read_seconds` in `compute_summary.json`. You can also try a larger
batch size, such as `--source-batch-size 500000`, if WSL has enough memory.
Larger batches reduce fetch round trips but increase peak memory.

PostgreSQL writes default to streaming `COPY FROM STDIN`, which is normally fastest:

```bash
--write-method copy
```

For comparison, use bounded multi-row inserts:

```bash
--write-method multirow --insert-page-size 4000
```

Use `--include-active-multipliers` only when required. Repeated multiplier-array
snapshots can significantly increase memory usage and Parquet size.

If an output directory already contains Parquet parts, computation stops instead
of overwriting them. To intentionally replace those parts:

```bash
--overwrite-output
```

## Timing Output

`compute_summary.json` separates:

- `database_read_seconds`
- `algorithm_compute_seconds`
- `parquet_write_seconds`
- `compute_wall_seconds`

`write_summary.json` records:

- Destination schema and table
- Write method
- Rows written
- Destination row count after writing
- PostgreSQL write time
- Total write wall time

The CLI verifies that the number of rows written equals the destination row count
after the operation.

## Notebook

The existing notebook remains available for interactive testing:

```bash
uv run jupyter lab notebooks/run_decay_and_write.ipynb
```

It keeps computation, manual inspection, and PostgreSQL writing in separate cells.

## Analytics Materialized Views

Analytics engagement materialized views are intentionally left in PostgreSQL.
Those views are relational joins over data already stored in Postgres, so keeping
their creation and refresh near the data is usually faster than pulling millions
of rows into Polars and writing them back.

Use the existing SQL procedures under `Mindshare_Backend/Analytics/functions/`
for Analytics view creation and refresh.
