-- Batch 5: USDJPY local-hours depreciation (Breedon and Ranaldo 2013), rules frozen in the ledger before this runner existed.
create or replace function intelligence.usdjpy_session_windows()
returns table(trade_date date, tokyo_open numeric, tokyo_close numeric, tokyo_pips numeric, london_pips numeric, ny_open numeric, ny_close numeric, ny_pips numeric)
language sql stable set search_path to '' as $function$
  with inst as (select id from core.instruments where symbol = 'USDJPY'),
  bars as (select b.ts, b.open, b.close from market.price_bars b, inst where b.instrument_id = inst.id and b.timeframe = '15m'),
  days as (select distinct (ts at time zone 'UTC')::date d from bars where extract(isodow from ts at time zone 'UTC') between 1 and 5)
  select dd.d, t0.open, t1.close, round((t1.close - t0.open) * 100, 4),
         round((l1.close - l0.open) * 100, 4), n0.open, n1.close, round((n1.close - n0.open) * 100, 4)
  from days dd
  left join bars t0 on t0.ts = dd.d::timestamp at time zone 'UTC'
  left join bars t1 on t1.ts = dd.d::timestamp at time zone 'UTC' + interval '6 hours 45 minutes'
  left join bars l0 on l0.ts = dd.d::timestamp at time zone 'UTC' + interval '7 hours'
  left join bars l1 on l1.ts = dd.d::timestamp at time zone 'UTC' + interval '12 hours 45 minutes'
  left join bars n0 on n0.ts = dd.d::timestamp at time zone 'UTC' + interval '13 hours'
  left join bars n1 on n1.ts = dd.d::timestamp at time zone 'UTC' + interval '20 hours 45 minutes'
  order by dd.d;
$function$;
revoke all on function intelligence.usdjpy_session_windows() from public, anon, authenticated;

create or replace function intelligence.run_batch5(p_key text, p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare net double precision[]; dates date[]; net2 double precision[]; trades jsonb; bench jsonb;
  sm double precision; ssd double precision; sn integer; bm double precision; bsd double precision; bn integer; wt double precision; wp double precision;
begin
  if p_key = 'usdjpy-tokyo-hours-jpy-depreciation' then
    select array_agg((x.tokyo_pips - 1.8)::float8 order by x.trade_date), array_agg(x.trade_date order by x.trade_date), array_agg((x.tokyo_pips - 3.6)::float8 order by x.trade_date),
           jsonb_agg(jsonb_build_object('date', x.trade_date, 'side', 1, 'entry', x.tokyo_open, 'exit', x.tokyo_close, 'gross_pips', x.tokyo_pips, 'net_pips', x.tokyo_pips - 1.8) order by x.trade_date)
      into net, dates, net2, trades from intelligence.usdjpy_session_windows() x where x.tokyo_pips is not null;
    select avg(x.tokyo_pips), stddev_samp(x.tokyo_pips), count(*) into sm, ssd, sn from intelligence.usdjpy_session_windows() x where x.tokyo_pips is not null;
    select avg(x.ny_pips), stddev_samp(x.ny_pips), count(*) into bm, bsd, bn from intelligence.usdjpy_session_windows() x where x.ny_pips is not null;
    wt := (sm - bm) / sqrt(ssd ^ 2 / sn + bsd ^ 2 / bn); wp := 1 - intelligence.norm_cdf(wt);
    bench := jsonb_build_object('tokyo_gross_mean_pips', sm, 'tokyo_n', sn, 'new_york_gross_mean_pips', bm, 'new_york_n', bn, 'welch_t', wt, 'welch_p_one_sided', wp);
  elsif p_key = 'usdjpy-new-york-hours-usd-depreciation' then
    select array_agg((-x.ny_pips - 1.8)::float8 order by x.trade_date), array_agg(x.trade_date order by x.trade_date), array_agg((-x.ny_pips - 3.6)::float8 order by x.trade_date),
           jsonb_agg(jsonb_build_object('date', x.trade_date, 'side', -1, 'entry', x.ny_open, 'exit', x.ny_close, 'gross_pips', -x.ny_pips, 'net_pips', -x.ny_pips - 1.8) order by x.trade_date)
      into net, dates, net2, trades from intelligence.usdjpy_session_windows() x where x.ny_pips is not null;
    select avg(x.london_pips), stddev_samp(x.london_pips), count(*) into sm, ssd, sn from intelligence.usdjpy_session_windows() x where x.london_pips is not null;
    select avg(x.ny_pips), stddev_samp(x.ny_pips), count(*) into bm, bsd, bn from intelligence.usdjpy_session_windows() x where x.ny_pips is not null;
    wt := (sm - bm) / sqrt(ssd ^ 2 / sn + bsd ^ 2 / bn); wp := 1 - intelligence.norm_cdf(wt);
    bench := jsonb_build_object('london_gross_mean_pips', sm, 'london_n', sn, 'new_york_gross_mean_pips', bm, 'new_york_n', bn, 'welch_t', wt, 'welch_p_one_sided', wp);
  else
    raise exception 'no batch-5 runner for %', p_key;
  end if;
  return intelligence.judge_and_store(p_key, 'USDJPY', 'pips', net, dates, net2, 300, 0.025, bench, wp <= 0.05, trades, p_persist);
end $function$;
revoke all on function intelligence.run_batch5(text, boolean) from public, anon, authenticated;
