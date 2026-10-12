-- Single statement; always raises an exception listing PASS/FAIL per check so nothing is persisted. Uses its own fixture accounts.
do $t$
declare acc uuid; acc2 uuid; host uuid; owner uuid; r jsonb; g record; inst uuid; sx uuid; res text[] := '{}'; ok boolean; a trading.accounts%rowtype;
  pol constant jsonb := '{"enabled": true, "risk_per_trade_fraction": 0.05, "daily_loss_fraction": 0.10, "weekly_loss_fraction": 0.20, "aggregate_open_risk_fraction": 0.05, "max_drawdown_fraction": 0.30, "min_margin_level_pct": 300}';
begin
  select id into inst from core.instruments where symbol = 'USDJPY';
  select user_id into owner from trading.account_members where role = 'owner' and active limit 1;

  -- A1 paper account: limits follow equity
  insert into trading.accounts(name, currency_code, execution_mode, initial_balance, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('t-auto-paper', 'USD', 'human_approval', 60, 0.75, 60, 4.5, 1, jsonb_build_object('broker_mode', 'demo', 'risk_policy', pol)) returning id into acc;
  r := trading.refresh_risk_limits(acc);
  select * into a from trading.accounts where id = acc;
  res := array_append(res, format('A1 paper equity 60 gives 3 / 6 / 12 / 3: %s', case when r ->> 'equity_source' = 'paper' and a.max_risk_per_trade = 3 and a.max_daily_loss = 6 and a.max_weekly_loss = 12 and (a.metadata ->> 'max_aggregate_open_risk')::numeric = 3 then 'PASS' else 'FAIL ' || r::text end));

  -- A2 rounding never exceeds the percentage
  update trading.accounts set initial_balance = 61.37 where id = acc;
  r := trading.refresh_risk_limits(acc);
  select * into a from trading.accounts where id = acc;
  res := array_append(res, format('A2 limits round down (61.37 x 5%% = 3.06): %s', case when a.max_risk_per_trade = 3.06 and a.max_risk_per_trade <= 61.37 * 0.05 then 'PASS' else 'FAIL ' || a.max_risk_per_trade end));

  -- A3 audit written when limits change
  res := array_append(res, format('A3 recompute audited: %s', case when exists (select 1 from trading.execution_audit_events where account_id = acc and event_type = 'risk_limits_recomputed') then 'PASS' else 'FAIL' end));

  -- A4 broker host: first snapshot adopts the broker balance, limits from broker equity
  insert into trading.accounts(name, currency_code, execution_mode, initial_balance, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('t-auto-broker', 'USD', 'human_approval', 15, 0.75, 60, 4.5, 1, jsonb_build_object('broker_mode', 'demo', 'risk_policy', pol)) returning id into acc2;
  insert into trading.execution_hosts(account_id, name, token_hash, mode, active) values (acc2, 't-host', repeat('a', 64), 'demo', true) returning id into host;
  perform public.host_report_snapshot(host, '{"balance": 120, "equity": 120, "margin_used": 0, "free_margin": 120, "currency": "USD", "positions": [], "orders": [], "terms": {"leverage": 2000, "margin_call_level": 60, "stop_out_level": 0, "margin_so_mode": 0}}'::jsonb);
  select * into a from trading.accounts where id = acc2;
  res := array_append(res, format('A4 broker balance 120 adopted, per trade 6: %s', case when a.initial_balance = 120 and a.max_risk_per_trade = 6 and a.metadata -> 'auto_risk' ->> 'equity_source' = 'broker' then 'PASS' else 'FAIL ' || (a.metadata -> 'auto_risk')::text end));
  res := array_append(res, format('A5 balance detection audited: %s', case when exists (select 1 from trading.execution_audit_events where account_id = acc2 and event_type = 'starting_balance_detected_from_broker') then 'PASS' else 'FAIL' end));
  res := array_append(res, format('A6 broker terms stored: %s', case when (select (broker_terms ->> 'leverage')::int from trading.broker_snapshots where account_id = acc2 order by taken_at desc limit 1) = 2000 then 'PASS' else 'FAIL' end));

  -- A7 intraday equity loss of 10%% blocks new entries
  perform public.host_report_snapshot(host, '{"balance": 120, "equity": 107.9, "margin_used": 0, "free_margin": 107.9, "currency": "USD", "positions": [], "orders": [], "terms": {"leverage": 2000}}'::jsonb);
  select * into a from trading.accounts where id = acc2;
  res := array_append(res, format('A7 equity down 10.1%% today blocks: %s', case when a.metadata -> 'auto_risk' -> 'blocks' ? 'daily_equity_loss_limit' and not a.kill_switch then 'PASS' else 'FAIL ' || (a.metadata -> 'auto_risk')::text end));

  -- A8 gate shows the engine block
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id) values (inst, now(), 'long', 'candidate', acc2) returning id into sx;
  select * into g from trading.evaluate_execution_risk(acc2, sx);
  res := array_append(res, format('A8 gate blocks with auto_risk reason: %s', case when g.decision = 'blocked' and g.reasons ? 'auto_risk:daily_equity_loss_limit' then 'PASS' else 'FAIL ' || g.reasons::text end));

  -- A9 margin level below 300%% blocks
  perform public.host_report_snapshot(host, '{"balance": 120, "equity": 115, "margin_used": 50, "free_margin": 65, "currency": "USD", "positions": [], "orders": [], "terms": {"leverage": 2000}}'::jsonb);
  select * into a from trading.accounts where id = acc2;
  res := array_append(res, format('A9 margin level 230%% blocks: %s', case when a.metadata -> 'auto_risk' -> 'blocks' ? 'margin_level_below_minimum' then 'PASS' else 'FAIL ' || (a.metadata -> 'auto_risk')::text end));

  -- A10 30%% drawdown from the peak engages the kill switch
  perform public.host_report_snapshot(host, '{"balance": 120, "equity": 83, "margin_used": 0, "free_margin": 83, "currency": "USD", "positions": [], "orders": [], "terms": {"leverage": 2000}}'::jsonb);
  select * into a from trading.accounts where id = acc2;
  res := array_append(res, format('A10 drawdown 30.8%% engages kill switch: %s', case when a.kill_switch and a.metadata -> 'auto_risk' -> 'blocks' ? 'max_drawdown_reached' then 'PASS' else 'FAIL ' || (a.metadata -> 'auto_risk')::text end));
  res := array_append(res, format('A11 limits shrink with equity (83 x 5%% = 4.15): %s', case when a.max_risk_per_trade = 4.15 then 'PASS' else 'FAIL ' || a.max_risk_per_trade end));

  -- A12 the engine never releases a kill switch on recovery
  perform public.host_report_snapshot(host, '{"balance": 120, "equity": 125, "margin_used": 0, "free_margin": 125, "currency": "USD", "positions": [], "orders": [], "terms": {"leverage": 2000}}'::jsonb);
  select * into a from trading.accounts where id = acc2;
  res := array_append(res, format('A12 recovery does not release the kill switch: %s', case when a.kill_switch then 'PASS' else 'FAIL' end));

  -- A13 accounts without a policy are untouched
  insert into trading.accounts(name, currency_code, execution_mode, initial_balance, max_risk_per_trade, max_daily_loss, max_weekly_loss, max_open_trades, metadata)
  values ('t-manual', 'USD', 'human_approval', 60, 0.75, 60, 4.5, 1, '{}') returning id into acc;
  r := trading.refresh_risk_limits(acc);
  select * into a from trading.accounts where id = acc;
  res := array_append(res, format('A13 no policy, no change: %s', case when (r ->> 'enabled')::boolean = false and a.max_risk_per_trade = 0.75 then 'PASS' else 'FAIL' end));

  -- A14 owner policy RPC validates bounds and dollar edits are refused while automatic
  perform set_config('request.jwt.claims', json_build_object('sub', owner, 'role', 'authenticated')::text, true);
  begin perform public.set_auto_risk_policy('bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d', 'test bounds', true, 0.08, 0.1, 0.2, 0.08, 0.3, 300); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('A14 per-trade above 5%% refused: %s', case when ok then 'PASS' else 'FAIL' end));
  perform public.set_auto_risk_policy('bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d', 'enable for test', true, 0.05, 0.1, 0.2, 0.05, 0.3, 300);
  begin perform public.update_risk_policy('bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d', 'try dollars', 9); ok := false; exception when others then ok := sqlerrm like '%automatic risk management is on%'; end;
  res := array_append(res, format('A15 dollar edits refused while automatic: %s', case when ok then 'PASS' else 'FAIL' end));
  raise exception E'RESULTS\n%', array_to_string(res, E'\n');
end $t$;
