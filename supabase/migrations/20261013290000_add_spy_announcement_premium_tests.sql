-- Batch 11: equity announcement-day premium on SPY (FOMC days; CPI, PPI and payrolls days); rules frozen in the ledger before this runner existed.
create or replace function intelligence.spy_event_day_trades(p_kind text)
returns table(trade_date date, event boolean, entry numeric, exit_price numeric, stopped boolean, net_bp numeric, stress_bp numeric)
language sql stable set search_path to '' as $function$
  with b as materialized (select (b.ts at time zone 'UTC')::date d, b.low, b.close, lag(b.close) over (order by b.ts) pc, lag((b.ts at time zone 'UTC')::date) over (order by b.ts) pd
             from market.price_bars b join core.instruments i on i.id = b.instrument_id where i.symbol = 'SPY' and b.timeframe = 'daily'),
  ev as materialized (
    select m.statement_date d from macro.fomc_meetings m where p_kind = 'fomc'
    union
    select (c.scheduled_release_time at time zone 'UTC')::date from macro.provider_release_calendars c
     where p_kind = 'bls' and c.provider = 'BLS' and c.release_name in ('Consumer Price Index', 'Producer Price Index', 'Employment Situation')
       and c.scheduled_release_time <= now()
       and not exists (select 1 from macro.fomc_meetings f where f.statement_date = (c.scheduled_release_time at time zone 'UTC')::date)),
  x as (select b.d, b.d in (select ev.d from ev) e, b.pc entry, b.low <= b.pc * 0.971 st, case when b.low <= b.pc * 0.971 then b.pc * 0.968 else b.close end ex, b.d - b.pd nights
        from b where b.pc is not null and (p_kind <> 'bls' or b.d >= '2021-01-01'))
  select d, e, entry, round(ex, 4), st, round((ex / entry - 1) * 10000 - 2, 3), round((ex / entry - 1) * 10000 - 4 - nights, 3) from x order by d;
$function$;
revoke all on function intelligence.spy_event_day_trades(text) from public, anon, authenticated;

create or replace function intelligence.run_spy_announcement_test(p_key text, p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare h record; kind text; min_n integer; hold_from date; net double precision[]; dates date[]; net2 double precision[]; trades jsonb; base jsonb; dbl jsonb; checks jsonb; passed boolean; rid uuid; summary jsonb; stops integer;
  fm double precision; fsd double precision; fn integer; om double precision; osd double precision; onn integer; wt double precision; wp double precision; mdd double precision;
begin
  select * into h from intelligence.research_hypotheses where key = p_key;
  if not found then raise exception 'hypothesis not registered'; end if;
  if p_key = 'spy-fomc-day-announcement-premium' then kind := 'fomc'; min_n := 120; hold_from := '2016-01-01';
  elsif p_key = 'spy-cpi-ppi-payrolls-day-premium' then kind := 'bls'; min_n := 150; hold_from := '2099-01-01';
  else raise exception 'no batch-11 runner for %', p_key; end if;
  create temp table if not exists _spy_event_trades on commit drop as select kind k, * from intelligence.spy_event_day_trades(kind);
  if exists (select 1 from pg_temp._spy_event_trades t where t.k <> kind) then raise exception 'run the two batch-11 tests in separate transactions'; end if;
  select array_agg(x.net_bp::float8 order by x.trade_date), array_agg(x.trade_date order by x.trade_date), array_agg(x.stress_bp::float8 order by x.trade_date),
         jsonb_agg(to_jsonb(x) - 'k' order by x.trade_date), count(*) filter (where x.stopped)
    into net, dates, net2, trades, stops from pg_temp._spy_event_trades x where x.event;
  select avg(x.net_bp) filter (where x.event), stddev_samp(x.net_bp) filter (where x.event), count(*) filter (where x.event),
         avg(x.net_bp) filter (where not x.event), stddev_samp(x.net_bp) filter (where not x.event), count(*) filter (where not x.event)
    into fm, fsd, fn, om, osd, onn from pg_temp._spy_event_trades x;
  wt := (fm - om) / sqrt(fsd ^ 2 / fn + osd ^ 2 / onn); wp := 1 - intelligence.norm_cdf(wt);
  select max(greatest(0, c.peak) - c.cum) into mdd from (select q.cum, max(q.cum) over (order by q.trade_date) peak from (
    select x.trade_date, sum(x.net_bp / 10000 * 200) over (order by x.trade_date) cum from pg_temp._spy_event_trades x where x.event) q) c;
  base := intelligence.trade_stats(net, dates, hold_from, 2000);
  dbl := intelligence.trade_stats(net2, dates, hold_from, 200);
  checks := jsonb_build_array(
    jsonb_build_object('name', 'events', 'value', base -> 'n', 'threshold', '>= ' || min_n, 'pass', (base ->> 'n')::int >= min_n),
    jsonb_build_object('name', 'one-sided p for a positive mean net result', 'value', base -> 'p_one_sided', 'threshold', '<= 0.025', 'pass', coalesce((base ->> 'p_one_sided')::float8 <= 0.025, false)),
    jsonb_build_object('name', 'first-half mean net', 'value', base -> 'first_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'first_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'second-half mean net', 'value', base -> 'second_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'second_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net at stress costs', 'value', dbl -> 'mean', 'threshold', '> 0', 'pass', coalesce((dbl ->> 'mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net without the best 5% of events', 'value', base -> 'mean_without_best_5pct', 'threshold', '> 0', 'pass', coalesce((base ->> 'mean_without_best_5pct')::float8 > 0, false)),
    jsonb_build_object('name', 'profit factor', 'value', base -> 'profit_factor', 'threshold', '>= 1.2', 'pass', coalesce((base ->> 'profit_factor')::float8 >= 1.2, false)),
    jsonb_build_object('name', 'event days beat other days (Welch one-sided p)', 'value', wp, 'threshold', '<= 0.05', 'pass', coalesce(wp <= 0.05, false)),
    jsonb_build_object('name', 'maximum drawdown at 200 USD notional (USD)', 'value', mdd, 'threshold', '< 36', 'pass', coalesce(mdd < 36, false)));
  if kind = 'fomc' then
    checks := checks || jsonb_build_array(jsonb_build_object('name', 'mean net from 2016-01-01', 'value', base -> 'holdout_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'holdout_mean')::float8 > 0, false)));
  end if;
  select bool_and((c ->> 'pass')::boolean) into passed from jsonb_array_elements(checks) c;
  summary := jsonb_build_object('hypothesis', h.key, 'code_version', 'event-study-v2', 'unit', 'basis points per trade', 'stopped_trades', stops, 'base', base, 'double_cost', dbl - 'boot_ci_95',
    'benchmark', jsonb_build_object('event_mean_net', fm, 'event_n', fn, 'other_days_mean_net', om, 'other_days_n', onn, 'welch_t', wt, 'welch_p_one_sided', wp),
    'max_drawdown_usd_at_200_notional', mdd, 'checks', checks, 'passed', passed);
  if p_persist then
    insert into intelligence.backtest_runs(code_version, symbol, params, data_summary, result, hypothesis_id)
    values ('event-study-v2', 'SPY', h.specification, jsonb_build_object('first_date', base -> 'first_date', 'last_date', base -> 'last_date', 'trades', base -> 'n'), summary || jsonb_build_object('trades', trades), h.id)
    returning id into rid;
    summary := summary || jsonb_build_object('stored_run_id', rid);
  end if;
  return summary;
end $function$;
revoke all on function intelligence.run_spy_announcement_test(text, boolean) from public, anon, authenticated;
