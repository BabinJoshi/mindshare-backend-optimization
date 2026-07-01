# Feature Matview — Performance & Incremental Refresh Plan

**Problem:** `create_engagement_clustering_features_view` takes 5–10 min per large project.  
**Root causes found via EXPLAIN ANALYZE:**  
1. `work_mem = 4MB` (default) → every HashAggregate spills to disk  
2. `user_engagement_history` LAG window → O(engagements × authors) cross join  
3. Full recompute on every refresh — no incremental logic  

---

## What Was Already Fixed (md_fix schemas)

| Fix | CTE affected | Impact |
|-----|-------------|--------|
| `RANGE BETWEEN float` → hourly bucket `GROUP BY` | `burst_windows` | O(n×w) → O(n log n) |
| LEFT JOIN IS NULL replacing NOT EXISTS | engagement matviews | O(n²) → O(n) hash anti-join |
| UNIQUE index on engaged_tweet_id | all engagement matviews | enables CONCURRENTLY refresh |
| NOT EXISTS → LEFT JOIN IS NULL | analytics engagement CTEs | eliminates correlated subquery |

---

## Level 1: work_mem — Immediate, Zero Risk (est. 2–4× speedup)

**Problem:** Default `work_mem = 4MB`. For quipnetwork's root_stats GROUP BY (~2.84M rows):
- With 4MB: 100+ disk spill batches, dominates refresh time  
- With 256MB: 1 batch, pure in-memory hash — **2.7× speedup measured on acurast (348ms → 85ms)**

**Measured evidence (acurast 114K rows):**

| work_mem | root_stats Batches | Disk usage | CTE time |
|---|---|---|---|
| 4MB | 5 | 7 MB | 228ms |
| 256MB | 1 | 0 | 60ms |

**Fix:** Set `work_mem` in the refresh procedure, not globally (global 256MB × max_connections = OOM risk):

```sql
CREATE OR REPLACE PROCEDURE mindshare_score_md_fix.create_engagement_clustering_features_view(
    IN project_keyword text
)
LANGUAGE plpgsql AS $procedure$
DECLARE
    ...
BEGIN
    -- Set for this session only — not a global change
    SET LOCAL work_mem = '512MB';
    ...
    EXECUTE format($sql$ CREATE MATERIALIZED VIEW ... $sql$, ...);
    ...
END;
$procedure$;
```

For quipnetwork root_stats (~2.84M rows), in-memory hash needs ~475MB. Set `512MB` for safety.

**Estimated quipnetwork refresh time after this fix:** 10 min → ~3–4 min.

---

## Level 2: pre-aggregate root_stats as separate MV (est. additional 30–50% speedup)

**Problem:** Every feature refresh re-scans the full analytics engagement matview just to compute per-post counts (total_engagements, min/max timestamps, p90).

`root_stats` is a pure GROUP BY — if a post got no new engagements since last refresh, its row is identical to what was computed before. Currently we recompute it from scratch every time.

**Fix:** Store `root_stats` as its own MV, refreshable CONCURRENTLY:

```sql
CREATE MATERIALIZED VIEW analytics_md_fix.mv_root_stats_quipnetwork AS
SELECT
    root_post_id,
    root_user_id,
    root_username,
    root_tweet_created_at,
    COUNT(engaged_tweet_id) AS total_engagements,      -- only count real engagements
    MIN(engaged_tweet_created_at) AS first_engagement,
    MAX(engaged_tweet_created_at) AS last_engagement,
    TO_TIMESTAMP(
        PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM engaged_tweet_created_at))
    ) AS p90_engagement
FROM analytics_md_fix.mv_engagement_quipnetwork
GROUP BY root_post_id, root_user_id, root_username, root_tweet_created_at;

CREATE UNIQUE INDEX ON analytics_md_fix.mv_root_stats_quipnetwork (root_post_id);
```

The feature MV then reads `FROM analytics_md_fix.mv_root_stats_quipnetwork` instead of recomputing root_stats inline. This CTE goes from a 2.84M row scan + sort to an index scan.

**Benefit:** root_stats refresh can run independently (it's cheap — just GROUP BY). Feature MV refresh only needs to read already-aggregated summaries.

---

## Level 3: Incremental Feature Refresh via Watermark Table

**PostgreSQL has no native incremental MV.** The pattern that works:  
→ Convert the MV to a regular TABLE + implement a procedure that recomputes only "hot" posts.

### Why it works for this workload

Most posts are "cold" after initial engagement burst (first 24–48h). A post's farming_score, burst_concentration, and cross_post_overlap are stable after the burst window passes. Only posts with NEW engagements since last refresh need recomputation.

For quipnetwork: if 5% of posts get new engagements per day, incremental refresh processes 5% of data → ~20× faster daily job.

### Schema changes

```sql
-- 1. Replace MV with regular table
CREATE TABLE mindshare_score_md_fix.features_quipnetwork (
    root_post_id        TEXT PRIMARY KEY,
    root_user_id        TEXT,
    root_username       TEXT,
    root_tweet_created_at TIMESTAMPTZ,
    total_engagements   BIGINT,
    burst_concentration NUMERIC,
    duration_days_p90   NUMERIC,
    cross_post_overlap  NUMERIC,
    prev_post_overlap   NUMERIC DEFAULT 0,
    coordinated_burst   NUMERIC,
    farming_score       NUMERIC,
    computed_at         TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Watermark table
CREATE TABLE mindshare_score_md_fix.refresh_watermarks (
    project_keyword          TEXT PRIMARY KEY,
    last_full_refresh_at     TIMESTAMPTZ,
    last_incremental_at      TIMESTAMPTZ,
    last_max_engagement_id   TEXT        -- max engaged_tweet_id processed
);
```

### Incremental refresh procedure logic

```sql
CREATE OR REPLACE PROCEDURE mindshare_score_md_fix.refresh_features_incremental(
    p_project TEXT,
    p_force_full BOOLEAN DEFAULT FALSE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_base_view TEXT := 'analytics_md_fix.mv_engagement_' || lower(replace(p_project, ' ', '_'));
    v_features  TEXT := 'mindshare_score_md_fix.features_' || lower(replace(p_project, ' ', '_'));
    v_watermark TIMESTAMPTZ;
    v_hot_author_count INT;
BEGIN
    SET LOCAL work_mem = '512MB';

    IF NOT p_force_full THEN
        SELECT last_incremental_at INTO v_watermark
        FROM mindshare_score_md_fix.refresh_watermarks
        WHERE project_keyword = p_project;
    END IF;

    -- Step 1: Find root_user_ids with new engagements since watermark
    -- Step 2: Find ALL root_post_ids by those authors (cross_post_overlap needs full history)
    -- Step 3: Run 12-CTE pipeline on that subset only
    -- Step 4: UPSERT into features table
    -- Step 5: Update watermark

    EXECUTE format($q$
        WITH hot_authors AS (
            SELECT DISTINCT root_user_id
            FROM %s
            WHERE engaged_tweet_created_at > %L
              AND engaged_tweet_created_at IS NOT NULL
        ),
        hot_posts AS (
            SELECT DISTINCT root_post_id
            FROM %s
            WHERE root_user_id IN (SELECT root_user_id FROM hot_authors)
        ),
        -- ... full 12-CTE pipeline here, but filtered to hot_posts ...
        -- Final: UPSERT
        INSERT INTO %s (...) SELECT ... FROM pipeline
        ON CONFLICT (root_post_id) DO UPDATE SET
            total_engagements = EXCLUDED.total_engagements,
            farming_score = EXCLUDED.farming_score,
            -- ... all columns
            computed_at = NOW();
    $q$, v_base_view, v_watermark, v_base_view, v_features);

    -- Update watermark
    INSERT INTO mindshare_score_md_fix.refresh_watermarks (project_keyword, last_incremental_at)
    VALUES (p_project, NOW())
    ON CONFLICT (project_keyword) DO UPDATE SET last_incremental_at = NOW();
END;
$$;
```

### Refresh schedule with this approach

| Job | Frequency | Scope | Est. time |
|-----|-----------|-------|-----------|
| Incremental | Hourly | Posts with new engagements in last 1h | < 30s |
| Incremental | Daily | Posts with new engagements since yesterday | < 2 min |
| Full rebuild | Weekly | All posts, all history | 3–5 min (with work_mem fix) |

---

## Level 4: Partition Analytics Matviews by Time (most scalable, structural change)

**Problem:** As projects grow, even incremental refresh gets slower because the analytics MV (source) keeps growing. quipnetwork analytics is already 1.4GB.

**Fix:** Partition `analytics_md_fix.mv_engagement_*` into immutable time slices:

```
analytics_md_fix.mv_engagement_quipnetwork_2024     -- immutable, never refreshed
analytics_md_fix.mv_engagement_quipnetwork_2025     -- immutable
analytics_md_fix.mv_engagement_quipnetwork_2026_q1  -- immutable after Mar 31
analytics_md_fix.mv_engagement_quipnetwork_current  -- last 30 days, refreshed nightly
```

Feature computation for incremental: only reads from `_current` slice (< 5MB vs 1.4GB).  
Cross-post overlap for historical accuracy: reads from `_current` + joins a pre-aggregated "author engagement summary" table that covers all history.

**Trade-off:** Requires restructuring the analytics create procedure. One-time migration effort ~2-3 days.

---

## Summary: Recommended Rollout Order

| Phase | Change | Effort | Expected speedup |
|-------|--------|--------|-----------------|
| **P1 (now)** | Add `SET LOCAL work_mem = '512MB'` in refresh procedure | 5 min | 2–4× |
| **P2 (week 1)** | Pre-compute `mv_root_stats_*` per project | 1 day | additional 30–50% |
| **P3 (week 2–3)** | Convert feature MV → table, implement watermark incremental | 3 days | daily refresh < 2 min |
| **P4 (month 2)** | Partition analytics MVs by time period | 1 week | indefinitely scalable |

### P1 alone gets refresh from 10 min → ~3–4 min with no risk.  
### P1 + P3 gets daily incremental refresh under 2 min.

---

## Cross_post_overlap — Correctness Constraint on Incremental

The one CTE that complicates incremental refresh is `user_engagement_history`:

```sql
user_engagement_history AS (
    SELECT b.root_post_id, b.engaged_user_id, p.root_user_id, p.post_rank,
           LAG(p.post_rank) OVER (PARTITION BY p.root_user_id, b.engaged_user_id ORDER BY p.post_rank)
    FROM (SELECT DISTINCT root_post_id, engaged_user_id FROM base) b
    JOIN ranked_post_order p ON p.root_post_id = b.root_post_id
)
```

**Cross-post overlap requires knowing ALL posts by an author, not just recently engaged ones.** A new engagement on post A by user X is only "cross-post" if X also engaged post B by the same author.

**Solution in incremental mode:**
- When recomputing features for "hot" author's posts: still query full history for that author
- Scope: `WHERE root_user_id IN (hot_authors)` — limits to authors with recent activity, but reads their complete history
- If 5% of authors are hot per day: 95% of the expensive LAG window computation is skipped
