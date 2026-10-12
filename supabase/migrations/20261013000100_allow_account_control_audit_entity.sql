-- The audit log must accept account-control changes (risk policy, mode, kill switch).
alter table trading.execution_audit_events drop constraint execution_audit_events_entity_type_check;
alter table trading.execution_audit_events add constraint execution_audit_events_entity_type_check
  check (entity_type = any (array['execution_request'::text, 'risk_decision'::text, 'account_ledger'::text, 'account_control'::text]));
