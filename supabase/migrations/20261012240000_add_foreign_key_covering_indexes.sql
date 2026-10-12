-- Covering indexes for foreign keys flagged by the performance advisor. Additive only; no behaviour change.
create index if not exists broker_snapshots_host_id_idx on trading.broker_snapshots (host_id);
create index if not exists execution_hosts_account_id_idx on trading.execution_hosts (account_id);
create index if not exists cot_observations_source_id_idx on macro.cot_observations (source_id);
create index if not exists policy_rate_observations_source_id_idx on macro.policy_rate_observations (source_id);
create index if not exists backtest_runs_hypothesis_id_idx on intelligence.backtest_runs (hypothesis_id);
