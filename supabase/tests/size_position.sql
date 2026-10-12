-- Pure-function checks for trading.size_position. The specification numbers are ILLUSTRATIVE, not any broker's real values.
do $$
declare r record;
begin
  select * into r from trading.size_position(15, 0.01, 150, 149.5, 0.001, 0.64, 0.01, 0.01, 100);
  if r.volume is not null or r.reason <> 'minimum_lot_risk_exceeds_budget' then raise exception 'FAIL: minimum lot above budget must return no size'; end if;
  select * into r from trading.size_position(1500, 0.01, 150, 149.5, 0.001, 0.64, 0.01, 0.01, 200);
  if r.volume <> 0.04 or r.reason <> 'ok' or r.risk_fraction_used > 0.01 then raise exception 'FAIL: size must round down and stay within the risk budget'; end if;
  select * into r from trading.size_position(1500, 0.01, 150, 150, 0.001, 0.64, 0.01, 0.01, 200);
  if r.reason <> 'invalid_input' then raise exception 'FAIL: stop equal to entry must be rejected'; end if;
  select * into r from trading.size_position(1500, 0.10, 150, 149.5, 0.001, 0.64, 0.01, 0.01, 200);
  if r.reason <> 'invalid_input' then raise exception 'FAIL: risk above 5 percent must be rejected'; end if;
  raise exception 'PASS: size_position checks (rolled back)';
end $$;
