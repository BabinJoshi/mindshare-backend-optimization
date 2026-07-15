----------------------------  CNPYNetwork  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement_cnpynetwork;



CALL analytics_md_fix.refresh_engagement_incremental('CNPYNetwork');


select count(*) from analytics.mv_engagement_cnpynetwork;
select count(*) from analytics_md_fix.mv_engagement_cnpynetwork;


with diff as (
    SELECT * FROM analytics.mv_engagement_cnpynetwork 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement_cnpynetwork
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement_cnpynetwork
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement_cnpynetwork
)
select count(*) from diff;

----------------------------  Acurast  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement_acurast;



CALL analytics_md_fix.refresh_engagement_incremental('Acurast');


select count(*) from analytics.mv_engagement_acurast;
select count(*) from analytics_md_fix.mv_engagement_acurast;


with diff as (
    SELECT * FROM analytics.mv_engagement_acurast 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement_acurast
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement_acurast
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement_acurast
)
select count(*) from diff;

----------------------------  IronAllies_  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement_ironallies_;



CALL analytics_md_fix.refresh_engagement_incremental('IronAllies_');


select count(*) from analytics.mv_engagement_ironallies_;
select count(*) from analytics_md_fix.mv_engagement_ironallies_;


with diff as (
    SELECT * FROM analytics.mv_engagement_ironallies_ 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement_ironallies_
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement_ironallies_
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement_ironallies_
)
select count(*) from diff;

----------------------------  D3lMundos  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement_d3lmundos;



CALL analytics_md_fix.refresh_engagement_incremental('D3lMundos');


select count(*) from analytics.mv_engagement_d3lmundos;
select count(*) from analytics_md_fix.mv_engagement_d3lmundos;


with diff as (
    SELECT * FROM analytics.mv_engagement_d3lmundos 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement_d3lmundos
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement_d3lmundos
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement_d3lmundos
)
select count(*) from diff;

----------------------------  EthraShip  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement_ethraship;



CALL analytics_md_fix.refresh_engagement_incremental('EthraShip');


select count(*) from analytics.mv_engagement_ethraship;
select count(*) from analytics_md_fix.mv_engagement_ethraship;


with diff as (
    SELECT * FROM analytics.mv_engagement_ethraship 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement_ethraship
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement_ethraship
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement_ethraship
)
select count(*) from diff;

----------------------------  NucleusCodes  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement_nucleuscodes;



CALL analytics_md_fix.refresh_engagement_incremental('NucleusCodes');


select count(*) from analytics.mv_engagement_nucleuscodes;
select count(*) from analytics_md_fix.mv_engagement_nucleuscodes;


with diff as (
    SELECT * FROM analytics.mv_engagement_nucleuscodes 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement_nucleuscodes
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement_nucleuscodes
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement_nucleuscodes
)
select count(*) from diff;

----------------------------  _technotainment  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement__technotainment;



CALL analytics_md_fix.refresh_engagement_incremental('_technotainment');


select count(*) from analytics.mv_engagement__technotainment;
select count(*) from analytics_md_fix.mv_engagement__technotainment;


with diff as (
    SELECT * FROM analytics.mv_engagement__technotainment 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement__technotainment
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement__technotainment
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement__technotainment
)
select count(*) from diff;


----------------------------  Pact_Swap  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement_pact_swap;



CALL analytics_md_fix.refresh_engagement_incremental('Pact_Swap');


select count(*) from analytics.mv_engagement_pact_swap;
select count(*) from analytics_md_fix.mv_engagement_pact_swap;


with diff as (
    SELECT * FROM analytics.mv_engagement_pact_swap 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement_pact_swap
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement_pact_swap
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement_pact_swap
)
select count(*) from diff;

----------------------------  YOM_Official  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement_yom_official;



CALL analytics_md_fix.refresh_engagement_incremental('YOM_Official');


select count(*) from analytics.mv_engagement_yom_official;
select count(*) from analytics_md_fix.mv_engagement_yom_official;


with diff as (
    SELECT * FROM analytics.mv_engagement_yom_official 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement_yom_official
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement_yom_official
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement_yom_official
)
select count(*) from diff;

----------------------------  TheARCTERMINAL  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement_thearcterminal;



CALL analytics_md_fix.refresh_engagement_incremental('TheARCTERMINAL');


select count(*) from analytics.mv_engagement_thearcterminal;
select count(*) from analytics_md_fix.mv_engagement_thearcterminal;


with diff as (
    SELECT * FROM analytics.mv_engagement_thearcterminal 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement_thearcterminal
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement_thearcterminal
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement_thearcterminal
)
select count(*) from diff;

----------------------------  sleepagotchi  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement_sleepagotchi;



CALL analytics_md_fix.refresh_engagement_incremental('sleepagotchi');


select count(*) from analytics.mv_engagement_sleepagotchi;
select count(*) from analytics_md_fix.mv_engagement_sleepagotchi;


with diff as (
    SELECT * FROM analytics.mv_engagement_sleepagotchi 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement_sleepagotchi
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement_sleepagotchi
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement_sleepagotchi
)
select count(*) from diff;

----------------------------  quipnetwork  ---------------------------

REFRESH MATERIALIZED VIEW analytics.mv_engagement_quipnetwork;



CALL analytics_md_fix.refresh_engagement_incremental('quipnetwork');


select count(*) from analytics.mv_engagement_quipnetwork;
select count(*) from analytics_md_fix.mv_engagement_quipnetwork;


with diff as (
    SELECT * FROM analytics.mv_engagement_quipnetwork 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_engagement_quipnetwork
)
--select count(*) from diff;
select * from diff 
order by diff.root_post_id ,root_user_id, diff.root_tweet_created_at 
limit 100;

with diff as (
    SELECT * FROM analytics_md_fix.mv_engagement_quipnetwork
    EXCEPT ALL
    SELECT * FROM analytics.mv_engagement_quipnetwork
)
select count(*) from diff;


--------------------------- User Engagement------------------------

REFRESH MATERIALIZED VIEW analytics.mv_user_posts_engagement;



CALL analytics_md_fix.refresh_user_posts_engagement_incremental();


select count(*) from analytics.mv_user_posts_engagement;
select count(*) from analytics_md_fix.mv_user_posts_engagement;


with diff as (
    SELECT * FROM analytics.mv_user_posts_engagement 
    EXCEPT ALL
    SELECT * FROM analytics_md_fix.mv_user_posts_engagement
)
select count(*) from diff;

with diff as (
    SELECT * FROM analytics_md_fix.mv_user_posts_engagement
    EXCEPT ALL
    SELECT * FROM analytics.mv_user_posts_engagement
)
select count(*) from diff;
