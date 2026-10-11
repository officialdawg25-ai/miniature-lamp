-- As-of US minus Japan yield differential. Each US observation (known from its availability time) is paired with the
-- latest Japan observation whose own availability time is not later. jp_age_days shows how old the Japan value is,
-- and jp_stale marks pairings where it is more than 7 days old. Nothing is interpolated or filled forward silently.
create or replace view market.v_yield_differential_asof
with (security_invoker = true) as
select
  us.ts                                         as us_ts,
  (us.metadata ->> 'available_at')::timestamptz as as_of,
  us.yield                                      as us_10y,
  us.real_yield                                 as us_real_10y,
  u2.yield                                      as us_2y,
  j10.ts                                        as jp_10y_ts,
  j10.yield                                     as jp_10y,
  j2.yield                                      as jp_2y,
  ((us.metadata ->> 'available_at')::timestamptz)::date - j10.ts::date as jp_age_days,
  (((us.metadata ->> 'available_at')::timestamptz)::date - j10.ts::date) > 7 as jp_stale,
  us.yield - j10.yield                          as diff_10y,
  u2.yield - j2.yield                           as diff_2y
from market.yield_observations us
left join market.yield_observations u2
  on u2.market_code = 'US' and u2.tenor_years = 2 and u2.ts = us.ts
left join lateral (
  select j.ts, j.yield from market.yield_observations j
  where j.market_code = 'JP' and j.tenor_years = 10
    and (j.metadata ->> 'available_at')::timestamptz <= (us.metadata ->> 'available_at')::timestamptz
  order by (j.metadata ->> 'available_at')::timestamptz desc limit 1
) j10 on true
left join lateral (
  select j.yield from market.yield_observations j
  where j.market_code = 'JP' and j.tenor_years = 2
    and (j.metadata ->> 'available_at')::timestamptz <= (us.metadata ->> 'available_at')::timestamptz
  order by (j.metadata ->> 'available_at')::timestamptz desc limit 1
) j2 on true
where us.market_code = 'US' and us.tenor_years = 10;

revoke all on market.v_yield_differential_asof from public, anon, authenticated;
grant select on market.v_yield_differential_asof to service_role;
