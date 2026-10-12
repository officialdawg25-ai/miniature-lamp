-- Batch 4 research functions (event-study-v2). Research only. Rules exactly as registered in the ledger.

-- USDJPY London breakout of the Tokyo range (usdjpy-london-breakout-tokyo-range).
create or replace function intelligence.trades_usdjpy_london_breakout(p_cost_pips numeric, p_slip_pips numeric)
returns table(trade_date date, side integer, range_pips numeric, entry numeric, stop numeric, exit_price numeric, stopped boolean, gross_pips numeric, net_pips numeric, net_usd_001 numeric)
language plpgsql stable set search_path to '' as $function$
declare inst uuid; d date; hi numeric; lo numeric; nb integer; mid numeric; b record; e_side integer; e_price numeric; e_ts timestamptz; x numeric; hit boolean;
begin
  select id into inst from core.instruments where symbol = 'USDJPY';
  for d in select distinct (b2.ts at time zone 'UTC')::date from market.price_bars b2 where b2.instrument_id = inst and b2.timeframe = '15m' and extract(isodow from b2.ts at time zone 'UTC') between 1 and 5 order by 1 loop
    select max(b2.high), min(b2.low), count(*) into hi, lo, nb from market.price_bars b2
      where b2.instrument_id = inst and b2.timeframe = '15m' and b2.ts >= d::timestamp at time zone 'UTC' and b2.ts < d::timestamp at time zone 'UTC' + interval '7 hours';
    continue when nb < 24 or (hi - lo) < 0.10 or (hi - lo) > 0.60;
    mid := (hi + lo) / 2; e_side := null;
    for b in select b2.ts, b2.close from market.price_bars b2 where b2.instrument_id = inst and b2.timeframe = '15m'
             and b2.ts >= d::timestamp at time zone 'UTC' + interval '7 hours' and b2.ts < d::timestamp at time zone 'UTC' + interval '11 hours' order by b2.ts loop
      if b.close > hi then e_side := 1; e_price := b.close; e_ts := b.ts; exit;
      elsif b.close < lo then e_side := -1; e_price := b.close; e_ts := b.ts; exit; end if;
    end loop;
    continue when e_side is null;
    hit := false; x := null;
    for b in select b2.ts, b2.high, b2.low, b2.close from market.price_bars b2 where b2.instrument_id = inst and b2.timeframe = '15m'
             and b2.ts > e_ts and b2.ts <= d::timestamp at time zone 'UTC' + interval '20 hours 30 minutes' order by b2.ts loop
      if (e_side = 1 and b.low <= mid) or (e_side = -1 and b.high >= mid) then hit := true; x := mid - e_side * p_slip_pips * 0.01; exit; end if;
      x := b.close;
    end loop;
    continue when x is null;
    trade_date := d; side := e_side; range_pips := round((hi - lo) / 0.01, 1); entry := e_price; stop := mid; exit_price := x; stopped := hit;
    gross_pips := round(e_side * (x - e_price) / 0.01, 4); net_pips := gross_pips - p_cost_pips; net_usd_001 := round(net_pips * 10 / x, 6);
    return next;
  end loop;
end $function$;

-- Gold session windows (xauusd-asia-london-session-drift): Asia+London = open of the 23:00 UTC bar the previous day to the close of the 12:45 UTC bar;
-- US = open of the 13:00 UTC bar to the close of the 20:45 UTC bar, same day. Both windows need their boundary bars.
create or replace function intelligence.gold_session_windows()
returns table(trade_date date, asia_open numeric, asia_close numeric, asia_gross numeric, us_open numeric, us_close numeric, us_gross numeric)
language sql stable set search_path to '' as $$
  with inst as (select id from core.instruments where symbol = 'XAUUSD'),
  bars as (select b.ts, b.open, b.close from market.price_bars b, inst where b.instrument_id = inst.id and b.timeframe = '15m'),
  days as (select distinct (ts at time zone 'UTC')::date d from bars where extract(isodow from ts at time zone 'UTC') between 1 and 5)
  select dd.d, a0.open, a1.close, a1.close - a0.open, u0.open, u1.close, u1.close - u0.open
  from days dd
  join bars a0 on a0.ts = (dd.d - 1)::timestamp at time zone 'UTC' + interval '23 hours'
  join bars a1 on a1.ts = dd.d::timestamp at time zone 'UTC' + interval '12 hours 45 minutes'
  left join bars u0 on u0.ts = dd.d::timestamp at time zone 'UTC' + interval '13 hours'
  left join bars u1 on u1.ts = dd.d::timestamp at time zone 'UTC' + interval '20 hours 45 minutes'
  order by dd.d;
$$;

-- Shared judge: applies the batch-4 criteria to an ordered array of per-trade net results and stores the run with every trade.
create or replace function intelligence.judge_and_store(p_key text, p_symbol text, p_unit text, p_net double precision[], p_dates date[], p_net_double_cost double precision[],
  p_min_n integer, p_alpha double precision, p_benchmark jsonb, p_benchmark_pass boolean, p_trades jsonb, p_persist boolean)
returns jsonb language plpgsql set search_path to '' as $function$
declare h record; base jsonb; dbl jsonb; checks jsonb; passed boolean; rid uuid; summary jsonb;
begin
  select * into h from intelligence.research_hypotheses where key = p_key;
  if not found then raise exception 'hypothesis % not registered', p_key; end if;
  base := intelligence.trade_stats(p_net, p_dates, '2025-10-13', 2000);
  dbl := intelligence.trade_stats(p_net_double_cost, p_dates, '2025-10-13', 200);
  checks := jsonb_build_array(
    jsonb_build_object('name', 'trades', 'value', base -> 'n', 'threshold', '>= ' || p_min_n, 'pass', (base ->> 'n')::int >= p_min_n),
    jsonb_build_object('name', 'one-sided p for a positive mean net result', 'value', base -> 'p_one_sided', 'threshold', '<= ' || round(p_alpha::numeric, 4), 'pass', coalesce((base ->> 'p_one_sided')::float8 <= p_alpha, false)),
    jsonb_build_object('name', 'first-half mean net', 'value', base -> 'first_half_mean', 'threshold', '> 0', 'pass', (base ->> 'first_half_mean')::float8 > 0),
    jsonb_build_object('name', 'second-half mean net', 'value', base -> 'second_half_mean', 'threshold', '> 0', 'pass', (base ->> 'second_half_mean')::float8 > 0),
    jsonb_build_object('name', 'holdout (from 2025-10-13) mean net', 'value', base -> 'holdout_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'holdout_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net at double costs', 'value', dbl -> 'mean', 'threshold', '> 0', 'pass', (dbl ->> 'mean')::float8 > 0),
    jsonb_build_object('name', 'mean net without the best 5% of trades', 'value', base -> 'mean_without_best_5pct', 'threshold', '> 0', 'pass', (base ->> 'mean_without_best_5pct')::float8 > 0),
    jsonb_build_object('name', 'profit factor', 'value', base -> 'profit_factor', 'threshold', '>= 1.2', 'pass', coalesce((base ->> 'profit_factor')::float8 >= 1.2, false)));
  if p_benchmark is not null then
    checks := checks || jsonb_build_array(jsonb_build_object('name', 'benchmark', 'value', p_benchmark, 'threshold', 'see specification', 'pass', coalesce(p_benchmark_pass, false)));
  end if;
  select bool_and((c ->> 'pass')::boolean) into passed from jsonb_array_elements(checks) c;
  summary := jsonb_build_object('hypothesis', p_key, 'code_version', 'event-study-v2', 'unit', p_unit, 'base', base, 'double_cost', dbl - 'boot_ci_95',
    'benchmark', p_benchmark, 'checks', checks, 'passed', passed);
  if p_persist then
    insert into intelligence.backtest_runs(code_version, symbol, params, data_summary, result, hypothesis_id)
    values ('event-study-v2', p_symbol, h.specification, jsonb_build_object('first_date', base -> 'first_date', 'last_date', base -> 'last_date', 'trades', base -> 'n'),
            summary || jsonb_build_object('trades', p_trades), h.id)
    returning id into rid;
    summary := summary || jsonb_build_object('stored_run_id', rid);
  end if;
  return summary;
end $function$;

create or replace function intelligence.run_batch4(p_key text, p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare net double precision[]; dates date[]; net2 double precision[]; trades jsonb; bench jsonb; bpass boolean;
  am double precision; asd double precision; an integer; um double precision; usd double precision; un integer; wt double precision; wp double precision;
begin
  if p_key = 'usdjpy-london-breakout-tokyo-range' then
    select array_agg(x.net_pips::float8 order by x.trade_date), array_agg(x.trade_date order by x.trade_date),
           jsonb_agg(to_jsonb(x) order by x.trade_date) into net, dates, trades from intelligence.trades_usdjpy_london_breakout(1.8, 0.5) x;
    select array_agg(x.net_pips::float8 order by x.trade_date) into net2 from intelligence.trades_usdjpy_london_breakout(3.6, 0.5) x;
    return intelligence.judge_and_store(p_key, 'USDJPY', 'pips', net, dates, net2, 300, 0.025, null, null, trades, p_persist);
  elsif p_key = 'xauusd-asia-london-session-drift' then
    select array_agg((x.asia_gross - 0.40)::float8 order by x.trade_date), array_agg(x.trade_date order by x.trade_date), array_agg((x.asia_gross - 0.80)::float8 order by x.trade_date),
           jsonb_agg(jsonb_build_object('date', x.trade_date, 'entry', x.asia_open, 'exit', x.asia_close, 'gross', x.asia_gross, 'net', x.asia_gross - 0.40) order by x.trade_date)
      into net, dates, net2, trades from intelligence.gold_session_windows() x;
    select avg(asia_gross), stddev_samp(asia_gross), count(*), avg(us_gross) filter (where us_gross is not null), stddev_samp(us_gross) filter (where us_gross is not null), count(us_gross)
      into am, asd, an, um, usd, un from intelligence.gold_session_windows();
    wt := (am - um) / sqrt(asd ^ 2 / an + usd ^ 2 / un); wp := 1 - intelligence.norm_cdf(wt);
    bench := jsonb_build_object('asia_london_gross_mean', am, 'asia_london_n', an, 'us_session_gross_mean', um, 'us_session_n', un, 'welch_t', wt, 'welch_p_one_sided', wp);
    bpass := wp <= 0.05;
    return intelligence.judge_and_store(p_key, 'XAUUSD', 'USD per ounce', net, dates, net2, 300, 0.025, bench, bpass, trades, p_persist);
  end if;
  raise exception 'no batch-4 runner for %', p_key;
end $function$;

revoke all on function intelligence.trades_usdjpy_london_breakout(numeric, numeric) from public, anon, authenticated;
revoke all on function intelligence.gold_session_windows() from public, anon, authenticated;
revoke all on function intelligence.judge_and_store(text, text, text, double precision[], date[], double precision[], integer, double precision, jsonb, boolean, jsonb, boolean) from public, anon, authenticated;
revoke all on function intelligence.run_batch4(text, boolean) from public, anon, authenticated;
