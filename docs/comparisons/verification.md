# Verification & Self-Test Runbook

Two parts:
- **Part A — Test it yourself**: copy-paste steps you run to convince yourself the incremental
  pipeline is correct and fast.
- **Part B — Evidence log**: the exact queries already run and the results obtained (2026-06-30,
  PostgreSQL 16.11).

All objects live in `mindshare_score_md_fix`. Nothing here touches production or `test_*`.

---

## Part A — Test it yourself

### A0. Pre-flight — what exists

```sql
SELECT tablename FROM pg_tables WHERE schemaname='mindshare_score_md_fix' AND tablename LIKE 'features_%' ORDER BY 1;
SELECT * FROM mindshare_score_md_fix.feature_watermarks ORDER BY project;
```
Expect 11 `features_<project>` tables and one watermark row per built project.

### A1. Correctness — new table == old materialized view

Pick a project that still has the old MV (e.g. `sleepagotchi`). Compare every row and value.
Round numerics so floating-point noise doesn't create false diffs.

```sql
WITH mvv AS (
  SELECT root_post_id, total_engagements, round(burst_concentration,6) bc,
         round(duration_days_p90,6) dp, round(cross_post_overlap,2) cpo,
         round(coordinated_burst,6) cb, round(farming_score,4) fs
  FROM mindshare_score_md_fix.mv_engagement_features_sleepagotchi),
tbl AS (
  SELECT root_post_id, total_engagements, round(burst_concentration,6) bc,
         round(duration_days_p90,6) dp, round(cross_post_overlap,2) cpo,
         round(coordinated_burst,6) cb, round(farming_score,4) fs
  FROM mindshare_score_md_fix.features_sleepagotchi)
SELECT (SELECT count(*) FROM mvv) AS mv_rows,
       (SELECT count(*) FROM tbl) AS tbl_rows,
       (SELECT count(*) FROM (SELECT * FROM mvv EXCEPT SELECT * FROM tbl) a) AS in_mv_not_tbl,
       (SELECT count(*) FROM (SELECT * FROM tbl EXCEPT SELECT * FROM mvv) b) AS in_tbl_not_mv;
```
✅ **PASS = `in_mv_not_tbl = 0` AND `in_tbl_not_mv = 0`** (row counts equal).

### A2. Incremental actually recomputes the right rows (corruption test)

This is the strongest test: deliberately wreck the rows incremental should fix, run incremental,
confirm they are healed. (Run on a project with an old MV to compare against, e.g. sleepagotchi.)

```sql
-- 1. rewind the watermark 1 day so the last day's authors become "hot"
UPDATE mindshare_score_md_fix.feature_watermarks
SET last_engaged_at = (SELECT max(engaged_tweet_created_at) FROM analytics_md_fix.mv_engagement_sleepagotchi) - interval '1 day'
WHERE project='sleepagotchi';

-- 2. corrupt every row incremental is supposed to touch
UPDATE mindshare_score_md_fix.features_sleepagotchi
SET farming_score = -999, total_engagements = -1
WHERE root_user_id IN (
  SELECT DISTINCT root_user_id FROM analytics_md_fix.mv_engagement_sleepagotchi
  WHERE engaged_tweet_created_at > (SELECT max(engaged_tweet_created_at) FROM analytics_md_fix.mv_engagement_sleepagotchi) - interval '1 day');

SELECT count(*) AS corrupted FROM mindshare_score_md_fix.features_sleepagotchi WHERE farming_score=-999;  -- > 0

-- 3. run incremental
CALL mindshare_score_md_fix.refresh_features_incremental('sleepagotchi');

-- 4. verify: nothing left corrupt, and table again matches the MV
SELECT
 (SELECT count(*) FROM mindshare_score_md_fix.features_sleepagotchi WHERE farming_score=-999) AS still_corrupt,
 (SELECT count(*) FROM (
    SELECT root_post_id, round(farming_score,4) fs FROM mindshare_score_md_fix.features_sleepagotchi
    EXCEPT
    SELECT root_post_id, round(farming_score,4) FROM mindshare_score_md_fix.mv_engagement_features_sleepagotchi) d) AS diff_vs_mv;
```
✅ **PASS = `still_corrupt = 0` AND `diff_vs_mv = 0`.**

### A3. Time it — full vs incremental

```sql
-- FULL build
DO $$ DECLARE t0 timestamptz:=clock_timestamp();
BEGIN CALL mindshare_score_md_fix.build_features_full('quipnetwork');
  RAISE NOTICE 'full build: % ms', round(EXTRACT(epoch FROM clock_timestamp()-t0)*1000);
END $$;

-- INCREMENTAL after 1 day of "new" data
UPDATE mindshare_score_md_fix.feature_watermarks
SET last_engaged_at=(SELECT max(engaged_tweet_created_at) FROM analytics_md_fix.mv_engagement_quipnetwork)-interval '1 day'
WHERE project='quipnetwork';
DO $$ DECLARE t0 timestamptz:=clock_timestamp();
BEGIN CALL mindshare_score_md_fix.refresh_features_incremental('quipnetwork');
  RAISE NOTICE 'incremental: % ms', round(EXTRACT(epoch FROM clock_timestamp()-t0)*1000);
END $$;
```
The `RAISE NOTICE` lines print in `psql`. Expect full ≈ minutes, incremental ≈ seconds.
(The repo also logs every run to `mindshare_score_md_fix._bench_log` — `SELECT * FROM …_bench_log ORDER BY id;`.)

### A4. API query speed — table vs old MV

```sql
-- old MV
EXPLAIN (ANALYZE, BUFFERS) SELECT root_post_id, farming_score FROM mindshare_score_md_fix.mv_engagement_features_sleepagotchi
WHERE root_tweet_created_at >= to_timestamp(1781418927) AND root_tweet_created_at <= to_timestamp(1781591927)
ORDER BY farming_score DESC LIMIT 100;
-- new table
EXPLAIN (ANALYZE, BUFFERS) SELECT root_post_id, farming_score FROM mindshare_score_md_fix.features_sleepagotchi
WHERE root_tweet_created_at >= to_timestamp(1781418927) AND root_tweet_created_at <= to_timestamp(1781591927)
ORDER BY farming_score DESC LIMIT 100;
```
✅ Old shows `Parallel Seq Scan … Sort`; new shows `Index Scan Backward using ix_features_sleepagotchi_score` with a far lower `Execution Time`.

### A5. Reset to a clean state

```sql
CALL mindshare_score_md_fix.build_features_full('sleepagotchi');   -- rebuilds + resets watermark
```

---

## Part B — Evidence log (results obtained 2026-06-30)

### Correctness (A1, A2)
| Check | Result |
|---|---|
| sleepagotchi table vs MV — rows | 760,154 = 760,154 |
| sleepagotchi table vs MV — `EXCEPT` both directions | **0 / 0** (re-confirmed on 2 runs) |
| corruption test — rows corrupted then healed | 251,513 corrupted → **0 still corrupt** |
| corruption test — diff vs MV after incremental | **0** |
| after full→incremental cycle — diff vs MV | **0** |

### Latency — refresh
| Project | Method | Rows out | Time |
|---|---|---|---|
| sleepagotchi | OLD full MV rebuild | 760,154 | 60.7 s |
| sleepagotchi | NEW full table build | 760,154 | 50.0 s cold / 35.3 s warm |
| sleepagotchi | NEW incremental (1-day) | — | 16.5 s / 17.4 s |
| quipnetwork | NEW full table build | 2,805,629 | **172.7 s (2.9 min)** |
| quipnetwork | NEW incremental (1-day) | — | **6.2 s / 2.2 s** |

> **quipnetwork "used to take ~3 minutes" — confirmed.** A *full* rebuild is still ~2.9 min
> (same heavy 12-CTE logic; full rebuild was never the target of the optimization). The change
> is that daily operation no longer needs a full rebuild: **incremental does it in 2–6 s**, a
> **~30–80×** reduction for the recurring job.

### Latency — `get_engagement_clustering` top-100, 2-day window
| Backing store | Execution time | Plan |
|---|---|---|
| old MV | 59.3 / 64.2 ms | parallel seq scan + top-N sort |
| new table | 0.54 / 1.28 ms | index-backward scan on `farming_score`, stops at 100 |

### Rollout build times (all 11 tables, 1.97 GB total)
technotainment / cnpynetwork / acurast / d3lmundos / ironallies / nucleus: small (batched);
pact_swap 49 s · yom_official 49 s · thearcterminal 95 s · quipnetwork 173 s.

### Sanity
- quipnetwork: 2,805,629 rows, **100%** with `farming_score` in `[0,100]`.
- Source matview already has `ix_mv_engagement_<project>_eng_created`; the incremental hot-author
  scope subquery uses it (sleepagotchi 1-day = 20.7 ms). No additional base-table index needed.
