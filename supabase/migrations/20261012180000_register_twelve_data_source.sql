insert into core.data_sources (name, provider_type, base_url, reliability_score, active, metadata)
select 'Twelve Data', 'market_data_vendor', 'https://api.twelvedata.com', null, true,
  '{"dataset":"forex and gold intraday bars (free Basic plan)","limits":"8 requests per minute, 800 per day (per vendor documentation; verify)","note":"bars carry no spread or volume; costs are assumed from broker quotes"}'::jsonb
where not exists (select 1 from core.data_sources where name = 'Twelve Data');
