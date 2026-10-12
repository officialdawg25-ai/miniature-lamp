-- Behaviour tests for the demo execution host bridge. Always rolls back; the final exception carries the PASS/FAIL list.
do $$
declare
  uid uuid; inst uuid; acc uuid; accL uuid; accOff uuid; hidOff uuid; s1 uuid; s2 uuid; s3 uuid; hid uuid; hash text := repeat('a', 64);
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

  raise exception 'RESULT: %', array_to_string(res, E'\n');
end $$;
