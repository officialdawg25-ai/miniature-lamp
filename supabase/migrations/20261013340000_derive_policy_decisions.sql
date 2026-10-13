-- Central-bank decision history derived deterministically from the stored policy-rate series (no model, no inference).
-- Fed: one row per scheduled FOMC meeting (hold or change, from macro.fomc_meetings) plus unscheduled changes.
-- ECB, BoE, RBA, RBNZ, BoC, SNB: rate changes only (holds need meeting calendars that are not stored yet).
-- BoJ is excluded: its stored series is the overnight call rate (a market rate), not the policy target.
-- Timing honesty: non-Fed rows know only the effective date, so decision_time is set to that date and flagged
-- 'effective_date_only'; research must use raw_payload.available_at, never decision_time, as the knowable time.
create unique index if not exists policy_decisions_derivation_key on macro.policy_decisions ((raw_payload ->> 'derivation_key')) where raw_payload ? 'derivation_key';

create or replace function macro.derive_policy_decisions()
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare fed_n integer := 0; other_n integer := 0; unsched_n integer := 0;
begin
  -- Fed scheduled meetings: rates in force on the statement day versus the next stored day.
  with fed as (select o.central_bank_id, o.source_id, o.ts::date d, o.rate up, o.rate_lower lo, o.available_at
               from macro.policy_rate_observations o join macro.central_banks b on b.id = o.central_bank_id where b.code = 'FED'),
  m as (select f.central_bank_id, f.source_id, mt.statement_date, f.up prev_up, f.lo prev_lo,
               n.up new_up, n.lo new_lo, n.d new_d, n.available_at
        from macro.fomc_meetings mt
        join fed f on f.d = (select max(x.d) from fed x where x.d <= mt.statement_date)
        join fed n on n.d = (select min(x.d) from fed x where x.d > mt.statement_date)
        where mt.statement_date > (select min(d) from fed)),
  ins as (insert into macro.policy_decisions(central_bank_id, source_id, decision_time, effective_time, previous_rate, new_rate, meeting_date, decision_type, source_document_url, raw_payload)
    select m.central_bank_id, m.source_id, (m.statement_date + time '14:00') at time zone 'America/New_York', m.new_d::timestamptz, m.prev_up, m.new_up, m.statement_date,
           case when m.new_up > m.prev_up then 'hike' when m.new_up < m.prev_up then 'cut' else 'hold' end,
           'https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm',
           jsonb_build_object('derivation_key', 'FED:meeting:' || m.statement_date, 'method', 'derived_from_policy_rate_series', 'series', 'DFEDTARU/DFEDTARL',
             'previous_range', jsonb_build_array(m.prev_lo, m.prev_up), 'new_range', jsonb_build_array(m.new_lo, m.new_up),
             'time_precision', 'approximate: scheduled statement day; release time taken as 14:00 New York (it was 12:30 to 14:15 in parts of 2011-2013)',
             'available_at', m.available_at, 'statement_text', 'not stored')
    from m on conflict do nothing returning 1)
  select count(*) into fed_n from ins;

  -- Fed changes that did not happen on a scheduled meeting (emergency actions).
  with fed as (select o.central_bank_id, o.source_id, o.ts::date d, o.rate up, o.rate_lower lo, o.available_at,
                      lag(o.rate) over (order by o.ts) pu, lag(o.rate_lower) over (order by o.ts) pl
               from macro.policy_rate_observations o join macro.central_banks b on b.id = o.central_bank_id where b.code = 'FED'),
  ins as (insert into macro.policy_decisions(central_bank_id, source_id, decision_time, effective_time, previous_rate, new_rate, decision_type, raw_payload)
    select f.central_bank_id, f.source_id, f.d::timestamptz, f.d::timestamptz, f.pu, f.up, 'unscheduled_' || case when f.up > f.pu then 'hike' else 'cut' end,
           jsonb_build_object('derivation_key', 'FED:unscheduled:' || f.d, 'method', 'derived_from_policy_rate_series', 'series', 'DFEDTARU/DFEDTARL',
             'previous_range', jsonb_build_array(f.pl, f.pu), 'new_range', jsonb_build_array(f.lo, f.up),
             'time_precision', 'effective_date_only', 'available_at', f.available_at)
    from fed f where f.pu is not null and f.up <> f.pu
      and not exists (select 1 from macro.fomc_meetings mt where mt.statement_date between f.d - 3 and f.d - 1)
    on conflict do nothing returning 1)
  select count(*) into unsched_n from ins;

  -- Other banks: every change in the stored policy-rate series.
  with s as (select b.code, o.central_bank_id, o.source_id, o.ts::date d, o.rate, o.available_at, o.metadata ->> 'series_id' series,
                    lag(o.rate) over (partition by o.central_bank_id order by o.ts) pr
             from macro.policy_rate_observations o join macro.central_banks b on b.id = o.central_bank_id
             where b.code in ('ECB', 'BOE', 'RBA', 'RBNZ', 'BOC', 'SNB')),
  ins as (insert into macro.policy_decisions(central_bank_id, source_id, decision_time, effective_time, previous_rate, new_rate, decision_type, raw_payload)
    select s.central_bank_id, s.source_id, s.d::timestamptz, s.d::timestamptz, s.pr, s.rate, case when s.rate > s.pr then 'hike' else 'cut' end,
           jsonb_build_object('derivation_key', s.code || ':change:' || s.d, 'method', 'derived_from_policy_rate_series', 'series', s.series,
             'time_precision', 'effective_date_only (announcement time not stored; usually on or before the effective date)',
             'available_at', s.available_at, 'holds_recorded', false)
    from s where s.pr is not null and s.rate <> s.pr
    on conflict do nothing returning 1)
  select count(*) into other_n from ins;

  return jsonb_build_object('fed_meetings_inserted', fed_n, 'fed_unscheduled_inserted', unsched_n, 'other_changes_inserted', other_n);
end $function$;
revoke all on function macro.derive_policy_decisions() from public, anon, authenticated;

-- Re-derive daily after the policy-rate refreshes (07:20 UTC); idempotent through the derivation key.
select cron.schedule('daily-derive-policy-decisions', '50 7 * * *', $job$ select macro.derive_policy_decisions(); $job$);
