# Change Inventory — what was added, where it lives, what can be removed

Every object created or modified during the optimization work, its location (DB schema **and**
repo file), and the old objects each one supersedes. Use the **Removable** column to plan
cleanup.

> Convention: production schemas (`mindshare`, `analytics`, `mindshare_score`) are read-only
> except non-destructive indexes. All new logic lives in `*_md_fix`. `test_mindshare_score` was
> **not touched**.

---

## A. New objects I created (this + prior rounds)

### Schema `mindshare_score_md_fix` — feature pipeline (MV → incremental table)
Repo: [`Mindshare_Backend/Mindshare_score_md_fix/functions/incremental_features.sql`](../../Mindshare_Backend/Mindshare_score_md_fix/functions/incremental_features.sql)

| DB object | Type | Purpose |
|---|---|---|
| `features_<project>` ×11 | table | farming-score output; replaces `mv_engagement_features_<project>` |
| `feature_watermarks` | table | per-project incremental watermark |
| `_features_pipeline_sql(mv, scope)` | function | the 12-CTE SELECT, shared by full + incremental |
| `_ensure_features_table(slug)` | procedure | create table + indexes if absent |
| `build_features_full(project)` | procedure | full TRUNCATE+INSERT |
| `refresh_features_incremental(project)` | procedure | hot-author UPSERT |
| `build_all_features()` / `refresh_all_features_incremental()` | procedure | orchestrators (per-loop COMMIT) |
| `get_engagement_clustering(bigint,bigint,text)` | function | **repointed** from MV to table |

### Schema `mindshare_score_md_fix` — set-based decay
Repo: [`Mindshare_Backend/Mindshare_score_md_fix/functions/decay_set_based.sql`](../../Mindshare_Backend/Mindshare_score_md_fix/functions/decay_set_based.sql)

| DB object | Type | Purpose |
|---|---|---|
| `calculate_decay_scores_fast(text, interval)` | procedure | project decay, 2-pass window, replaces the loop |
| `calculate_global_decay_scores_fast(interval)` | procedure | global decay (writes `global_contribution_scores`) |

### Scratch / benchmark
| DB object | Type | Note |
|---|---|---|
| `mindshare_score_md_fix._bench_log` | table | timing log; **removable anytime** |

### Indexes on production base tables (non-destructive, kept)
On each `features_<project>` table: PK `root_post_id`, `root_user_id`, `farming_score`,
`root_tweet_created_at`. (Base `mindshare.*` decay/replier indexes were added in earlier rounds —
see summary.md §7–8.)

---

## B. Pre-existing `_md_fix` work (not mine; context)

| Schema | Objects | Note |
|---|---|---|
| `analytics_md_fix` | 12 `mv_engagement_*` matviews + build/refresh procs + 4 query fns | `NOT EXISTS`→`LEFT JOIN` rewrite; still **materialized views** (not incremental) |
| `mindshare_md_fix` | 3 fixed API functions | Bugs 2/3/4 fixed; **not promoted** to prod |
| `mindshare_score_md_fix` | `mv_engagement_features_*` MVs, `create_engagement_clustering_features_view`, `calculate_decay_scores` (loop), `contribution_scores`, etc. | the feature MVs + loop are now superseded (see C) |

---

## C. Old objects — superseded / removable

Ordered by safety. **Nothing here is dropped automatically** — each needs the replacement wired
into callers first.

| Old object | Superseded by | When safe to remove |
|---|---|---|
| `mindshare_score_md_fix.mv_engagement_features_<project>` (feature MVs) | `features_<project>` tables | after app/API reads the tables (API fn already repointed) |
| `mindshare_score_md_fix.create_engagement_clustering_features_view` | `build_features_full` | with the MVs above |
| `mindshare_score_md_fix.calculate_decay_scores` (loop) | `calculate_decay_scores_fast` | after fast version validated at full scale + wired into pipeline |
| `mindshare.calculate_decay_scores(text)` | dead — never worked (writes to nonexistent table) | drop now (no callers; see summary.md §9) |
| `mindshare.calculate_all_decay_scores()` | dead | drop now |
| `mindshare.calculate_scores_by_project(text)` | dead | drop now |
| `mindshare.calculate_all_scores_parallel()` | dead | drop now |
| `mindshare_score.contribution_scores_mv` | empty legacy matview | drop now (0 rows, no dependents) |
| `mindshare_score_md_fix._bench_log` | — | drop anytime (my scratch) |

### Removal SQL (run after confirming callers)
```sql
-- feature MVs once API/app uses features_<project>:
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname='mindshare_score_md_fix'
           AND matviewname LIKE 'mv_engagement_features_%' LOOP
    EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS mindshare_score_md_fix.%I CASCADE', r.matviewname);
  END LOOP;
END $$;
DROP PROCEDURE IF EXISTS mindshare_score_md_fix.create_engagement_clustering_features_view(text);

-- decay loop once fast version is the pipeline default:
DROP PROCEDURE IF EXISTS mindshare_score_md_fix.calculate_decay_scores(text, interval);

-- dead production legacy (verified no callers in earlier analysis — re-verify):
DROP FUNCTION IF EXISTS mindshare.calculate_decay_scores(text);
DROP FUNCTION IF EXISTS mindshare.calculate_all_decay_scores();
DROP FUNCTION IF EXISTS mindshare.calculate_scores_by_project(text);
DROP FUNCTION IF EXISTS mindshare.calculate_all_scores_parallel();
DROP MATERIALIZED VIEW IF EXISTS mindshare_score.contribution_scores_mv;

-- benchmark scratch:
DROP TABLE IF EXISTS mindshare_score_md_fix._bench_log;
```

---

## D. Repo files added

| File | Contains |
|---|---|
| [`Mindshare_Backend/Mindshare_score_md_fix/functions/incremental_features.sql`](../../Mindshare_Backend/Mindshare_score_md_fix/functions/incremental_features.sql) | feature table + watermark + build/refresh/orchestrator procs + repointed API fn |
| [`Mindshare_Backend/Mindshare_score_md_fix/functions/decay_set_based.sql`](../../Mindshare_Backend/Mindshare_score_md_fix/functions/decay_set_based.sql) | set-based project + global decay procs |
| `docs/comparisons/*.md` | this comparison set |

> The DB is the source of truth for what is deployed; these `.sql` files are kept in sync so the
> changes are reviewable and replayable. Re-running a file is idempotent (`CREATE OR REPLACE`,
> `CREATE TABLE IF NOT EXISTS`).
