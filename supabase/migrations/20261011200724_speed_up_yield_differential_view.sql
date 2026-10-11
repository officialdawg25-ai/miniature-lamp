-- The first version of this view looked up the latest Japan value with a lateral subquery per US row (about 12M
-- comparisons), taking ~11s. The API role times out at 8s, so data-health received an error. This version merges the
-- US and Japan events in one sorted pass and carries the latest Japan timestamp forward with a running maximum.
-- Output columns and values are identical (verified by checksum). Assumes a series' availability time increases with
-- its observation date, which holds because availability is set to observation date + 2 days.
create or replace view market.v_yield_differential_asof
with (security_invoker = true) as
with us as (
  select ts, yield, real_yield, (metadata ->> 'available_at')::timestamptz as avail
  from market.yield_observations where market_code = 'US' and tenor_years = 10
), u2 as (
  select ts, yield from market.yield_observations where market_code = 'US' and tenor_years = 2
), jp10 as (
  select ts, yield, (metadata ->> 'available_at')::timestamptz as avail
  from market.yield_observations where market_code = 'JP' and tenor_years = 10
), jp2 as (
  select ts, yield, (metadata ->> 'available_at')::timestamptz as avail
  from market.yield_observations where market_code = 'JP' and tenor_years = 2
), events as (
  select avail, 1 as k, ts as us_ts, null::timestamptz as jp10_ts, null::timestamptz as jp2_ts from us
  union all select avail, 0, null::timestamptz, ts, null::timestamptz from jp10
  union all select avail, 0, null::timestamptz, null::timestamptz, ts from jp2
), stamped as (
  select avail, k, us_ts,
         max(jp10_ts) over w as jp10_asof,
         max(jp2_ts) over w as jp2_asof
  from events
  window w as (order by avail, k rows between unbounded preceding and current row)
)
select
  us.ts                                         as us_ts,
  us.avail                                      as as_of,
  us.yield                                      as us_10y,
  us.real_yield                                 as us_real_10y,
  u2.yield                                      as us_2y,
  s.jp10_asof                                   as jp_10y_ts,
  j10.yield                                     as jp_10y,
  j2.yield                                      as jp_2y,
  us.avail::date - s.jp10_asof::date            as jp_age_days,
  (us.avail::date - s.jp10_asof::date) > 7      as jp_stale,
  us.yield - j10.yield                          as diff_10y,
  u2.yield - j2.yield                           as diff_2y
from stamped s
join us on s.k = 1 and us.ts = s.us_ts
left join u2 on u2.ts = us.ts
left join jp10 j10 on j10.ts = s.jp10_asof
left join jp2 j2 on j2.ts = s.jp2_asof;
