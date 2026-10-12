-- Read-only overview for the Operations page: latest decision per instrument, research ledger status, and the caller's own accounts.
-- SECURITY DEFINER because the ledger tables have no browser policies; access is limited to institutional users, and account data
-- is limited to accounts the caller is an active member of.
create or replace function public.get_operations_overview()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  uid uuid := (select auth.uid());
  result jsonb;
begin
  if uid is null or not (select private.is_institutional_user()) then
    raise exception 'institutional access required' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'decisions', coalesce((
      select jsonb_agg(d order by d.symbol) from (
        select distinct on (dr.instrument_id) i.symbol, dr.outcome, dr.reason_codes, dr.evaluated_at, dr.mode, dr.evidence
        from intelligence.decision_records dr join core.instruments i on i.id = dr.instrument_id
        order by dr.instrument_id, dr.evaluated_at desc) d), '[]'::jsonb),
    'hypotheses', coalesce((
      select jsonb_agg(jsonb_build_object('key', h.key, 'title', h.title, 'status', h.status, 'status_changed_at', h.status_changed_at) order by h.key)
      from intelligence.research_hypotheses h), '[]'::jsonb),
    'accounts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', a.name, 'broker', a.broker, 'platform', a.platform, 'currency', a.currency_code, 'execution_mode', a.execution_mode, 'active', a.active,
        'open_positions', (select count(*) from trading.positions p where p.account_id = a.id and p.status = 'open'),
        'recent_requests', coalesce((select jsonb_agg(jsonb_build_object('requested_at', r.requested_at, 'side', r.side, 'quantity', r.quantity, 'status', r.status, 'broker_dispatch_state', r.broker_dispatch_state, 'rejection_reason', r.rejection_reason) order by r.requested_at desc)
          from (select * from trading.execution_requests er where er.account_id = a.id order by er.requested_at desc limit 10) r), '[]'::jsonb)))
      from trading.accounts a join trading.account_members m on m.account_id = a.id and m.user_id = uid and m.active), '[]'::jsonb),
    'generated_at', now()
  ) into result;
  return result;
end;
$function$;
revoke all on function public.get_operations_overview() from public, anon;
grant execute on function public.get_operations_overview() to authenticated;
