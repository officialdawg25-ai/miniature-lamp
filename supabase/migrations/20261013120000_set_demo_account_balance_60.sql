-- Owner request: the Exness demo account is funded to 60 USD (a 60 USD deposit on the broker side). The platform's starting balance follows it.
-- Risk limits are deliberately unchanged here; any change to them goes through update_risk_policy with its own reason. Audited as an account-control change.
-- The account had no trades, ledger rows or broker snapshots at the time, so no history is rewritten.
with before as (select id, name, initial_balance from trading.accounts where id = 'bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d'),
upd as (
  update trading.accounts set initial_balance = 60, name = 'Exness demo Standard'
  where id = 'bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d' and initial_balance = 15
  returning id, name, initial_balance)
insert into trading.execution_audit_events(account_id, entity_type, entity_id, event_type, actor_user_id, actor_role, before_state, after_state, metadata)
select u.id, 'account_control', u.id, 'starting_balance_changed',
  (select m.user_id from trading.account_members m where m.account_id = u.id and m.role = 'owner' and m.active limit 1), 'owner',
  jsonb_build_object('initial_balance', b.initial_balance, 'name', b.name), jsonb_build_object('initial_balance', u.initial_balance, 'name', u.name),
  jsonb_build_object('reason', 'Owner funded the demo account to 60 USD; applied on the owner''s instruction in chat', 'risk_limits_changed', false)
from upd u join before b on b.id = u.id;
