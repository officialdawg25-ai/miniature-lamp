-- Decision records: one append-only row per instrument per evaluation, with the outcome and machine-readable reason codes.
-- "no_trade" is a legitimate, recorded outcome. Nothing here creates an order or a trade setup.
create table if not exists intelligence.decision_records (
  id uuid primary key default gen_random_uuid(),
  evaluated_at timestamptz not null default now(),
  instrument_id uuid not null references core.instruments(id),
  outcome text not null check (outcome in ('no_trade', 'watch', 'candidate')),
  reason_codes text[] not null check (cardinality(reason_codes) > 0),
  evidence jsonb not null default '{}'::jsonb,
  mode text not null default 'research' check (mode in ('research', 'backtest', 'paper', 'mt5_demo', 'restricted_live', 'autonomous'))
);
create index if not exists decision_records_instrument_time_idx on intelligence.decision_records (instrument_id, evaluated_at desc);

create trigger decision_records_no_change before update or delete on intelligence.decision_records
  for each row execute function intelligence.prevent_history_mutation();

alter table intelligence.decision_records enable row level security;
create policy decision_records_institutional_read on intelligence.decision_records
  for select to authenticated using ((select private.is_institutional_user()));
grant select on intelligence.decision_records to authenticated, service_role;

-- Evaluates each active instrument that has price data. A strategy counts as validated only once a hypothesis reaches
-- paper, restricted_live or active. No signal-evaluation engine exists yet, so even then the outcome is "watch", never "candidate".
create or replace function intelligence.generate_decision_records(p_mode text default 'research')
returns table(symbol text, outcome text, reason_codes text[])
language plpgsql security definer set search_path to 'intelligence', 'core', 'market', 'public'
as $function$
declare
  i record;
  latest timestamptz;
  age_days integer;
  validated integer;
  reasons text[];
  out_text text;
  ev jsonb;
begin
  for i in select ins.id, ins.symbol from core.instruments ins where ins.active order by ins.symbol loop
    select max(t) into latest from (
      select max(pc.ts) t from market.price_closes pc where pc.instrument_id = i.id
      union all select max(pb.ts) from market.price_bars pb where pb.instrument_id = i.id
    ) x;
    if latest is null then continue; end if;
    age_days := floor(extract(epoch from (now() - latest)) / 86400);
    select count(*) into validated from intelligence.research_hypotheses h
      where i.symbol = any(h.instruments) and h.status in ('paper', 'restricted_live', 'active');

    reasons := '{}';
    if age_days > 5 then reasons := array_append(reasons, 'stale_price_data'::text); end if;
    if validated = 0 then
      reasons := array_append(reasons, 'no_validated_strategy'::text);
      out_text := 'no_trade';
    else
      reasons := array_append(reasons, 'signal_evaluation_not_implemented'::text);
      out_text := case when age_days > 5 then 'no_trade' else 'watch' end;
    end if;

    ev := jsonb_build_object(
      'latest_price_at', latest, 'price_age_days', age_days, 'validated_strategies', validated,
      'hypotheses_by_status', (select coalesce(jsonb_object_agg(s.status, s.n), '{}'::jsonb) from (
          select h.status, count(*) n from intelligence.research_hypotheses h where i.symbol = any(h.instruments) group by h.status) s));
    insert into intelligence.decision_records(instrument_id, outcome, reason_codes, evidence, mode)
      values (i.id, out_text, reasons, ev, p_mode);
    symbol := i.symbol; outcome := out_text; reason_codes := reasons;
    return next;
  end loop;
end;
$function$;
revoke all on function intelligence.generate_decision_records(text) from public, anon, authenticated;
grant execute on function intelligence.generate_decision_records(text) to service_role;

-- Scheduled daily after the data refresh (created directly on the project; pg_cron runs as the database owner).
select cron.schedule('daily-decision-records', '30 7 * * *', 'select * from intelligence.generate_decision_records(''research'')');
