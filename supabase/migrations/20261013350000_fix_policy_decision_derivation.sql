-- Fixes to macro.derive_policy_decisions found by checking its first output:
-- 1) the Fed range sometimes changes on the statement day itself (2015-12-16, 2016-12-14), so a meeting compares the day
--    before the statement with the day after it, and a change on the statement day counts as scheduled;
-- 2) the BIS RBA series carries market-rate noise in 2008 (7 -> 6.9997 -> 7), so changes are detected on rates rounded to
--    0.01 (no policy move has been smaller than 0.05).
-- Rows the corrected derivation no longer produces are kept and marked superseded (decision_type 'superseded'), not deleted.
create or replace function macro.derive_policy_decisions()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare upserted integer := 0; superseded integer := 0;
begin
  create temp table if not exists _derived_decisions (like macro.policy_decisions including defaults) on commit drop;
  -- Fed scheduled meetings
  insert into _derived_decisions(central_bank_id, source_id, decision_time, effective_time, previous_rate, new_rate, meeting_date, decision_type, source_document_url, raw_payload)
  with fed as (select o.central_bank_id, o.source_id, o.ts::date d, o.rate up, o.rate_lower lo, o.available_at
               from macro.policy_rate_observations o join macro.central_banks b on b.id = o.central_bank_id where b.code = 'FED'),
  m as (select p.central_bank_id, p.source_id, mt.statement_date, p.up prev_up, p.lo prev_lo, n.up new_up, n.lo new_lo, n.d new_d, n.available_at,
               (select min(x.d) from fed x where x.d >= mt.statement_date and x.up <> p.up) change_d
        from macro.fomc_meetings mt
        join fed p on p.d = (select max(x.d) from fed x where x.d < mt.statement_date)
        join fed n on n.d = (select min(x.d) from fed x where x.d > mt.statement_date))
  select m.central_bank_id, m.source_id, (m.statement_date + time '14:00') at time zone 'America/New_York',
         case when m.new_up <> m.prev_up then m.change_d::timestamptz end, m.prev_up, m.new_up, m.statement_date,
         case when m.new_up > m.prev_up then 'hike' when m.new_up < m.prev_up then 'cut' else 'hold' end,
         'https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm',
         jsonb_build_object('derivation_key', 'FED:meeting:' || m.statement_date, 'method', 'derived_from_policy_rate_series', 'method_version', 2,
           'series', 'DFEDTARU/DFEDTARL', 'previous_range', jsonb_build_array(m.prev_lo, m.prev_up), 'new_range', jsonb_build_array(m.new_lo, m.new_up),
           'time_precision', 'approximate: scheduled statement day; release time taken as 14:00 New York (it was 12:30 to 14:15 in parts of 2011-2013)',
           'available_at', m.available_at, 'statement_text', 'not stored')
  from m;
  -- Fed changes on no scheduled statement day or the day after (emergency actions)
  insert into _derived_decisions(central_bank_id, source_id, decision_time, effective_time, previous_rate, new_rate, decision_type, raw_payload)
  with fed as (select o.central_bank_id, o.source_id, o.ts::date d, o.rate up, o.rate_lower lo, o.available_at,
                      lag(o.rate) over (order by o.ts) pu, lag(o.rate_lower) over (order by o.ts) pl
               from macro.policy_rate_observations o join macro.central_banks b on b.id = o.central_bank_id where b.code = 'FED')
  select f.central_bank_id, f.source_id, f.d::timestamptz, f.d::timestamptz, f.pu, f.up, 'unscheduled_' || case when f.up > f.pu then 'hike' else 'cut' end,
         jsonb_build_object('derivation_key', 'FED:unscheduled:' || f.d, 'method', 'derived_from_policy_rate_series', 'method_version', 2, 'series', 'DFEDTARU/DFEDTARL',
           'previous_range', jsonb_build_array(f.pl, f.pu), 'new_range', jsonb_build_array(f.lo, f.up), 'time_precision', 'effective_date_only', 'available_at', f.available_at)
  from fed f where f.pu is not null and f.up <> f.pu
    and not exists (select 1 from macro.fomc_meetings mt where mt.statement_date between f.d - 3 and f.d);
  -- Other banks: changes in the rate rounded to 0.01
  insert into _derived_decisions(central_bank_id, source_id, decision_time, effective_time, previous_rate, new_rate, decision_type, raw_payload)
  with s as (select b.code, o.central_bank_id, o.source_id, o.ts::date d, round(o.rate, 2) r, o.available_at, o.metadata ->> 'series_id' series,
                    lag(round(o.rate, 2)) over (partition by o.central_bank_id order by o.ts) pr
             from macro.policy_rate_observations o join macro.central_banks b on b.id = o.central_bank_id
             where b.code in ('ECB', 'BOE', 'RBA', 'RBNZ', 'BOC', 'SNB'))
  select s.central_bank_id, s.source_id, s.d::timestamptz, s.d::timestamptz, s.pr, s.r, case when s.r > s.pr then 'hike' else 'cut' end,
         jsonb_build_object('derivation_key', s.code || ':change:' || s.d, 'method', 'derived_from_policy_rate_series', 'method_version', 2, 'series', s.series,
           'time_precision', 'effective_date_only (announcement time not stored; usually on or before the effective date)',
           'available_at', s.available_at, 'holds_recorded', false, 'rounding', '0.01')
  from s where s.pr is not null and s.r <> s.pr;

  with up as (
    insert into macro.policy_decisions as t (central_bank_id, source_id, decision_time, effective_time, previous_rate, new_rate, meeting_date, decision_type, source_document_url, raw_payload)
    select central_bank_id, source_id, decision_time, effective_time, previous_rate, new_rate, meeting_date, decision_type, source_document_url, raw_payload from _derived_decisions
    on conflict ((raw_payload ->> 'derivation_key')) where raw_payload ? 'derivation_key'
    do update set decision_time = excluded.decision_time, effective_time = excluded.effective_time, previous_rate = excluded.previous_rate, new_rate = excluded.new_rate,
                  meeting_date = excluded.meeting_date, decision_type = excluded.decision_type, raw_payload = excluded.raw_payload
    where (t.raw_payload ->> 'method') = 'derived_from_policy_rate_series' and (t.decision_type, t.previous_rate, t.new_rate, t.effective_time) is distinct from (excluded.decision_type, excluded.previous_rate, excluded.new_rate, excluded.effective_time)
    returning 1)
  select count(*) into upserted from up;

  with sup as (
    update macro.policy_decisions t set decision_type = 'superseded',
      raw_payload = t.raw_payload || jsonb_build_object('superseded_at', now(), 'superseded_reason', 'not produced by the corrected derivation (method_version 2)')
    where (t.raw_payload ->> 'method') = 'derived_from_policy_rate_series' and t.decision_type <> 'superseded'
      and not exists (select 1 from _derived_decisions d where (d.raw_payload ->> 'derivation_key') = (t.raw_payload ->> 'derivation_key'))
    returning 1)
  select count(*) into superseded from sup;

  return jsonb_build_object('derived', (select count(*) from _derived_decisions), 'inserted_or_corrected', upserted, 'marked_superseded', superseded);
end $function$;
revoke all on function macro.derive_policy_decisions() from public, anon, authenticated;
