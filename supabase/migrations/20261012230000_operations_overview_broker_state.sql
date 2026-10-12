-- Operations overview now includes the execution host status, the latest broker snapshot, reconciliation flags and recent broker deals per account.
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
        'broker_mode', a.metadata ->> 'broker_mode',
        'limits', jsonb_build_object('per_trade', a.max_risk_per_trade, 'daily', a.max_daily_loss, 'weekly', a.max_weekly_loss, 'open_trades', a.max_open_trades),
        'open_positions', (select count(*) from trading.positions p where p.account_id = a.id and p.status = 'open'),
        'host', (select jsonb_build_object('name', x.name, 'active', x.active, 'last_seen_at', x.last_seen_at, 'mode', x.mode) from trading.execution_hosts x where x.account_id = a.id order by x.created_at desc limit 1),
        'snapshot', (select jsonb_build_object('taken_at', s.taken_at, 'balance', s.balance, 'equity', s.equity, 'margin_used', s.margin_used, 'currency', s.currency,
                       'position_count', s.position_count, 'order_count', jsonb_array_length(s.orders), 'positions', s.positions)
                     from trading.broker_snapshots s where s.account_id = a.id order by s.taken_at desc limit 1),
        'flags', trading.reconcile_account(a.id),
        'recent_deals', coalesce((select jsonb_agg(jsonb_build_object('time', dd.deal_time, 'symbol', dd.symbol, 'side', dd.side, 'entry', dd.entry, 'volume', dd.volume, 'price', dd.price,
                          'profit', dd.profit, 'commission', dd.commission, 'swap', dd.swap) order by dd.deal_time desc)
                          from (select * from trading.broker_deals bd where bd.account_id = a.id order by bd.deal_time desc limit 10) dd), '[]'::jsonb),
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
