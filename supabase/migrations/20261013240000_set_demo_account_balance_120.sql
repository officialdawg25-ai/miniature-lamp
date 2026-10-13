-- Owner request: the Exness demo account is funded to 120 USD. The platform's starting balance follows it; option 2 percentages are unchanged.
-- A deposit is not profit, so the engine's peak, day-start and week-start equity move to the new balance before the limits are recomputed.
-- The account had no trades, ledger rows or broker snapshots at the time, so no history is rewritten. Audited as an account-control change.
with before as (select id, initial_balance, metadata -> 'auto_risk' ar from trading.accounts where id = 'bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d'),
upd as (
  update trading.accounts a set initial_balance = 120,
    metadata = jsonb_set(a.metadata, '{auto_risk}', coalesce(a.metadata -> 'auto_risk', '{}'::jsonb) || jsonb_build_object('peak_equity', 120, 'day_start_equity', 120, 'week_start_equity', 120))
  where a.id = 'bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d' and a.initial_balance = 60
    and not exists (select 1 from trading.account_ledger l where l.account_id = a.id)
    and not exists (select 1 from trading.broker_snapshots s where s.account_id = a.id)
  returning a.id, a.initial_balance)
insert into trading.execution_audit_events(account_id, entity_type, entity_id, event_type, actor_user_id, actor_role, before_state, after_state, metadata)
select u.id, 'account_control', u.id, 'starting_balance_changed',
  (select m.user_id from trading.account_members m where m.account_id = u.id and m.role = 'owner' and m.active limit 1), 'owner',
  jsonb_build_object('initial_balance', b.initial_balance, 'auto_risk', b.ar), jsonb_build_object('initial_balance', u.initial_balance),
  jsonb_build_object('reason', 'Owner funded the demo account to 120 USD; applied on the owner''s instruction in chat', 'risk_percentages_changed', false)
from upd u join before b on b.id = u.id;
select trading.refresh_risk_limits('bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d');
