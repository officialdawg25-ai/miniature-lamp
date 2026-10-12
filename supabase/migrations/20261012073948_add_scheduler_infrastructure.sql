-- Scheduler infrastructure, approved by the owner on 12 October 2026.
-- The shared secret is generated inside the database and stored in the Vault. It is never returned by this migration, never appears in
-- the repository, and never reaches the browser. Scheduled jobs send it as a header; Edge Functions check it with verify_cron_secret.
create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'cron_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'cron_secret', 'Shared secret for scheduled jobs that call Edge Functions');
  end if;
end $$;

create or replace function public.verify_cron_secret(p_secret text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select p_secret is not null and exists (
    select 1 from vault.decrypted_secrets s
    where s.name = 'cron_secret' and length(s.decrypted_secret) = length(p_secret) and s.decrypted_secret = p_secret
  )
$function$;
revoke all on function public.verify_cron_secret(text) from public, anon, authenticated;
grant execute on function public.verify_cron_secret(text) to service_role;