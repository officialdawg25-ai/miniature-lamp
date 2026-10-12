-- The Controls page shows the automatic risk engine: policy percentages, equity source, peak, day and week starts, computed limits, blocks and broker terms.
create or replace function public.get_account_controls()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid());
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  return jsonb_build_object('generated_at', now(), 'accounts', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id, 'name', a.name, 'broker', a.broker, 'platform', a.platform, 'currency', a.currency_code, 'broker_mode', a.metadata ->> 'broker_mode',
      'role', m.role, 'active', a.active, 'operating_mode', a.operating_mode, 'execution_mode', a.execution_mode,
      'kill_switch', a.kill_switch, 'kill_switch_reason', a.kill_switch_reason, 'kill_switch_at', a.kill_switch_at,
      'initial_balance', a.initial_balance,
      'risk_policy', a.metadata -> 'risk_policy', 'auto_risk', a.metadata -> 'auto_risk',
      'policy', jsonb_build_object('max_risk_per_trade', a.max_risk_per_trade, 'risk_per_trade_fraction', a.metadata -> 'risk_per_trade_fraction',
        'max_daily_loss', a.max_daily_loss, 'max_weekly_loss', a.max_weekly_loss, 'max_open_trades', a.max_open_trades,
        'max_aggregate_open_risk', a.metadata -> 'max_aggregate_open_risk', 'max_setup_age_minutes', coalesce(a.metadata -> 'max_setup_age_minutes', to_jsonb(1440))),
      'audit', coalesce((select jsonb_agg(jsonb_build_object('at', e.occurred_at, 'event', e.event_type, 'actor', e.actor_role, 'before', e.before_state, 'after', e.after_state, 'reason', e.metadata ->> 'reason') order by e.occurred_at desc)
        from (select * from trading.execution_audit_events x where x.account_id = a.id and x.entity_type = 'account_control' order by x.occurred_at desc limit 20) e), '[]'::jsonb)
    ) order by a.name)
    from trading.accounts a join trading.account_members m on m.account_id = a.id and m.user_id = uid and m.active), '[]'::jsonb));
end $function$;
