-- Batch 9: the 120 USD form of the FOMC-day EURUSD rule (56-pip stop, alpha 0.025); rule frozen in the ledger before this runner existed.
-- Same code as batch 8 with the stop levels as parameters.
create or replace function intelligence.eurusd_long_stop_days(p_trigger_pips numeric, p_exit_pips numeric)
returns table(trade_date date, fomc boolean, entry numeric, low_price numeric, exit_price numeric, stopped boolean, gross_pips numeric, net_pips numeric, net_pips_double numeric)
language sql stable set search_path to '' as $function$
  with b as (select (b.ts at time zone 'UTC')::date d, b.low, b.close, lag(b.close) over (order by b.ts) pc
             from market.price_bars b join core.instruments i on i.id = b.instrument_id where i.symbol = 'EURUSD' and b.timeframe = 'daily'),
  x as (select d, pc entry, low, low <= pc - p_trigger_pips / 10000 st, case when low <= pc - p_trigger_pips / 10000 then pc - p_exit_pips / 10000 else close end ex from b where pc is not null)
  select x.d, exists (select 1 from macro.fomc_meetings m where m.statement_date = x.d), x.entry, x.low, x.ex, x.st,
         round((x.ex - x.entry) * 10000, 2), round((x.ex - x.entry) * 10000 - 1.6, 2), round((x.ex - x.entry) * 10000 - 3.2, 2)
  from x order by x.d;
$function$;
revoke all on function intelligence.eurusd_long_stop_days(numeric, numeric) from public, anon, authenticated;

create or replace function intelligence.run_eurusd_fomc_stop56_test(p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare h record; net double precision[]; dates date[]; net2 double precision[]; trades jsonb; base jsonb; dbl jsonb; checks jsonb; passed boolean; rid uuid; summary jsonb;
  fm double precision; fsd double precision; fn integer; om double precision; osd double precision; onn integer; wt double precision; wp double precision; stops integer;
begin
  select * into h from intelligence.research_hypotheses where key = 'eurusd-fomc-day-long-stop56';
  if not found then raise exception 'hypothesis not registered'; end if;
  select array_agg(x.net_pips::float8 order by x.trade_date), array_agg(x.trade_date order by x.trade_date), array_agg(x.net_pips_double::float8 order by x.trade_date),
         jsonb_agg(to_jsonb(x) order by x.trade_date), count(*) filter (where x.stopped)
    into net, dates, net2, trades, stops from intelligence.eurusd_long_stop_days(53, 58) x where x.fomc;
  select avg(x.net_pips) filter (where x.fomc), stddev_samp(x.net_pips) filter (where x.fomc), count(*) filter (where x.fomc),
         avg(x.net_pips) filter (where not x.fomc), stddev_samp(x.net_pips) filter (where not x.fomc), count(*) filter (where not x.fomc)
    into fm, fsd, fn, om, osd, onn from intelligence.eurusd_long_stop_days(53, 58) x;
  wt := (fm - om) / sqrt(fsd ^ 2 / fn + osd ^ 2 / onn); wp := 1 - intelligence.norm_cdf(wt);
  base := intelligence.trade_stats(net, dates, '2017-01-01', 2000);
  dbl := intelligence.trade_stats(net2, dates, '2017-01-01', 200);
  checks := jsonb_build_array(
    jsonb_build_object('name', 'events', 'value', base -> 'n', 'threshold', '>= 120', 'pass', (base ->> 'n')::int >= 120),
    jsonb_build_object('name', 'one-sided p for a positive mean net result', 'value', base -> 'p_one_sided', 'threshold', '<= 0.025', 'pass', coalesce((base ->> 'p_one_sided')::float8 <= 0.025, false)),
    jsonb_build_object('name', 'first-half mean net', 'value', base -> 'first_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'first_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'second-half mean net', 'value', base -> 'second_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'second_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'post-publication (from 2017-01-01) mean net', 'value', base -> 'holdout_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'holdout_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net at double costs', 'value', dbl -> 'mean', 'threshold', '> 0', 'pass', coalesce((dbl ->> 'mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net without the best 5% of events', 'value', base -> 'mean_without_best_5pct', 'threshold', '> 0', 'pass', coalesce((base ->> 'mean_without_best_5pct')::float8 > 0, false)),
    jsonb_build_object('name', 'profit factor', 'value', base -> 'profit_factor', 'threshold', '>= 1.2', 'pass', coalesce((base ->> 'profit_factor')::float8 >= 1.2, false)),
    jsonb_build_object('name', 'FOMC days beat other days (Welch one-sided p)', 'value', wp, 'threshold', '<= 0.05', 'pass', coalesce(wp <= 0.05, false)));
  select bool_and((c ->> 'pass')::boolean) into passed from jsonb_array_elements(checks) c;
  summary := jsonb_build_object('hypothesis', h.key, 'code_version', 'event-study-v2', 'unit', 'pips per trade', 'stopped_trades', stops, 'base', base, 'double_cost', dbl - 'boot_ci_95',
    'benchmark', jsonb_build_object('fomc_mean_net_pips', fm, 'fomc_n', fn, 'other_days_mean_net_pips', om, 'other_days_n', onn, 'welch_t', wt, 'welch_p_one_sided', wp),
    'checks', checks, 'passed', passed);
  if p_persist then
    insert into intelligence.backtest_runs(code_version, symbol, params, data_summary, result, hypothesis_id)
    values ('event-study-v2', 'EURUSD', h.specification, jsonb_build_object('first_date', base -> 'first_date', 'last_date', base -> 'last_date', 'trades', base -> 'n'), summary || jsonb_build_object('trades', trades), h.id)
    returning id into rid;
    summary := summary || jsonb_build_object('stored_run_id', rid);
  end if;
  return summary;
end $function$;
revoke all on function intelligence.run_eurusd_fomc_stop56_test(boolean) from public, anon, authenticated;
