-- CFTC Traders in Financial Futures (futures only), weekly, for the seven currency futures against USD.
-- A report dated Tuesday D is published on Friday D+3 (later after a holiday). It counts as known from Monday D+6 00:00Z, which
-- covers a one-day holiday delay and never uses a position before it was public.
create table if not exists macro.cot_observations (
  id uuid primary key default gen_random_uuid(),
  contract_code text not null,
  currency_code text not null,
  report_date date not null,
  available_at timestamptz not null,
  open_interest bigint not null,
  lev_long bigint not null,
  lev_short bigint not null,
  asset_long bigint not null,
  asset_short bigint not null,
  dealer_long bigint not null,
  dealer_short bigint not null,
  source_id uuid references core.data_sources(id),
  retrieved_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  constraint cot_observations_unique unique (contract_code, report_date),
  constraint cot_available_after_report check (available_at > report_date)
);
create index if not exists cot_observations_currency_available_idx on macro.cot_observations (currency_code, available_at);
alter table macro.cot_observations enable row level security;
grant select, insert, update on table macro.cot_observations to service_role;

insert into core.data_sources (name, provider_type, base_url, reliability_score, active, metadata)
select 'CFTC Commitments of Traders', 'official_public', 'https://publicreporting.cftc.gov', null, true,
  '{"dataset":"Traders in Financial Futures, futures only (gpe5-46if)","frequency":"weekly, Tuesday positions, published Friday"}'::jsonb
where not exists (select 1 from core.data_sources where name = 'CFTC Commitments of Traders');

-- Weekly refresh of the last 120 days (idempotent), Friday to Sunday evenings to cover holiday-delayed releases.
select cron.schedule('weekly-cot-refresh', '30 21 * * 5,6,0', $job$
  select net.http_post(
    url := 'https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/cot-ingestion',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),
    body := jsonb_build_object('dry_run', false, 'start_date', to_char(current_date - 120, 'YYYY-MM-DD')),
    timeout_milliseconds := 120000);
$job$);
