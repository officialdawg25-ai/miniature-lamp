-- Broker contract specifications, as reported by the broker terminal (MT5 symbol_info), one row per account and symbol.
-- Nothing is assumed: until a row is synced from the terminal, position sizing for that symbol returns no size.
-- All money values (tick value, equity) must be in the same unit the terminal reports. On a cent account that unit is cents.
create table if not exists trading.broker_symbol_specs (
  account_id uuid not null references trading.accounts(id),
  symbol text not null,
  contract_size numeric not null check (contract_size > 0),
  tick_size numeric not null check (tick_size > 0),
  tick_value numeric not null check (tick_value > 0),
  volume_min numeric not null check (volume_min > 0),
  volume_step numeric not null check (volume_step > 0),
  volume_max numeric not null check (volume_max >= volume_min),
  account_currency text not null,
  source text not null default 'mt5_symbol_info',
  observed_at timestamptz not null default now(),
  primary key (account_id, symbol)
);
alter table trading.broker_symbol_specs enable row level security;
grant select on trading.broker_symbol_specs to authenticated;
create policy broker_symbol_specs_member_read on trading.broker_symbol_specs for select to authenticated
  using (exists (select 1 from trading.account_members m where m.account_id = broker_symbol_specs.account_id and m.user_id = (select auth.uid()) and m.active));

-- Size a position from a fixed fraction of equity at risk and the stop distance.
-- Returns volume null with a reason when the minimum lot already risks more than the budget; it never rounds up past the budget.
create or replace function trading.size_position(
  p_equity numeric, p_risk_fraction numeric, p_entry numeric, p_stop numeric,
  p_tick_size numeric, p_tick_value numeric, p_volume_min numeric, p_volume_step numeric, p_volume_max numeric
)
returns table(volume numeric, risk_amount numeric, risk_fraction_used numeric, reason text)
language plpgsql immutable set search_path to ''
as $function$
declare
  budget numeric; per_lot numeric; raw numeric; v numeric;
begin
  if p_equity is null or p_equity <= 0 or p_risk_fraction is null or p_risk_fraction <= 0 or p_risk_fraction > 0.05
     or p_entry is null or p_stop is null or p_entry = p_stop or p_tick_size is null or p_tick_size <= 0
     or p_tick_value is null or p_tick_value <= 0 or p_volume_min is null or p_volume_min <= 0
     or p_volume_step is null or p_volume_step <= 0 or p_volume_max is null or p_volume_max < p_volume_min then
    return query select null::numeric, null::numeric, null::numeric, 'invalid_input'::text; return;
  end if;
  budget := p_equity * p_risk_fraction;
  per_lot := abs(p_entry - p_stop) / p_tick_size * p_tick_value;
  raw := budget / per_lot;
  v := floor(raw / p_volume_step) * p_volume_step;
  if v < p_volume_min then
    return query select null::numeric, p_volume_min * per_lot, p_volume_min * per_lot / p_equity, 'minimum_lot_risk_exceeds_budget'::text; return;
  end if;
  v := least(v, p_volume_max);
  return query select v, v * per_lot, v * per_lot / p_equity, 'ok'::text;
end;
$function$;
revoke all on function trading.size_position(numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric) from public, anon, authenticated;
grant execute on function trading.size_position(numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric) to service_role;
