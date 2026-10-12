-- Run as a single statement; it always raises an exception listing PASS/FAIL per check so nothing is persisted.
do $t$
declare acct uuid := 'bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d'; uid uuid; res text[] := '{}'; r jsonb; g record; ok boolean; n int; inst uuid; sx uuid;
begin
  select id into inst from core.instruments where symbol = 'USDJPY';
  insert into trading.trade_setups(instrument_id, as_of, side, status, account_id) values (inst, now(), 'long', 'candidate', acct) returning id into sx;
  select user_id into uid from trading.account_members where account_id = acct and role = 'owner' and active limit 1;
  -- These checks exercise the manual dollar policy, so the automatic engine is switched off inside this rolled-back test.
  update trading.accounts set metadata = jsonb_set(metadata, '{risk_policy,enabled}', 'false'::jsonb) where id = acct and metadata ? 'risk_policy';
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  r := public.get_account_controls();
  res := array_append(res, format('C1 controls readable: %s', case when jsonb_array_length(r->'accounts') = 1 and (r->'accounts'->0->>'operating_mode') = 'demo' then 'PASS' else 'FAIL '||r::text end));
  r := public.update_risk_policy(acct, 'test change', 0.5, null, null, null, 2, null, null);
  res := array_append(res, format('C2 policy update: %s', case when (r->>'max_risk_per_trade')::numeric = 0.5 and (r->>'max_open_trades')::int = 2 then 'PASS' else 'FAIL '||r::text end));
  select count(*) into n from trading.execution_audit_events where account_id = acct and event_type = 'risk_policy_updated';
  res := array_append(res, format('C3 audit written: %s', case when n >= 1 then 'PASS' else 'FAIL' end));
  begin perform public.update_risk_policy(acct, 'bad value', 99); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('C4 per-trade above weekly rejected: %s', case when ok then 'PASS' else 'FAIL' end));
  begin perform public.update_risk_policy(acct, 'x'); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('C5 short reason rejected: %s', case when ok then 'PASS' else 'FAIL' end));
  begin perform public.set_account_mode(acct, 'try live', 'restricted_live'); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('C6 live mode refused: %s', case when ok then 'PASS' else 'FAIL' end));
  begin perform public.set_account_mode(acct, 'try auto', null, 'automated'); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('C7 automated refused: %s', case when ok then 'PASS' else 'FAIL' end));
  perform public.set_account_mode(acct, 'research test', 'research');
  select * into g from trading.evaluate_execution_risk(acct, sx);
  res := array_append(res, format('C8 research mode blocks: %s', case when g.decision = 'blocked' and g.reasons ? 'operating_mode_research_no_orders' then 'PASS' else 'FAIL '||g.reasons::text end));
  perform public.set_account_mode(acct, 'back to demo', 'demo');
  perform public.set_kill_switch(acct, true, 'test engage');
  select * into g from trading.evaluate_execution_risk(acct, sx);
  res := array_append(res, format('C9 kill switch blocks: %s', case when g.reasons ? 'kill_switch_active' then 'PASS' else 'FAIL '||g.reasons::text end));
  perform public.set_kill_switch(acct, false, 'test release');
  select * into g from trading.evaluate_execution_risk(acct, sx);
  res := array_append(res, format('C10 release clears: %s', case when not (g.reasons ? 'kill_switch_active') then 'PASS' else 'FAIL' end));
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  begin perform public.set_kill_switch(acct, true, 'intruder'); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('C11 non-member kill switch refused: %s', case when ok then 'PASS' else 'FAIL' end));
  begin perform public.update_risk_policy(acct, 'intruder', 1); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('C12 non-member policy refused: %s', case when ok then 'PASS' else 'FAIL' end));
  raise exception E'RESULTS\n%', array_to_string(res, E'\n');
end $t$;
