-- Scheduled daily FX bars (fx-daily-refresh, insert-only): two batches of five pairs, Tuesday to Saturday after the daily bar closes.
-- Ten provider calls a day, well inside the Alpha Vantage free allowance.
select cron.schedule('fx-daily-refresh-a', '25 6 * * 2-6', $job$
  select net.http_post(url := 'https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/fx-daily-refresh',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),
    body := '{"symbols":["EURUSD","USDJPY","GBPUSD","AUDUSD","USDCAD"]}'::jsonb, timeout_milliseconds := 140000);
$job$);
select cron.schedule('fx-daily-refresh-b', '40 6 * * 2-6', $job$
  select net.http_post(url := 'https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/fx-daily-refresh',
    headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),
    body := '{"symbols":["USDCHF","NZDUSD","EURJPY","GBPJPY","AUDJPY"]}'::jsonb, timeout_milliseconds := 140000);
$job$);
