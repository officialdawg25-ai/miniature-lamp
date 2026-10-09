-- Register the dedicated XAU/USD feed independently of the FX-only Alpha Vantage adapter.
-- Safe to re-run: the provider name is unique and updates only this provider's own registry row.
insert into core.data_sources (name, provider_type, base_url, reliability_score, active, metadata)
values (
  'Twelve Data',
  'market_data',
  'https://api.twelvedata.com',
  85,
  true,
  jsonb_build_object(
    'adapter', 'xauusd-ingestion',
    'coverage', 'XAU/USD daily bars',
    'provider_symbol', 'XAU/USD',
    'requires_secret', 'TWELVE_DATA_API_KEY',
    'timestamp_semantics', 'UTC midnight session label; not an exact exchange close timestamp'
  )
)
on conflict (name) do update
set provider_type = excluded.provider_type,
    base_url = excluded.base_url,
    reliability_score = excluded.reliability_score,
    active = excluded.active,
    metadata = coalesce(core.data_sources.metadata, '{}'::jsonb) || excluded.metadata;
