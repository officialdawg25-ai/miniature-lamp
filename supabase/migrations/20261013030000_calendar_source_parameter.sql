-- The calendar upsert now takes the source name, because the vendor with actual values (FMP) needs a paid plan and the free feed (Forex Factory via Faireconomy) has forecasts only.
insert into core.data_sources(name, provider_type, base_url, active, metadata)
select 'Forex Factory feed (Faireconomy)', 'market_data_vendor', 'https://nfs.faireconomy.media', true,
  '{"use": "economic calendar", "unofficial": true, "has_actuals": false, "terms": "free weekly JSON feed, forecast and previous only; not a licensed redistribution source"}'::jsonb
where not exists (select 1 from core.data_sources where name = 'Forex Factory feed (Faireconomy)');
update core.data_sources set active = false, metadata = metadata || '{"note": "economic calendar endpoint needs a paid plan (HTTP 402 on the free key)"}'::jsonb where name = 'Financial Modeling Prep';

-- The first version, macro_upsert_calendar_events(jsonb), is left in place unused (service role only); dropping it is an owner task.
create or replace function public.macro_upsert_calendar_rows(p_rows jsonb, p_source text)
returns integer language plpgsql security definer set search_path to '' as $function$
declare src uuid; n integer;
begin
  select id into src from core.data_sources where name = p_source;
  if src is null then raise exception 'calendar source not registered'; end if;
  with incoming as (
    select x.event_key, x.scheduled_at, x.country, x.currency, x.event, x.impact, x.previous, x.estimate, x.actual
    from jsonb_to_recordset(p_rows) as x(event_key text, scheduled_at timestamptz, country text, currency text, event text, impact text, previous numeric, estimate numeric, actual numeric)
  ), up as (
    insert into macro.calendar_events as e (event_key, scheduled_at, country, currency, event, impact, previous, estimate, actual, source_id, estimate_first_seen_at, actual_first_seen_at)
    select i.event_key, i.scheduled_at, i.country, i.currency, i.event, i.impact, i.previous, i.estimate, i.actual, src,
           case when i.estimate is not null then now() end, case when i.actual is not null then now() end
    from incoming i
    on conflict (event_key) do update set
      impact = coalesce(excluded.impact, e.impact), previous = coalesce(excluded.previous, e.previous),
      estimate = coalesce(excluded.estimate, e.estimate), actual = coalesce(excluded.actual, e.actual),
      estimate_first_seen_at = coalesce(e.estimate_first_seen_at, case when excluded.estimate is not null then now() end),
      actual_first_seen_at = coalesce(e.actual_first_seen_at, case when excluded.actual is not null then now() end),
      last_seen_at = now()
    returning 1)
  select count(*) into n from up;
  return n;
end $function$;
revoke all on function public.macro_upsert_calendar_rows(jsonb, text) from public, anon, authenticated;
grant execute on function public.macro_upsert_calendar_rows(jsonb, text) to service_role;

-- Hourly on weekdays, 06:07-22:07 UTC (17 requests a day for each of two weekly files).
select cron.schedule('hourly-calendar-refresh', '7 6-22 * * 1-5', $job$
  select net.http_post(
    url := 'https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/calendar-ingestion',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),
    body := '{"dry_run": false, "source": "faireconomy"}'::jsonb,
    timeout_milliseconds := 40000);
$job$);
