-- Source registry record (configuration, not data) for the Japan Ministry of Finance JGB benchmark yield CSV.
insert into core.data_sources (name, provider_type, base_url, active, metadata)
select 'Ministry of Finance Japan', 'official_public', 'https://www.mof.go.jp', true,
       jsonb_build_object('dataset', 'JGB benchmark yields (jgbcme_all.csv)', 'units', 'percent')
where not exists (select 1 from core.data_sources where name = 'Ministry of Finance Japan');
