-- Lists indicators that have as-of (scheduled_time or better) vintage evidence. Service role only.
create or replace function macro.pit_indicator_codes()
returns setof text
language sql
stable
security invoker
set search_path = pg_catalog, macro
as $$ select distinct indicator_code from macro.pit_alfred_observations order by 1; $$;

revoke all on function macro.pit_indicator_codes() from public, anon, authenticated;
grant execute on function macro.pit_indicator_codes() to service_role;
