-- Replication of the gold session rule on 2016-01-01 to 2020-09-10, exactly as registered (xauusd-asia-london-session-drift-replication).
-- Same windows and costs as the original; only the evaluation period and its pre-registered criteria differ. Service role only.
create or replace function intelligence.run_gold_session_replication(p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare h record; net double precision[]; dates date[]; net2 double precision[]; trades jsonb; base jsonb; dbl jsonb; checks jsonb; passed boolean; rid uuid; summary jsonb;
  am double precision; asd double precision; an integer; um double precision; usd double precision; un integer; wt double precision; wp double precision;
begin
  select * into h from intelligence.research_hypotheses where key = 'xauusd-asia-london-session-drift-replication';
  if not found then raise exception 'hypothesis not registered'; end if;
  select array_agg((x.asia_gross - 0.40)::float8 order by x.trade_date), array_agg(x.trade_date order by x.trade_date), array_agg((x.asia_gross - 0.80)::float8 order by x.trade_date),
         jsonb_agg(jsonb_build_object('date', x.trade_date, 'entry', x.asia_open, 'exit', x.asia_close, 'gross', x.asia_gross, 'net', x.asia_gross - 0.40) order by x.trade_date)
    into net, dates, net2, trades from intelligence.gold_session_windows() x where x.trade_date >= '2016-01-01' and x.trade_date < '2020-09-11';
  if coalesce(array_length(net, 1), 0) < 2 then return jsonb_build_object('n', coalesce(array_length(net, 1), 0), 'note', 'no bars for the window yet'); end if;
  select avg(asia_gross), stddev_samp(asia_gross), count(*), avg(us_gross) filter (where us_gross is not null), stddev_samp(us_gross) filter (where us_gross is not null), count(us_gross)
    into am, asd, an, um, usd, un from intelligence.gold_session_windows() where trade_date >= '2016-01-01' and trade_date < '2020-09-11';
  wt := (am - um) / sqrt(asd ^ 2 / an + usd ^ 2 / un); wp := 1 - intelligence.norm_cdf(wt);
  base := intelligence.trade_stats(net, dates, '2099-01-01', 2000);
  dbl := intelligence.trade_stats(net2, dates, '2099-01-01', 200);
  checks := jsonb_build_array(
    jsonb_build_object('name', 'trades', 'value', base -> 'n', 'threshold', '>= 500', 'pass', (base ->> 'n')::int >= 500),
    jsonb_build_object('name', 'one-sided p for a positive mean net result', 'value', base -> 'p_one_sided', 'threshold', '<= 0.05', 'pass', coalesce((base ->> 'p_one_sided')::float8 <= 0.05, false)),
    jsonb_build_object('name', 'first-half mean net', 'value', base -> 'first_half_mean', 'threshold', '> 0', 'pass', (base ->> 'first_half_mean')::float8 > 0),
    jsonb_build_object('name', 'second-half mean net', 'value', base -> 'second_half_mean', 'threshold', '> 0', 'pass', (base ->> 'second_half_mean')::float8 > 0),
    jsonb_build_object('name', 'mean net at double costs', 'value', dbl -> 'mean', 'threshold', '> 0', 'pass', (dbl ->> 'mean')::float8 > 0),
    jsonb_build_object('name', 'mean net without the best 5% of trades', 'value', base -> 'mean_without_best_5pct', 'threshold', '> 0', 'pass', (base ->> 'mean_without_best_5pct')::float8 > 0),
    jsonb_build_object('name', 'profit factor', 'value', base -> 'profit_factor', 'threshold', '>= 1.2', 'pass', coalesce((base ->> 'profit_factor')::float8 >= 1.2, false)),
    jsonb_build_object('name', 'Asia+London beats US session (Welch one-sided p)', 'value', wp, 'threshold', '<= 0.05', 'pass', wp <= 0.05));
  select bool_and((c ->> 'pass')::boolean) into passed from jsonb_array_elements(checks) c;
  summary := jsonb_build_object('hypothesis', h.key, 'code_version', 'event-study-v2', 'unit', 'USD per ounce',
    'base', base - 'holdout_from' - 'holdout_n' - 'holdout_mean', 'double_cost', dbl - 'boot_ci_95' - 'holdout_from' - 'holdout_n' - 'holdout_mean',
    'benchmark', jsonb_build_object('asia_london_gross_mean', am, 'asia_london_n', an, 'us_session_gross_mean', um, 'us_session_n', un, 'welch_t', wt, 'welch_p_one_sided', wp),
    'checks', checks, 'passed', passed);
  if p_persist then
    insert into intelligence.backtest_runs(code_version, symbol, params, data_summary, result, hypothesis_id)
    values ('event-study-v2', 'XAUUSD', h.specification, jsonb_build_object('first_date', base -> 'first_date', 'last_date', base -> 'last_date', 'trades', base -> 'n'), summary || jsonb_build_object('trades', trades), h.id)
    returning id into rid;
    summary := summary || jsonb_build_object('stored_run_id', rid);
  end if;
  return summary;
end $function$;
revoke all on function intelligence.run_gold_session_replication(boolean) from public, anon, authenticated;
