-- Event-study engine for intraday hypotheses on 15-minute bars (bar ts = bar open, UTC; verified: the release spike sits in the bar stamped with the release time).
-- Every trade is returned and stored; statistics are computed from the stored trades. Research only: no orders, no status changes.
-- Point in time: gotobi dates are a fixed calendar rule; US release times come from the official BLS schedule published in advance; signals use only bars that have closed.

-- Standard normal CDF (Abramowitz and Stegun 7.1.26 for erf, error below 1.5e-7). The square is parenthesised: in Postgres unary minus binds tighter than ^.
create or replace function intelligence.norm_cdf(x double precision)
returns double precision language sql immutable set search_path to '' as $$
  select case when x < 0 then 1 - intelligence.norm_cdf(-x) else
    1 - 0.5 * (t * exp(-((x / sqrt(2)) ^ 2)) * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))))) end
  from (select 1 / (1 + 0.3275911 * abs(x) / sqrt(2)) t) s;
$$;

-- Gotobi days: the 5th, 10th, 15th, 20th, 25th and last day of each month; a Saturday or Sunday moves to the preceding Friday.
-- Japanese public holidays are not modelled (no holiday calendar is stored), which mislabels a few days and can only dilute an effect.
create or replace function intelligence.gotobi_dates(p_from date, p_to date)
returns table(d date) language sql immutable set search_path to '' as $$
  select distinct case extract(isodow from g)::int when 6 then g - 1 when 7 then g - 2 else g end
  from (select gs::date g from generate_series(p_from, p_to, interval '1 day') gs) c
  where extract(day from g) in (5, 10, 15, 20, 25) or g = (date_trunc('month', g) + interval '1 month - 1 day')::date
  order by 1;
$$;

-- USDJPY Tokyo-fix window: buy at the open of the 00:00 UTC bar (09:00 JST), sell at the close of the 00:30 UTC bar (09:45 JST, ten minutes before the 09:55 fix).
-- A protective stop p_stop_pips below entry is hit if any bar in the window trades through it; it fills p_slip_pips worse. Round-trip cost p_cost_pips is charged on every trade.
create or replace function intelligence.trades_usdjpy_tokyo_window(p_cost_pips numeric, p_stop_pips numeric, p_slip_pips numeric)
returns table(trade_date date, is_gotobi boolean, entry numeric, exit_price numeric, stopped boolean, gross_pips numeric, net_pips numeric, net_usd_001 numeric)
language sql stable set search_path to '' as $$
  with inst as (select id from core.instruments where symbol = 'USDJPY'),
  bars as (select b.ts, b.open, b.high, b.low, b.close from market.price_bars b, inst where b.instrument_id = inst.id and b.timeframe = '15m'),
  days as (select ts::date d from bars where ts = date_trunc('day', ts) and extract(isodow from ts) between 1 and 5),
  w as (
    select dd.d, b0.open entry, b2.close c2, least(b0.low, b1.low, b2.low) lo
    from days dd
    join bars b0 on b0.ts = dd.d::timestamp at time zone 'UTC'
    join bars b1 on b1.ts = dd.d::timestamp at time zone 'UTC' + interval '15 minutes'
    join bars b2 on b2.ts = dd.d::timestamp at time zone 'UTC' + interval '30 minutes'),
  g as (select d from intelligence.gotobi_dates((select min(d) from days), (select max(d) from days)))
  select w.d, exists (select 1 from g where g.d = w.d), w.entry,
    case when w.lo <= w.entry - p_stop_pips * 0.01 then w.entry - (p_stop_pips + p_slip_pips) * 0.01 else w.c2 end,
    w.lo <= w.entry - p_stop_pips * 0.01,
    round(((case when w.lo <= w.entry - p_stop_pips * 0.01 then w.entry - (p_stop_pips + p_slip_pips) * 0.01 else w.c2 end) - w.entry) / 0.01, 4),
    round(((case when w.lo <= w.entry - p_stop_pips * 0.01 then w.entry - (p_stop_pips + p_slip_pips) * 0.01 else w.c2 end) - w.entry) / 0.01 - p_cost_pips, 4),
    round((((case when w.lo <= w.entry - p_stop_pips * 0.01 then w.entry - (p_stop_pips + p_slip_pips) * 0.01 else w.c2 end) - w.entry) / 0.01 - p_cost_pips) * 10 / w.c2, 6)
  from w order by w.d;
$$;

-- Post-release continuation: the direction of the release bar [T, T+15m) decides the side; enter at that bar's close, exit at the close of the bar starting T+105m (T+2h).
-- A release bar with no net move is skipped. p_cost is the round-trip cost in price units. P&L is also given for 0.01 lot (USDJPY 1,000 units, XAUUSD 1 oz).
create or replace function intelligence.trades_release_continuation(p_symbol text, p_releases text[], p_cost numeric)
returns table(release_at timestamptz, release_name text, side integer, entry numeric, exit_price numeric, gross numeric, net numeric, net_usd_001 numeric)
language sql stable set search_path to '' as $$
  with inst as (select id from core.instruments where symbol = p_symbol),
  bars as (select b.ts, b.open, b.close from market.price_bars b, inst where b.instrument_id = inst.id and b.timeframe = '15m'),
  ev as (select distinct on (c.scheduled_release_time) c.scheduled_release_time t, c.release_name n from macro.provider_release_calendars c
         where c.provider = 'BLS' and c.release_name = any (p_releases) and c.scheduled_release_time <= now() order by c.scheduled_release_time, c.release_name),
  x as (select ev.t, ev.n, sign(b0.close - b0.open)::int s, b0.close entry, bx.close ex
        from ev join bars b0 on b0.ts = ev.t join bars bx on bx.ts = ev.t + interval '105 minutes')
  select t, n, s, entry, ex, round(s * (ex - entry), 6), round(s * (ex - entry) - p_cost, 6),
    round(case when p_symbol = 'USDJPY' then (s * (ex - entry) - p_cost) * 1000 / ex else (s * (ex - entry) - p_cost) * 1 end, 6)
  from x where s <> 0 order by t;
$$;

-- Statistics from an ordered array of per-trade net results. One-sided t-test for a positive mean (normal approximation, stated as such),
-- bootstrap 95% interval for the mean with a fixed seed, chronological halves, last-12-months holdout, profit factor and the mean without the best 5% of trades.
create or replace function intelligence.trade_stats(p_net double precision[], p_dates date[], p_holdout_from date, p_reps integer default 2000)
returns jsonb language plpgsql set search_path to '' as $function$
declare n integer := coalesce(array_length(p_net, 1), 0); mean double precision; sd double precision; t double precision; boots double precision[] := '{}';
  s double precision; h integer; m1 double precision; m2 double precision; mh double precision; nh integer; pf double precision; trimmed double precision; k integer; wins integer;
begin
  if n < 2 then return jsonb_build_object('n', n, 'note', 'too few trades'); end if;
  select avg(v), stddev_samp(v), count(*) filter (where v > 0) into mean, sd, wins from unnest(p_net) v;
  t := case when sd > 0 then mean / (sd / sqrt(n)) else null end;
  perform setseed(0.20261013);
  for i in 1 .. p_reps loop
    s := 0; for j in 1 .. n loop s := s + p_net[1 + floor(random() * n)::int]; end loop;
    boots := array_append(boots, s / n);
  end loop;
  h := n / 2;
  select avg(v) into m1 from unnest(p_net[1:h]) v;
  select avg(v) into m2 from unnest(p_net[h + 1:n]) v;
  select avg(v), count(*) into mh, nh from unnest(p_net, p_dates) u(v, d) where d >= p_holdout_from;
  select sum(v) filter (where v > 0) / nullif(-sum(v) filter (where v < 0), 0) into pf from unnest(p_net) v;
  k := ceil(n * 0.05)::int;
  select avg(v) into trimmed from (select v from unnest(p_net) v order by v desc offset k) z;
  return jsonb_build_object('n', n, 'mean', mean, 'sd', sd, 't', t, 'p_one_sided', case when t is null then null else 1 - intelligence.norm_cdf(t) end,
    'p_method', 'normal approximation to the t distribution',
    'boot_ci_95', jsonb_build_array((select percentile_cont(0.025) within group (order by b) from unnest(boots) b), (select percentile_cont(0.975) within group (order by b) from unnest(boots) b)),
    'win_rate', wins::double precision / n, 'profit_factor', pf, 'first_half_mean', m1, 'second_half_mean', m2,
    'holdout_from', p_holdout_from, 'holdout_n', nh, 'holdout_mean', mh, 'mean_without_best_5pct', trimmed, 'removed_best', k,
    'first_date', p_dates[1], 'last_date', p_dates[n]);
end $function$;

revoke all on function intelligence.norm_cdf(double precision) from public, anon, authenticated;
revoke all on function intelligence.gotobi_dates(date, date) from public, anon, authenticated;
revoke all on function intelligence.trades_usdjpy_tokyo_window(numeric, numeric, numeric) from public, anon, authenticated;
revoke all on function intelligence.trades_release_continuation(text, text[], numeric) from public, anon, authenticated;
revoke all on function intelligence.trade_stats(double precision[], date[], date, integer) from public, anon, authenticated;
