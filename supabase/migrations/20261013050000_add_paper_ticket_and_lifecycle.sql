-- Operator paper tickets and the trade lifecycle read model.
-- A paper ticket is the operator's own idea: it is sized from the account risk policy, goes through the same risk gate and approval path as any request,
-- and fills only in paper mode. Paper fills are instant at the entered price; they do not wait for a limit level.
-- Quantity for paper positions is stored as contract-scaled units (lots x units_per_lot) so the existing paper accounting yields USD profit and R-multiples.
-- Contract specifications below are standard assumptions for a standard Exness account and are flagged as assumed in every setup; they are replaced by synced broker specs when a host reports them.
create or replace function private.paper_spec(p_symbol text, p_entry numeric)
returns table(units_per_lot numeric, tick_size numeric, tick_value numeric, vol_min numeric, vol_step numeric, vol_max numeric)
language sql immutable set search_path to '' as $$
  select s.u, s.t, s.u * s.t, 0.01::numeric, 0.01::numeric, 100::numeric from (
    select case p_symbol
      when 'XAUUSD' then 100::numeric when 'EURUSD' then 100000 when 'GBPUSD' then 100000 when 'AUDUSD' then 100000 when 'NZDUSD' then 100000
      when 'USDJPY' then 100000 / p_entry when 'USDCAD' then 100000 / p_entry when 'USDCHF' then 100000 / p_entry end u,
    case p_symbol when 'XAUUSD' then 0.01::numeric when 'USDJPY' then 0.001 else 0.00001 end t) s where s.u is not null;
$$;
revoke all on function private.paper_spec(text, numeric) from public, anon, authenticated;

create or replace function public.submit_paper_idea(p_account_id uuid, p_symbol text, p_side text, p_entry numeric, p_stop numeric, p_target numeric, p_thesis text)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  uid uuid := (select auth.uid()); a trading.accounts%rowtype; sym text := upper(btrim(p_symbol)); inst uuid; sp record; sz record; eq numeric; frac numeric;
  s trading.side; setup uuid; req record; units numeric; last_close numeric; last_ts timestamptz; rr numeric;
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  if not exists (select 1 from trading.account_members m where m.account_id = p_account_id and m.user_id = uid and m.active and m.role in ('owner', 'trader')) then
    raise exception 'only an owner or trader can submit a paper idea' using errcode = '42501';
  end if;
  select * into a from trading.accounts where id = p_account_id and active;
  if not found then raise exception 'account inactive or not found'; end if;
  if a.operating_mode <> 'paper' then raise exception 'switch the account to paper mode first (current mode: %)', a.operating_mode; end if;
  if p_side not in ('long', 'short') then raise exception 'side must be long or short'; end if;
  s := p_side::trading.side;
  if p_entry is null or p_stop is null or p_entry <= 0 or p_stop <= 0 then raise exception 'entry and stop must be positive'; end if;
  if p_thesis is null or length(btrim(p_thesis)) < 10 then raise exception 'write a thesis of at least 10 characters'; end if;
  if (s = 'long' and p_stop >= p_entry) or (s = 'short' and p_stop <= p_entry) then raise exception 'stop must be beyond the entry on the losing side'; end if;
  if p_target is not null and ((s = 'long' and p_target <= p_entry) or (s = 'short' and p_target >= p_entry)) then raise exception 'target must be beyond the entry on the winning side'; end if;
  select id into inst from core.instruments where symbol = sym;
  if inst is null then raise exception 'unknown instrument %', sym; end if;
  select * into sp from private.paper_spec(sym, p_entry);
  if sp.units_per_lot is null then raise exception 'paper sizing is not available for % yet (supported: USD pairs and XAUUSD)', sym; end if;

  select b.close, b.ts into last_close, last_ts from market.price_bars b where b.instrument_id = inst order by b.ts desc limit 1;
  eq := a.initial_balance + coalesce((select sum(l.realized_pnl) from trading.account_ledger l where l.account_id = a.id), 0);
  frac := least(coalesce(nullif(a.metadata ->> 'risk_per_trade_fraction', '')::numeric, 0.01), 0.05);
  select * into sz from trading.size_position(eq, frac, p_entry, p_stop, sp.tick_size, sp.tick_value, sp.vol_min, sp.vol_step, sp.vol_max);

  if sz.reason <> 'ok' then
    insert into trading.risk_events(account_id, event_type, severity, message, metrics)
    values (a.id, 'paper_idea_not_sizable', 'warning', 'Paper idea rejected before a setup was created: the smallest allowed position exceeds the risk budget.',
      jsonb_build_object('symbol', sym, 'side', p_side, 'entry', p_entry, 'stop', p_stop, 'equity', eq, 'risk_fraction', frac, 'minimum_lot_risk', sz.risk_amount, 'reason', sz.reason, 'user', uid));
    return jsonb_build_object('ok', false, 'outcome', 'no_trade', 'reason', sz.reason, 'equity', eq, 'risk_budget', round(eq * frac, 4), 'minimum_lot_risk', round(sz.risk_amount, 4),
      'explanation', 'The smallest permitted position (0.01 lot) would risk more than the budget at this stop distance, so the trade is rejected. Tighten the stop, or raise the risk fraction in Controls if that is acceptable.');
  end if;

  units := round(sz.volume * sp.units_per_lot, 6);
  rr := case when p_target is null then null else abs(p_target - p_entry) / abs(p_entry - p_stop) end;
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, take_profit, position_size, maximum_loss, reward_risk, thesis, evidence)
  values (inst, now(), s, 'approved', a.id, p_entry, p_entry, p_stop, p_target, units, round(sz.risk_amount, 4), rr, btrim(p_thesis),
    jsonb_build_object('source', 'operator_paper_idea', 'submitted_by', uid, 'lots', sz.volume, 'units_per_lot', sp.units_per_lot, 'risk_fraction_used', frac, 'equity_used', eq,
      'specs_assumed', true, 'specs_note', 'standard contract assumptions, not synced from the broker', 'fill_model', 'instant_at_entered_price',
      'last_stored_close', last_close, 'last_stored_close_at', last_ts, 'stored_data_is_stale_for_price_check', coalesce(last_ts < now() - interval '2 days', true)))
  returning id into setup;

  select * into req from trading.request_execution(a.id, setup, inst, s, units, 'limit', p_entry, p_stop, p_target, jsonb_build_object('source', 'operator_paper_idea', 'lots', sz.volume));
  return jsonb_build_object('ok', true, 'setup_id', setup, 'execution_request_id', req.execution_request_id, 'status', req.status, 'decision', req.decision, 'reasons', req.reasons,
    'lots', sz.volume, 'units', units, 'risk_amount', round(sz.risk_amount, 4), 'risk_fraction_used', round(sz.risk_fraction_used, 5), 'reward_risk', rr);
end $function$;

create or replace function public.approve_and_fill_paper(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid()); r trading.execution_requests%rowtype; ap record;
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  select * into r from trading.execution_requests where id = p_request_id;
  if not found then raise exception 'request not found'; end if;
  if not exists (select 1 from trading.account_members m where m.account_id = r.account_id and m.user_id = uid and m.active and m.role = 'owner') then raise exception 'only an owner can approve' using errcode = '42501'; end if;
  if (select a.operating_mode from trading.accounts a where a.id = r.account_id) <> 'paper' then raise exception 'the account is not in paper mode'; end if;
  if r.status = 'manual_review' then select * into ap from trading.approve_paper_execution(p_request_id); end if;
  return trading.dispatch_paper_execution(p_request_id);
end $function$;

create or replace function public.close_paper_position(p_position_id uuid, p_price numeric, p_reason text default 'manual_close')
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid()); p trading.positions%rowtype; req record;
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  select * into p from trading.positions where id = p_position_id and status = 'open';
  if not found then raise exception 'open position not found'; end if;
  if not exists (select 1 from trading.account_members m where m.account_id = p.account_id and m.user_id = uid and m.active and m.role in ('owner', 'trader')) then raise exception 'access denied' using errcode = '42501'; end if;
  if (select a.operating_mode from trading.accounts a where a.id = p.account_id) <> 'paper' then raise exception 'the account is not in paper mode'; end if;
  select * into req from trading.request_position_close(p.account_id, p.id, p.quantity, 'market', p_price, coalesce(nullif(btrim(p_reason), ''), 'manual_close'), '{}'::jsonb);
  return trading.simulate_paper_position_close(req.execution_request_id);
end $function$;

create or replace function public.mark_paper_position_price(p_position_id uuid, p_price numeric)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid()); p trading.positions%rowtype;
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  select * into p from trading.positions where id = p_position_id and status = 'open';
  if not found then raise exception 'open position not found'; end if;
  if not exists (select 1 from trading.account_members m where m.account_id = p.account_id and m.user_id = uid and m.active and m.role in ('owner', 'trader')) then raise exception 'access denied' using errcode = '42501'; end if;
  return trading.mark_paper_position(p_position_id, p_price);
end $function$;

create or replace function public.get_lifecycle()
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid());
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  return jsonb_build_object('generated_at', now(),
    'decisions', coalesce((select jsonb_agg(d order by d.symbol) from (
        select distinct on (dr.instrument_id) i.symbol, dr.outcome, dr.reason_codes, dr.evaluated_at, dr.mode from intelligence.decision_records dr join core.instruments i on i.id = dr.instrument_id
        order by dr.instrument_id, dr.evaluated_at desc) d), '[]'::jsonb),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object(
      'id', a.id, 'name', a.name, 'operating_mode', a.operating_mode, 'execution_mode', a.execution_mode, 'kill_switch', a.kill_switch, 'role', m.role,
      'summary', trading.paper_account_summary(a.id),
      'positions', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'symbol', i.symbol, 'side', p.side, 'quantity', p.quantity, 'entry', p.average_entry, 'stop', p.stop_loss, 'target', p.take_profit,
          'mark', p.mark_price, 'unrealized', p.unrealized_pnl, 'opened_at', p.opened_at) order by p.opened_at desc)
          from trading.positions p join core.instruments i on i.id = p.instrument_id where p.account_id = a.id and p.status = 'open'), '[]'::jsonb),
      'chains', coalesce((select jsonb_agg(c order by c.created desc) from (
          select ts.created_at created, jsonb_build_object(
            'setup', jsonb_build_object('id', ts.id, 'symbol', i.symbol, 'side', ts.side, 'status', ts.status, 'entry', ts.entry_low, 'stop', ts.stop_loss, 'target', ts.take_profit, 'size', ts.position_size,
              'max_loss', ts.maximum_loss, 'reward_risk', ts.reward_risk, 'thesis', ts.thesis, 'created_at', ts.created_at,
              'source', ts.evidence ->> 'source', 'lots', ts.evidence -> 'lots', 'specs_assumed', ts.evidence -> 'specs_assumed', 'fill_model', ts.evidence ->> 'fill_model'),
            'risk', coalesce((select jsonb_agg(jsonb_build_object('decision', rd.decision, 'reasons', rd.reasons, 'at', rd.created_at) order by rd.created_at) from trading.risk_decisions rd where rd.setup_id = ts.id), '[]'::jsonb),
            'requests', coalesce((select jsonb_agg(jsonb_build_object('id', er.id, 'status', er.status, 'dispatch', er.broker_dispatch_state, 'rejection', er.rejection_reason, 'at', er.requested_at,
                'is_close', coalesce((er.metadata ->> 'paper_position_close')::boolean, false)) order by er.requested_at) from trading.execution_requests er where er.setup_id = ts.id), '[]'::jsonb),
            'orders', coalesce((select jsonb_agg(jsonb_build_object('status', o.status, 'side', o.side, 'filled_price', o.filled_price, 'filled_at', o.filled_at, 'simulation', o.metadata ->> 'simulation') order by o.requested_at) from trading.orders o where o.setup_id = ts.id), '[]'::jsonb),
            'trade', (select jsonb_build_object('entry', t.entry_price, 'exit', t.exit_price, 'pnl', t.pnl, 'pnl_r', t.pnl_r, 'opened_at', t.opened_at, 'closed_at', t.closed_at, 'exit_reason', t.exit_reason) from trading.trades t where t.setup_id = ts.id order by t.opened_at desc limit 1)
          ) c from trading.trade_setups ts join core.instruments i on i.id = ts.instrument_id where ts.account_id = a.id order by ts.created_at desc limit 30) c), '[]'::jsonb)
    ) order by a.name) from trading.accounts a join trading.account_members m on m.account_id = a.id and m.user_id = uid and m.active), '[]'::jsonb));
end $function$;

revoke all on function public.submit_paper_idea(uuid, text, text, numeric, numeric, numeric, text) from public, anon;
revoke all on function public.approve_and_fill_paper(uuid) from public, anon;
revoke all on function public.close_paper_position(uuid, numeric, text) from public, anon;
revoke all on function public.mark_paper_position_price(uuid, numeric) from public, anon;
revoke all on function public.get_lifecycle() from public, anon;
grant execute on function public.submit_paper_idea(uuid, text, text, numeric, numeric, numeric, text) to authenticated;
grant execute on function public.approve_and_fill_paper(uuid) to authenticated;
grant execute on function public.close_paper_position(uuid, numeric, text) to authenticated;
grant execute on function public.mark_paper_position_price(uuid, numeric) to authenticated;
grant execute on function public.get_lifecycle() to authenticated;
