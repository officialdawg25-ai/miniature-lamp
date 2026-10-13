-- Batch 10: month-end equity hedge rebalancing (Melvin and Prins 2015) on EURUSD; rule frozen in the ledger before this runner existed.
create or replace function intelligence.eurusd_month_end_trades()
returns table(event_date date, placebo boolean, rel_return numeric, side integer, entry numeric, exit_price numeric, stopped boolean, net_pips numeric, net_pips_double numeric)
language sql stable set search_path to '' as $function$
  with fx as (select (b.ts at time zone 'UTC')::date d, b.high, b.low, b.close, lag(b.close) over (order by b.ts) pc
              from market.price_bars b join core.instruments i on i.id = b.instrument_id where i.symbol = 'EURUSD' and b.timeframe = 'daily'),
  cand as (select fx.*, row_number() over (order by d) rn from fx
           where pc is not null and extract(isodow from d) between 1 and 5
             and not (extract(month from d) in (5, 8) and extract(isodow from d) = 1 and extract(month from d + 7) <> extract(month from d))),
  -- the last month in the data is incomplete, so its latest bar is not a month-end
  me as (select date_trunc('month', d)::date m, max(d) d from cand group by 1 having date_trunc('month', max(d)) < (select date_trunc('month', max(fx.d)) from fx)),
  ev as (select me.m, c.d, false placebo from me join cand c on c.d = me.d
         union all
         select me.m, p.d, true from me join cand c on c.d = me.d join cand p on p.rn = c.rn - 10 where date_trunc('month', p.d) = me.m),
  etf as (select i.symbol, (b.ts at time zone 'UTC')::date d, b.close from market.price_bars b join core.instruments i on i.id = b.instrument_id
          where i.symbol in ('SPY', 'EZU') and b.timeframe = 'daily'),
  sig as (select ev.m, ev.d, ev.placebo,
            (select e.close from etf e where e.symbol = 'EZU' and e.d < ev.m order by e.d desc limit 1) ez0,
            (select e.close from etf e where e.symbol = 'EZU' and e.d < ev.d order by e.d desc limit 1) ez1,
            (select e.close from etf e where e.symbol = 'SPY' and e.d < ev.m order by e.d desc limit 1) sp0,
            (select e.close from etf e where e.symbol = 'SPY' and e.d < ev.d order by e.d desc limit 1) sp1
          from ev),
  t as (select s.d, s.placebo, s.ez1 / s.ez0 - s.sp1 / s.sp0 r, -sign(s.ez1 / s.ez0 - s.sp1 / s.sp0)::int side, c.pc entry, c.high, c.low, c.close
        from sig s join cand c on c.d = s.d where s.ez0 is not null and s.sp0 is not null and s.ez1 is not null and s.sp1 is not null),
  x as (select t.*, case when side = 1 then low <= entry - 0.0053 else high >= entry + 0.0053 end st from t where side <> 0),
  y as (select x.*, case when st then entry - side * 0.0058 else close end ex from x)
  select d, placebo, round(r, 6), side, entry, ex, st, round(side * (ex - entry) * 10000 - 1.6, 2), round(side * (ex - entry) * 10000 - 3.2, 2)
  from y order by d, placebo;
$function$;
revoke all on function intelligence.eurusd_month_end_trades() from public, anon, authenticated;

create or replace function intelligence.run_month_end_hedge_test(p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare h record; net double precision[]; dates date[]; net2 double precision[]; trades jsonb; base jsonb; dbl jsonb; checks jsonb; passed boolean; rid uuid; summary jsonb; stops integer;
  fm double precision; fsd double precision; fn integer; om double precision; osd double precision; onn integer; wt double precision; wp double precision; mdd double precision;
begin
  select * into h from intelligence.research_hypotheses where key = 'eurusd-month-end-hedge-rebalancing';
  if not found then raise exception 'hypothesis not registered'; end if;
  select array_agg(x.net_pips::float8 order by x.event_date), array_agg(x.event_date order by x.event_date), array_agg(x.net_pips_double::float8 order by x.event_date),
         jsonb_agg(to_jsonb(x) order by x.event_date), count(*) filter (where x.stopped)
    into net, dates, net2, trades, stops from intelligence.eurusd_month_end_trades() x where not x.placebo;
  select avg(x.net_pips) filter (where not x.placebo), stddev_samp(x.net_pips) filter (where not x.placebo), count(*) filter (where not x.placebo),
         avg(x.net_pips) filter (where x.placebo), stddev_samp(x.net_pips) filter (where x.placebo), count(*) filter (where x.placebo)
    into fm, fsd, fn, om, osd, onn from intelligence.eurusd_month_end_trades() x;
  wt := (fm - om) / sqrt(fsd ^ 2 / fn + osd ^ 2 / onn); wp := 1 - intelligence.norm_cdf(wt);
  select max(greatest(0, c.peak) - c.cum) * 0.10 into mdd from (select q.cum, max(q.cum) over (order by q.event_date) peak from (
    select x.event_date, sum(x.net_pips) over (order by x.event_date) cum from intelligence.eurusd_month_end_trades() x where not x.placebo) q) c;
  base := intelligence.trade_stats(net, dates, '2015-01-01', 2000);
  dbl := intelligence.trade_stats(net2, dates, '2015-01-01', 200);
  checks := jsonb_build_array(
    jsonb_build_object('name', 'events', 'value', base -> 'n', 'threshold', '>= 150', 'pass', (base ->> 'n')::int >= 150),
    jsonb_build_object('name', 'one-sided p for a positive mean net result', 'value', base -> 'p_one_sided', 'threshold', '<= 0.05', 'pass', coalesce((base ->> 'p_one_sided')::float8 <= 0.05, false)),
    jsonb_build_object('name', 'first-half mean net', 'value', base -> 'first_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'first_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'second-half mean net', 'value', base -> 'second_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'second_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'post-publication (from 2015-01-01) mean net', 'value', base -> 'holdout_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'holdout_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net at double costs', 'value', dbl -> 'mean', 'threshold', '> 0', 'pass', coalesce((dbl ->> 'mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net without the best 5% of events', 'value', base -> 'mean_without_best_5pct', 'threshold', '> 0', 'pass', coalesce((base ->> 'mean_without_best_5pct')::float8 > 0, false)),
    jsonb_build_object('name', 'profit factor', 'value', base -> 'profit_factor', 'threshold', '>= 1.2', 'pass', coalesce((base ->> 'profit_factor')::float8 >= 1.2, false)),
    jsonb_build_object('name', 'month-end beats placebo day (Welch one-sided p)', 'value', wp, 'threshold', '<= 0.05', 'pass', coalesce(wp <= 0.05, false)),
    jsonb_build_object('name', 'maximum drawdown at 0.01 lot (USD)', 'value', mdd, 'threshold', '< 36', 'pass', coalesce(mdd < 36, false)));
  select bool_and((c ->> 'pass')::boolean) into passed from jsonb_array_elements(checks) c;
  summary := jsonb_build_object('hypothesis', h.key, 'code_version', 'event-study-v2', 'unit', 'pips per trade', 'stopped_trades', stops, 'base', base, 'double_cost', dbl - 'boot_ci_95',
    'benchmark', jsonb_build_object('month_end_mean_net', fm, 'month_end_n', fn, 'placebo_mean_net', om, 'placebo_n', onn, 'welch_t', wt, 'welch_p_one_sided', wp),
    'max_drawdown_usd', mdd, 'checks', checks, 'passed', passed);
  if p_persist then
    insert into intelligence.backtest_runs(code_version, symbol, params, data_summary, result, hypothesis_id)
    values ('event-study-v2', 'EURUSD', h.specification, jsonb_build_object('first_date', base -> 'first_date', 'last_date', base -> 'last_date', 'trades', base -> 'n'), summary || jsonb_build_object('trades', trades), h.id)
    returning id into rid;
    summary := summary || jsonb_build_object('stored_run_id', rid);
  end if;
  return summary;
end $function$;
revoke all on function intelligence.run_month_end_hedge_test(boolean) from public, anon, authenticated;
