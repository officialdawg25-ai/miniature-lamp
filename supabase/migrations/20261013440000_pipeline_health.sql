-- Pipeline health: one read-only check of every scheduled feed against its own expected cadence, plus scheduled-job failures.
-- A feed is 'stale' when its newest stored observation is older than its limit; FX intraday feeds are 'market_closed' at the weekend.
-- private.pipeline_checks() is the single definition, used by the app (public.get_pipeline_health) and by a daily snapshot that
-- records the result, so a feed that silently stopped is visible in the app and in history.
create or replace function private.pipeline_checks()
returns table(feed text, latest timestamptz, last_ingested timestamptz, max_age interval, status text, note text)
language sql stable security definer set search_path to '' as $function$
  with fx_closed as (select (extract(isodow from now() at time zone 'UTC') = 5 and extract(hour from now() at time zone 'UTC') >= 21)
                          or extract(isodow from now() at time zone 'UTC') = 6
                          or (extract(isodow from now() at time zone 'UTC') = 7 and extract(hour from now() at time zone 'UTC') < 22) c),
  raw as (
    -- newest bar per instrument and timeframe through the primary-key index (no scan of the bar table)
    select 'Prices ' || t.tf || ' ' || i.symbol feed, lb.ts latest, lb.retrieved_at ing,
           case when t.tf = '15m' then interval '2 hours' else interval '4 days' end lim, t.tf = '15m' intraday, null::text note
      from core.instruments i cross join (values ('15m'), ('daily')) t(tf)
      join lateral (select b.ts, b.retrieved_at from market.price_bars b where b.instrument_id = i.id and b.timeframe = t.tf::core.data_frequency order by b.ts desc limit 1) lb on true
    union all
    select 'Policy rate ' || c.code, max(o.ts), max(o.retrieved_at), interval '35 days', false, case when c.code = 'BOJ' then 'market call rate, not the policy rate' end
      from macro.policy_rate_observations o join macro.central_banks c on c.id = o.central_bank_id group by c.code
    union all
    select 'Yield ' || market_code || ' ' || tenor_years::int || 'Y', max(ts), max(retrieved_at), interval '6 days', false, null
      from market.yield_observations group by market_code, tenor_years
    union all
    select 'Reference ' || s.series_id, lo.obs_date::timestamptz, lo.retrieved_at,
           case when s.series_id = 'DTWEXBGS' then interval '16 days' else interval '7 days' end, false,
           case when s.series_id = 'EVZCLS' then 'discontinued by the publisher on 2025-03-11' end
      from market.reference_series s
      left join lateral (select o.obs_date, o.retrieved_at from market.reference_observations o where o.series_id = s.series_id order by o.obs_date desc limit 1) lo on true
    union all
    select 'CFTC positioning', max(available_at), max(retrieved_at), interval '10 days', false, null from macro.cot_observations
    union all
    select 'Central-bank news', max(last_seen_at), max(last_seen_at), interval '8 hours', false, 'time of the last successful feed read' from market.news_events
    union all
    select 'Economic calendar', max(last_seen_at), max(last_seen_at), interval '3 days', false, 'time of the last successful feed read' from macro.calendar_events
    union all
    select 'Macro regime', max(created_at), max(created_at), interval '26 hours', false, null from intelligence.regime_states
    union all
    select 'Decision records', max(evaluated_at), max(evaluated_at), interval '26 hours', false, null from intelligence.decision_records
    union all
    select 'FOMC statements', (select max(available_at) from macro.fomc_statements), (select max(fetched_at) from macro.central_bank_documents where bank_code = 'FED'),
           interval '2 days', false,
           (select nullif(concat_ws('; ',
              case when count(*) filter (where not m.exhausted) > 0 then 'awaiting: ' || string_agg(m.d::text, ', ' order by m.d) filter (where not m.exhausted) end,
              case when count(*) filter (where m.exhausted) > 0 then 'not published at the expected addresses (a-d tried): ' || string_agg(m.d::text, ', ' order by m.d) filter (where m.exhausted) end), '')
            from (select f.statement_date d,
                         (select count(distinct q.url) from macro.document_fetches q where q.doc_type = 'fomc_statement' and q.doc_date = f.statement_date and q.collected_at is not null) >= 4 exhausted
                  from macro.fomc_meetings f
                  where f.statement_date < current_date - 2 and not exists (select 1 from macro.fomc_statements s where s.doc_date = f.statement_date)) m)
  )
  select r.feed, r.latest, r.ing, r.lim,
         case when r.note like 'discontinued%' then 'discontinued'
              when r.feed = 'FOMC statements' then case when r.note like 'awaiting%' then 'stale' else 'ok' end
              when r.latest is null then 'missing'
              when r.intraday and (select c from fx_closed) then case when now() - r.latest <= interval '3 days' then 'market_closed' else 'stale' end
              when now() - r.latest > r.lim then 'stale' else 'ok' end,
         r.note
  from raw r order by r.feed;
$function$;
revoke all on function private.pipeline_checks() from public, anon, authenticated;

create or replace function public.get_pipeline_health()
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
begin
  if (select auth.uid()) is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'generated_at', now(),
    'feeds', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from private.pipeline_checks() c),
    'summary', (select jsonb_object_agg(status, n) from (select status, count(*) n from private.pipeline_checks() group by status) s),
    'job_failures_24h', (select coalesce(jsonb_agg(jsonb_build_object('job', j.jobname, 'failures', f.n, 'last_failure', f.last, 'message', left(f.msg, 160)) order by f.last desc), '[]'::jsonb)
        from (select d.jobid, count(*) n, max(d.end_time) last, (array_agg(d.return_message order by d.end_time desc))[1] msg
              from cron.job_run_details d where d.status = 'failed' and d.start_time > now() - interval '24 hours' group by d.jobid) f
        join cron.job j on j.jobid = f.jobid),
    'ingestion_failures_7d', (select coalesce(jsonb_agg(jsonb_build_object('provider', a.provider, 'at', a.started_at, 'error', a.error_code, 'stage', a.error_stage) order by a.started_at desc), '[]'::jsonb)
        from (select * from market.ingestion_audit where status = 'failed' and started_at > now() - interval '7 days' order by started_at desc limit 20) a),
    'note', 'Each feed is judged against its own cadence. HTTP calls made by scheduled jobs are asynchronous, so a job can succeed while the function it calls fails; the feed age is the reliable signal.');
end $function$;
revoke all on function public.get_pipeline_health() from public, anon;
grant execute on function public.get_pipeline_health() to authenticated;

-- Daily snapshot so stale periods are kept in history (insert-only).
create table if not exists market.pipeline_health_snapshots (
  id uuid primary key default gen_random_uuid(),
  taken_at timestamptz not null default now(),
  stale_feeds text[] not null,
  missing_feeds text[] not null,
  feeds jsonb not null
);
alter table market.pipeline_health_snapshots enable row level security;
revoke all on market.pipeline_health_snapshots from public, anon, authenticated;

create or replace function private.snapshot_pipeline_health() returns integer language sql security definer set search_path to '' as $$
  insert into market.pipeline_health_snapshots(stale_feeds, missing_feeds, feeds)
  select coalesce(array_agg(feed) filter (where status = 'stale'), '{}'), coalesce(array_agg(feed) filter (where status = 'missing'), '{}'), jsonb_agg(to_jsonb(c))
  from private.pipeline_checks() c returning 1;
$$;
revoke all on function private.snapshot_pipeline_health() from public, anon, authenticated;
select cron.schedule('daily-pipeline-health-snapshot', '0 9 * * *', $job$ select private.snapshot_pipeline_health(); $job$);
