-- Demo-only bridge between the platform and an MT5 execution host (a Windows machine running supabase/../execution-host).
-- The host pulls work; the platform never connects out to a broker. There is no live mode: execution_hosts.mode can only be 'demo'.
-- A host authenticates with a secret that only exists on the host; the database stores its SHA-256 hash.
create table if not exists trading.execution_hosts (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references trading.accounts(id),
  name text not null,
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  mode text not null default 'demo' check (mode = 'demo'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz
);
alter table trading.execution_hosts enable row level security;

-- Run once by the owner in the SQL editor, with the hash printed by the host's token tool. The account must be flagged as demo.
create or replace function trading.register_execution_host(p_account_id uuid, p_name text, p_token_hash text)
returns uuid
language plpgsql security definer set search_path to 'trading', 'public'
as $function$
declare a trading.accounts%rowtype; hid uuid;
begin
  select * into a from trading.accounts where id = p_account_id;
  if not found then raise exception 'account not found'; end if;
  if coalesce(a.metadata ->> 'broker_mode', '') <> 'demo' then raise exception 'account must have metadata.broker_mode = demo'; end if;
  if a.execution_mode <> 'human_approval' then raise exception 'account execution_mode must be human_approval'; end if;
  insert into trading.execution_hosts(account_id, name, token_hash) values (p_account_id, p_name, p_token_hash) returning id into hid;
  return hid;
end;
$function$;
revoke all on function trading.register_execution_host(uuid, text, text) from public, anon, authenticated;

create or replace function public.host_resolve(p_token_hash text)
returns table(host_id uuid, account_id uuid)
language plpgsql security definer set search_path to 'trading', 'public'
as $function$
declare h trading.execution_hosts%rowtype; a trading.accounts%rowtype;
begin
  select * into h from trading.execution_hosts x where x.token_hash = p_token_hash and x.active;
  if not found then return; end if;
  select * into a from trading.accounts ac where ac.id = h.account_id;
  if not found or not a.active or coalesce(a.metadata ->> 'broker_mode', '') <> 'demo' then return; end if;
  update trading.execution_hosts x set last_seen_at = now() where x.id = h.id;
  return query select h.id, h.account_id;
end;
$function$;

create or replace function public.host_upsert_specs(p_host_id uuid, p_specs jsonb)
returns integer
language plpgsql security definer set search_path to 'trading', 'public'
as $function$
declare h trading.execution_hosts%rowtype; s jsonb; n integer := 0;
begin
  select * into h from trading.execution_hosts x where x.id = p_host_id and x.active;
  if not found then raise exception 'host not active'; end if;
  if jsonb_typeof(p_specs) <> 'array' or jsonb_array_length(p_specs) > 100 then raise exception 'specs must be an array of at most 100 items'; end if;
  for s in select * from jsonb_array_elements(p_specs) loop
    insert into trading.broker_symbol_specs(account_id, symbol, contract_size, tick_size, tick_value, volume_min, volume_step, volume_max, account_currency, source, observed_at)
    values (h.account_id, upper(s ->> 'symbol'), (s ->> 'contract_size')::numeric, (s ->> 'tick_size')::numeric, (s ->> 'tick_value')::numeric,
            (s ->> 'volume_min')::numeric, (s ->> 'volume_step')::numeric, (s ->> 'volume_max')::numeric, s ->> 'account_currency', 'mt5_symbol_info', now())
    on conflict (account_id, symbol) do update set contract_size = excluded.contract_size, tick_size = excluded.tick_size, tick_value = excluded.tick_value,
      volume_min = excluded.volume_min, volume_step = excluded.volume_step, volume_max = excluded.volume_max, account_currency = excluded.account_currency, observed_at = now();
    n := n + 1;
  end loop;
  return n;
end;
$function$;

-- Hands authorized requests to the host. Each request is re-checked at this moment (risk gate, human approval where required, and the
-- broker's own volume rules) and is only then moved to 'queued'. Requests that fail are rejected here and never reach the host.
create or replace function public.host_claim_requests(p_host_id uuid, p_limit integer default 5)
returns jsonb
language plpgsql security definer set search_path to 'trading', 'public', 'pg_catalog'
as $function$
declare
  h trading.execution_hosts%rowtype; a trading.accounts%rowtype; r trading.execution_requests%rowtype;
  g record; sp trading.broker_symbol_specs%rowtype; sym text; out jsonb := '[]'::jsonb;
  ap jsonb; approver uuid; why text;
begin
  select * into h from trading.execution_hosts x where x.id = p_host_id and x.active;
  if not found then raise exception 'host not active'; end if;
  select * into a from trading.accounts ac where ac.id = h.account_id;
  if not a.active or coalesce(a.metadata ->> 'broker_mode', '') <> 'demo' or a.execution_mode <> 'human_approval' then return out; end if;

  for r in
    select * from trading.execution_requests er
    where er.account_id = h.account_id and er.status = 'authorized' and er.broker_dispatch_state = 'not_dispatched'
    order by er.requested_at limit least(greatest(p_limit, 1), 20) for update skip locked
  loop
    why := null;
    select i.symbol into sym from core.instruments i where i.id = r.instrument_id;
    select * into g from trading.evaluate_execution_risk(r.account_id, r.setup_id, r.side, r.quantity, r.order_type, r.requested_price, r.stop_loss, r.take_profit, r.id);
    if g.decision = 'blocked' then
      why := 'risk gate re-evaluation blocked: ' || g.reasons::text;
    elsif g.decision = 'manual_review' then
      ap := coalesce(r.metadata -> 'paper_approval', '{}'::jsonb);
      approver := nullif(ap ->> 'approved_by', '')::uuid;
      if approver is null or coalesce(ap ->> 'approved_role', '') not in ('owner', 'risk_manager')
         or not exists (select 1 from trading.account_members m where m.account_id = r.account_id and m.user_id = approver and m.active and m.role in ('owner', 'risk_manager')) then
        why := 'manual-review request lacks valid human approval';
      end if;
    end if;
    if why is null then
      select * into sp from trading.broker_symbol_specs s where s.account_id = r.account_id and s.symbol = sym;
      if not found then why := 'no broker specification synced for ' || sym;
      elsif r.quantity < sp.volume_min or r.quantity > sp.volume_max then why := 'quantity outside broker volume limits';
      elsif abs(round(r.quantity / sp.volume_step) * sp.volume_step - r.quantity) > sp.volume_step * 1e-6 then why := 'quantity not a multiple of the broker volume step';
      end if;
    end if;
    if why is not null then
      update trading.execution_requests er set status = 'cancelled', broker_dispatch_state = 'rejected', risk_decision_id = coalesce(g.risk_decision_id, er.risk_decision_id), rejection_reason = why where er.id = r.id;
      insert into trading.risk_events(account_id, setup_id, event_type, severity, message, metrics)
      values (r.account_id, r.setup_id, 'host_claim_rejected', 'warning', 'Request rejected before reaching the execution host.', jsonb_build_object('execution_request_id', r.id, 'reason', why));
      continue;
    end if;
    update trading.execution_requests er set broker_dispatch_state = 'queued', risk_decision_id = g.risk_decision_id where er.id = r.id;
    insert into trading.risk_events(account_id, setup_id, event_type, severity, message, metrics)
    values (r.account_id, r.setup_id, 'host_claim_queued', 'info', 'Request queued for the demo execution host.', jsonb_build_object('execution_request_id', r.id, 'host_id', h.id));
    out := out || jsonb_build_array(jsonb_build_object(
      'request_id', r.id, 'symbol', sym, 'side', r.side, 'volume', r.quantity, 'order_type', r.order_type,
      'price', r.requested_price, 'stop_loss', r.stop_loss, 'take_profit', r.take_profit));
  end loop;
  return out;
end;
$function$;

-- The host reports each step. 'sent' and 'acknowledged' are refused when the host says it was a dry run, so a dry run cannot be recorded as an order.
create or replace function public.host_report(p_host_id uuid, p_request_id uuid, p_state text, p_detail jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path to 'trading', 'public', 'pg_catalog'
as $function$
declare h trading.execution_hosts%rowtype; r trading.execution_requests%rowtype; new_status text;
begin
  select * into h from trading.execution_hosts x where x.id = p_host_id and x.active;
  if not found then raise exception 'host not active'; end if;
  if p_state not in ('sent', 'acknowledged', 'rejected') then raise exception 'unsupported state'; end if;
  select * into r from trading.execution_requests er where er.id = p_request_id and er.account_id = h.account_id for update;
  if not found then raise exception 'request not found for this host'; end if;
  if p_state in ('sent', 'acknowledged') and coalesce((p_detail ->> 'dry_run')::boolean, false) then raise exception 'a dry run cannot be recorded as % ', p_state; end if;
  new_status := case when p_state = 'sent' then 'submitted' when p_state = 'rejected' and r.broker_dispatch_state = 'queued' then 'cancelled' else r.status end;
  update trading.execution_requests er set broker_dispatch_state = p_state, status = new_status,
    rejection_reason = case when p_state = 'rejected' then left(coalesce(p_detail ->> 'reason', 'rejected by host'), 300) else er.rejection_reason end,
    metadata = er.metadata || jsonb_build_object('broker_result', coalesce(er.metadata -> 'broker_result', '{}'::jsonb) || jsonb_build_object(p_state, p_detail - 'secret'))
  where er.id = r.id;
  insert into trading.risk_events(account_id, setup_id, event_type, severity, message, metrics)
  values (r.account_id, r.setup_id, 'host_report_' || p_state, case when p_state = 'rejected' then 'warning' else 'info' end, 'Execution host reported ' || p_state || '.',
          jsonb_build_object('execution_request_id', r.id, 'host_id', h.id, 'detail', p_detail - 'secret'));
  return jsonb_build_object('request_id', r.id, 'broker_dispatch_state', p_state, 'status', new_status);
end;
$function$;

revoke all on function public.host_resolve(text) from public, anon, authenticated;
revoke all on function public.host_upsert_specs(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.host_claim_requests(uuid, integer) from public, anon, authenticated;
revoke all on function public.host_report(uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.host_resolve(text) to service_role;
grant execute on function public.host_upsert_specs(uuid, jsonb) to service_role;
grant execute on function public.host_claim_requests(uuid, integer) to service_role;
grant execute on function public.host_report(uuid, uuid, text, jsonb) to service_role;
