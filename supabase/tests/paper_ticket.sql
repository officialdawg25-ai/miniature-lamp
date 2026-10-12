-- Single statement; always raises an exception listing PASS/FAIL per check so nothing is persisted. Uses the demo account and owner membership.
do $t$
declare acct uuid := 'bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d'; uid uuid; res text[] := '{}'; r jsonb; ok boolean; lc jsonb; pid uuid; rid uuid; ch jsonb; tr jsonb; sm jsonb;
begin
  select user_id into uid from trading.account_members where account_id = acct and role = 'owner' and active limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  begin perform public.submit_paper_idea(acct, 'USDJPY', 'long', 158.00, 157.90, 158.30, 'test thesis long enough'); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('P4 not in paper mode refused: %s', case when ok then 'PASS' else 'FAIL' end));
  perform public.set_account_mode(acct, 'paper test', 'paper');
  begin perform public.submit_paper_idea(acct, 'USDJPY', 'long', 158.00, 158.10, 158.30, 'test thesis long enough'); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('P3 stop on wrong side refused: %s', case when ok then 'PASS' else 'FAIL' end));
  r := public.submit_paper_idea(acct, 'USDJPY', 'long', 158.00, 157.50, 158.60, 'test thesis long enough');
  res := array_append(res, format('P2 oversize stop is no_trade: %s', case when (r->>'ok')::boolean = false and r->>'outcome' = 'no_trade' then 'PASS' else 'FAIL '||r::text end));
  r := public.submit_paper_idea(acct, 'USDJPY', 'long', 158.00, 157.90, 158.30, 'test thesis long enough');
  res := array_append(res, format('P1 valid idea sized 0.01 lot and awaiting approval: %s', case when (r->>'ok')::boolean and (r->>'lots')::numeric = 0.01 and r->>'status' = 'manual_review' and abs((r->>'risk_amount')::numeric - 0.6329) < 0.001 then 'PASS' else 'FAIL '||r::text end));
  rid := (r->>'execution_request_id')::uuid;
  r := public.approve_and_fill_paper(rid);
  res := array_append(res, format('P5 approved and paper filled: %s', case when r->>'broker_dispatch_state' = 'paper_filled' and (r->>'broker_dispatched')::boolean = false then 'PASS' else 'FAIL '||r::text end));
  lc := public.get_lifecycle();
  ch := lc->'accounts'->0->'chains'->0;
  res := array_append(res, format('P6 lifecycle shows setup, risk, request, order, trade and one open position: %s', case when ch->'setup'->>'symbol' = 'USDJPY' and jsonb_array_length(ch->'risk') >= 1 and jsonb_array_length(ch->'requests') = 1 and jsonb_array_length(ch->'orders') = 1 and ch->'trade' is not null and jsonb_array_length(lc->'accounts'->0->'positions') = 1 then 'PASS' else 'FAIL '||ch::text end));
  pid := (lc->'accounts'->0->'positions'->0->>'id')::uuid;
  sm := public.mark_paper_position_price(pid, 158.10);
  res := array_append(res, format('P7 mark-to-market gives USD unrealized (0.10 yen on 0.01 lot = 0.6329): %s', case when abs((sm->>'unrealized_pnl')::numeric - 0.6329) < 0.005 then 'PASS' else 'FAIL '||sm::text end));
  r := public.close_paper_position(pid, 158.20, 'test_target');
  lc := public.get_lifecycle(); tr := lc->'accounts'->0->'chains'->0->'trade';
  res := array_append(res, format('P8 close realises about 1.266 USD and 2R: %s', case when abs((tr->>'pnl')::numeric - 1.2658) < 0.01 and abs((tr->>'pnl_r')::numeric - 2) < 0.01 and jsonb_array_length(lc->'accounts'->0->'positions') = 0 then 'PASS' else 'FAIL '||tr::text end));
  res := array_append(res, format('P9 equity reflects profit (15 + pnl): %s', case when abs((lc->'accounts'->0->'summary'->>'equity')::numeric - 16.2658) < 0.01 then 'PASS' else 'FAIL '||(lc->'accounts'->0->'summary')::text end));
  perform public.set_kill_switch(acct, true, 'test engage');
  r := public.submit_paper_idea(acct, 'XAUUSD', 'long', 2000.00, 1999.50, 2002.00, 'test thesis long enough');
  res := array_append(res, format('P10 kill switch blocks the new request: %s', case when r->>'status' = 'blocked' and r->'reasons' ? 'kill_switch_active' then 'PASS' else 'FAIL '||r::text end));
  perform public.set_kill_switch(acct, false, 'test release');
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  begin perform public.submit_paper_idea(acct, 'USDJPY', 'long', 158.00, 157.90, 158.30, 'test thesis long enough'); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('P11 non-member refused: %s', case when ok then 'PASS' else 'FAIL' end));
  raise exception E'RESULTS\n%', array_to_string(res, E'\n');
end $t$;
