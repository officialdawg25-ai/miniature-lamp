-- Forward test of the FOMC-day EURUSD rule (eurusd-fomc-day-long-stop56-forward) on 15-minute bars, plus forward EURUSD ingestion.
create or replace function intelligence.eurusd_fomc_15m_trades(p_from date)
returns table(event_date date, entry_at timestamptz, entry numeric, min_low numeric, stopped boolean, exit_price numeric, net_pips numeric, net_pips_double numeric)
language sql stable set search_path to '' as $function$
  with inst as (select id from core.instruments where symbol = 'EURUSD'),
  ev as (select m.statement_date d from macro.fomc_meetings m where m.statement_date >= p_from and m.statement_date <= current_date),
  en as (select ev.d, e.ts, e.close from ev cross join lateral (
           select b.ts, b.close from market.price_bars b, inst where b.instrument_id = inst.id and b.timeframe = '15m'
             and b.ts < ev.d::timestamp at time zone 'UTC' and extract(hour from b.ts at time zone 'UTC') = 22 and extract(minute from b.ts at time zone 'UTC') = 15
           order by b.ts desc limit 1) e
         where e.ts > ev.d::timestamp at time zone 'UTC' - interval '4 days'),
  ex as (select en.d, en.ts, en.close entry, x.close exit_close,
           (select min(b.low) from market.price_bars b, inst where b.instrument_id = inst.id and b.timeframe = '15m'
              and b.ts > en.ts and b.ts <= en.d::timestamp at time zone 'UTC' + interval '21 hours 45 minutes') lo
         from en join market.price_bars x on x.instrument_id = (select id from inst) and x.timeframe = '15m' and x.ts = en.d::timestamp at time zone 'UTC' + interval '21 hours 45 minutes')
  select d, ts, entry, lo, lo <= entry - 0.0053, case when lo <= entry - 0.0053 then entry - 0.0058 else exit_close end,
         round(((case when lo <= entry - 0.0053 then entry - 0.0058 else exit_close end) - entry) * 10000 - 1.6, 2),
         round(((case when lo <= entry - 0.0053 then entry - 0.0058 else exit_close end) - entry) * 10000 - 3.2, 2)
  from ex order by d;
$function$;
revoke all on function intelligence.eurusd_fomc_15m_trades(date) from public, anon, authenticated;

create or replace function intelligence.run_eurusd_fomc_forward(p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare h record; n integer; m double precision; sd double precision; t double precision; p double precision; pf double precision; worst_cum double precision; trades jsonb; phase text; passed boolean; summary jsonb; rid uuid;
begin
  select * into h from intelligence.research_hypotheses where key = 'eurusd-fomc-day-long-stop56-forward';
  if not found then raise exception 'hypothesis not registered'; end if;
  select count(*), avg(x.net_pips), stddev_samp(x.net_pips),
         sum(x.net_pips) filter (where x.net_pips > 0) / nullif(-sum(x.net_pips) filter (where x.net_pips < 0), 0),
         jsonb_agg(to_jsonb(x) order by x.event_date)
    into n, m, sd, pf, trades from intelligence.eurusd_fomc_15m_trades('2026-10-28') x;
  select coalesce(min(c.cum), 0) into worst_cum from (select sum(x.net_pips) over (order by x.event_date) cum from intelligence.eurusd_fomc_15m_trades('2026-10-28') x) c;
  if n >= 2 and sd > 0 then t := m / (sd / sqrt(n)); p := 1 - intelligence.norm_cdf(t); end if;
  phase := case when worst_cum <= -360 then 'early stop: cumulative loss reached 360 pips' when n >= 24 then 'decision' else 'interim (monitoring only)' end;
  passed := case when phase = 'decision' then coalesce(m > 0 and p <= 0.10 and pf >= 1.2, false) when phase like 'early stop%' then false end;
  summary := jsonb_build_object('hypothesis', h.key, 'unit', 'pips per trade', 'events', n, 'decision_at', 24, 'mean_net', m, 'sd', sd, 't', t, 'p_one_sided', p, 'profit_factor', pf,
    'worst_cumulative_pips', worst_cum, 'phase', phase, 'passed', passed);
  if p_persist and n > 0 then
    insert into intelligence.backtest_runs(code_version, symbol, params, data_summary, result, hypothesis_id)
    values ('event-study-v2', 'EURUSD', h.specification, jsonb_build_object('events', n, 'phase', phase), summary || jsonb_build_object('trades', trades), h.id)
    returning id into rid;
    summary := summary || jsonb_build_object('stored_run_id', rid);
  end if;
  return summary;
end $function$;
revoke all on function intelligence.run_eurusd_fomc_forward(boolean) from public, anon, authenticated;

-- Forward 15-minute EURUSD bars (hourly on weekdays), and a stored forward run on each FOMC day after the exit bar has been ingested.
select cron.schedule('intraday-forward-eurusd', '5 * * * 1-5', $job$
  select net.http_post(url := 'https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/intraday-twelvedata',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),
    body := '{"symbol":"EURUSD","dry_run":false,"direction":"forward"}'::jsonb, timeout_milliseconds := 60000);
$job$);
select cron.schedule('eurusd-fomc-forward-run', '40 22 * * 1-5', $job$
  select intelligence.run_eurusd_fomc_forward(true) where exists (select 1 from macro.fomc_meetings where statement_date = current_date);
$job$);
