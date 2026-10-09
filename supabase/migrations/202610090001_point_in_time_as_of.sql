-- Historical model queries must use information that was both released and observable by the decision time.
-- This function is additive: it does not change existing tables, views, or production data.
create or replace function macro.observations_as_of(p_as_of timestamptz)
returns setof macro.point_in_time_observation_history
language sql
stable
security invoker
set search_path = ''
as $function$
  select h.*
  from macro.point_in_time_observation_history as h
  where p_as_of is not null
    and h.authoritative_release_time is not null
    and h.revision_release_time is not null
    and h.first_seen_at is not null
    and h.retrieved_at is not null
    and h.authoritative_release_time <= p_as_of
    and h.revision_release_time <= p_as_of
    and h.first_seen_at <= p_as_of
    and h.retrieved_at <= p_as_of;
$function$;

comment on function macro.observations_as_of(timestamptz) is
  'Returns only point-in-time-validated macro observations whose release, revision release, first-seen and retrieval timestamps are no later than the requested model decision time. Source/series mapping history is not yet versioned, so callers must not treat this as complete historical configuration reconstruction.';
