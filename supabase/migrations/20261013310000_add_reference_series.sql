-- Reference market series from FRED (implied volatility indices, credit spread, breakeven inflation, curve, broad dollar).
-- Each observation keeps its source date, a conservative availability time and the FRED realtime start, so features
-- built from it can be filtered to what was known at a decision time.
create table if not exists market.reference_series (
  series_id text primary key,
  provider text not null default 'FRED',
  title text not null,
  family text not null,
  units text,
  frequency text,
  observation_start date,
  provider_last_updated timestamptz,
  revisable boolean not null default false,
  availability_rule text not null,
  probed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);
create table if not exists market.reference_observations (
  series_id text not null references market.reference_series(series_id),
  obs_date date not null,
  value numeric not null,
  available_at timestamptz not null,
  source_realtime_start date,
  retrieved_at timestamptz not null default now(),
  primary key (series_id, obs_date),
  check (available_at > obs_date::timestamptz)
);
alter table market.reference_series enable row level security;
alter table market.reference_observations enable row level security;
revoke all on market.reference_series, market.reference_observations from public, anon, authenticated;
comment on table market.reference_observations is 'Daily FRED reference series. available_at = next day 14:00 UTC (conservative: FRED posts daily market series the following day). Missing FRED values (".") are not stored.';
-- The ingestion function writes as service_role (same grants as market.price_bars and market.yield_observations).
grant select, insert, update on market.reference_series, market.reference_observations to service_role;
