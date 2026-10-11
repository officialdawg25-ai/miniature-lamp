-- Scheduled-availability tier for ALFRED vintage evidence and as-of (point-in-time) windows.
--
-- Rule: an ALFRED vintage row may be given availability_time_precision='scheduled_time' only when
--   * its vintage date was matched to a BLS release of the correct category (evidence_status='calendar_date_matched'),
--   * the matched BLS calendar entry's scheduled release time is already in the past, and
--   * that scheduled time falls on the vintage date (America/New_York calendar day).
-- point_in_time_eligible stays FALSE: the existing CHECK alfred_pit_requires_verified_availability reserves
-- eligibility for verified timestamps. Nothing here changes provider_observations or existing constraints.

create or replace view macro.v_alfred_promotion_candidates
with (security_invoker = true) as
select a.id,
       a.indicator_code,
       c.scheduled_release_time,
       coalesce(c.raw_payload ->> 'source_url', a.bls_archive_url) as evidence_url
from macro.alfred_vintage_observations a
join macro.provider_release_calendars c on c.id = a.matched_bls_calendar_id
where a.evidence_status = 'calendar_date_matched'
  and a.availability_time_precision = 'date_only'
  and a.observation_value is not null
  and a.point_in_time_eligible = false
  and a.vintage_start = a.vintage_end
  and c.provider = 'BLS'
  and c.scheduled_release_time <= now()
  and (c.scheduled_release_time at time zone 'America/New_York')::date = a.vintage_start;

create or replace function macro.promote_alfred_scheduled_availability(p_dry_run boolean default true)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, macro
as $$
declare
  v_candidates jsonb;
  v_breakdown jsonb;
  v_updated integer := 0;
begin
  select coalesce(jsonb_object_agg(indicator_code, n), '{}'::jsonb) into v_candidates
  from (select indicator_code, count(*) n from macro.v_alfred_promotion_candidates group by 1) s;

  select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) into v_breakdown
  from (select evidence_status || '/' || availability_time_precision as k, count(*) n
        from macro.alfred_vintage_observations group by 1) s;

  if not coalesce(p_dry_run, true) then
    update macro.alfred_vintage_observations a
       set source_available_at = c.scheduled_release_time,
           availability_time_precision = 'scheduled_time',
           availability_evidence_url = c.evidence_url,
           validation_notes = a.validation_notes || jsonb_build_object(
             'availability_basis', 'bls_official_release_schedule',
             'availability_promoted_at', now(),
             'availability_note', 'Scheduled BLS release time; actual publication time not independently verified. Not point-in-time eligible.')
      from macro.v_alfred_promotion_candidates c
     where a.id = c.id;
    get diagnostics v_updated = row_count;
  end if;

  return jsonb_build_object(
    'dry_run', coalesce(p_dry_run, true),
    'candidates_by_indicator', v_candidates,
    'candidates_total', (select coalesce(sum(value::int), 0) from jsonb_each_text(v_candidates)),
    'rows_updated', v_updated,
    'store_breakdown_before', v_breakdown,
    'point_in_time_eligible_rows_written', 0
  );
end;
$$;

-- Rows usable for as-of research: availability established at scheduled_time or better.
create or replace view macro.pit_alfred_observations
with (security_invoker = true) as
select indicator_id, indicator_code, observation_date,
       observation_value as value,
       source_available_at as available_at,
       availability_time_precision as tier,
       vintage_start
from macro.alfred_vintage_observations
where availability_time_precision in ('scheduled_time', 'verified_timestamp')
  and source_available_at is not null
  and observation_value is not null;

-- For every release event of an indicator, the latest p_window observations as they were known at that moment.
-- The value for each observation is the latest vintage with available_at <= the event time (no look-ahead).
create or replace function macro.pit_event_windows(p_indicator_code text, p_window integer default 14)
returns table (as_of timestamptz, observation_dates date[], vals numeric[], tiers text[])
language sql
stable
security invoker
set search_path = pg_catalog, macro
as $$
  with events as (
    select distinct available_at from macro.pit_alfred_observations where indicator_code = p_indicator_code
  ), known as (
    select e.available_at as as_of, o.observation_date, o.value, o.tier,
           row_number() over (partition by e.available_at order by o.observation_date desc) as rn
    from events e
    cross join lateral (
      select distinct on (p.observation_date) p.observation_date, p.value, p.tier
      from macro.pit_alfred_observations p
      where p.indicator_code = p_indicator_code and p.available_at <= e.available_at
      order by p.observation_date, p.available_at desc
    ) o
  )
  select k.as_of,
         array_agg(k.observation_date order by k.observation_date),
         array_agg(k.value order by k.observation_date),
         array_agg(distinct k.tier)
  from known k
  where k.rn <= greatest(p_window, 1)
  group by k.as_of
  order by k.as_of;
$$;

revoke all on function macro.promote_alfred_scheduled_availability(boolean) from public, anon, authenticated;
revoke all on function macro.pit_event_windows(text, integer) from public, anon, authenticated;
revoke all on macro.v_alfred_promotion_candidates from public, anon, authenticated;
revoke all on macro.pit_alfred_observations from public, anon, authenticated;
grant execute on function macro.promote_alfred_scheduled_availability(boolean) to service_role;
grant execute on function macro.pit_event_windows(text, integer) to service_role;
grant select on macro.v_alfred_promotion_candidates to service_role;
grant select on macro.pit_alfred_observations to service_role;
