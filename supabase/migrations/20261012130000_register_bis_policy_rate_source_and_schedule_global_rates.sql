-- BIS is the source for BoE, RBA, RBNZ, BoC and SNB policy rates (dataflow WS_CBPOL, daily). ECB comes from FRED (ECBDFR).
insert into core.data_sources (name, provider_type, base_url, reliability_score, active, metadata)
select 'Bank for International Settlements', 'official_public', 'https://stats.bis.org', null, true,
  '{"dataset":"WS_CBPOL central bank policy rates, daily","units":"percent per annum","coverage":"RBA, BoC, BoE, RBNZ, SNB"}'::jsonb
where not exists (select 1 from core.data_sources where name = 'Bank for International Settlements');

-- Daily idempotent refresh of the six banks over the last 400 days. The shared secret is read from Vault inside the job.
select cron.schedule('daily-global-policy-rates', '20 7 * * *', $job$
  select net.http_post(
    url := 'https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/policy-rates-global',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),
    body := jsonb_build_object('dry_run', false, 'start_date', to_char(current_date - 400, 'YYYY-MM-DD')),
    timeout_milliseconds := 120000);
$job$);
