-- Daily policy-rate levels per central bank, with the time each value counts as publicly known.
-- Written only by the policy-rate-ingestion Edge Function (service_role). RLS is on with no policies, so no browser role can read or write it directly.
create table if not exists macro.policy_rate_observations (
  id uuid primary key default gen_random_uuid(),
  central_bank_id uuid not null references macro.central_banks(id),
  ts timestamptz not null,
  rate numeric not null,
  rate_lower numeric,
  series_id text not null,
  available_at timestamptz not null,
  source_id uuid references core.data_sources(id),
  retrieved_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  constraint policy_rate_observations_unique unique (central_bank_id, ts),
  constraint policy_rate_available_after_ts check (available_at >= ts)
);
create index if not exists policy_rate_observations_bank_available_idx on macro.policy_rate_observations (central_bank_id, available_at);
alter table macro.policy_rate_observations enable row level security;
grant select, insert, update on table macro.policy_rate_observations to service_role;
