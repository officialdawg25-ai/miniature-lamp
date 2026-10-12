-- P0 safety: the pre-trade risk gate and the paper dispatch path.
--
-- Defects fixed (reproduced on the live database before this migration):
--  1. A "blocked" outcome could be downgraded to "manual_review" by a later check (an unapproved setup with missing risk data, or a
--     per-trade risk breach on an automated account). A human can approve manual_review but never blocked, so a block could be approved.
--  2. The gate evaluated only the setup's own declared maximum loss. request_execution took quantity, stop and side from the caller and
--     never compared them with the approved setup, and did not require a stop loss.
--  3. Missing account risk limits meant "unlimited" instead of "no policy".
--  4. The paper dispatcher Edge Function read and wrote the trading tables with the service key, but service_role has no access to the
--     trading schema (and the schema is not exposed to the API), so it could never have worked.
--
-- Nothing is dropped: the stricter gate is a new function (evaluate_execution_risk) and the old entry point delegates to it.
-- Design: severity only escalates (approved < manual_review < blocked). Dispatch re-runs the gate immediately before any fill.
-- No privileges are granted to service_role. The only new API surface is public.dispatch_paper_execution, callable by signed-in users.

create function trading.evaluate_execution_risk(
  p_account_id uuid, p_setup_id uuid,
  p_side trading.side default null, p_quantity numeric default null, p_order_type text default null,
  p_requested_price numeric default null, p_stop_loss numeric default null, p_take_profit numeric default null,
  p_exclude_request_id uuid default null
)
returns table(decision text, reasons jsonb, metrics jsonb, risk_decision_id uuid)
language plpgsql
security definer
set search_path to 'trading', 'public'
as $function$
declare
  a trading.accounts%rowtype;
  s trading.trade_setups%rowtype;
  blocked text[] := '{}';
  review text[] := '{}';
  open_count integer := 0;
  daily_realized numeric := 0;
  weekly_realized numeric := 0;
  open_risk numeric := 0;
  max_age_min numeric;
  agg_limit numeric;
  mid numeric;
  denom numeric;
  ratio numeric := 1;
  est_risk numeric;
  eff_side trading.side;
  req_validated boolean := (p_side is not null or p_quantity is not null);
  setup_ok boolean := false;
  final_decision text;
  reason_list jsonb;
  m jsonb;
  rd uuid;
begin
  select * into a from trading.accounts where id = p_account_id;
  if not found then
    raise exception 'account not found';
  end if;
  if not a.active then blocked := blocked || 'account_inactive'; end if;

  select * into s from trading.trade_setups where id = p_setup_id;
  if not found then
    blocked := blocked || 'setup_not_found';
  elsif s.account_id <> p_account_id then
    blocked := blocked || 'setup_account_mismatch';
  else
    setup_ok := true;
    if s.status <> 'approved' then blocked := blocked || 'setup_not_approved'; end if;
    if s.maximum_loss is null then blocked := blocked || 'setup_maximum_loss_missing'; end if;
    if s.position_size is null then blocked := blocked || 'setup_position_size_missing'; end if;
    if s.stop_loss is null then blocked := blocked || 'setup_stop_loss_missing'; end if;
    max_age_min := case when a.metadata ->> 'max_setup_age_minutes' ~ '^[0-9]+(\.[0-9]+)?$' then (a.metadata ->> 'max_setup_age_minutes')::numeric else 1440 end;
    if s.as_of < now() - make_interval(secs => max_age_min * 60) then blocked := blocked || 'setup_expired'; end if;
    if s.as_of > now() + interval '5 minutes' then blocked := blocked || 'setup_timestamp_in_future'; end if;
  end if;

  -- Account risk policy: a missing limit means there is no policy, not an unlimited one.
  if a.max_risk_per_trade is null then blocked := blocked || 'risk_limit_not_configured:max_risk_per_trade'; end if;
  if a.max_daily_loss is null then blocked := blocked || 'risk_limit_not_configured:max_daily_loss'; end if;
  if a.max_weekly_loss is null then blocked := blocked || 'risk_limit_not_configured:max_weekly_loss'; end if;
  if a.max_open_trades is null then blocked := blocked || 'risk_limit_not_configured:max_open_trades'; end if;

  select count(*) into open_count from trading.positions p where p.account_id = a.id and p.status = 'open';
  if a.max_open_trades is not null and open_count >= a.max_open_trades then blocked := blocked || 'max_open_trades_reached'; end if;

  select coalesce(sum(case when t.pnl < 0 then t.pnl else 0 end), 0) into daily_realized
  from trading.trades t where t.account_id = a.id and t.closed_at >= date_trunc('day', now());
  select coalesce(sum(case when t.pnl < 0 then t.pnl else 0 end), 0) into weekly_realized
  from trading.trades t where t.account_id = a.id and t.closed_at >= date_trunc('week', now());
  if a.max_daily_loss is not null and abs(daily_realized) >= a.max_daily_loss then blocked := blocked || 'max_daily_loss_reached'; end if;
  if a.max_weekly_loss is not null and abs(weekly_realized) >= a.max_weekly_loss then blocked := blocked || 'max_weekly_loss_reached'; end if;

  if a.execution_mode = 'automated' then review := review || 'automated_execution_not_enabled_by_risk_gate'; end if;

  -- Request-level validation: the actual quantity, stop and prices must fit inside what the setup approved.
  if setup_ok and req_validated then
    eff_side := coalesce(p_side, s.side);
    if p_side is null then blocked := blocked || 'request_side_missing';
    elsif p_side <> s.side then blocked := blocked || 'request_side_differs_from_setup'; end if;

    if p_quantity is null or p_quantity <= 0 then
      blocked := blocked || 'request_quantity_invalid';
    elsif s.position_size is not null and p_quantity > s.position_size then
      blocked := blocked || 'request_quantity_exceeds_setup_position_size';
    end if;

    if p_order_type is null or p_order_type not in ('market', 'limit') then blocked := blocked || 'unsupported_order_type'; end if;
    if p_requested_price is null or p_requested_price <= 0 then blocked := blocked || 'reference_price_required'; end if;
    if p_stop_loss is null or p_stop_loss <= 0 then blocked := blocked || 'stop_loss_required'; end if;

    if p_requested_price is not null and p_requested_price > 0 and p_stop_loss is not null and p_stop_loss > 0 then
      if eff_side = 'long' then
        if p_stop_loss >= p_requested_price then blocked := blocked || 'stop_not_beyond_entry'; end if;
        if s.stop_loss is not null and p_stop_loss < s.stop_loss then blocked := blocked || 'stop_looser_than_setup'; end if;
        if p_take_profit is not null and p_take_profit <= p_requested_price then blocked := blocked || 'take_profit_wrong_side'; end if;
      else
        if p_stop_loss <= p_requested_price then blocked := blocked || 'stop_not_beyond_entry'; end if;
        if s.stop_loss is not null and p_stop_loss > s.stop_loss then blocked := blocked || 'stop_looser_than_setup'; end if;
        if p_take_profit is not null and p_take_profit >= p_requested_price then blocked := blocked || 'take_profit_wrong_side'; end if;
      end if;
      if s.entry_low is not null and s.entry_high is not null and (p_requested_price < s.entry_low or p_requested_price > s.entry_high) then
        blocked := blocked || 'price_outside_setup_entry_range';
      end if;
    end if;

    -- Scale the setup's declared maximum loss by the size and stop distance actually requested.
    if p_quantity is not null and p_quantity > 0 and s.position_size is not null and s.position_size > 0 then
      ratio := p_quantity / s.position_size;
      if s.entry_low is not null and s.entry_high is not null and s.stop_loss is not null and p_requested_price is not null and p_stop_loss is not null then
        mid := (s.entry_low + s.entry_high) / 2;
        denom := abs(mid - s.stop_loss);
        if denom > 0 then ratio := ratio * (abs(p_requested_price - p_stop_loss) / denom); end if;
      end if;
    end if;
  end if;

  est_risk := case when s.maximum_loss is not null then s.maximum_loss * ratio else null end;
  if a.max_risk_per_trade is not null and est_risk is not null and est_risk > a.max_risk_per_trade then
    blocked := blocked || 'per_trade_risk_limit_exceeded';
  end if;

  -- Aggregate open risk, from the declared maximum loss of the setups behind trades that are still open.
  select coalesce(sum(ts.maximum_loss), 0) into open_risk
  from trading.trades t join trading.trade_setups ts on ts.id = t.setup_id
  where t.account_id = a.id and t.closed_at is null;
  agg_limit := case when a.metadata ->> 'max_aggregate_open_risk' ~ '^[0-9]+(\.[0-9]+)?$' then (a.metadata ->> 'max_aggregate_open_risk')::numeric else null end;
  if agg_limit is null then
    review := review || 'aggregate_open_risk_limit_not_configured';
  elsif open_risk + coalesce(est_risk, 0) > agg_limit then
    blocked := blocked || 'aggregate_open_risk_limit_exceeded';
  end if;

  -- One live request per setup: prevents duplicate orders from retries and double submission.
  if exists (
    select 1 from trading.execution_requests er
    where er.setup_id = p_setup_id and er.status in ('manual_review', 'authorized', 'submitted')
      and (p_exclude_request_id is null or er.id <> p_exclude_request_id)
  ) then
    blocked := blocked || 'setup_already_has_active_execution_request';
  end if;

  final_decision := case when cardinality(blocked) > 0 then 'blocked' when cardinality(review) > 0 then 'manual_review' else 'approved' end;
  reason_list := to_jsonb(blocked || review);
  m := jsonb_build_object(
    'open_positions', open_count, 'daily_realized_loss', abs(daily_realized), 'weekly_realized_loss', abs(weekly_realized),
    'setup_maximum_loss', s.maximum_loss, 'estimated_request_risk', est_risk, 'account_max_risk_per_trade', a.max_risk_per_trade,
    'aggregate_open_risk', open_risk, 'aggregate_open_risk_limit', agg_limit, 'execution_mode', a.execution_mode,
    'request_validated', req_validated,
    'monetary_risk_note', 'Estimated from the setup declared maximum loss scaled by size and stop distance; broker contract specifications are not yet available.'
  );

  insert into trading.risk_decisions(account_id, setup_id, decision, reasons, metrics, execution_mode)
  values (p_account_id, p_setup_id, final_decision, reason_list, m, a.execution_mode)
  returning id into rd;

  insert into trading.risk_events(account_id, setup_id, event_type, severity, message, metrics)
  values (p_account_id, p_setup_id, 'pretrade_risk_evaluation',
          case when final_decision = 'blocked' then 'critical' when final_decision = 'manual_review' then 'warning' else 'info' end,
          'Pre-trade risk gate evaluated',
          jsonb_build_object('decision', final_decision, 'risk_decision_id', rd, 'reasons', reason_list));

  return query select final_decision, reason_list, m, rd;
end;
$function$;

revoke all on function trading.evaluate_execution_risk(uuid, uuid, trading.side, numeric, text, numeric, numeric, numeric, uuid) from public, anon, authenticated, service_role;

-- The original two-argument entry point stays (nothing is dropped) but now delegates to the strict gate, with no request parameters.
create or replace function trading.evaluate_pretrade_risk(p_account_id uuid, p_setup_id uuid)
returns table(decision text, reasons jsonb, metrics jsonb, risk_decision_id uuid)
language sql
security definer
set search_path to 'trading', 'public'
as $function$ select * from trading.evaluate_execution_risk(p_account_id, p_setup_id) $function$;

revoke all on function trading.evaluate_pretrade_risk(uuid, uuid) from public, anon, authenticated, service_role;

create or replace function trading.request_execution(
  p_account_id uuid, p_setup_id uuid, p_instrument_id uuid, p_side trading.side, p_quantity numeric, p_order_type text,
  p_requested_price numeric default null, p_stop_loss numeric default null, p_take_profit numeric default null, p_metadata jsonb default '{}'::jsonb
)
returns table(execution_request_id uuid, status text, risk_decision_id uuid, decision text, reasons jsonb)
language plpgsql
security definer
set search_path to 'trading', 'public', 'pg_catalog', 'auth'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_account trading.accounts%rowtype;
  v_setup trading.trade_setups%rowtype;
  v_risk record;
  v_request_id uuid;
  v_status text;
  v_reason text;
begin
  if v_user_id is null then raise exception 'authenticated user required'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'quantity must be greater than zero'; end if;

  select am.role into v_role
  from trading.account_members am
  where am.account_id = p_account_id and am.user_id = v_user_id and am.active = true and am.role in ('owner','trader','risk_manager');
  if v_role is null then raise exception 'account access denied'; end if;

  select * into v_account from trading.accounts where id = p_account_id and active = true;
  if not found then raise exception 'account inactive or not found'; end if;

  select * into v_setup from trading.trade_setups where id = p_setup_id and instrument_id = p_instrument_id and account_id = p_account_id;
  if not found then raise exception 'trade setup not found, account mismatch, or instrument mismatch'; end if;

  select * into v_risk from trading.evaluate_execution_risk(p_account_id, p_setup_id, p_side, p_quantity, p_order_type, p_requested_price, p_stop_loss, p_take_profit, null);

  if v_risk.decision = 'blocked' then
    v_status := 'blocked'; v_reason := coalesce(v_risk.reasons::text, 'pre-trade risk blocked execution');
  elsif v_risk.decision = 'manual_review' or v_account.execution_mode = 'human_approval' then
    v_status := 'manual_review'; v_reason := case when v_risk.decision = 'manual_review' then 'pre-trade risk requires manual review' else 'account requires human approval' end;
  elsif v_account.execution_mode = 'analysis_only' then
    v_status := 'manual_review'; v_reason := 'account is analysis_only; broker execution is disabled';
  else
    v_status := 'authorized'; v_reason := null;
  end if;

  insert into trading.execution_requests (account_id, setup_id, instrument_id, requested_by, side, quantity, order_type, requested_price, stop_loss, take_profit, risk_decision_id, status, broker_dispatch_state, rejection_reason, metadata)
  values (p_account_id, p_setup_id, p_instrument_id, v_user_id, p_side, p_quantity, p_order_type, p_requested_price, p_stop_loss, p_take_profit, v_risk.risk_decision_id, v_status, 'not_dispatched', v_reason, coalesce(p_metadata, '{}'::jsonb))
  returning id into v_request_id;

  insert into trading.execution_audit_events (account_id, entity_type, entity_id, event_type, actor_user_id, actor_role, before_state, after_state, metadata)
  values (
    p_account_id, 'execution_request', v_request_id, 'execution_request_created', v_user_id, v_role, null,
    jsonb_build_object('status', v_status, 'broker_dispatch_state', 'not_dispatched', 'risk_decision_id', v_risk.risk_decision_id, 'decision', v_risk.decision),
    jsonb_build_object('setup_id', p_setup_id, 'instrument_id', p_instrument_id, 'side', p_side, 'quantity', p_quantity, 'order_type', p_order_type, 'requested_price', p_requested_price, 'stop_loss', p_stop_loss, 'take_profit', p_take_profit, 'reason', v_reason)
  );

  insert into trading.risk_events (account_id, setup_id, event_type, severity, message, metrics)
  values (p_account_id, p_setup_id, 'execution_request_created',
          case when v_status = 'blocked' then 'high' when v_status = 'manual_review' then 'medium' else 'info' end,
          case when v_status = 'authorized' then 'Execution request passed risk gate; broker dispatch remains controlled.' else v_reason end,
          jsonb_build_object('execution_request_id', v_request_id, 'risk_decision_id', v_risk.risk_decision_id, 'execution_mode', v_account.execution_mode, 'requested_by', v_user_id, 'role', v_role));

  return query select v_request_id, v_status, v_risk.risk_decision_id, v_risk.decision, v_risk.reasons;
end;
$function$;

-- Dispatch for paper execution. Runs the whole sequence in one transaction as the signed-in user: authority checks, a fresh risk-gate
-- evaluation immediately before the fill (state may have changed since the request), the queue transition, and the simulated fill.
create or replace function trading.dispatch_paper_execution(p_execution_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'trading', 'public', 'pg_catalog', 'auth'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  r trading.execution_requests%rowtype;
  a trading.accounts%rowtype;
  g record;
  v_approval jsonb;
  v_approver uuid;
  sim jsonb;
begin
  if v_user_id is null then raise exception 'authenticated user required'; end if;

  select * into r from trading.execution_requests where id = p_execution_request_id for update;
  if not found then raise exception 'execution request not found'; end if;
  select * into a from trading.accounts where id = r.account_id;
  if not found then raise exception 'account not found'; end if;

  select am.role into v_role from trading.account_members am
  where am.account_id = r.account_id and am.user_id = v_user_id and am.active = true and am.role in ('owner','trader','risk_manager');
  if v_role is null then raise exception 'account access denied'; end if;

  if not a.active then raise exception 'account execution circuit breaker is active'; end if;
  if a.execution_mode <> 'human_approval' then raise exception 'paper dispatch requires account execution_mode=human_approval'; end if;

  if r.broker_dispatch_state = 'paper_filled' then
    return jsonb_build_object('execution_request_id', r.id, 'broker_dispatch_state', 'paper_filled', 'broker_dispatched', false, 'idempotent_replay', true,
                              'order_id', r.metadata ->> 'paper_order_id', 'trade_id', r.metadata ->> 'paper_trade_id', 'position_id', r.metadata ->> 'paper_position_id');
  end if;
  if r.broker_dispatch_state <> 'not_dispatched' then raise exception 'request already dispatched or processed: %', r.broker_dispatch_state; end if;
  if r.status <> 'authorized' then raise exception 'only authorized requests may enter paper dispatch (status: %)', r.status; end if;
  if r.risk_decision_id is null then raise exception 'risk decision required'; end if;

  select * into g from trading.evaluate_execution_risk(r.account_id, r.setup_id, r.side, r.quantity, r.order_type, r.requested_price, r.stop_loss, r.take_profit, r.id);

  if g.decision = 'blocked' then
    update trading.execution_requests
    set status = 'cancelled', broker_dispatch_state = 'rejected', risk_decision_id = g.risk_decision_id,
        rejection_reason = 'risk gate re-evaluation blocked dispatch: ' || g.reasons::text
    where id = r.id;
    insert into trading.risk_events(account_id, setup_id, event_type, severity, message, metrics)
    values (r.account_id, r.setup_id, 'paper_dispatch_blocked_by_reevaluation', 'critical', 'Risk gate re-evaluation blocked paper dispatch; no fill was simulated.',
            jsonb_build_object('execution_request_id', r.id, 'risk_decision_id', g.risk_decision_id, 'reasons', g.reasons));
    return jsonb_build_object('execution_request_id', r.id, 'broker_dispatch_state', 'rejected', 'status', 'cancelled', 'broker_dispatched', false, 'reasons', g.reasons);
  end if;

  if g.decision = 'manual_review' then
    v_approval := coalesce(r.metadata -> 'paper_approval', '{}'::jsonb);
    v_approver := nullif(v_approval ->> 'approved_by', '')::uuid;
    if v_approver is null or coalesce(v_approval ->> 'approved_role', '') not in ('owner', 'risk_manager') then
      raise exception 'manual-review request lacks valid human approval';
    end if;
    if not exists (select 1 from trading.account_members am where am.account_id = r.account_id and am.user_id = v_approver and am.active = true and am.role in ('owner', 'risk_manager')) then
      raise exception 'human approver is no longer authorized';
    end if;
  end if;

  update trading.execution_requests
  set broker_dispatch_state = 'paper_queued', risk_decision_id = g.risk_decision_id
  where id = r.id and broker_dispatch_state = 'not_dispatched';
  if not found then raise exception 'dispatch race or request state changed'; end if;

  insert into trading.risk_events(account_id, setup_id, event_type, severity, message, metrics)
  values (r.account_id, r.setup_id, 'paper_execution_queued', 'info', 'Execution request queued for paper dispatch; no broker order was sent.',
          jsonb_build_object('execution_request_id', r.id, 'risk_decision_id', g.risk_decision_id, 'requested_by', v_user_id, 'role', v_role, 'broker_dispatch_state', 'paper_queued'));

  sim := trading.simulate_paper_execution(r.id);
  return sim || jsonb_build_object('queued_by_user_id', v_user_id, 'dispatch_completed', (sim ->> 'broker_dispatch_state') = 'paper_filled');
end;
$function$;

revoke all on function trading.dispatch_paper_execution(uuid) from public, anon;
grant execute on function trading.dispatch_paper_execution(uuid) to authenticated;

-- The trading schema is not exposed to the API. A single thin wrapper in public is the only entry point, so the exposed surface stays minimal.
create or replace function public.dispatch_paper_execution(p_execution_request_id uuid)
returns jsonb
language sql
security invoker
set search_path to ''
as $function$ select trading.dispatch_paper_execution(p_execution_request_id) $function$;

revoke all on function public.dispatch_paper_execution(uuid) from public, anon;
grant execute on function public.dispatch_paper_execution(uuid) to authenticated;
