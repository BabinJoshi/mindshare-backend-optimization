# PostgreSQL Performance Improvement Guide

This guide documents performance improvements for the PostgreSQL-side Mindshare
workload. It intentionally keeps SQL-changing recommendations separate from the
current object inventory.

Current split:

- Polars owns decay score computation.
- PostgreSQL owns analytics materialized views, derived feature materialized
  views, and query/leaderboard functions.

## Priority Areas

1. Speed up source reads for the Polars decay pipeline.
2. Speed up materialized-view creation and refresh.
3. Speed up leaderboard/API functions that join materialized views and score
   tables.
4. Keep query plans predictable as row counts grow.

## Decay Source Read Indexes

The Polars decay pipeline spends most of its time reading from PostgreSQL when
projects are large. The project source query filters reply rows, joins replies
to original posts, and orders by replier/time:

```sql
WHERE p.project_keyword = $1
  AND p.is_reply = true
  AND p.replied_post_id IS NOT NULL
JOIN original
  ON original.project_keyword = p.project_keyword
 AND original.post_id = p.replied_post_id
ORDER BY p.user_x_id, p.post_created_at
```

Recommended index script:

```text
Mindshare_Backend/Mindshare_score/Indexes/decay_source_read_indexes.sql
```

It adds:

- `mindshare_post(project_keyword, user_x_id, post_created_at)` partial index on
  replies, including `post_id` and `replied_post_id`
- `mindshare_post(project_keyword, post_id)` lookup index, including `user_x_id`
- `user_post(user_x_id, post_created_at)` partial index on replies, including
  `post_id` and `replied_post_id`
- `user_post(post_id)` lookup index, including `user_x_id`
- `user_post(retweeted_post_id)` for analytics paths that join retweets to roots

Expected benefit:

- Lower `database_read_seconds` in Polars compute summaries.
- Less sorting work for project decay reads.
- Faster reply-to-original lookups.

Validation:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.project_keyword,
       p.post_id AS reply_post_id,
       op.post_id AS original_post_id,
       p.user_x_id AS replier_x_id,
       p.post_created_at,
       op.user_x_id AS original_author_x_id,
       u.score AS replier_base_score
FROM mindshare.mindshare_post p
JOIN mindshare.mindshare_post op
  ON p.replied_post_id = op.post_id
 AND p.project_keyword = op.project_keyword
JOIN mindshare.mindshare_user u
  ON p.user_x_id = u.x_id
WHERE p.is_reply = true
  AND p.replied_post_id IS NOT NULL
  AND p.project_keyword = 'quipnetwork'
ORDER BY p.user_x_id, p.post_created_at;
```

Watch for:

- Index scans instead of large sequential scans where practical.
- Reduced sort cost.
- Reduced temp file usage.

## Analytics Materialized View Indexes

### `analytics.mv_engagement_<project>`

Created by `analytics.create_engagement_view(project_keyword)`.

Existing indexes created by the procedure:

- Unique index on `engaged_tweet_id`
- Index on `root_post_id`
- Index on `engaged_user_id`

Recommendations:

- Keep `root_post_id` indexed because derived feature views and post-level
  analytics group/join by root.
- Keep `engaged_user_id` indexed for user-level engagement lookups.
- Keep the unique `engaged_tweet_id` index only if each engagement tweet appears
  at most once in the result.
- If `REFRESH MATERIALIZED VIEW CONCURRENTLY` is required, PostgreSQL needs a
  valid unique index that covers every row.

Important caveat (sharpened after inspecting the view definition):

- The project view's final `SELECT` is `engagements_with_scores UNION ALL
  posts_with_no_engagement`. The no-engagement branch sets `engaged_tweet_id`,
  `engaged_user_id`, and every engagement column to `NULL`. So **no single
  column — and no obvious column combination — is unique across all rows.**
  `engaged_tweet_id` is unique only among engagement rows; every no-engagement
  row carries `NULL` there.
- PostgreSQL allows the unique index to *exist* (multiple `NULL`s do not
  conflict), which is why `ix_mv_engagement_<project>_tweet` is created without
  error. But `REFRESH MATERIALIZED VIEW CONCURRENTLY` needs a unique index that
  uniquely identifies **every** row, including the all-`NULL` ones. With more
  than one no-engagement root, those rows are not distinguishable, so concurrent
  refresh is not safe for this view.
- This is consistent with the code: `analytics.refresh_engagement_views_all`
  uses **plain** (non-concurrent) `REFRESH`. Treat the unique
  `engaged_tweet_id` index as a data-quality guard for engagement rows, **not**
  as a concurrent-refresh enabler.
- If concurrent refresh of the project base view is ever required, add a column
  that is unique per row (e.g. a generated surrogate key, or
  `COALESCE(engaged_tweet_id, 'root:' || root_post_id)` materialized into a real
  column) and build the unique index on that.

By contrast, both **feature** views (`mv_engagement_features_<project>` and
`mv_user_posts_engagement_features`) have one row per `root_post_id` and a
genuine `UNIQUE (root_post_id)` index, so `REFRESH ... CONCURRENTLY` is valid
for them — and `refresh_engagement_features_views_all` already uses it.

### `analytics.mv_user_posts_engagement`

Created by `analytics.create_user_posts_engagement_view()`.

Existing indexes:

- `root_post_id`
- `root_user_id`

Recommended additional source-table index:

```sql
CREATE INDEX IF NOT EXISTS ix_user_post_retweeted_post_id
ON mindshare.user_post (retweeted_post_id);
```

Reason:

- The materialized view joins retweets using
  `e.retweeted_post_id = r.post_id`.
- `user_post` already has indexes for `replied_post_id` and `quoted_post_id` in
  the table definition, but no explicit `retweeted_post_id` index was present in
  the inspected table SQL.

Potential materialized-view index for concurrent refresh:

```sql
CREATE UNIQUE INDEX IF NOT EXISTS ix_mv_user_posts_engagement_tweet
ON analytics.mv_user_posts_engagement (engaged_tweet_id);
```

Only add this if `engaged_tweet_id` is guaranteed unique in the result.

## Materialized View Refresh Strategy

Use `CREATE MATERIALIZED VIEW` only when:

- Creating the view for the first time.
- Changing the query definition.
- Rebuilding after a destructive schema change.

Use `REFRESH MATERIALIZED VIEW` for normal data updates:

```sql
REFRESH MATERIALIZED VIEW analytics.mv_user_posts_engagement;
REFRESH MATERIALIZED VIEW analytics.mv_engagement_quipnetwork;
```

Use `REFRESH MATERIALIZED VIEW CONCURRENTLY` only when:

- The view already exists.
- The view has a valid unique index.
- Reads must continue during refresh.

Example:

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_engagement_quipnetwork;
```

Important correction:

- PostgreSQL materialized views are not incrementally refreshed by default.
- A refresh reruns the full view query and replaces the stored result.
- Concurrent refresh reduces blocking for readers but does not make the refresh
  incremental.

Avoid this during normal refresh:

```sql
DROP MATERIALIZED VIEW ... CASCADE;
CREATE MATERIALIZED VIEW ...;
```

Why:

- Drops dependent objects.
- Forces indexes to be recreated.
- Can break readers during rebuild.
- Should be reserved for definition changes.

## Leaderboard and Analytics Query Indexes

### `DISTINCT ON` Contribution Score Pattern

Several functions use a pattern like:

```sql
SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id)
...
FROM mindshare_score.contribution_scores cs
ORDER BY cs.original_post_id, cs.replier_x_id, cs.post_created_at ASC
```

There are actually **two distinct access shapes** for this pattern, and they
want slightly different indexes. Verified against the function bodies:

Shape A — **post-scoped** `DISTINCT ON`, no `project_keyword` predicate on the
score table (scope comes from a join/`EXISTS` on `original_post_id`). Used by
`get_account_level_metrics`, `get_post_level_metrics`,
`get_single_post_smart_reach`, `get_v2_user_posts_analytics`, and the two global
metric functions (`get_global_account_level_metrics`,
`get_global_post_level_metrics`, which — note — read the **project** table):

```sql
CREATE INDEX IF NOT EXISTS idx_cs_original_replier_created
ON mindshare_score.contribution_scores (
    original_post_id,
    replier_x_id,
    post_created_at
);
```

Shape B — **project-filtered** `DISTINCT ON`, with `cs.project_keyword = $n` in
the predicate. Used by `get_mindshare_leaderboard`,
`get_private_mindshare_leaderboard`, and `get_v2_analytics`. A keyword-leading
composite lets the same index satisfy the filter and the `DISTINCT ON` ordering:

```sql
CREATE INDEX IF NOT EXISTS idx_cs_keyword_original_replier_created
ON mindshare_score.contribution_scores (
    project_keyword,
    original_post_id,
    replier_x_id,
    post_created_at
);
```

This supersedes the narrower existing `idx_cs_keyword_replier` and
`idx_cs_keyword_author` for these hot leaderboard paths (keep those only if
other queries depend on them).

For global contribution scores (used by `get_all_users_analytics` and
`get_user_posts_analytics`, both with the same `DISTINCT ON` shape):

```sql
CREATE INDEX IF NOT EXISTS idx_gcs_original_replier_created
ON mindshare_score.global_contribution_scores (
    original_post_id,
    replier_x_id,
    post_created_at
);
```

Expected benefit:

- Faster earliest-reply lookup per original post/replier pair.
- Lower sort pressure in leaderboard and analytics functions.
- Shape B avoids a separate filter + sort by serving both from one index.

### Project Leaderboard Functions

Functions:

- `mindshare_score.get_mindshare_leaderboard`
- `mindshare_score.get_private_mindshare_leaderboard`
- `mindshare_score.get_v2_analytics`

Common dependencies:

- Dynamic `analytics.mv_engagement_<project>`
- `mindshare_score.contribution_scores`
- `mindshare.mindshare_post`
- `mindshare.mindshare_user`
- `mindshare.project_post_cap`

Useful checks:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM mindshare_score.get_mindshare_leaderboard(
    1751328000,
    1759276800,
    'quipnetwork'
);
```

Note:

- Because these are PL/pgSQL functions with dynamic SQL, the outer explain often
  shows only a `Function Scan`. To inspect internals, copy the generated dynamic
  SQL or temporarily log it with `RAISE NOTICE`.

## Partitioning Guidance

### `mindshare.mindshare_post`

Current table definition partitions by `project_keyword`.

Keep this strategy because:

- Most project analytics and project decay queries filter by `project_keyword`.
- Per-project materialized views are naturally aligned with project partitions.
- Project-specific refresh/rebuild work benefits from partition pruning.

Consider additional time partitioning only if:

- Queries consistently filter by time windows.
- Partitions become too large to vacuum/analyze efficiently.
- Operational maintenance windows require smaller independent chunks.

Avoid changing partitioning without measuring:

- Existing project pruning behavior.
- Write overhead.
- Index maintenance cost across partitions.

### `mindshare.user_post`

This table powers global analytics and global decay.

Avoid over-partitioning unless query plans prove a clear bottleneck. Many global
queries need broad scans or joins across users/posts, so too many partitions can
increase planning and maintenance overhead.

Potential future partitioning candidates:

- Time-based partitioning on `post_created_at`, if most queries use bounded time
  windows and old data becomes cold.
- Hash partitioning by `user_x_id`, only if user-local workloads dominate and
  global scans remain acceptable.

## Query Shape Improvements

### Avoid `OR` Joins When Possible

Some queries join engagements with conditions like:

```sql
mp.replied_post_id = tp.post_id
OR mp.quoted_post_id = tp.post_id
```

PostgreSQL can struggle to use indexes efficiently with `OR` join predicates.
For hot paths, consider rewriting as `UNION ALL`:

```sql
SELECT ...
FROM replies
JOIN target_posts ON replies.replied_post_id = target_posts.post_id

UNION ALL

SELECT ...
FROM quotes
JOIN target_posts ON quotes.quoted_post_id = target_posts.post_id
WHERE quotes.replied_post_id IS NULL;
```

This matches the style already used in the engagement materialized view
procedures and can make index use clearer.

### Avoid Repeated Full Work in API Functions

Functions such as `analytics.get_all_users_analytics` compute many aggregated
metrics over `user_post`, engagement feature views, and global contribution
scores.

If called frequently:

- Consider a scheduled materialized view for all-users analytics.
- Refresh it after `mv_user_posts_engagement_features` and global contribution
  scores are refreshed.
- Keep the live function as a fallback or for ad hoc parameterized limits.

## Reliability Issues Worth Fixing Alongside Performance

These were found while verifying the function bodies. They are not pure
performance items, but they cause silent wrong/empty results or block the
migration, so fix them in the same pass.

### `get_unique_reach_increase` builds the wrong view name for multi-word projects

It builds `'analytics.mv_engagement_' || LOWER(projectname)` and injects with
`%s` — **without** `REPLACE(projectname, ' ', '_')`. Every other function uses
`LOWER(REPLACE(projectname, ' ', '_'))` with `%I`. For any project whose keyword
contains a space (e.g. `Pact Swap`), this resolves to a non-existent view and
the function errors or returns nothing. `get_user_level_unique_reach_increase_flag`
calls it and inherits the bug. Align it with the canonical normalization:

```sql
-- inside get_unique_reach_increase, replace the table_name build with:
view_name := 'mv_engagement_' || LOWER(REPLACE(projectname, ' ', '_'));
-- and inject with %I against the analytics schema, matching the other functions.
```

### `active_multipliers` is `NOT NULL` in the production score tables

`mindshare_score.contribution_scores` and `global_contribution_scores` both
declare `active_multipliers _numeric NOT NULL`. The Polars writer omits that
column by default and creates its own `test_*` tables without it. Before the
pipeline can write the **production** tables you must either:

- populate `active_multipliers` (run the pipeline with
  `--include-active-multipliers`, accepting the higher memory/Parquet cost the
  README warns about), or
- drop the `NOT NULL` (or the column) on the production tables.

Decide this deliberately as part of the cutover; it is not a runtime tunable.

### Confirm the global metric functions' score-table choice

`get_global_account_level_metrics` and `get_global_post_level_metrics` read the
**project** `contribution_scores` table while every other input is the global
`user_post`. If that is a bug, fixing it changes which index matters (the global
composite index above instead of the project one). Resolve the intent before
optimizing these two.

## Materialized-View Build and Refresh Cost

The `analytics.create_engagement_view` procedure `DROP ... CASCADE`s and
recreates the view, then rebuilds three indexes. The source notes one project
(`quipnetwork`, ~2.6M rows) took ~2m19s to create. Two practical levers:

- **Prefer `REFRESH` over recreate for data updates** (already covered above) —
  recreate only for definition changes.
- **Refresh projects in parallel.** `refresh_engagement_features_views_all`
  already commits per project; project base views are independent, so multiple
  sessions can refresh different projects concurrently. The hard serialization
  is only *within* one view (a plain `REFRESH` takes an exclusive lock on that
  one view). Partition pruning on `mindshare_post` means each project's rebuild
  only scans its own partition.
- For the global feature pipeline, respect the ordering enforced by
  `refresh_user_post_engagement_views`: base `mv_user_posts_engagement` first,
  then `mv_user_posts_engagement_features`.

## Statistics and Maintenance

After large writes, refreshes, or index creation:

```sql
ANALYZE mindshare.mindshare_post;
ANALYZE mindshare.user_post;
ANALYZE mindshare.mindshare_user;
ANALYZE mindshare_score.contribution_scores;
ANALYZE mindshare_score.global_contribution_scores;
```

For materialized views:

```sql
ANALYZE analytics.mv_user_posts_engagement;
ANALYZE mindshare_score.mv_user_posts_engagement_features;
```

For project views:

```sql
ANALYZE analytics.mv_engagement_quipnetwork;
ANALYZE mindshare_score.mv_engagement_features_quipnetwork;
```

## Measurement Checklist

Track these separately:

- Polars `database_read_seconds`
- Polars `algorithm_compute_seconds`
- Polars `parquet_write_seconds`
- PostgreSQL materialized-view creation time
- PostgreSQL materialized-view refresh time
- PostgreSQL function execution time
- Temp read/write buffers from `EXPLAIN (ANALYZE, BUFFERS)`

Example:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM mindshare_score.get_mindshare_leaderboard(
    1751328000,
    1759276800,
    'quipnetwork'
);
```

Interpretation:

- `Planning Time` is usually small for function calls.
- `Execution Time` is total runtime.
- `actual time=...` in a `Function Scan` is reported in milliseconds.
- A PL/pgSQL function may hide the internal query plan unless dynamic SQL is
  extracted and explained directly.

## Recommended Order of Work

1. Apply and validate source-read indexes for decay.
2. Add missing `user_post(retweeted_post_id)` index if retweet joins are slow.
3. Replace normal drop/recreate workflows with refresh workflows; only the
   feature views can use `CONCURRENTLY` (they have a real unique key), not the
   project base engagement view.
4. Add the contribution-score `DISTINCT ON` indexes — Shape A
   (`original_post_id, replier_x_id, post_created_at`) for post-scoped functions
   and the two global metric functions, Shape B
   (`project_keyword, original_post_id, replier_x_id, post_created_at`) for the
   leaderboards and `get_v2_analytics`; mirror Shape A onto
   `global_contribution_scores`.
5. Fix `get_unique_reach_increase`'s view-name normalization and confirm the
   global metric functions' score-table choice (see Reliability Issues).
6. Use `EXPLAIN (ANALYZE, BUFFERS)` on the slowest leaderboard/API calls.
7. Resolve the `active_multipliers NOT NULL` question before pointing the Polars
   pipeline at the production score tables.
8. Consider materializing expensive all-user analytics only if the live function
   is called frequently enough to justify refresh cost.
