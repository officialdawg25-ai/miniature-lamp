-- The risk gate now uses real broker state for accounts that have an active execution host: a stale snapshot blocks, broker positions, pending orders and requests in flight count toward
-- the open-trade limit, and realized broker losses count toward the daily and weekly limits. Accounts without a host behave exactly as before.
create or replace function trading.evaluate_execution_risk(
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
  snap trading.broker_snapshots%rowtype;
  has_host boolean := false;
  broker_loss_d numeric := 0;
  broker_loss_w numeric := 0;
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
  if not a.active then blocked := array_append(blocked, 'account_inactive'::text); end if;

  select * into s from trading.trade_setups where id = p_setup_id;
  if not found then
    blocked := array_append(blocked, 'setup_not_found'::text);
  elsif s.account_id <> p_account_id then
    blocked := array_append(blocked, 'setup_account_mismatch'::text);
  else
    setup_ok := true;
    if s.status <> 'approved' then blocked := array_append(blocked, 'setup_not_approved'::text); end if;
    if s.maximum_loss is null then blocked := array_append(blocked, 'setup_maximum_loss_missing'::text); end if;
    if s.position_size is null then blocked := array_append(blocked, 'setup_position_size_missing'::text); end if;
    if s.stop_loss is null then blocked := array_append(blocked, 'setup_stop_loss_missing'::text); end if;
    max_age_min := case when a.metadata ->> 'max_setup_age_minutes' ~ '^[0-9]+(\.[0-9]+)?$' then (a.metadata ->> 'max_setup_age_minutes')::numeric else 1440 end;
    if s.as_of < now() - make_interval(secs => max_age_min * 60) then blocked := array_append(blocked, 'setup_expired'::text); end if;
    if s.as_of > now() + interval '5 minutes' then blocked := array_append(blocked, 'setup_timestamp_in_future'::text); end if;
  end if;

  -- Account risk policy: a missing limit means there is no policy, not an unlimited one.
  if a.max_risk_per_trade is null then blocked := array_append(blocked, 'risk_limit_not_configured:max_risk_per_trade'::text); end if;
  if a.max_daily_loss is null then blocked := array_append(blocked, 'risk_limit_not_configured:max_daily_loss'::text); end if;
  if a.max_weekly_loss is null then blocked := array_append(blocked, 'risk_limit_not_configured:max_weekly_loss'::text); end if;
  if a.max_open_trades is null then blocked := array_append(blocked, 'risk_limit_not_configured:max_open_trades'::text); end if;

  select count(*) into open_count from trading.positions p where p.account_id = a.id and p.status = 'open';

  -- Accounts with an execution host use real broker state: stale state blocks (fail-safe), broker positions count toward the open-trade limit,
  -- and realized losses at the broker count toward the daily and weekly limits.
  select exists (select 1 from trading.execution_hosts hh where hh.account_id = a.id and hh.active) into has_host;
  if has_host then
    select * into snap from trading.broker_snapshots bs where bs.account_id = a.id order by bs.taken_at desc limit 1;
    if not found or snap.taken_at < now() - interval '15 minutes' then
      blocked := array_append(blocked, 'broker_snapshot_stale'::text);
    else
      open_count := greatest(open_count, snap.position_count + jsonb_array_length(snap.orders)
        + (select count(*) from trading.execution_requests er2 where er2.account_id = a.id and er2.broker_dispatch_state in ('queued', 'sent')
             and (p_exclude_request_id is null or er2.id <> p_exclude_request_id)));
    end if;
    select coalesce(sum(least(d.profit + d.commission + d.swap, 0)), 0) into broker_loss_d from trading.broker_deals d
      where d.account_id = a.id and d.entry in ('out', 'inout', 'out_by') and d.deal_time >= date_trunc('day', now());
    select coalesce(sum(least(d.profit + d.commission + d.swap, 0)), 0) into broker_loss_w from trading.broker_deals d
      where d.account_id = a.id and d.entry in ('out', 'inout', 'out_by') and d.deal_time >= date_trunc('week', now());
  end if;
  if a.max_open_trades is not null and open_count >= a.max_open_trades then blocked := array_append(blocked, 'max_open_trades_reached'::text); end if;

  select coalesce(sum(case when t.pnl < 0 then t.pnl else 0 end), 0) into daily_realized
  from trading.trades t where t.account_id = a.id and t.closed_at >= date_trunc('day', now());
  select coalesce(sum(case when t.pnl < 0 then t.pnl else 0 end), 0) into weekly_realized
  from trading.trades t where t.account_id = a.id and t.closed_at >= date_trunc('week', now());
  daily_realized := daily_realized + broker_loss_d;
  weekly_realized := weekly_realized + broker_loss_w;
  if a.max_daily_loss is not null and abs(daily_realized) >= a.max_daily_loss then blocked := array_append(blocked, 'max_daily_loss_reached'::text); end if;
  if a.max_weekly_loss is not null and abs(weekly_realized) >= a.max_weekly_loss then blocked := array_append(blocked, 'max_weekly_loss_reached'::text); end if;

  if a.execution_mode = 'automated' then review := array_append(review, 'automated_execution_not_enabled_by_risk_gate'::text); end if;

  -- Request-level validation: the actual quantity, stop and prices must fit inside what the setup approved.
  if setup_ok and req_validated then
    eff_side := coalesce(p_side, s.side);
    if p_side is null then blocked := array_append(blocked, 'request_side_missing'::text);
    elsif p_side <> s.side then blocked := array_append(blocked, 'request_side_differs_from_setup'::text); end if;

    if p_quantity is null or p_quantity <= 0 then
      blocked := array_append(blocked, 'request_quantity_invalid'::text);
    elsif s.position_size is not null and p_quantity > s.position_size then
      blocked := array_append(blocked, 'request_quantity_exceeds_setup_position_size'::text);
    end if;

    if p_order_type is null or p_order_type not in ('market', 'limit') then blocked := array_append(blocked, 'unsupported_order_type'::text); end if;
    if p_requested_price is null or p_requested_price <= 0 then blocked := array_append(blocked, 'reference_price_required'::text); end if;
    if p_stop_loss is null or p_stop_loss <= 0 then blocked := array_append(blocked, 'stop_loss_required'::text); end if;

    if p_requested_price is not null and p_requested_price > 0 and p_stop_loss is not null and p_stop_loss > 0 then
      if eff_side = 'long' then
        if p_stop_loss >= p_requested_price then blocked := array_append(blocked, 'stop_not_beyond_entry'::text); end if;
        if s.stop_loss is not null and p_stop_loss < s.stop_loss then blocked := array_append(blocked, 'stop_looser_than_setup'::text); end if;
        if p_take_profit is not null and p_take_profit <= p_requested_price then blocked := array_append(blocked, 'take_profit_wrong_side'::text); end if;
      else
        if p_stop_loss <= p_requested_price then blocked := array_append(blocked, 'stop_not_beyond_entry'::text); end if;
        if s.stop_loss is not null and p_stop_loss > s.stop_loss then blocked := array_append(blocked, 'stop_looser_than_setup'::text); end if;
        if p_take_profit is not null and p_take_profit >= p_requested_price then blocked := array_append(blocked, 'take_profit_wrong_side'::text); end if;
      end if;
      if s.entry_low is not null and s.entry_high is not null and (p_requested_price < s.entry_low or p_requested_price > s.entry_high) then
        blocked := array_append(blocked, 'price_outside_setup_entry_range'::text);
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
    blocked := array_append(blocked, 'per_trade_risk_limit_exceeded'::text);
  end if;

  -- Aggregate open risk, from the declared maximum loss of the setups behind trades that are still open.
  select coalesce(sum(ts.maximum_loss), 0) into open_risk
  from trading.trades t join trading.trade_setups ts on ts.id = t.setup_id
  where t.account_id = a.id and t.closed_at is null;
  agg_limit := case when a.metadata ->> 'max_aggregate_open_risk' ~ '^[0-9]+(\.[0-9]+)?$' then (a.metadata ->> 'max_aggregate_open_risk')::numeric else null end;
  if agg_limit is null then
    review := array_append(review, 'aggregate_open_risk_limit_not_configured'::text);
  elsif open_risk + coalesce(est_risk, 0) > agg_limit then
    blocked := array_append(blocked, 'aggregate_open_risk_limit_exceeded'::text);
  end if;

  -- One live request per setup: prevents duplicate orders from retries and double submission.
  if exists (
    select 1 from trading.execution_requests er
    where er.setup_id = p_setup_id and er.status in ('manual_review', 'authorized', 'submitted')
      and (p_exclude_request_id is null or er.id <> p_exclude_request_id)
  ) then
    blocked := array_append(blocked, 'setup_already_has_active_execution_request'::text);
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
