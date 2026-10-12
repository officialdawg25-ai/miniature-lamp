-- Confirmatory test of us-release-fade-usdjpy-oos, exactly as registered: the fade side of the release bar, releases from 2021-01-01 to 2023-08-21 only
-- (the sample that suggested the idea, 2023-09 onward, is excluded), 3.0 pips round trip, stress at 6.0. Service role only.
create or replace function intelligence.run_release_fade_oos(p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare h record; net double precision[]; dates date[]; net2 double precision[]; trades jsonb; base jsonb; dbl jsonb; checks jsonb; passed boolean; rid uuid; summary jsonb;
  coverage jsonb;
begin
  select * into h from intelligence.research_hypotheses where key = 'us-release-fade-usdjpy-oos';
  if not found then raise exception 'hypothesis not registered'; end if;
  select array_agg(((-x.gross - 0.030) / 0.01)::double precision order by x.release_at), array_agg(x.release_at::date order by x.release_at),
         jsonb_agg(jsonb_build_object('at', x.release_at, 'release', x.release_name, 'side', -x.side, 'entry', x.entry, 'exit', x.exit_price, 'gross_pips', -x.gross / 0.01, 'net_pips', (-x.gross - 0.030) / 0.01) order by x.release_at)
    into net, dates, trades
    from intelligence.trades_release_continuation('USDJPY', array['Consumer Price Index', 'Employment Situation'], 0) x
    where x.release_at >= '2021-01-01' and x.release_at < '2023-08-22';
  select array_agg(((-x.gross - 0.060) / 0.01)::double precision order by x.release_at) into net2
    from intelligence.trades_release_continuation('USDJPY', array['Consumer Price Index', 'Employment Situation'], 0) x
    where x.release_at >= '2021-01-01' and x.release_at < '2023-08-22';
  select jsonb_build_object('scheduled_releases_in_window', count(*)) into coverage from macro.provider_release_calendars c
    where c.provider = 'BLS' and c.release_name in ('Consumer Price Index', 'Employment Situation') and c.scheduled_release_time >= '2021-01-01' and c.scheduled_release_time < '2023-08-22';
  if coalesce(array_length(net, 1), 0) < 2 then return jsonb_build_object('n', coalesce(array_length(net, 1), 0), 'coverage', coverage, 'note', 'no bars for the window yet'); end if;
  base := intelligence.trade_stats(net, dates, '2099-01-01', 2000);
  dbl := intelligence.trade_stats(net2, dates, '2099-01-01', 200);
  checks := jsonb_build_array(
    jsonb_build_object('name', 'trades', 'value', base -> 'n', 'threshold', '>= 50', 'pass', (base ->> 'n')::int >= 50),
    jsonb_build_object('name', 'one-sided p for a positive mean net result', 'value', base -> 'p_one_sided', 'threshold', '<= 0.05', 'pass', coalesce((base ->> 'p_one_sided')::float8 <= 0.05, false)),
    jsonb_build_object('name', 'first-half mean net', 'value', base -> 'first_half_mean', 'threshold', '> 0', 'pass', (base ->> 'first_half_mean')::float8 > 0),
    jsonb_build_object('name', 'second-half mean net', 'value', base -> 'second_half_mean', 'threshold', '> 0', 'pass', (base ->> 'second_half_mean')::float8 > 0),
    jsonb_build_object('name', 'mean net at double costs', 'value', dbl -> 'mean', 'threshold', '> 0', 'pass', (dbl ->> 'mean')::float8 > 0),
    jsonb_build_object('name', 'mean net without the best 5% of trades', 'value', base -> 'mean_without_best_5pct', 'threshold', '> 0', 'pass', (base ->> 'mean_without_best_5pct')::float8 > 0),
    jsonb_build_object('name', 'profit factor', 'value', base -> 'profit_factor', 'threshold', '>= 1.2', 'pass', coalesce((base ->> 'profit_factor')::float8 >= 1.2, false)));
  select bool_and((c ->> 'pass')::boolean) into passed from jsonb_array_elements(checks) c;
  summary := jsonb_build_object('hypothesis', 'us-release-fade-usdjpy-oos', 'code_version', 'event-study-v1', 'unit', 'pips', 'coverage', coverage,
    'base', base - 'holdout_from' - 'holdout_n' - 'holdout_mean', 'double_cost', dbl - 'boot_ci_95' - 'holdout_from' - 'holdout_n' - 'holdout_mean', 'checks', checks, 'passed', passed);
  if p_persist then
    insert into intelligence.backtest_runs(code_version, symbol, params, data_summary, result, hypothesis_id)
    values ('event-study-v1', 'USDJPY', h.specification, jsonb_build_object('first_date', base -> 'first_date', 'last_date', base -> 'last_date', 'trades', base -> 'n'), summary || jsonb_build_object('trades', trades), h.id)
    returning id into rid;
    summary := summary || jsonb_build_object('stored_run_id', rid);
  end if;
  return summary;
end $function$;
revoke all on function intelligence.run_release_fade_oos(boolean) from public, anon, authenticated;
