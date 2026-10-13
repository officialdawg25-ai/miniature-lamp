-- Integrity guard: a historical hypothesis gets exactly one stored confirmation run. Found in the 2026-10-13 audit: a client timeout
-- let eurusd-month-end-hedge-rebalancing be stored twice (identical results). Forward tests, whose specification has an
-- interim_policy, keep storing interim runs. The duplicate (713b8d48, identical to 4b50cc26) is left unchanged and documented in
-- docs/platform-audit-2026-10.md; modifying stored evidence needs the owner's approval.
create or replace function intelligence.enforce_single_confirmation_run()
returns trigger language plpgsql set search_path to '' as $function$
begin
  if new.hypothesis_id is null then return new; end if;
  if exists (select 1 from intelligence.research_hypotheses h where h.id = new.hypothesis_id and h.specification ? 'interim_policy') then return new; end if;
  perform pg_advisory_xact_lock(hashtext('confirmation_run:' || new.hypothesis_id::text));
  if exists (select 1 from intelligence.backtest_runs r where r.hypothesis_id = new.hypothesis_id) then
    raise exception 'hypothesis % already has a stored confirmation run; a second run is not allowed', new.hypothesis_id;
  end if;
  return new;
end $function$;
revoke all on function intelligence.enforce_single_confirmation_run() from public, anon, authenticated;
create or replace trigger backtest_runs_single_confirmation before insert on intelligence.backtest_runs
  for each row execute function intelligence.enforce_single_confirmation_run();

