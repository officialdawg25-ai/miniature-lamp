-- Stores each backtest run with its parameters, a data snapshot summary and the full result, so every reported
-- number can be traced to the code version and the data it was computed from. Server-side only: RLS is enabled
-- with no policies, and only service_role can read and insert.
create table if not exists intelligence.backtest_runs (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by uuid,
  code_version text not null,
  symbol text not null,
  params jsonb not null,
  data_summary jsonb not null,
  result jsonb not null
);
alter table intelligence.backtest_runs enable row level security;
revoke all on intelligence.backtest_runs from public, anon, authenticated;
grant select, insert on intelligence.backtest_runs to service_role;
