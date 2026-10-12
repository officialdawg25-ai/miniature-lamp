-- Batch 7: the dollar on scheduled FOMC days (Mueller, Tahbaz-Salehi and Vedolin 2017); rule frozen in the ledger before this runner existed.
create or replace function intelligence.usd_short_basket_days()
returns table(trade_date date, fomc boolean, pairs integer, gross_bp numeric, cost_bp numeric, net_bp numeric)
language sql stable set search_path to '' as $function$
  with cost(sym, pips, pip, usd_base) as (values ('EURUSD', 1.0, 0.0001, false), ('GBPUSD', 1.2, 0.0001, false), ('AUDUSD', 1.2, 0.0001, false), ('NZDUSD', 2.0, 0.0001, false),
                                                 ('USDCAD', 1.9, 0.0001, true), ('USDCHF', 1.5, 0.0001, true), ('USDJPY', 1.2, 0.01, true)),
  b as (select i.symbol sym, (b.ts at time zone 'UTC')::date d, b.close from market.price_bars b join core.instruments i on i.id = b.instrument_id
        where b.timeframe = 'daily' and i.symbol in (select sym from cost)),
  r as (select b.sym, b.d, b.close, lag(b.close) over (partition by b.sym order by b.d) pc from b),
  x as (select r.d, (case when c.usd_base then -1 else 1 end) * (r.close / r.pc - 1) * 10000 ret, (c.pips + 0.6) * c.pip / r.pc * 10000 cst
        from r join cost c on c.sym = r.sym where r.pc is not null),
  dd as (select x.d, count(*)::int n, avg(x.ret) g, avg(x.cst) k from x group by x.d having count(*) = 7)
  select dd.d, exists (select 1 from macro.fomc_meetings m where m.statement_date = dd.d), dd.n, round(dd.g, 4), round(dd.k, 4), round(dd.g - dd.k, 4)
  from dd order by dd.d;
$function$;
revoke all on function intelligence.usd_short_basket_days() from public, anon, authenticated;

create or replace function intelligence.run_fomc_dollar_test(p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare h record; net double precision[]; dates date[]; net2 double precision[]; trades jsonb; base jsonb; dbl jsonb; checks jsonb; passed boolean; rid uuid; summary jsonb;
  fm double precision; fsd double precision; fn integer; om double precision; osd double precision; onn integer; wt double precision; wp double precision;
begin
  select * into h from intelligence.research_hypotheses where key = 'fx-usd-weakens-on-fomc-days';
  if not found then raise exception 'hypothesis not registered'; end if;
  select array_agg(x.net_bp::float8 order by x.trade_date), array_agg(x.trade_date order by x.trade_date), array_agg((x.gross_bp - 2 * x.cost_bp)::float8 order by x.trade_date),
         jsonb_agg(to_jsonb(x) order by x.trade_date)
    into net, dates, net2, trades from intelligence.usd_short_basket_days() x where x.fomc;
  select avg(x.gross_bp) filter (where x.fomc), stddev_samp(x.gross_bp) filter (where x.fomc), count(*) filter (where x.fomc),
         avg(x.gross_bp) filter (where not x.fomc), stddev_samp(x.gross_bp) filter (where not x.fomc), count(*) filter (where not x.fomc)
    into fm, fsd, fn, om, osd, onn from intelligence.usd_short_basket_days() x;
  wt := (fm - om) / sqrt(fsd ^ 2 / fn + osd ^ 2 / onn); wp := 1 - intelligence.norm_cdf(wt);
  base := intelligence.trade_stats(net, dates, '2017-01-01', 2000);
  dbl := intelligence.trade_stats(net2, dates, '2017-01-01', 200);
  checks := jsonb_build_array(
    jsonb_build_object('name', 'events', 'value', base -> 'n', 'threshold', '>= 120', 'pass', (base ->> 'n')::int >= 120),
    jsonb_build_object('name', 'one-sided p for a positive mean net result', 'value', base -> 'p_one_sided', 'threshold', '<= 0.05', 'pass', coalesce((base ->> 'p_one_sided')::float8 <= 0.05, false)),
    jsonb_build_object('name', 'first-half mean net', 'value', base -> 'first_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'first_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'second-half mean net', 'value', base -> 'second_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'second_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'post-publication (from 2017-01-01) mean net', 'value', base -> 'holdout_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'holdout_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net at double costs', 'value', dbl -> 'mean', 'threshold', '> 0', 'pass', coalesce((dbl ->> 'mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net without the best 5% of events', 'value', base -> 'mean_without_best_5pct', 'threshold', '> 0', 'pass', coalesce((base ->> 'mean_without_best_5pct')::float8 > 0, false)),
    jsonb_build_object('name', 'profit factor', 'value', base -> 'profit_factor', 'threshold', '>= 1.2', 'pass', coalesce((base ->> 'profit_factor')::float8 >= 1.2, false)),
    jsonb_build_object('name', 'FOMC days beat other days (Welch one-sided p)', 'value', wp, 'threshold', '<= 0.05', 'pass', coalesce(wp <= 0.05, false)));
  select bool_and((c ->> 'pass')::boolean) into passed from jsonb_array_elements(checks) c;
  summary := jsonb_build_object('hypothesis', h.key, 'code_version', 'event-study-v2', 'unit', 'basis points per event', 'base', base, 'double_cost', dbl - 'boot_ci_95',
    'benchmark', jsonb_build_object('fomc_gross_mean_bp', fm, 'fomc_n', fn, 'other_days_gross_mean_bp', om, 'other_days_n', onn, 'welch_t', wt, 'welch_p_one_sided', wp),
    'checks', checks, 'passed', passed);
  if p_persist then
    insert into intelligence.backtest_runs(code_version, symbol, params, data_summary, result, hypothesis_id)
    values ('event-study-v2', 'FX7', h.specification, jsonb_build_object('first_date', base -> 'first_date', 'last_date', base -> 'last_date', 'trades', base -> 'n'), summary || jsonb_build_object('trades', trades), h.id)
    returning id into rid;
    summary := summary || jsonb_build_object('stored_run_id', rid);
  end if;
  return summary;
end $function$;
revoke all on function intelligence.run_fomc_dollar_test(boolean) from public, anon, authenticated;
