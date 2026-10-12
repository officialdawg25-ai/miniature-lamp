-- Owner choice "option 2" in chat: 5% per trade, 10% daily, 20% weekly, 5% total open risk; engine defaults 30% maximum drawdown and 300% minimum margin level.
-- Applied once, audited, then the limits are computed by the engine from the current equity.
with a as (select id, metadata from trading.accounts where id = 'bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d'),
pol as (select jsonb_build_object('enabled', true, 'risk_per_trade_fraction', 0.05, 'daily_loss_fraction', 0.10, 'weekly_loss_fraction', 0.20,
  'aggregate_open_risk_fraction', 0.05, 'max_drawdown_fraction', 0.30, 'min_margin_level_pct', 300,
  'broker_reference', 'Exness Standard publishes a 60% margin call and 0% stop out; the engine uses the levels MT5 reports and keeps its own minimum above them') p),
upd as (update trading.accounts t set metadata = t.metadata || jsonb_build_object('risk_policy', (select p from pol)) from a where t.id = a.id returning t.id)
insert into trading.execution_audit_events(account_id, entity_type, entity_id, event_type, actor_user_id, actor_role, before_state, after_state, metadata)
select a.id, 'account_control', a.id, 'auto_risk_policy_updated', (select m.user_id from trading.account_members m where m.account_id = a.id and m.role = 'owner' and m.active limit 1), 'owner',
  coalesce(a.metadata -> 'risk_policy', '{}'::jsonb), (select p from pol), jsonb_build_object('reason', 'Owner chose option 2 in chat: limits scale with equity')
from a join upd on upd.id = a.id;
select trading.refresh_risk_limits('bd30821e-fafb-4cb2-8db5-1a7ac9f15f0d');
