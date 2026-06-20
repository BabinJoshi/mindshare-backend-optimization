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

Important caveat:

- The project view includes roots with no engagement and sets `engaged_tweet_id`
  to `NULL`. PostgreSQL unique indexes allow multiple `NULL` values, so this can
  still be valid, but confirm it behaves correctly for concurrent refresh and
  downstream assumptions.

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

Recommended index:

```sql
CREATE INDEX IF NOT EXISTS idx_cs_original_replier_created
ON mindshare_score.contribution_scores (
    original_post_id,
    replier_x_id,
    post_created_at
);
```

For global contribution scores:

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
3. Replace normal drop/recreate workflows with refresh workflows.
4. Add unique indexes only where uniqueness is guaranteed and concurrent refresh
   is needed.
5. Add composite `original_post_id, replier_x_id, post_created_at` indexes for
   contribution-score `DISTINCT ON` patterns.
6. Use `EXPLAIN (ANALYZE, BUFFERS)` on the slowest leaderboard/API calls.
7. Consider materializing expensive all-user analytics only if the live function
   is called frequently enough to justify refresh cost.
