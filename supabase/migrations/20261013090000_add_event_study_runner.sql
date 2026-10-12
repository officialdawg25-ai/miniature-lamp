-- Runs one of the three registered event-study hypotheses exactly as frozen in the ledger, judges it against its pre-registered criteria,
-- and stores the run with every trade in intelligence.backtest_runs. Service role only. Changing a rule means a new hypothesis key, never an edit here.
create or replace function intelligence.run_event_study(p_key text, p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare
  h record; base jsonb; dbl jsonb; trades jsonb; bench jsonb := null; net double precision[]; dates date[]; net2 double precision[];
  checks jsonb := '[]'::jsonb; passed boolean; min_n integer; alpha constant double precision := 0.05 / 3; holdout constant date := '2025-10-13';
  g_mean double precision; g_sd double precision; g_n integer; o_mean double precision; o_sd double precision; o_n integer; welch_t double precision; welch_p double precision;
  rid uuid; summary jsonb;
begin
  select * into h from intelligence.research_hypotheses where key = p_key;
  if not found then raise exception 'hypothesis % not registered', p_key; end if;

  if p_key = 'usdjpy-gotobi-tokyo-fix-drift' then
    min_n := 100;
    select array_agg(x.net_pips::double precision order by x.trade_date), array_agg(x.trade_date order by x.trade_date),
           jsonb_agg(jsonb_build_object('date', x.trade_date, 'entry', x.entry, 'exit', x.exit_price, 'stopped', x.stopped, 'gross_pips', x.gross_pips, 'net_pips', x.net_pips, 'net_usd_001', x.net_usd_001) order by x.trade_date)
      into net, dates, trades from intelligence.trades_usdjpy_tokyo_window(1.8, 10, 0.5) x where x.is_gotobi;
    select array_agg(net_pips::double precision order by trade_date) into net2 from intelligence.trades_usdjpy_tokyo_window(3.6, 10, 0.5) where is_gotobi;
    select avg(gross_pips), stddev_samp(gross_pips), count(*) into g_mean, g_sd, g_n from intelligence.trades_usdjpy_tokyo_window(0, 10, 0.5) where is_gotobi;
    select avg(gross_pips), stddev_samp(gross_pips), count(*) into o_mean, o_sd, o_n from intelligence.trades_usdjpy_tokyo_window(0, 10, 0.5) where not is_gotobi;
    welch_t := (g_mean - o_mean) / sqrt(g_sd ^ 2 / g_n + o_sd ^ 2 / o_n);
    welch_p := 1 - intelligence.norm_cdf(welch_t);
    bench := jsonb_build_object('gotobi_gross_mean_pips', g_mean, 'gotobi_n', g_n, 'other_days_gross_mean_pips', o_mean, 'other_days_n', o_n, 'welch_t', welch_t, 'welch_p_one_sided', welch_p);
  elsif p_key in ('us-release-continuation-usdjpy', 'us-release-continuation-xauusd') then
    min_n := 50;
    select array_agg((case when p_key like '%usdjpy' then x.net / 0.01 else x.net end)::double precision order by x.release_at), array_agg(x.release_at::date order by x.release_at),
           jsonb_agg(jsonb_build_object('at', x.release_at, 'release', x.release_name, 'side', x.side, 'entry', x.entry, 'exit', x.exit_price, 'gross', x.gross, 'net', x.net, 'net_usd_001', x.net_usd_001) order by x.release_at)
      into net, dates, trades
      from intelligence.trades_release_continuation(case when p_key like '%usdjpy' then 'USDJPY' else 'XAUUSD' end, array['Consumer Price Index', 'Employment Situation'], case when p_key like '%usdjpy' then 0.030 else 0.80 end) x;
    select array_agg((case when p_key like '%usdjpy' then x.net / 0.01 else x.net end)::double precision order by x.release_at) into net2
      from intelligence.trades_release_continuation(case when p_key like '%usdjpy' then 'USDJPY' else 'XAUUSD' end, array['Consumer Price Index', 'Employment Situation'], case when p_key like '%usdjpy' then 0.060 else 1.60 end) x;
  else
    raise exception 'no runner for %', p_key;
  end if;

  base := intelligence.trade_stats(net, dates, holdout, 2000);
  dbl := intelligence.trade_stats(net2, dates, holdout, 200);
  checks := jsonb_build_array(
    jsonb_build_object('name', 'trades', 'value', base -> 'n', 'threshold', '>= ' || min_n, 'pass', (base ->> 'n')::int >= min_n),
    jsonb_build_object('name', 'one-sided p for a positive mean net result', 'value', base -> 'p_one_sided', 'threshold', '<= 0.0167', 'pass', coalesce((base ->> 'p_one_sided')::float8 <= alpha, false)),
    jsonb_build_object('name', 'first-half mean net', 'value', base -> 'first_half_mean', 'threshold', '> 0', 'pass', (base ->> 'first_half_mean')::float8 > 0),
    jsonb_build_object('name', 'second-half mean net', 'value', base -> 'second_half_mean', 'threshold', '> 0', 'pass', (base ->> 'second_half_mean')::float8 > 0),
    jsonb_build_object('name', 'holdout (from 2025-10-13) mean net', 'value', base -> 'holdout_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'holdout_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net at double costs', 'value', dbl -> 'mean', 'threshold', '> 0', 'pass', (dbl ->> 'mean')::float8 > 0),
    jsonb_build_object('name', 'mean net without the best 5% of trades', 'value', base -> 'mean_without_best_5pct', 'threshold', '> 0', 'pass', (base ->> 'mean_without_best_5pct')::float8 > 0),
    jsonb_build_object('name', 'profit factor', 'value', base -> 'profit_factor', 'threshold', '>= 1.2', 'pass', coalesce((base ->> 'profit_factor')::float8 >= 1.2, false)));
  if bench is not null then
    checks := checks || jsonb_build_array(jsonb_build_object('name', 'gotobi beats other days (Welch one-sided p)', 'value', bench -> 'welch_p_one_sided', 'threshold', '<= 0.05', 'pass', (bench ->> 'welch_p_one_sided')::float8 <= 0.05));
  end if;
  select bool_and((c ->> 'pass')::boolean) into passed from jsonb_array_elements(checks) c;
  summary := jsonb_build_object('hypothesis', p_key, 'code_version', 'event-study-v1', 'unit', case when p_key like '%xauusd' then 'USD per ounce' else 'pips' end,
    'base', base, 'double_cost', dbl - 'boot_ci_95', 'benchmark', bench, 'checks', checks, 'passed', passed, 'programme_bonferroni_0_05_over_14', (base ->> 'p_one_sided')::float8 <= 0.05 / 14);
  if p_persist then
    insert into intelligence.backtest_runs(code_version, symbol, params, data_summary, result, hypothesis_id)
    values ('event-study-v1', case when p_key like '%xauusd' then 'XAUUSD' else 'USDJPY' end, h.specification, jsonb_build_object('first_date', base -> 'first_date', 'last_date', base -> 'last_date', 'trades', base -> 'n'),
            summary || jsonb_build_object('trades', trades), h.id)
    returning id into rid;
    summary := summary || jsonb_build_object('stored_run_id', rid);
  end if;
  return summary;
end $function$;
revoke all on function intelligence.run_event_study(text, boolean) from public, anon, authenticated;
