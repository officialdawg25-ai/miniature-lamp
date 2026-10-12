-- Single statement; always raises an exception listing PASS/FAIL per check so nothing is persisted. Uses the demo account and owner membership.
do $t$
declare acct uuid := 'bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d'; uid uuid; res text[] := '{}'; r jsonb; ok boolean; lc jsonb; pid uuid; rid uuid; ch jsonb; tr jsonb; sm jsonb;
  eq0 numeric; frac numeric; ex record; units_e numeric; usd_per_pip numeric;
begin
  select user_id into uid from trading.account_members where account_id = acct and role = 'owner' and active limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  begin perform public.submit_paper_idea(acct, 'USDJPY', 'long', 158.00, 157.90, 158.30, 'test thesis long enough'); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('P4 not in paper mode refused: %s', case when ok then 'PASS' else 'FAIL' end));
  perform public.set_account_mode(acct, 'paper test', 'paper');
  -- Expected sizing follows whatever balance and policy the account has (no hard-coded lot size).
  select a.initial_balance + coalesce((select sum(l.realized_pnl) from trading.account_ledger l where l.account_id = a.id), 0), least(coalesce((a.metadata ->> 'risk_per_trade_fraction')::numeric, 0.01), 0.05)
    into eq0, frac from trading.accounts a where a.id = acct;
  select * into ex from trading.size_position(eq0, frac, 158.00, 157.90, 0.001, 100000 * 0.001 / 158.00, 0.01, 0.01, 100);
  units_e := ex.volume * 100000 / 158.00; usd_per_pip := units_e * 0.01;
  begin perform public.submit_paper_idea(acct, 'USDJPY', 'long', 158.00, 158.10, 158.30, 'test thesis long enough'); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('P3 stop on wrong side refused: %s', case when ok then 'PASS' else 'FAIL' end));
  r := public.submit_paper_idea(acct, 'USDJPY', 'long', 158.00, 157.50, 158.60, 'test thesis long enough');
  res := array_append(res, format('P2 oversize stop is no_trade: %s', case when (r->>'ok')::boolean = false and r->>'outcome' = 'no_trade' then 'PASS' else 'FAIL '||r::text end));
  r := public.submit_paper_idea(acct, 'USDJPY', 'long', 158.00, 157.90, 158.30, 'test thesis long enough');
  res := array_append(res, format('P1 valid idea sized from the policy (%s lot) and awaiting approval: %s', ex.volume, case when (r->>'ok')::boolean and (r->>'lots')::numeric = ex.volume and r->>'status' = 'manual_review' and abs((r->>'risk_amount')::numeric - ex.risk_amount) < 0.001 then 'PASS' else 'FAIL '||r::text end));
  rid := (r->>'execution_request_id')::uuid;
  r := public.approve_and_fill_paper(rid);
  res := array_append(res, format('P5 approved and paper filled: %s', case when r->>'broker_dispatch_state' = 'paper_filled' and (r->>'broker_dispatched')::boolean = false then 'PASS' else 'FAIL '||r::text end));
  lc := public.get_lifecycle();
  ch := lc->'accounts'->0->'chains'->0;
  res := array_append(res, format('P6 lifecycle shows setup, risk, request, order, trade and one open position: %s', case when ch->'setup'->>'symbol' = 'USDJPY' and jsonb_array_length(ch->'risk') >= 1 and jsonb_array_length(ch->'requests') = 1 and jsonb_array_length(ch->'orders') = 1 and ch->'trade' is not null and jsonb_array_length(lc->'accounts'->0->'positions') = 1 then 'PASS' else 'FAIL '||ch::text end));
  pid := (lc->'accounts'->0->'positions'->0->>'id')::uuid;
  sm := public.mark_paper_position_price(pid, 158.10);
  res := array_append(res, format('P7 mark-to-market gives USD unrealized (10 pips): %s', case when abs((sm->>'unrealized_pnl')::numeric - usd_per_pip * 10) < 0.005 then 'PASS' else 'FAIL '||sm::text end));
  r := public.close_paper_position(pid, 158.20, 'test_target');
  lc := public.get_lifecycle(); tr := lc->'accounts'->0->'chains'->0->'trade';
  res := array_append(res, format('P8 close realises 20 pips and 2R: %s', case when abs((tr->>'pnl')::numeric - usd_per_pip * 20) < 0.01 and abs((tr->>'pnl_r')::numeric - 2) < 0.01 and jsonb_array_length(lc->'accounts'->0->'positions') = 0 then 'PASS' else 'FAIL '||tr::text end));
  res := array_append(res, format('P9 equity reflects profit (balance + pnl): %s', case when abs((lc->'accounts'->0->'summary'->>'equity')::numeric - (eq0 + usd_per_pip * 20)) < 0.01 then 'PASS' else 'FAIL '||(lc->'accounts'->0->'summary')::text end));
  perform public.set_kill_switch(acct, true, 'test engage');
  r := public.submit_paper_idea(acct, 'XAUUSD', 'long', 2000.00, 1999.50, 2002.00, 'test thesis long enough');
  res := array_append(res, format('P10 kill switch blocks the new request: %s', case when r->>'status' = 'blocked' and r->'reasons' ? 'kill_switch_active' then 'PASS' else 'FAIL '||r::text end));
  perform public.set_kill_switch(acct, false, 'test release');
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  begin perform public.submit_paper_idea(acct, 'USDJPY', 'long', 158.00, 157.90, 158.30, 'test thesis long enough'); ok := false; exception when others then ok := true; end;
  res := array_append(res, format('P11 non-member refused: %s', case when ok then 'PASS' else 'FAIL' end));
  raise exception E'RESULTS\n%', array_to_string(res, E'\n');
end $t$;
