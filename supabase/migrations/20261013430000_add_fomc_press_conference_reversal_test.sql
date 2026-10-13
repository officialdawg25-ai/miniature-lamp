-- Phase 3: eurusd-fomc-press-conference-reversal. Rules were frozen in the ledger before this runner existed and before any
-- 14:00-16:00 New York FOMC price path was computed. Bar timestamps are bar opens (UTC); New York times are converted per date,
-- so daylight-saving changes are handled. The trade function also serves the descriptive secondary checks on USDJPY and XAUUSD.
create or replace function intelligence.fomc_presser_reversal_trades(p_symbol text, p_pip numeric, p_filter_pips numeric, p_cost_pips numeric)
returns table(event_date date, t_statement timestamptz, open_1400 numeric, close_1415 numeric, close_1545 numeric,
              reaction_pips numeric, traded boolean, side integer, gross_pips numeric, net_pips numeric, net_pips_stress numeric, missing_bars boolean)
language sql stable set search_path to '' as $function$
  with inst as (select id from core.instruments where symbol = p_symbol),
  ev as (select m.statement_date d, (m.statement_date + time '14:00') at time zone 'America/New_York' t
         from macro.fomc_meetings m where m.statement_date >= date '2020-02-01' and m.statement_date < current_date),
  px as (select ev.d, ev.t,
           (select b.open from market.price_bars b where b.instrument_id = (select id from inst) and b.timeframe = '15m' and b.ts = ev.t) o14,
           (select b.close from market.price_bars b where b.instrument_id = (select id from inst) and b.timeframe = '15m' and b.ts = ev.t + interval '15 minutes') c1415,
           (select b.close from market.price_bars b where b.instrument_id = (select id from inst) and b.timeframe = '15m' and b.ts = ev.t + interval '105 minutes') c1545
         from ev),
  r as (select px.*, round((c1415 - o14) / p_pip, 2) rp from px)
  select d, t, o14, c1415, c1545, rp,
         coalesce(abs(rp) >= p_filter_pips, false),
         case when abs(rp) >= p_filter_pips then -sign(rp)::int end,
         case when abs(rp) >= p_filter_pips then round(-sign(rp) * (c1545 - c1415) / p_pip, 2) end,
         case when abs(rp) >= p_filter_pips then round(-sign(rp) * (c1545 - c1415) / p_pip - p_cost_pips, 2) end,
         case when abs(rp) >= p_filter_pips then round(-sign(rp) * (c1545 - c1415) / p_pip - 2 * p_cost_pips, 2) end,
         (o14 is null or c1415 is null or c1545 is null)
  from r order by d;
$function$;
revoke all on function intelligence.fomc_presser_reversal_trades(text, numeric, numeric, numeric) from public, anon, authenticated;

create or replace function intelligence.run_fomc_presser_reversal_test(p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare h record; net double precision[]; dates date[]; net2 double precision[]; trades jsonb; base jsonb; dbl jsonb; checks jsonb; passed boolean; rid uuid; summary jsonb;
  worst double precision; maxdd double precision; skipped integer; events integer; secondary jsonb;
begin
  select * into h from intelligence.research_hypotheses where key = 'eurusd-fomc-press-conference-reversal';
  if not found then raise exception 'hypothesis not registered'; end if;
  select count(*), count(*) filter (where x.missing_bars) into events, skipped from intelligence.fomc_presser_reversal_trades('EURUSD', 0.0001, 10, 2.6) x;
  select array_agg(x.net_pips::float8 order by x.event_date), array_agg(x.event_date order by x.event_date), array_agg(x.net_pips_stress::float8 order by x.event_date),
         jsonb_agg(to_jsonb(x) order by x.event_date), min(x.net_pips)
    into net, dates, net2, trades, worst
    from intelligence.fomc_presser_reversal_trades('EURUSD', 0.0001, 10, 2.6) x where x.traded and not x.missing_bars;
  select coalesce(max(c.peak - c.cum), 0) into maxdd from (
    select cum, greatest(0, max(cum) over (order by d)) peak from (select u.d, sum(u.v) over (order by u.d) cum from unnest(net, dates) u(v, d)) s) c;
  base := intelligence.trade_stats(net, dates, '2024-01-01', 2000);
  dbl := intelligence.trade_stats(net2, dates, '2024-01-01', 200);
  checks := jsonb_build_array(
    jsonb_build_object('name', 'trades', 'value', base -> 'n', 'threshold', '>= 35', 'pass', coalesce((base ->> 'n')::int >= 35, false)),
    jsonb_build_object('name', 'one-sided p for a positive mean net result', 'value', base -> 'p_one_sided', 'threshold', '<= 0.025', 'pass', coalesce((base ->> 'p_one_sided')::float8 <= 0.025, false)),
    jsonb_build_object('name', 'first-half mean net', 'value', base -> 'first_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'first_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'second-half mean net', 'value', base -> 'second_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'second_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'holdout (from 2024-01-01) mean net', 'value', base -> 'holdout_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'holdout_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net at stress costs', 'value', dbl -> 'mean', 'threshold', '> 0', 'pass', coalesce((dbl ->> 'mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net without the best 5% of trades', 'value', base -> 'mean_without_best_5pct', 'threshold', '> 0', 'pass', coalesce((base ->> 'mean_without_best_5pct')::float8 > 0, false)),
    jsonb_build_object('name', 'profit factor', 'value', base -> 'profit_factor', 'threshold', '>= 1.2', 'pass', coalesce((base ->> 'profit_factor')::float8 >= 1.2, false)),
    jsonb_build_object('name', 'worst trade (pips)', 'value', worst, 'threshold', '>= -60', 'pass', coalesce(worst >= -60, false)),
    jsonb_build_object('name', 'maximum drawdown (pips)', 'value', maxdd, 'threshold', '<= 360', 'pass', coalesce(maxdd <= 360, false)));
  select bool_and((c ->> 'pass')::boolean) into passed from jsonb_array_elements(checks) c;
  -- Descriptive secondary results (no decision): the same rule on USDJPY (pip 0.01) and XAUUSD (point 0.1, cost 4 points).
  secondary := jsonb_build_object(
    'USDJPY', (select jsonb_build_object('trades', count(*), 'mean_net', round(avg(x.net_pips), 2), 'hit_rate', round(avg((x.net_pips > 0)::int), 3))
               from intelligence.fomc_presser_reversal_trades('USDJPY', 0.01, 10, 2.6) x where x.traded and not x.missing_bars),
    'XAUUSD', (select jsonb_build_object('trades', count(*), 'mean_net_points', round(avg(x.net_pips), 2), 'hit_rate', round(avg((x.net_pips > 0)::int), 3))
               from intelligence.fomc_presser_reversal_trades('XAUUSD', 0.1, 10, 4) x where x.traded and not x.missing_bars),
    'eurusd_by_statement_change', (select jsonb_agg(jsonb_build_object('change_half', g, 'trades', n, 'mean_net', m)) from (
        select (c.jaccard < (select percentile_cont(0.5) within group (order by jaccard) from macro.fomc_statement_changes_current)) g, count(*) n, round(avg(x.net_pips), 2) m
        from intelligence.fomc_presser_reversal_trades('EURUSD', 0.0001, 10, 2.6) x join macro.fomc_statement_changes_current c on c.doc_date = x.event_date
        where x.traded and not x.missing_bars group by 1) q),
    'note', 'secondary results are descriptive; they cannot change the decision on the primary hypothesis');
  summary := jsonb_build_object('hypothesis', h.key, 'code_version', 'event-study-v2', 'unit', 'pips per trade', 'events', events, 'events_skipped_missing_bars', skipped,
    'base', base, 'stress_cost', dbl - 'boot_ci_95', 'worst_trade_pips', worst, 'max_drawdown_pips', maxdd, 'checks', checks, 'passed', passed, 'secondary', secondary);
  if p_persist then
    insert into intelligence.backtest_runs(code_version, symbol, params, data_summary, result, hypothesis_id)
    values ('event-study-v2', 'EURUSD', h.specification, jsonb_build_object('first_date', base -> 'first_date', 'last_date', base -> 'last_date', 'trades', base -> 'n', 'events', events), summary || jsonb_build_object('trades', trades), h.id)
    returning id into rid;
    summary := summary || jsonb_build_object('stored_run_id', rid);
  end if;
  return summary;
end $function$;
revoke all on function intelligence.run_fomc_presser_reversal_test(boolean) from public, anon, authenticated;
