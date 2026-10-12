-- Daily refresh of US/JP yields and Fed/BoJ policy rates via the scheduled-refresh Edge Function.
-- The shared secret is read from Vault inside the job; it is never stored in this file.
select cron.schedule(
  'daily-market-data-refresh',
  '15 7 * * *',
  $job$
  select net.http_post(
    url := 'https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/scheduled-refresh',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),
    body := jsonb_build_object('job','daily'),
    timeout_milliseconds := 120000
  );
  $job$
);
