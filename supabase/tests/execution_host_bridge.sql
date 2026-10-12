-- Behaviour tests for the demo execution host bridge. Always rolls back; the final exception carries the PASS/FAIL list.
do $$
declare
  uid uuid; inst uuid; acc uuid; accL uuid; accOff uuid; hidOff uuid; accS uuid; hidS uuid; accO uuid; hidO uuid; accD uuid; hidD uuid; accM uuid; hidM uuid; sp uuid; rqS uuid; rqO uuid; rqD uuid; rqM uuid; snap jsonb; ev text; why text; rn text; s1 uuid; s2 uuid; s3 uuid; hid uuid; hash text := repeat('a', 64);
  r record; out jsonb; rq1 uuid; rq2 uuid; rq3 uuid; st text; ds text; res text[] := '{}';
begin
  select user_id into uid from private.institutional_access where is_active limit 1;
  select id into inst from core.instruments where symbol = 'USDJPY';

  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('h-demo', 'USD', 'human_approval', 100, 200, 500, 5, '{"broker_mode":"demo","max_aggregate_open_risk":1000}') returning id into acc;
  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('h-notdemo', 'USD', 'human_approval', 100, 200, 500, 5, '{}') returning id into accL;
  insert into trading.account_members(account_id, user_id, role) values (acc, uid, 'owner');

  begin perform trading.register_execution_host(accL, 'x', hash); res := array_append(res, 'H1 register on a non-demo account FAIL'::text);
  exception when others then res := array_append(res, 'H1 register refused on a non-demo account PASS'::text); end;

  hid := trading.register_execution_host(acc, 'vps', hash);
  perform public.host_report_snapshot(hid, '{"balance":15,"equity":15,"positions":[],"orders":[]}'::jsonb);
  begin insert into trading.execution_hosts(account_id, name, token_hash, mode) values (acc, 'live', repeat('b', 64), 'live'); res := array_append(res, 'H2 live host row FAIL'::text);
  exception when check_violation then res := array_append(res, 'H2 live mode impossible PASS'::text); end;

  select * into r from public.host_resolve(hash);
  res := array_append(res, 'H3 valid token resolves ' || case when r.host_id = hid then 'PASS' else 'FAIL' end);
  select * into r from public.host_resolve(repeat('c', 64));
  res := array_append(res, 'H4 wrong token resolves nothing ' || case when r.host_id is null then 'PASS' else 'FAIL' end);

  perform public.host_upsert_specs(hid, '[{"symbol":"usdjpy","contract_size":1000,"tick_size":0.001,"tick_value":0.0064,"volume_min":0.01,"volume_step":0.01,"volume_max":100,"account_currency":"USC"}]'::jsonb);
  res := array_append(res, 'H5 spec stored upper-cased ' || case when exists (select 1 from trading.broker_symbol_specs where account_id = acc and symbol = 'USDJPY') then 'PASS' else 'FAIL' end);

  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, take_profit, position_size, maximum_loss) values (inst, now(), 'long', 'approved', acc, 150.0, 150.2, 149.5, 151.5, 1, 8) returning id into s1;
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, take_profit, position_size, maximum_loss) values (inst, now(), 'long', 'approved', acc, 150.0, 150.2, 149.5, 151.5, 1, 8) returning id into s2;
  select * into r from trading.evaluate_execution_risk(acc, s1, 'long', 0.5, 'limit', 150.1, 149.6, 151.0);
  insert into trading.execution_requests(account_id, setup_id, instrument_id, requested_by, side, quantity, order_type, requested_price, stop_loss, take_profit, risk_decision_id, status, broker_dispatch_state)
  values (acc, s1, inst, uid, 'long', 0.5, 'limit', 150.1, 149.6, 151.0, r.risk_decision_id, 'authorized', 'not_dispatched') returning id into rq1;
  insert into trading.execution_requests(account_id, setup_id, instrument_id, requested_by, side, quantity, order_type, requested_price, stop_loss, take_profit, risk_decision_id, status, broker_dispatch_state)
  values (acc, s2, inst, uid, 'long', 0.555, 'limit', 150.1, 149.6, 151.0, r.risk_decision_id, 'authorized', 'not_dispatched') returning id into rq2;

  out := public.host_claim_requests(hid, 5);
  select broker_dispatch_state into st from trading.execution_requests where id = rq1;
  res := array_append(res, 'H6 valid request queued and returned ' || case when st = 'queued' and jsonb_array_length(out) = 1 and (out -> 0 ->> 'request_id')::uuid = rq1 and out -> 0 ->> 'symbol' = 'USDJPY' then 'PASS' else 'FAIL(' || st || ' ' || out::text || ')' end);
  select broker_dispatch_state into st from trading.execution_requests where id = rq2;
  res := array_append(res, 'H7 volume off the broker step rejected ' || case when st = 'rejected' then 'PASS' else 'FAIL(' || st || ')' end);

  begin perform public.host_report(hid, rq1, 'sent', '{"dry_run":true}'::jsonb); res := array_append(res, 'H8 dry run recorded as sent FAIL'::text);
  exception when others then res := array_append(res, 'H8 dry run cannot be recorded as sent PASS'::text); end;
  begin perform public.host_report(hid, rq1, 'acknowledged', '{"ticket":1}'::jsonb); res := array_append(res, 'H9 skipping the sent step FAIL'::text);
  exception when others then res := array_append(res, 'H9 cannot skip the sent step PASS'::text); end;
  perform public.host_report(hid, rq1, 'sent', '{"dry_run":false}'::jsonb);
  perform public.host_report(hid, rq1, 'acknowledged', '{"ticket":123,"price":150.1}'::jsonb);
  select status, broker_dispatch_state into ds, st from trading.execution_requests where id = rq1;
  res := array_append(res, 'H10 sent then acknowledged recorded ' || case when st = 'acknowledged' and ds = 'submitted' then 'PASS' else 'FAIL(' || ds || ' ' || st || ')' end);

  -- Circuit breaker: a separate, inactive demo account with its own host and one authorized request.
  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata, active)
  values ('h-off', 'USD', 'human_approval', 100, 200, 500, 5, '{"broker_mode":"demo"}', false) returning id into accOff;
  hidOff := trading.register_execution_host(accOff, 'vps-off', repeat('d', 64));
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, take_profit, position_size, maximum_loss) values (inst, now(), 'long', 'approved', accOff, 150.0, 150.2, 149.5, 151.5, 1, 8) returning id into s3;
  insert into trading.execution_requests(account_id, setup_id, instrument_id, requested_by, side, quantity, order_type, requested_price, stop_loss, take_profit, risk_decision_id, status, broker_dispatch_state)
  values (accOff, s3, inst, uid, 'long', 0.5, 'limit', 150.1, 149.6, 151.0, r.risk_decision_id, 'authorized', 'not_dispatched') returning id into rq3;
  out := public.host_claim_requests(hidOff, 5);
  select broker_dispatch_state into st from trading.execution_requests where id = rq3;
  res := array_append(res, 'H11 circuit breaker stops claims ' || case when jsonb_array_length(out) = 0 and st = 'not_dispatched' then 'PASS' else 'FAIL' end);
  select * into r from public.host_resolve(repeat('d', 64));
  res := array_append(res, 'H12 inactive account cannot resolve ' || case when r.host_id is null then 'PASS' else 'FAIL' end);

  begin set local role authenticated; perform public.host_claim_requests(hid, 5); res := array_append(res, 'H13 browser role can claim FAIL'::text);
  exception when insufficient_privilege then res := array_append(res, 'H13 browser role cannot claim PASS'::text); end;
  reset role;


  -- Broker-state checks. Each scenario has its own account, so no update or delete statements are needed.
  snap := public.host_report_snapshot(hid, '{"balance":15,"equity":15,"positions":[],"orders":[]}'::jsonb);
  res := array_append(res, 'R1 identical recent snapshot is not stored twice ' || case when (snap ->> 'stored')::boolean = false then 'PASS' else 'FAIL' end);

  -- R2: host without any snapshot fails safe
  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('h-stale', 'USD', 'human_approval', 100, 200, 500, 5, '{"broker_mode":"demo","max_aggregate_open_risk":1000}') returning id into accS;
  hidS := trading.register_execution_host(accS, 'vps-s', repeat('e', 64));
  perform public.host_upsert_specs(hidS, '[{"symbol":"usdjpy","contract_size":1000,"tick_size":0.001,"tick_value":0.0064,"volume_min":0.01,"volume_step":0.01,"volume_max":100,"account_currency":"USD"}]'::jsonb);
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, take_profit, position_size, maximum_loss) values (inst, now(), 'long', 'approved', accS, 150.0, 150.2, 149.5, 151.5, 1, 8) returning id into sp;
  insert into trading.execution_requests(account_id, setup_id, instrument_id, requested_by, side, quantity, order_type, requested_price, stop_loss, take_profit, risk_decision_id, status, broker_dispatch_state)
  values (accS, sp, inst, uid, 'long', 0.5, 'limit', 150.1, 149.6, 151.0, null, 'authorized', 'not_dispatched') returning id into rqS;
  out := public.host_claim_requests(hidS, 5);
  select rejection_reason into why from trading.execution_requests where id = rqS;
  res := array_append(res, 'R2 no snapshot blocks the claim ' || case when jsonb_array_length(out) = 0 and why like '%broker_snapshot_stale%' then 'PASS' else 'FAIL(' || coalesce(why, 'null') || ')' end);

  -- R3/R4/R5: broker positions count toward the open-trade limit and are flagged
  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('h-open', 'USD', 'human_approval', 100, 200, 500, 1, '{"broker_mode":"demo","max_aggregate_open_risk":1000}') returning id into accO;
  hidO := trading.register_execution_host(accO, 'vps-o', repeat('f', 64));
  perform public.host_upsert_specs(hidO, '[{"symbol":"usdjpy","contract_size":1000,"tick_size":0.001,"tick_value":0.0064,"volume_min":0.01,"volume_step":0.01,"volume_max":100,"account_currency":"USD"}]'::jsonb);
  snap := public.host_report_snapshot(hidO, '{"balance":15,"equity":15,"positions":[{"ticket":1,"symbol":"USDJPY","sl":0,"comment":""},{"ticket":2,"symbol":"USDJPY","sl":149.0,"comment":"rq00000000000000000000000000ab"}],"orders":[]}'::jsonb);
  res := array_append(res, 'R3 position without a stop is flagged critical ' || case when snap -> 'flags' @> '[{"code":"position_without_stop","severity":"critical"}]'::jsonb then 'PASS' else 'FAIL' end);
  res := array_append(res, 'R4 manual and unknown-tag positions are flagged ' || case when snap -> 'flags' @> '[{"code":"manual_position"}]'::jsonb and snap -> 'flags' @> '[{"code":"unknown_request_position"}]'::jsonb then 'PASS' else 'FAIL(' || (snap -> 'flags')::text || ')' end);
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, take_profit, position_size, maximum_loss) values (inst, now(), 'long', 'approved', accO, 150.0, 150.2, 149.5, 151.5, 1, 8) returning id into sp;
  insert into trading.execution_requests(account_id, setup_id, instrument_id, requested_by, side, quantity, order_type, requested_price, stop_loss, take_profit, risk_decision_id, status, broker_dispatch_state)
  values (accO, sp, inst, uid, 'long', 0.5, 'limit', 150.1, 149.6, 151.0, null, 'authorized', 'not_dispatched') returning id into rqO;
  out := public.host_claim_requests(hidO, 5);
  select rejection_reason into why from trading.execution_requests where id = rqO;
  res := array_append(res, 'R5 broker positions block at the open-trade limit ' || case when jsonb_array_length(out) = 0 and why like '%max_open_trades_reached%' then 'PASS' else 'FAIL(' || coalesce(why, 'null') || ')' end);

  -- R6: realized broker losses count toward the daily limit
  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('h-loss', 'USD', 'human_approval', 100, 1, 500, 5, '{"broker_mode":"demo","max_aggregate_open_risk":1000}') returning id into accD;
  hidD := trading.register_execution_host(accD, 'vps-d', repeat('1', 64));
  perform public.host_upsert_specs(hidD, '[{"symbol":"usdjpy","contract_size":1000,"tick_size":0.001,"tick_value":0.0064,"volume_min":0.01,"volume_step":0.01,"volume_max":100,"account_currency":"USD"}]'::jsonb);
  perform public.host_report_snapshot(hidD, '{"balance":15,"equity":15,"positions":[],"orders":[]}'::jsonb);
  perform public.host_report_deals(hidD, jsonb_build_array(jsonb_build_object('deal_ticket', 9001, 'symbol', 'usdjpy', 'side', 'sell', 'entry', 'out', 'volume', 0.01, 'price', 150.0, 'profit', -2.5, 'commission', 0, 'swap', 0, 'deal_time', now(), 'comment', 'x')));
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, take_profit, position_size, maximum_loss) values (inst, now(), 'long', 'approved', accD, 150.0, 150.2, 149.5, 151.5, 1, 8) returning id into sp;
  insert into trading.execution_requests(account_id, setup_id, instrument_id, requested_by, side, quantity, order_type, requested_price, stop_loss, take_profit, risk_decision_id, status, broker_dispatch_state)
  values (accD, sp, inst, uid, 'long', 0.5, 'limit', 150.1, 149.6, 151.0, null, 'authorized', 'not_dispatched') returning id into rqD;
  out := public.host_claim_requests(hidD, 5);
  select rejection_reason into why from trading.execution_requests where id = rqD;
  res := array_append(res, 'R6 broker loss counts toward the daily limit ' || case when jsonb_array_length(out) = 0 and why like '%max_daily_loss_reached%' then 'PASS' else 'FAIL(' || coalesce(why, 'null') || ')' end);
  res := array_append(res, 'R7 deals are stored idempotently ' || case when public.host_report_deals(hidD, jsonb_build_array(jsonb_build_object('deal_ticket', 9001, 'symbol', 'usdjpy', 'side', 'sell', 'entry', 'out', 'volume', 0.01, 'price', 150.0, 'profit', -2.5, 'deal_time', now()))) = 1
       and (select count(*) from trading.broker_deals where account_id = accD) = 1 then 'PASS' else 'FAIL' end);

  -- R8: an acknowledged request that the broker never shows is flagged
  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('h-missing', 'USD', 'human_approval', 100, 200, 500, 5, '{"broker_mode":"demo"}') returning id into accM;
  hidM := trading.register_execution_host(accM, 'vps-m', repeat('2', 64));
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, position_size, maximum_loss, stop_loss) values (inst, now(), 'long', 'approved', accM, 1, 8, 149.5) returning id into sp;
  insert into trading.execution_requests(account_id, setup_id, instrument_id, requested_by, side, quantity, order_type, requested_price, stop_loss, risk_decision_id, status, broker_dispatch_state, requested_at, metadata)
  values (accM, sp, inst, uid, 'long', 0.01, 'limit', 150.1, 149.6, null, 'submitted', 'acknowledged', now() - interval '20 minutes', '{"broker_result":{"acknowledged":{"dry_run":false,"ticket":5}}}') returning id into rqM;
  snap := public.host_report_snapshot(hidM, '{"balance":15,"equity":15,"positions":[],"orders":[]}'::jsonb);
  res := array_append(res, 'R8 acknowledged request missing at the broker is flagged ' || case when snap -> 'flags' @> '[{"code":"acknowledged_but_missing_at_broker"}]'::jsonb then 'PASS' else 'FAIL(' || (snap -> 'flags')::text || ')' end);

  begin set local role authenticated; perform public.host_report_snapshot(hid, '{}'::jsonb); res := array_append(res, 'R9 browser role can report snapshots FAIL'::text);
  exception when insufficient_privilege then res := array_append(res, 'R9 browser role cannot report snapshots PASS'::text); end;
  reset role;

  raise exception 'RESULT: %', array_to_string(res, E'\n');
end $$;
