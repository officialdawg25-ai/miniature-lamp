-- Behaviour tests for the pre-trade risk gate and the paper dispatch path.
-- Runs in one block and always rolls back (it ends by raising an exception that carries the PASS/FAIL list), so it leaves no data behind.
-- Run with the SQL editor or the MCP execute_sql tool against a database that has migration 20261012080000 applied.
do $$
declare
  uid uuid; inst uuid; inst2 uuid;
  accA uuid; accB uuid; accC uuid; accD uuid; accE uuid;
  s1 uuid; s2 uuid; s3 uuid; sx uuid; sd uuid;
  r record; req1 uuid; req2 uuid; req3 uuid; blocked_req uuid; dup uuid;
  disp jsonb; n_pos int; n_ord int; n_led int; st text;
  res text[] := '{}';
  ok boolean;

begin
  select user_id into uid from private.institutional_access where is_active limit 1;
  select id into inst from core.instruments where symbol = 'USDJPY';
  select id into inst2 from core.instruments where symbol = 'EURUSD';

  -- Account A: human approval, full limits, aggregate open risk limit configured.
  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('t-A', 'USD', 'human_approval', 10, 20, 50, 3, '{"max_aggregate_open_risk": 30}') returning id into accA;
  insert into trading.account_members(account_id, user_id, role) values (accA, uid, 'owner');

  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, take_profit, position_size, maximum_loss)
  values (inst, now(), 'long', 'approved', accA, 150.0, 150.2, 149.5, 151.5, 1, 8) returning id into s1;

  -- G1 valid request is approved
  select * into r from trading.evaluate_execution_risk(accA, s1, 'long', 1, 'limit', 150.1, 149.6, 151.0);
  res := res || format('G1 valid request approved=%s', case when r.decision = 'approved' then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);

  -- G2..G10 each invalid request is blocked for the expected reason
  select * into r from trading.evaluate_execution_risk(accA, s1, 'long', 2, 'limit', 150.1, 149.6, 151.0);
  res := res || format('G2 quantity above setup size blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('request_quantity_exceeds_setup_position_size') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);
  select * into r from trading.evaluate_execution_risk(accA, s1, 'long', 1, 'limit', 150.1, null, 151.0);
  res := res || format('G3 missing stop blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('stop_loss_required') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);
  select * into r from trading.evaluate_execution_risk(accA, s1, 'long', 1, 'limit', 150.1, 150.5, 151.0);
  res := res || format('G4 stop on wrong side of entry blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('stop_not_beyond_entry') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);
  select * into r from trading.evaluate_execution_risk(accA, s1, 'long', 1, 'limit', 150.1, 149.0, 151.0);
  res := res || format('G5 stop looser than setup blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('stop_looser_than_setup') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);
  select * into r from trading.evaluate_execution_risk(accA, s1, 'long', 1, 'limit', 151.0, 149.6, 152.0);
  res := res || format('G6 price outside entry range blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('price_outside_setup_entry_range') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);
  select * into r from trading.evaluate_execution_risk(accA, s1, 'short', 1, 'limit', 150.1, 150.6, 149.0);
  res := res || format('G7 side differs from setup blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('request_side_differs_from_setup') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);
  select * into r from trading.evaluate_execution_risk(accA, s1, 'long', 1, 'stop', 150.1, 149.6, 151.0);
  res := res || format('G8 unsupported order type blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('unsupported_order_type') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);
  select * into r from trading.evaluate_execution_risk(accA, s1, 'long', 1, 'limit', null, 149.6, 151.0);
  res := res || format('G9 missing reference price blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('reference_price_required') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);
  select * into r from trading.evaluate_execution_risk(accA, s1, 'long', 1, 'limit', 150.1, 149.6, 150.0);
  res := res || format('G10 take profit on wrong side blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('take_profit_wrong_side') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);

  -- G11 regression: a block must never be downgraded (unapproved setup with missing risk data)
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id) values (inst, now(), 'long', 'candidate', accA) returning id into sx;
  select * into r from trading.evaluate_execution_risk(accA, sx);
  res := res || format('G11 unapproved setup with missing data stays blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('setup_not_approved') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);

  -- G12 regression: per-trade risk breach on an automated account stays blocked
  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('t-B', 'USD', 'automated', 10, 20, 50, 3, '{"max_aggregate_open_risk": 30}') returning id into accB;
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, position_size, maximum_loss, stop_loss) values (inst, now(), 'long', 'approved', accB, 1, 999, 149.5) returning id into sx;
  select * into r from trading.evaluate_execution_risk(accB, sx);
  res := res || format('G12 risk breach on automated account stays blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('per_trade_risk_limit_exceeded') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);

  -- G13 stale setup
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, position_size, maximum_loss) values (inst, now() - interval '3 days', 'long', 'approved', accA, 150.0, 150.2, 149.5, 1, 8) returning id into sx;
  select * into r from trading.evaluate_execution_risk(accA, sx, 'long', 1, 'limit', 150.1, 149.6, 151.0);
  res := res || format('G13 expired setup blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('setup_expired') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);

  -- G14 duplicate request for the same setup (own setup, so no cleanup statement is needed)
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, take_profit, position_size, maximum_loss)
  values (inst, now(), 'long', 'approved', accA, 150.0, 150.2, 149.5, 151.5, 1, 8) returning id into sd;
  insert into trading.execution_requests(account_id, setup_id, instrument_id, requested_by, side, quantity, order_type, status, broker_dispatch_state)
  values (accA, sd, inst, uid, 'long', 1, 'limit', 'manual_review', 'not_dispatched') returning id into dup;
  select * into r from trading.evaluate_execution_risk(accA, sd, 'long', 1, 'limit', 150.1, 149.6, 151.0);
  res := res || format('G14 second live request for a setup blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('setup_already_has_active_execution_request') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);
  select * into r from trading.evaluate_execution_risk(accA, sd, 'long', 1, 'limit', 150.1, 149.6, 151.0, dup);
  res := res || format('G14b same request excluded from the duplicate check=%s', case when r.decision = 'approved' then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);

  -- G15 aggregate open risk
  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('t-C', 'USD', 'human_approval', 10, 20, 50, 3, '{"max_aggregate_open_risk": 10}') returning id into accC;
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, position_size, maximum_loss) values (inst, now(), 'long', 'approved', accC, 150.0, 150.2, 149.5, 1, 8) returning id into sx;
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, position_size, maximum_loss) values (inst, now(), 'long', 'approved', accC, 150.0, 150.2, 149.5, 1, 8) returning id into s3;
  insert into trading.trades(account_id, setup_id, instrument_id, side, entry_price, quantity, opened_at) values (accC, sx, inst, 'long', 150.1, 1, now());
  select * into r from trading.evaluate_execution_risk(accC, s3, 'long', 1, 'limit', 150.1, 149.6, 151.0);
  res := res || format('G15 aggregate open risk limit blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('aggregate_open_risk_limit_exceeded') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);

  -- G16 missing account limit means no policy
  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('t-D', 'USD', 'human_approval', 10, null, 50, 3, '{"max_aggregate_open_risk": 30}') returning id into accD;
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, position_size, maximum_loss) values (inst, now(), 'long', 'approved', accD, 150.0, 150.2, 149.5, 1, 8) returning id into sx;
  select * into r from trading.evaluate_execution_risk(accD, sx, 'long', 1, 'limit', 150.1, 149.6, 151.0);
  res := res || format('G16 missing account limit blocked=%s', case when r.decision = 'blocked' and r.reasons @> jsonb_build_array('risk_limit_not_configured:max_daily_loss') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);

  -- G17 no aggregate limit configured requires manual review (not an unlimited pass)
  insert into trading.accounts(name, currency_code, execution_mode, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('t-E', 'USD', 'human_approval', 10, 20, 50, 3, '{}') returning id into accE;
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, position_size, maximum_loss) values (inst, now(), 'long', 'approved', accE, 150.0, 150.2, 149.5, 1, 8) returning id into sx;
  select * into r from trading.evaluate_execution_risk(accE, sx, 'long', 1, 'limit', 150.1, 149.6, 151.0);
  res := res || format('G17 aggregate limit not configured needs review=%s', case when r.decision = 'manual_review' and r.reasons @> jsonb_build_array('aggregate_open_risk_limit_not_configured') then 'PASS' else 'FAIL(' || r.decision || ' ' || r.reasons::text || ')' end);

  -- Privileges: the gate and the simulator are not callable by API roles
  ok := not has_function_privilege('authenticated', 'trading.evaluate_execution_risk(uuid,uuid,trading.side,numeric,text,numeric,numeric,numeric,uuid)', 'execute')
    and not has_function_privilege('anon', 'trading.evaluate_execution_risk(uuid,uuid,trading.side,numeric,text,numeric,numeric,numeric,uuid)', 'execute')
    and not has_function_privilege('service_role', 'trading.evaluate_execution_risk(uuid,uuid,trading.side,numeric,text,numeric,numeric,numeric,uuid)', 'execute')
    and not has_function_privilege('authenticated', 'trading.evaluate_pretrade_risk(uuid,uuid)', 'execute')
    and not has_function_privilege('anon', 'public.dispatch_paper_execution(uuid)', 'execute')
    and has_function_privilege('authenticated', 'public.dispatch_paper_execution(uuid)', 'execute');
  res := res || format('P1 gate not callable by API roles; wrapper callable only when signed in=%s', case when ok then 'PASS' else 'FAIL' end);

  -- ---- End to end as the signed-in owner ----
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, take_profit, position_size, maximum_loss)
  values (inst, now(), 'long', 'approved', accA, 150.0, 150.2, 149.5, 151.5, 1, 8) returning id into s2;
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id, entry_low, entry_high, stop_loss, take_profit, position_size, maximum_loss)
  values (inst, now(), 'long', 'approved', accA, 150.0, 150.2, 149.5, 151.5, 1, 8) returning id into s3;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);

  -- E1 valid request awaits human approval
  select * into r from trading.request_execution(accA, s1, inst, 'long', 1, 'limit', 150.1, 149.6, 151.0);
  req1 := r.execution_request_id;
  res := res || format('E1 valid request awaits human approval=%s', case when r.status = 'manual_review' and r.decision = 'approved' then 'PASS' else 'FAIL(' || r.status || ' ' || r.decision || ')' end);

  -- E2 oversize request is blocked and can be neither approved nor dispatched
  select * into r from trading.request_execution(accA, s2, inst, 'long', 5, 'limit', 150.1, 149.6, 151.0);
  blocked_req := r.execution_request_id;
  res := res || format('E2 oversize request blocked=%s', case when r.status = 'blocked' then 'PASS' else 'FAIL(' || r.status || ')' end);
  begin
    perform trading.approve_paper_execution(blocked_req);
    res := res || 'E2b blocked request cannot be approved=FAIL(no error)';
  exception when others then
    res := res || format('E2b blocked request cannot be approved=PASS(%s)', sqlerrm);
  end;
  begin
    perform public.dispatch_paper_execution(blocked_req);
    res := res || 'E2c blocked request cannot be dispatched=FAIL(no error)';
  exception when others then
    res := res || format('E2c blocked request cannot be dispatched=PASS(%s)', sqlerrm);
  end;
  begin
    perform public.dispatch_paper_execution(req1);
    res := res || 'E2d unapproved request cannot be dispatched=FAIL(no error)';
  exception when others then
    res := res || format('E2d unapproved request cannot be dispatched=PASS(%s)', sqlerrm);
  end;

  -- E3 approve then dispatch: paper fill with accounting
  perform trading.approve_paper_execution(req1);
  disp := public.dispatch_paper_execution(req1);
  res := res || format('E3 approved request fills in paper=%s', case when disp ->> 'broker_dispatch_state' = 'paper_filled' and (disp ->> 'broker_dispatched')::boolean = false then 'PASS' else 'FAIL(' || disp::text || ')' end);
  select count(*) into n_pos from trading.positions where account_id = accA and status = 'open';
  select count(*) into n_ord from trading.orders where account_id = accA;
  select count(*) into n_led from trading.account_ledger where account_id = accA;
  res := res || format('E3b one order, one open position, one ledger row=%s', case when n_pos = 1 and n_ord = 1 and n_led = 1 then 'PASS' else format('FAIL(pos=%s ord=%s led=%s)', n_pos, n_ord, n_led) end);

  -- E4 replay is idempotent
  disp := public.dispatch_paper_execution(req1);
  select count(*) into n_ord from trading.orders where account_id = accA;
  res := res || format('E4 dispatch replay is idempotent=%s', case when (disp ->> 'idempotent_replay')::boolean and n_ord = 1 then 'PASS' else 'FAIL(' || disp::text || ' orders=' || n_ord || ')' end);

  -- E5 a second request for the same setup is blocked
  select * into r from trading.request_execution(accA, s1, inst, 'long', 1, 'limit', 150.1, 149.6, 151.0);
  res := res || format('E5 duplicate request for a filled setup blocked=%s', case when r.status = 'blocked' then 'PASS' else 'FAIL(' || r.status || ')' end);

  -- E6 state changes between approval and dispatch: the gate is re-run and blocks
  select * into r from trading.request_execution(accA, s3, inst, 'long', 1, 'limit', 150.1, 149.6, 151.0);
  req3 := r.execution_request_id;
  perform trading.approve_paper_execution(req3);
  reset role;
  insert into trading.positions(account_id, instrument_id, side, quantity, average_entry, opened_at, status) values (accA, inst2, 'long', 1, 1.1, now(), 'open');
  insert into trading.positions(account_id, instrument_id, side, quantity, average_entry, opened_at, status) values (accA, inst2, 'short', 1, 1.1, now(), 'open');
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  disp := public.dispatch_paper_execution(req3);
  select count(*) into n_ord from trading.orders where account_id = accA;
  select status into st from trading.execution_requests where id = req3;
  res := res || format('E6 re-evaluation blocks dispatch after limits are reached=%s', case when disp ->> 'broker_dispatch_state' = 'rejected' and st = 'cancelled' and n_ord = 1 then 'PASS' else 'FAIL(' || disp::text || ' status=' || st || ' orders=' || n_ord || ')' end);

  -- E7 direct table writes by the signed-in role are refused
  begin
    insert into trading.execution_requests(account_id, setup_id, instrument_id, requested_by, side, quantity, order_type, status) values (accA, s2, inst, uid, 'long', 1, 'limit', 'authorized');
    res := res || 'E7 direct insert refused=FAIL(no error)';
  exception when others then res := res || format('E7 direct insert refused=PASS(%s)', sqlerrm); end;
  begin
    perform trading.evaluate_execution_risk(accA, s2);
    res := res || 'E7c gate not callable directly=FAIL(no error)';
  exception when others then res := res || format('E7c gate not callable directly=PASS(%s)', sqlerrm); end;

  reset role;
  raise exception E'TRADING_TEST_RESULTS\n%\nsummary: % pass, % fail', array_to_string(res, E'\n'),
    (select count(*) from unnest(res) x where x like '%=PASS%'), (select count(*) from unnest(res) x where x like '%=FAIL%');
end $$;
