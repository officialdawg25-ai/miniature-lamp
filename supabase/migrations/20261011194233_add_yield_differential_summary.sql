-- Read-only summary of the as-of US minus Japan yield differential for the research views.
-- Statistics use only pairings whose Japan value is at most 7 days old; the latest pairing is reported separately
-- with its own staleness flag so a stale Japan value is never presented as current.
create or replace function market.yield_differential_summary()
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog, market
as $$
  with v as (select * from market.v_yield_differential_asof where diff_10y is not null),
  fresh as (select * from v where not coalesce(jp_stale, true)),
  latest as (select * from v order by us_ts desc limit 1),
  latest_fresh as (select * from fresh order by us_ts desc limit 1),
  win as (select diff_10y from fresh order by us_ts desc limit 252),
  stats as (select avg(diff_10y) as m, stddev_pop(diff_10y) as sd, count(*) as n from win)
  select jsonb_build_object(
    'latest', (select to_jsonb(l) from latest l),
    'latest_fresh', (select to_jsonb(f) from latest_fresh f),
    'observations', (select count(*) from v),
    'stale_observations', (select count(*) from v where jp_stale),
    'window_observations', (select n from stats),
    'window_mean_10y', (select round(m::numeric, 4) from stats),
    'window_sd_10y', (select round(sd::numeric, 4) from stats),
    'latest_fresh_zscore_252', (select round(((f.diff_10y - s.m) / nullif(s.sd, 0))::numeric, 3) from latest_fresh f, stats s),
    'latest_fresh_percentile_252', (select round((count(*) filter (where w.diff_10y <= f.diff_10y))::numeric / nullif(count(*), 0), 3) from win w, latest_fresh f),
    'latest_fresh_change_20_obs', (select round((f.diff_10y - (select diff_10y from fresh order by us_ts desc offset 20 limit 1))::numeric, 3) from latest_fresh f),
    'us_real_10y_latest', (select us_real_10y from latest),
    'us_real_10y_change_20_obs', (select round(((select us_real_10y from latest) - (select us_real_10y from v order by us_ts desc offset 20 limit 1))::numeric, 3))
  );
$$;

revoke all on function market.yield_differential_summary() from public, anon, authenticated;
grant execute on function market.yield_differential_summary() to service_role;
