-- Batch 12: equity variance risk premium monthly timing (spy-variance-risk-premium-monthly-timing); rules frozen in the ledger
-- before VIX was stored or this runner existed.
create or replace function intelligence.spy_vrp_months()
returns table(signal_month date, last_day date, entry_day date, exit_day date, rv numeric, iv numeric, vrp numeric, vrp_median numeric,
              in_market boolean, hold_return numeric, net numeric, stress numeric)
language sql stable set search_path to '' as $function$
  with spy as materialized (
    select (b.ts at time zone 'UTC')::date d, b.close, lag(b.close) over (order by b.ts) pc
    from market.price_bars b join core.instruments i on i.id = b.instrument_id where i.symbol = 'SPY' and b.timeframe = 'daily'),
  mo as materialized (
    select date_trunc('month', d)::date m, min(d) first_day, max(d) last_day, count(*) filter (where pc is not null) days,
           sum(ln(close / pc) ^ 2) filter (where pc is not null) rv
    from spy group by 1),
  sig as materialized (
    select mo.m, mo.last_day, mo.days, mo.rv,
           (select v.value from market.reference_observations v where v.series_id = 'VIXCLS' and v.obs_date <= mo.last_day order by v.obs_date desc limit 1) vix,
           (select v.obs_date from market.reference_observations v where v.series_id = 'VIXCLS' and v.obs_date <= mo.last_day order by v.obs_date desc limit 1) vix_date,
           lead(mo.first_day, 1) over (order by mo.m) entry_day, lead(mo.first_day, 2) over (order by mo.m) exit_day
    from mo),
  v as materialized (
    select s.*, (s.vix / 100) ^ 2 / 12 iv, (s.vix / 100) ^ 2 / 12 - s.rv vrp, row_number() over (order by s.m) rn
    from sig s where s.days >= 15 and s.vix is not null and s.vix_date > s.last_day - 7),
  med as materialized (
    select v.*, (select percentile_cont(0.5) within group (order by w.vrp) from v w where w.rn between v.rn - 59 and v.rn) md,
           (select count(*) from v w where w.rn between v.rn - 59 and v.rn and w.m >= v.m - interval '59 months') cnt
    from v),
  h as (
    select med.*, e.close c0, x.close c1,
           (select avg(r.value) from market.reference_observations r where r.series_id = 'DFF' and r.obs_date >= med.entry_day and r.obs_date < med.exit_day) dff
    from med join spy e on e.d = med.entry_day join spy x on x.d = med.exit_day
    where med.cnt = 60
      -- the VIX value used must have been available before the entry close (about 20:00-21:00 UTC on entry_day)
      and (select o.available_at from market.reference_observations o where o.series_id = 'VIXCLS' and o.obs_date = med.vix_date) <= med.entry_day::timestamptz + interval '20 hours')
  select m, last_day, entry_day, exit_day, round(rv::numeric, 8), round(iv::numeric, 8), round(vrp::numeric, 8), round(md::numeric, 8), vrp > md,
         round((c1 / c0 - 1) * 100, 4),
         round(((c1 / c0 - 1) - (dff / 100 + 0.025) * (exit_day - entry_day) / 365.0 - 0.0002) * 100, 4),
         round(((c1 / c0 - 1) - (dff / 100 + 0.045) * (exit_day - entry_day) / 365.0 - 0.0004 - 0.015 * (exit_day - entry_day) / 365.0) * 100, 4)
  from h where dff is not null order by m;
$function$;
revoke all on function intelligence.spy_vrp_months() from public, anon, authenticated;

create or replace function intelligence.run_spy_vrp_test(p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare h record; net double precision[]; dates date[]; net2 double precision[]; trades jsonb; base jsonb; dbl jsonb; checks jsonb; passed boolean; rid uuid; summary jsonb;
  im double precision; isd double precision; inn integer; om double precision; osd double precision; onn integer; wt double precision; wp double precision;
  s_mean double precision; s_sd double precision; b_mean double precision; b_sd double precision; s_sharpe double precision; b_sharpe double precision; mdd double precision;
begin
  select * into h from intelligence.research_hypotheses where key = 'spy-variance-risk-premium-monthly-timing';
  if not found then raise exception 'hypothesis not registered'; end if;
  create temp table if not exists _vrp_months on commit drop as select * from intelligence.spy_vrp_months();
  select array_agg(x.net::float8 order by x.entry_day), array_agg(x.entry_day order by x.entry_day), array_agg(x.stress::float8 order by x.entry_day), jsonb_agg(to_jsonb(x) order by x.entry_day)
    into net, dates, net2, trades from pg_temp._vrp_months x where x.in_market;
  select avg(x.net) filter (where x.in_market), stddev_samp(x.net) filter (where x.in_market), count(*) filter (where x.in_market),
         avg(x.net) filter (where not x.in_market), stddev_samp(x.net) filter (where not x.in_market), count(*) filter (where not x.in_market),
         avg(case when x.in_market then x.net else 0 end), stddev_samp(case when x.in_market then x.net else 0 end), avg(x.net), stddev_samp(x.net)
    into im, isd, inn, om, osd, onn, s_mean, s_sd, b_mean, b_sd from pg_temp._vrp_months x;
  wt := (im - om) / sqrt(isd ^ 2 / inn + osd ^ 2 / onn); wp := 1 - intelligence.norm_cdf(wt);
  s_sharpe := s_mean / nullif(s_sd, 0) * sqrt(12); b_sharpe := b_mean / nullif(b_sd, 0) * sqrt(12);
  select max(greatest(0, c.peak) - c.cum) into mdd from (select q.cum, max(q.cum) over (order by q.entry_day) peak from (
    select x.entry_day, sum(case when x.in_market then x.net / 100 * 60 else 0 end) over (order by x.entry_day) cum from pg_temp._vrp_months x) q) c;
  base := intelligence.trade_stats(net, dates, '2010-01-01', 2000);
  dbl := intelligence.trade_stats(net2, dates, '2010-01-01', 200);
  checks := jsonb_build_array(
    jsonb_build_object('name', 'in-market months', 'value', base -> 'n', 'threshold', '>= 120', 'pass', (base ->> 'n')::int >= 120),
    jsonb_build_object('name', 'one-sided p for a positive mean net in-market month', 'value', base -> 'p_one_sided', 'threshold', '<= 0.025', 'pass', coalesce((base ->> 'p_one_sided')::float8 <= 0.025, false)),
    jsonb_build_object('name', 'in-market months beat out-of-market months (Welch one-sided p)', 'value', wp, 'threshold', '<= 0.05', 'pass', coalesce(wp <= 0.05, false)),
    jsonb_build_object('name', 'first-half mean net', 'value', base -> 'first_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'first_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'second-half mean net', 'value', base -> 'second_half_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'second_half_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'post-publication (from 2010-01) mean net', 'value', base -> 'holdout_mean', 'threshold', '> 0', 'pass', coalesce((base ->> 'holdout_mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net at stress', 'value', dbl -> 'mean', 'threshold', '> 0', 'pass', coalesce((dbl ->> 'mean')::float8 > 0, false)),
    jsonb_build_object('name', 'mean net without the best 5% of months', 'value', base -> 'mean_without_best_5pct', 'threshold', '> 0', 'pass', coalesce((base ->> 'mean_without_best_5pct')::float8 > 0, false)),
    jsonb_build_object('name', 'Sharpe of timed strategy not below buy and hold', 'value', jsonb_build_object('timed', s_sharpe, 'buy_and_hold', b_sharpe), 'threshold', 'timed >= buy and hold', 'pass', coalesce(s_sharpe >= b_sharpe, false)),
    jsonb_build_object('name', 'maximum drawdown at 60 USD notional (USD)', 'value', mdd, 'threshold', '< 36', 'pass', coalesce(mdd < 36, false)));
  select bool_and((c ->> 'pass')::boolean) into passed from jsonb_array_elements(checks) c;
  summary := jsonb_build_object('hypothesis', h.key, 'code_version', 'vrp-v1', 'unit', 'percent of notional per month', 'base', base, 'stress', dbl - 'boot_ci_95',
    'benchmark', jsonb_build_object('in_market_mean_net', im, 'in_market_n', inn, 'out_of_market_mean_net', om, 'out_of_market_n', onn, 'welch_t', wt, 'welch_p_one_sided', wp,
      'timed_sharpe', s_sharpe, 'buy_and_hold_sharpe', b_sharpe), 'max_drawdown_usd_at_60_notional', mdd, 'checks', checks, 'passed', passed);
  if p_persist then
    insert into intelligence.backtest_runs(code_version, symbol, params, data_summary, result, hypothesis_id)
    values ('vrp-v1', 'SPY', h.specification, jsonb_build_object('first_date', base -> 'first_date', 'last_date', base -> 'last_date', 'in_market_months', base -> 'n', 'all_months', inn + onn),
            summary || jsonb_build_object('months', trades), h.id)
    returning id into rid;
    summary := summary || jsonb_build_object('stored_run_id', rid);
  end if;
  return summary;
end $function$;
revoke all on function intelligence.run_spy_vrp_test(boolean) from public, anon, authenticated;
