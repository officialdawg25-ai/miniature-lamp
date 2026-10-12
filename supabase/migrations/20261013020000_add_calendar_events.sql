-- Vendor economic calendar (all countries) with point-in-time stamps. Separate from macro.economic_releases, which is keyed to the platform's own indicators.
-- first_seen_at / estimate_first_seen_at / actual_first_seen_at record when the platform obtained each value, so no test can use a value before it was known.
create table if not exists macro.calendar_events (
  id uuid primary key default gen_random_uuid(),
  event_key text not null unique,
  scheduled_at timestamptz not null,
  country text not null,
  currency text,
  event text not null,
  impact text check (impact in ('high', 'medium', 'low')),
  previous numeric,
  estimate numeric,
  actual numeric,
  source_id uuid references core.data_sources(id),
  first_seen_at timestamptz not null default now(),
  estimate_first_seen_at timestamptz,
  actual_first_seen_at timestamptz,
  last_seen_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);
create index if not exists calendar_events_scheduled_at_idx on macro.calendar_events (scheduled_at);
create index if not exists calendar_events_source_id_idx on macro.calendar_events (source_id);
alter table macro.calendar_events enable row level security;
revoke all on macro.calendar_events from anon, authenticated;

insert into core.data_sources(name, provider_type, base_url, active, metadata)
select 'Financial Modeling Prep', 'market_data_vendor', 'https://financialmodelingprep.com', true, '{"use": "economic calendar", "key_secret": "FMP_API_KEY"}'::jsonb
where not exists (select 1 from core.data_sources where name = 'Financial Modeling Prep');

create or replace function public.macro_upsert_calendar_events(p_rows jsonb)
returns integer language plpgsql security definer set search_path to '' as $function$
declare src uuid; n integer;
begin
  select id into src from core.data_sources where name = 'Financial Modeling Prep' and active;
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
revoke all on function public.macro_upsert_calendar_events(jsonb) from public, anon, authenticated;
grant execute on function public.macro_upsert_calendar_events(jsonb) to service_role;

create or replace function public.get_calendar_events()
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid());
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  return jsonb_build_object('generated_at', now(),
    'total', (select count(*) from macro.calendar_events),
    'last_refreshed', (select max(last_seen_at) from macro.calendar_events),
    'upcoming', coalesce((select jsonb_agg(to_jsonb(u) order by u.at) from (
        select e.scheduled_at at, e.country, e.currency, e.event, e.impact, e.previous, e.estimate from macro.calendar_events e
        where e.scheduled_at >= now() and e.scheduled_at < now() + interval '14 days' order by e.scheduled_at limit 200) u), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(to_jsonb(r) order by r.at desc) from (
        select e.scheduled_at at, e.country, e.currency, e.event, e.impact, e.previous, e.estimate, e.actual,
               case when e.actual is not null and e.estimate is not null then e.actual - e.estimate end surprise
        from macro.calendar_events e where e.scheduled_at < now() and e.scheduled_at >= now() - interval '7 days' order by e.scheduled_at desc limit 200) r), '[]'::jsonb));
end $function$;
revoke all on function public.get_calendar_events() from public, anon;
grant execute on function public.get_calendar_events() to authenticated;
