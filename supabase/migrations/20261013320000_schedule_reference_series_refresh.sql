-- Daily refresh of the live FRED reference series (last 30 days, idempotent upserts). EVZCLS is discontinued and not refreshed.
select cron.schedule('reference-series-daily-refresh', '35 15 * * 2-6', $job$
  select net.http_post(url := 'https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/reference-series-ingestion',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),
    body := jsonb_build_object('series_id', s, 'start_date', (current_date - 30)::text, 'dry_run', false), timeout_milliseconds := 60000)
  from unnest(array['VIXCLS','GVZCLS','BAA10Y','T10YIE','T10Y2Y','DTWEXBGS','DFF']) s;
$job$);
