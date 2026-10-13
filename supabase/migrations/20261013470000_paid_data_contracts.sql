-- Point-in-time contracts for the paid historical data the owner is obtaining (consensus forecasts, first-print actuals and
-- market-implied policy expectations). Nothing is loaded here. Imports go through validating functions (service role only):
-- every batch is recorded, rows are insert-only, invalid rows are rejected with a reason, and a forecast or expectation is only
-- accepted with the time it was observed, which must be before the release it refers to. Surprise = first-print actual minus the
-- last consensus observed before release, so nothing that was not yet known can enter a backtest.
create table if not exists macro.data_import_batches (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  dataset text not null check (dataset in ('consensus', 'actuals', 'rate_expectations')),
  source_file text,
  licence_note text not null,
  rows_received integer not null default 0,
  rows_accepted integer not null default 0,
  rows_duplicate integer not null default 0,
  rows_rejected integer not null default 0,
  rejections jsonb not null default '[]'::jsonb,
  imported_at timestamptz not null default now()
);

create table if not exists macro.consensus_forecasts (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references macro.data_import_batches(id),
  provider text not null,
  release_key text not null,             -- e.g. US_NFP, US_CPI_YOY, EZ_HICP_FLASH (see docs/paid-data-import.md)
  period_label text not null,            -- reference period, e.g. 2026-09
  scheduled_release_at timestamptz not null,
  observed_at timestamptz not null,      -- when this consensus value was published/observed
  forecast numeric not null,
  forecast_low numeric, forecast_high numeric, contributors integer,
  unit text not null,
  imported_at timestamptz not null default now(),
  unique (provider, release_key, period_label, observed_at),
  check (observed_at < scheduled_release_at)
);

create table if not exists macro.release_actuals (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references macro.data_import_batches(id),
  provider text not null,
  release_key text not null,
  period_label text not null,
  released_at timestamptz not null,
  actual numeric not null,
  unit text not null,
  revision integer not null default 0,   -- 0 = first print as released; later revisions are separate rows
  imported_at timestamptz not null default now(),
  unique (provider, release_key, period_label, revision)
);

create table if not exists market.rate_expectations (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references macro.data_import_batches(id),
  provider text not null,
  currency text not null,                -- policy currency, e.g. USD
  instrument text not null,              -- e.g. FF futures 2026-12, SOFR OIS 1Y, meeting-dated OIS
  meeting_date date,                     -- for meeting-dated instruments
  observed_at timestamptz not null,      -- end-of-day or intraday observation time
  implied_rate numeric not null,         -- percent
  imported_at timestamptz not null default now(),
  unique (provider, instrument, observed_at)
);

do $$ declare t text; begin
  foreach t in array array['macro.data_import_batches', 'macro.consensus_forecasts', 'macro.release_actuals', 'market.rate_expectations'] loop
    execute format('alter table %s enable row level security', t);
    execute format('revoke all on %s from public, anon, authenticated', t);
    execute format('grant select on %s to service_role', t);
  end loop;
end $$;

-- Validating, insert-only import. p_rows is a JSON array of objects in the documented field names. Returns the batch summary.
create or replace function macro.import_paid_data(p_provider text, p_dataset text, p_licence_note text, p_source_file text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare b uuid; r jsonb; i integer := 0; acc integer := 0; dup integer := 0; rej jsonb := '[]'::jsonb; reason text; n integer;
begin
  if coalesce(btrim(p_provider), '') = '' or coalesce(btrim(p_licence_note), '') = '' then raise exception 'provider and licence note are required'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 50000 then raise exception 'rows must be a JSON array of at most 50000 objects'; end if;
  insert into macro.data_import_batches(provider, dataset, source_file, licence_note, rows_received) values (p_provider, p_dataset, p_source_file, p_licence_note, jsonb_array_length(p_rows)) returning id into b;
  for r in select value from jsonb_array_elements(p_rows) loop
    i := i + 1; reason := null;
    begin
      if p_dataset = 'consensus' then
        if (r->>'observed_at')::timestamptz >= (r->>'scheduled_release_at')::timestamptz then reason := 'observed_at is not before the release';
        elsif (r->>'observed_at')::timestamptz > now() then reason := 'observed_at is in the future';
        else
          insert into macro.consensus_forecasts(batch_id, provider, release_key, period_label, scheduled_release_at, observed_at, forecast, forecast_low, forecast_high, contributors, unit)
          values (b, p_provider, r->>'release_key', r->>'period_label', (r->>'scheduled_release_at')::timestamptz, (r->>'observed_at')::timestamptz, (r->>'forecast')::numeric,
                  (r->>'forecast_low')::numeric, (r->>'forecast_high')::numeric, (r->>'contributors')::integer, r->>'unit')
          on conflict do nothing;
          get diagnostics n = row_count; if n = 1 then acc := acc + 1; else dup := dup + 1; end if;
        end if;
      elsif p_dataset = 'actuals' then
        if (r->>'released_at')::timestamptz > now() then reason := 'released_at is in the future';
        else
          insert into macro.release_actuals(batch_id, provider, release_key, period_label, released_at, actual, unit, revision)
          values (b, p_provider, r->>'release_key', r->>'period_label', (r->>'released_at')::timestamptz, (r->>'actual')::numeric, r->>'unit', coalesce((r->>'revision')::integer, 0))
          on conflict do nothing;
          get diagnostics n = row_count; if n = 1 then acc := acc + 1; else dup := dup + 1; end if;
        end if;
      elsif p_dataset = 'rate_expectations' then
        if (r->>'observed_at')::timestamptz > now() then reason := 'observed_at is in the future';
        elsif (r->>'implied_rate')::numeric not between -5 and 30 then reason := 'implied_rate outside -5..30 percent';
        else
          insert into market.rate_expectations(batch_id, provider, currency, instrument, meeting_date, observed_at, implied_rate)
          values (b, p_provider, r->>'currency', r->>'instrument', (r->>'meeting_date')::date, (r->>'observed_at')::timestamptz, (r->>'implied_rate')::numeric)
          on conflict do nothing;
          get diagnostics n = row_count; if n = 1 then acc := acc + 1; else dup := dup + 1; end if;
        end if;
      else raise exception 'unknown dataset %', p_dataset;
      end if;
    exception when others then
      if sqlerrm like 'unknown dataset%' then raise; end if;
      reason := 'invalid row: ' || left(sqlerrm, 120);
    end;
    if reason is not null and jsonb_array_length(rej) < 200 then rej := rej || jsonb_build_object('row', i, 'reason', reason); end if;
  end loop;
  update macro.data_import_batches set rows_accepted = acc, rows_duplicate = dup, rows_rejected = i - acc - dup, rejections = rej where id = b;
  return jsonb_build_object('batch_id', b, 'received', i, 'accepted', acc, 'duplicate', dup, 'rejected', i - acc - dup, 'rejections', rej);
end $function$;
revoke all on function macro.import_paid_data(text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function macro.import_paid_data(text, text, text, text, jsonb) to service_role;

-- Point-in-time surprise: first print minus the last consensus observed before the release.
create or replace view macro.release_surprises with (security_invoker = true) as
select a.release_key, a.period_label, a.released_at, a.actual, c.forecast consensus, c.observed_at consensus_observed_at, a.actual - c.forecast surprise,
       a.unit, a.provider actual_provider, c.provider consensus_provider
from macro.release_actuals a
join lateral (select f.* from macro.consensus_forecasts f where f.release_key = a.release_key and f.period_label = a.period_label
              and f.observed_at < a.released_at order by f.observed_at desc limit 1) c on true
where a.revision = 0;
revoke all on macro.release_surprises from public, anon, authenticated;
grant select on macro.release_surprises to service_role;
