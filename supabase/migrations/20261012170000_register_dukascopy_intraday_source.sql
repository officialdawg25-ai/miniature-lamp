-- Dukascopy hourly tick files are the intraday source for 5-minute bars (built from the bid). Prices differ slightly from any one broker.
insert into core.data_sources (name, provider_type, base_url, reliability_score, active, metadata)
select 'Dukascopy', 'market_data_vendor', 'https://datafeed.dukascopy.com', null, true,
  '{"dataset":"hourly bid/ask tick files, bars built from the bid","note":"prices differ slightly from any one broker; spreads are Dukascopy spreads"}'::jsonb
where not exists (select 1 from core.data_sources where name = 'Dukascopy');
