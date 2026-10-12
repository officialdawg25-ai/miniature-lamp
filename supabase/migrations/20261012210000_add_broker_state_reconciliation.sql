-- Broker-state mirror and reconciliation for the demo execution host.
-- The host reports account snapshots and closed deals; the platform stores them, flags mismatches, and (next migration) lets the risk gate
-- use real broker state: open positions, realized losses, and a fail-safe when the snapshot is stale.
create table if not exists trading.broker_snapshots (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references trading.accounts(id),
  host_id uuid not null references trading.execution_hosts(id),
  taken_at timestamptz not null default now(),
  balance numeric not null,
  equity numeric not null,
  margin_used numeric,
  free_margin numeric,
  currency text,
  position_count integer not null,
  positions jsonb not null default '[]'::jsonb,
  orders jsonb not null default '[]'::jsonb
);
create index if not exists broker_snapshots_account_time_idx on trading.broker_snapshots (account_id, taken_at desc);
alter table trading.broker_snapshots enable row level security;

create table if not exists trading.broker_deals (
  account_id uuid not null references trading.accounts(id),
  deal_ticket bigint not null,
  position_ticket bigint,
  symbol text not null,
  side text not null check (side in ('buy', 'sell')),
  entry text not null check (entry in ('in', 'out', 'inout', 'out_by')),
  volume numeric not null,
  price numeric not null,
  profit numeric not null default 0,
  commission numeric not null default 0,
  swap numeric not null default 0,
  deal_time timestamptz not null,
  comment text,
  received_at timestamptz not null default now(),
  primary key (account_id, deal_ticket)
);
create index if not exists broker_deals_account_time_idx on trading.broker_deals (account_id, deal_time desc);
alter table trading.broker_deals enable row level security;

-- Flags for one account: positions the platform did not open, positions without a stop, requests the broker never confirmed, stale state.
create or replace function trading.reconcile_account(p_account_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'trading', 'public', 'pg_catalog'
as $function$
declare
  snap trading.broker_snapshots%rowtype; flags jsonb := '[]'::jsonb; p jsonb; r record; cmt text; has_host boolean;
begin
  select exists (select 1 from trading.execution_hosts h where h.account_id = p_account_id and h.active) into has_host;
  if not has_host then return flags; end if;
  select * into snap from trading.broker_snapshots s where s.account_id = p_account_id order by s.taken_at desc limit 1;
  if not found then return jsonb_build_array(jsonb_build_object('code', 'no_broker_snapshot', 'severity', 'warning', 'detail', 'The execution host has not reported yet.')); end if;
  if snap.taken_at < now() - interval '15 minutes' then
    flags := flags || jsonb_build_array(jsonb_build_object('code', 'broker_snapshot_stale', 'severity', 'critical', 'detail', 'Last broker snapshot is older than 15 minutes; new requests are blocked.'));
  end if;
  for p in select * from jsonb_array_elements(snap.positions) loop
    cmt := coalesce(p ->> 'comment', '');
    if coalesce((p ->> 'sl')::numeric, 0) = 0 then
      flags := flags || jsonb_build_array(jsonb_build_object('code', 'position_without_stop', 'severity', 'critical', 'detail', format('Ticket %s on %s has no stop loss.', p ->> 'ticket', p ->> 'symbol')));
    end if;
    if cmt !~ '^rq[0-9a-f]{28}$' then
      flags := flags || jsonb_build_array(jsonb_build_object('code', 'manual_position', 'severity', 'warning', 'detail', format('Ticket %s on %s was not opened by the platform.', p ->> 'ticket', p ->> 'symbol')));
    elsif not exists (select 1 from trading.execution_requests er where er.account_id = p_account_id and substr(replace(er.id::text, '-', ''), 1, 28) = substr(cmt, 3)) then
      flags := flags || jsonb_build_array(jsonb_build_object('code', 'unknown_request_position', 'severity', 'critical', 'detail', format('Ticket %s carries a request tag with no matching request.', p ->> 'ticket')));
    end if;
  end loop;
  for r in
    select er.id from trading.execution_requests er
    where er.account_id = p_account_id and er.broker_dispatch_state = 'acknowledged'
      and coalesce((er.metadata -> 'broker_result' -> 'acknowledged' ->> 'dry_run')::boolean, false) = false
      and er.requested_at < now() - interval '10 minutes'
      and not exists (select 1 from jsonb_array_elements(snap.positions) pp where pp ->> 'comment' = 'rq' || substr(replace(er.id::text, '-', ''), 1, 28))
      and not exists (select 1 from jsonb_array_elements(snap.orders) oo where oo ->> 'comment' = 'rq' || substr(replace(er.id::text, '-', ''), 1, 28))
      and not exists (select 1 from trading.broker_deals d where d.account_id = p_account_id and d.comment = 'rq' || substr(replace(er.id::text, '-', ''), 1, 28))
  loop
    flags := flags || jsonb_build_array(jsonb_build_object('code', 'acknowledged_but_missing_at_broker', 'severity', 'critical', 'detail', format('Request %s was acknowledged but no position, order or deal exists at the broker.', r.id)));
  end loop;
  return flags;
end;
$function$;
revoke all on function trading.reconcile_account(uuid) from public, anon, authenticated;

-- Stores a snapshot unless it is identical to the previous one and recent (keeps the table small), and returns the reconciliation flags.
create or replace function public.host_report_snapshot(p_host_id uuid, p_snapshot jsonb)
returns jsonb
language plpgsql security definer set search_path to 'trading', 'public', 'pg_catalog'
as $function$
declare
  h trading.execution_hosts%rowtype; prev trading.broker_snapshots%rowtype; pos jsonb; ord jsonb; bal numeric; eq numeric; stored boolean := false;
begin
  select * into h from trading.execution_hosts x where x.id = p_host_id and x.active;
  if not found then raise exception 'host not active'; end if;
  bal := (p_snapshot ->> 'balance')::numeric; eq := (p_snapshot ->> 'equity')::numeric;
  pos := coalesce(p_snapshot -> 'positions', '[]'::jsonb); ord := coalesce(p_snapshot -> 'orders', '[]'::jsonb);
  if bal is null or eq is null or jsonb_typeof(pos) <> 'array' or jsonb_typeof(ord) <> 'array' or jsonb_array_length(pos) > 50 or jsonb_array_length(ord) > 50 then
    raise exception 'invalid snapshot';
  end if;
  select * into prev from trading.broker_snapshots s where s.account_id = h.account_id order by s.taken_at desc limit 1;
  if not found or prev.positions is distinct from pos or prev.orders is distinct from ord or prev.taken_at < now() - interval '5 minutes' then
    insert into trading.broker_snapshots(account_id, host_id, balance, equity, margin_used, free_margin, currency, position_count, positions, orders)
    values (h.account_id, h.id, bal, eq, (p_snapshot ->> 'margin_used')::numeric, (p_snapshot ->> 'free_margin')::numeric, left(p_snapshot ->> 'currency', 8), jsonb_array_length(pos), pos, ord);
    stored := true;
  end if;
  return jsonb_build_object('stored', stored, 'flags', trading.reconcile_account(h.account_id));
end;
$function$;

create or replace function public.host_report_deals(p_host_id uuid, p_deals jsonb)
returns integer
language plpgsql security definer set search_path to 'trading', 'public', 'pg_catalog'
as $function$
declare h trading.execution_hosts%rowtype; d jsonb; n integer := 0;
begin
  select * into h from trading.execution_hosts x where x.id = p_host_id and x.active;
  if not found then raise exception 'host not active'; end if;
  if jsonb_typeof(p_deals) <> 'array' or jsonb_array_length(p_deals) > 200 then raise exception 'deals must be an array of at most 200 items'; end if;
  for d in select * from jsonb_array_elements(p_deals) loop
    insert into trading.broker_deals(account_id, deal_ticket, position_ticket, symbol, side, entry, volume, price, profit, commission, swap, deal_time, comment)
    values (h.account_id, (d ->> 'deal_ticket')::bigint, nullif(d ->> 'position_ticket', '')::bigint, upper(d ->> 'symbol'), d ->> 'side', d ->> 'entry', (d ->> 'volume')::numeric, (d ->> 'price')::numeric,
            coalesce((d ->> 'profit')::numeric, 0), coalesce((d ->> 'commission')::numeric, 0), coalesce((d ->> 'swap')::numeric, 0), (d ->> 'deal_time')::timestamptz, left(d ->> 'comment', 40))
    on conflict (account_id, deal_ticket) do nothing;
    n := n + 1;
  end loop;
  return n;
end;
$function$;

revoke all on function public.host_report_snapshot(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.host_report_deals(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.host_report_snapshot(uuid, jsonb) to service_role;
grant execute on function public.host_report_deals(uuid, jsonb) to service_role;
