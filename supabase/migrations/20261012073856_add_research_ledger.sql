-- P1 research governance. Every hypothesis is registered before it is tested; its lifecycle status can only move one step forward (or to
-- suspended/retired), every change is logged in an append-only history with the reason and the quality of the evidence, and null results
-- are kept. Backtest results stay in intelligence.backtest_runs, which gains a link to the hypothesis (no second results table).

create table intelligence.research_hypotheses (
  id uuid primary key default gen_random_uuid(),
  key text not null unique check (key ~ '^[a-z0-9][a-z0-9-]{2,80}$'),
  title text not null,
  rationale text not null,
  instruments text[] not null,
  horizon text,
  specification jsonb not null default '{}'::jsonb,
  data_requirements jsonb not null default '{}'::jsonb,
  status text not null default 'research_hypothesis' check (status in (
    'research_hypothesis','data_ready','candidate_implemented','backtest_completed','oos_validated','robustness_done',
    'paper','restricted_live','active','suspended','retired')),
  status_changed_at timestamptz not null default now(),
  preregistered_at timestamptz not null default now(),
  created_by uuid,
  created_at timestamptz not null default now()
);

create table intelligence.hypothesis_status_history (
  id uuid primary key default gen_random_uuid(),
  hypothesis_id uuid not null references intelligence.research_hypotheses(id),
  from_status text,
  to_status text not null,
  reason text not null,
  evidence jsonb not null default '{}'::jsonb,
  evidence_quality text not null default 'recorded' check (evidence_quality in ('full_result_stored','verdict_only','recorded')),
  changed_by uuid,
  changed_at timestamptz not null default now()
);
create index hypothesis_status_history_hypothesis_idx on intelligence.hypothesis_status_history (hypothesis_id, changed_at);

alter table intelligence.backtest_runs add column hypothesis_id uuid references intelligence.research_hypotheses(id);

create or replace function intelligence.prevent_history_mutation()
returns trigger language plpgsql set search_path to '' as $$
begin
  raise exception 'hypothesis_status_history is append-only';
end;
$$;
create trigger hypothesis_status_history_no_change before update or delete on intelligence.hypothesis_status_history
  for each row execute function intelligence.prevent_history_mutation();

alter table intelligence.research_hypotheses enable row level security;
alter table intelligence.hypothesis_status_history enable row level security;
grant select on intelligence.research_hypotheses to service_role;
grant select on intelligence.hypothesis_status_history to service_role;

-- The only way to change a status. A status may move one step forward along the lifecycle, or to suspended or retired from any state;
-- a retired hypothesis is terminal. Skipping stages (for example straight to paper or live) is refused.
create or replace function intelligence.set_hypothesis_status(
  p_key text, p_to text, p_reason text, p_evidence jsonb default '{}'::jsonb, p_quality text default 'recorded', p_actor uuid default null
) returns jsonb
language plpgsql security definer set search_path to ''
as $function$
declare
  h intelligence.research_hypotheses%rowtype;
  stages text[] := array['research_hypothesis','data_ready','candidate_implemented','backtest_completed','oos_validated','robustness_done','paper','restricted_live','active'];
  i_from int; i_to int;
begin
  if p_reason is null or length(btrim(p_reason)) < 10 then raise exception 'a reason of at least 10 characters is required'; end if;
  select * into h from intelligence.research_hypotheses where key = p_key for update;
  if not found then raise exception 'hypothesis not found: %', p_key; end if;
  if h.status = 'retired' then raise exception 'a retired hypothesis cannot change status'; end if;
  if p_to not in ('research_hypothesis','data_ready','candidate_implemented','backtest_completed','oos_validated','robustness_done','paper','restricted_live','active','suspended','retired') then
    raise exception 'unknown status: %', p_to;
  end if;
  if p_to = h.status then raise exception 'hypothesis is already %', p_to; end if;
  if p_to not in ('suspended','retired') then
    i_to := array_position(stages, p_to);
    if h.status = 'suspended' then
      -- resuming is allowed only to a stage already reached before the suspension
      if not exists (select 1 from intelligence.hypothesis_status_history x where x.hypothesis_id = h.id and x.to_status = p_to) then
        raise exception 'cannot resume at a stage that was never reached: %', p_to;
      end if;
    else
      i_from := array_position(stages, h.status);
      if i_to is null or i_to > i_from + 1 or i_to < i_from then
        raise exception 'illegal status step % -> % (one step forward at a time)', h.status, p_to;
      end if;
    end if;
  end if;
  update intelligence.research_hypotheses set status = p_to, status_changed_at = now() where id = h.id;
  insert into intelligence.hypothesis_status_history(hypothesis_id, from_status, to_status, reason, evidence, evidence_quality, changed_by)
  values (h.id, h.status, p_to, p_reason, coalesce(p_evidence, '{}'::jsonb), p_quality, p_actor);
  return jsonb_build_object('key', p_key, 'from', h.status, 'to', p_to);
end;
$function$;
revoke all on function intelligence.set_hypothesis_status(text, text, text, jsonb, text, uuid) from public, anon, authenticated;
grant execute on function intelligence.set_hypothesis_status(text, text, text, jsonb, text, uuid) to service_role;

-- Registration goes through a function as well, so a hypothesis always starts at the first stage with a history row.
create or replace function intelligence.register_hypothesis(
  p_key text, p_title text, p_rationale text, p_instruments text[], p_horizon text, p_specification jsonb, p_data_requirements jsonb, p_actor uuid default null
) returns uuid
language plpgsql security definer set search_path to ''
as $function$
declare v_id uuid;
begin
  if p_rationale is null or length(btrim(p_rationale)) < 30 then raise exception 'an economic rationale of at least 30 characters is required'; end if;
  insert into intelligence.research_hypotheses(key, title, rationale, instruments, horizon, specification, data_requirements, created_by)
  values (p_key, p_title, p_rationale, p_instruments, p_horizon, coalesce(p_specification, '{}'::jsonb), coalesce(p_data_requirements, '{}'::jsonb), p_actor)
  returning id into v_id;
  insert into intelligence.hypothesis_status_history(hypothesis_id, from_status, to_status, reason, changed_by)
  values (v_id, null, 'research_hypothesis', 'Registered before testing, with its specification and data requirements.', p_actor);
  return v_id;
end;
$function$;
revoke all on function intelligence.register_hypothesis(text, text, text, text[], text, jsonb, jsonb, uuid) from public, anon, authenticated;
grant execute on function intelligence.register_hypothesis(text, text, text, text[], text, jsonb, jsonb, uuid) to service_role;

-- ---- Seed: the three rate-signal hypotheses already tested, recorded honestly --------------------------------------------------
-- Evidence quality is "verdict_only": the verdict boxes were reported by the owner and the full results were never stored. Which of the two
-- USDJPY long-window boxes belongs to which signal is inferred from the order in which they were pasted (yield differential, then policy rate).
select intelligence.register_hypothesis('usdjpy-yield-differential-rules',
  'USDJPY: US-Japan 10Y yield differential level and change rules, plus price momentum',
  'The interest-rate differential between the US and Japan is a standard macro driver of USDJPY. Nine pre-specified rules (differential level z-score over 63/126/252 days, differential change over 5/20/60 days, price momentum over 20/60/120 days) were selected walk-forward.',
  array['USDJPY'], 'daily, walk-forward with a 252-day untouched holdout',
  '{"rules":9,"signal":"us_jp_10y_differential","costs_bp":1,"carry_proxy":"US2Y-JP2Y"}'::jsonb,
  '{"datasets":["market.price_bars USDJPY","market.yield_observations US and JP 2Y/10Y"],"ready":true}'::jsonb);
select intelligence.set_hypothesis_status('usdjpy-yield-differential-rules','data_ready','US and Japan yields loaded and checked from 2008 to 2026.');
select intelligence.set_hypothesis_status('usdjpy-yield-differential-rules','candidate_implemented','Walk-forward harness with nine pre-specified rules implemented in backtest-runner.');
select intelligence.set_hypothesis_status('usdjpy-yield-differential-rules','backtest_completed','Walk-forward runs on two windows both returned no evidence of an edge.',
  '{"windows":[{"start":"2021-01-01","oos_days":748},{"start":"2008-01-01","oos_days":4140}],"verdict":"no_evidence","failed_checks":["sharpe_ci_includes_zero","timing_shift_not_rejected","deflated_sharpe_below_0.95","does_not_beat_buy_and_hold"],"holdout":"passed","source":"verdict boxes reported by the owner; full results were not stored","long_window_attribution":"inferred from paste order"}'::jsonb, 'verdict_only');
select intelligence.set_hypothesis_status('usdjpy-yield-differential-rules','retired','No evidence on a 16-year out-of-sample window; adding more rules of this type only increases the multiple-testing burden.',
  '{"decision":"retire","can_be_reopened_by":"a new pre-registered hypothesis with a different mechanism"}'::jsonb, 'verdict_only');

select intelligence.register_hypothesis('xauusd-real-yield-rules',
  'XAUUSD: US 10Y real yield level and change rules, plus price momentum',
  'Gold pays no yield, so a rising real yield raises its opportunity cost. The direction (higher real yield favours short gold) was fixed in advance and not fitted. The same nine-rule structure was used.',
  array['XAUUSD'], 'daily, weekdays only, walk-forward with a 252-day untouched holdout',
  '{"rules":9,"signal":"us_10y_real_yield","signal_sign":-1,"costs_bp":2}'::jsonb,
  '{"datasets":["market.price_closes XAUUSD","market.yield_observations US 10Y real_yield"],"ready":true,"known_issue":"gold series changes construction on 2013-03-27"}'::jsonb);
select intelligence.set_hypothesis_status('xauusd-real-yield-rules','data_ready','Gold closes and US real yields available; the 2013-03-27 construction change was identified and flagged.');
select intelligence.set_hypothesis_status('xauusd-real-yield-rules','candidate_implemented','Gold branch added to backtest-runner with a fixed negative signal sign.');
select intelligence.set_hypothesis_status('xauusd-real-yield-rules','backtest_completed','Walk-forward runs on two windows both returned no evidence of an edge.',
  '{"windows":[{"start":"2021-01-01","oos_days":748},{"start":"2015-01-01","oos_days":2314}],"verdict":"no_evidence","failed_checks":["sharpe_ci_includes_zero","timing_shift_not_rejected","deflated_sharpe_below_0.95","does_not_beat_buy_and_hold"],"holdout":"passed","source":"verdict boxes reported by the owner; full results were not stored"}'::jsonb, 'verdict_only');
select intelligence.set_hypothesis_status('xauusd-real-yield-rules','retired','No evidence on a 9-year out-of-sample window on a single-construction gold series.',
  '{"decision":"retire"}'::jsonb, 'verdict_only');

select intelligence.register_hypothesis('usdjpy-policy-rate-differential-rules',
  'USDJPY: Fed target minus Bank of Japan overnight call rate level and change rules, plus price momentum',
  'Divergence between Federal Reserve and Bank of Japan policy is a core macro driver of USDJPY. The same nine-rule structure was applied to the policy-rate differential. Policy rates move in few steps, so the number of independent events is small.',
  array['USDJPY'], 'daily, walk-forward with a 252-day untouched holdout',
  '{"rules":9,"signal":"fed_upper_minus_boj_call_rate","max_age_days":{"fed":14,"boj":10}}'::jsonb,
  '{"datasets":["macro.policy_rate_observations FED and BOJ"],"ready":true,"known_issue":"BoJ figure is the overnight call rate, a market rate that tracks the policy rate"}'::jsonb);
select intelligence.set_hypothesis_status('usdjpy-policy-rate-differential-rules','data_ready','Fed and BoJ rates loaded from 2008 with availability times and checked.');
select intelligence.set_hypothesis_status('usdjpy-policy-rate-differential-rules','candidate_implemented','Policy-rate differential signal added to backtest-runner with a maximum-age rule.');
select intelligence.set_hypothesis_status('usdjpy-policy-rate-differential-rules','backtest_completed','Walk-forward runs on two windows both returned no evidence of an edge.',
  '{"windows":[{"start":"2021-01-01","oos_days":748,"attribution":"inferred from paste order"},{"start":"2008-01-01","oos_days":4140,"attribution":"inferred from paste order"}],"verdict":"no_evidence","failed_checks":["sharpe_ci_includes_zero","timing_shift_not_rejected","deflated_sharpe_below_0.95","does_not_beat_buy_and_hold"],"holdout":"passed","source":"verdict boxes reported by the owner; full results were not stored"}'::jsonb, 'verdict_only');
select intelligence.set_hypothesis_status('usdjpy-policy-rate-differential-rules','retired','No evidence on a 16-year out-of-sample window; few independent policy changes limit what the signal can show.',
  '{"decision":"retire"}'::jsonb, 'verdict_only');

-- ---- Seed: new pre-registered hypotheses (specification frozen before any run) ---------------------------------------------------
select intelligence.register_hypothesis('fx-g8-cross-sectional-momentum',
  'G8 currencies: cross-sectional 12-1 month momentum against the US dollar',
  'Currencies that outperformed over the past year tend to keep outperforming relative to losers over the next month (documented cross-sectional FX momentum). A single fixed specification avoids the multiple-testing problem of tuning rules: rank the seven non-USD currencies by return over months t-12 to t-1 (skipping the latest month), go long the top three and short the bottom three against USD, equal weight, rebalance monthly, 2 bp cost per leg.',
  array['EURUSD','GBPUSD','AUDUSD','NZDUSD','USDCAD','USDCHF','USDJPY'], 'monthly rebalance',
  '{"lookback_months":12,"skip_months":1,"long":3,"short":3,"weights":"equal","rebalance":"monthly","cost_bp_per_leg":2,"parameters_tuned":false,"frozen_on":"2026-10-12","primary_test":"net Sharpe of the long-short portfolio with block-bootstrap CI and comparison to a zero-signal benchmark; no parameter search"}'::jsonb,
  '{"datasets":["market.price_bars for the seven USD pairs, daily from 2007-08"],"ready":true,"checks_pending":"gap and bad-print checks for the six pairs other than USDJPY"}'::jsonb);
select intelligence.set_hypothesis_status('fx-g8-cross-sectional-momentum','data_ready','Bar counts verified for the seven USD pairs (4,999 to 5,000 daily bars from 2007-08 to 2026-10-08); gap checks still pending.',
  '{"bars":{"AUDUSD":5000,"EURUSD":5000,"GBPUSD":5000,"NZDUSD":4999,"USDCAD":5000,"USDCHF":5000,"USDJPY":5000}}'::jsonb, 'recorded');

select intelligence.register_hypothesis('fx-g8-cross-sectional-carry',
  'G8 currencies: cross-sectional carry (long high policy rate, short low policy rate)',
  'Currencies with high short-term interest rates have historically earned a premium over low-rate currencies, compensating for crash risk. Ranking the eight currencies by policy rate and holding the top against the bottom isolates this effect from single-pair noise. The specification will be frozen before the first run.',
  array['EURUSD','GBPUSD','AUDUSD','NZDUSD','USDCAD','USDCHF','USDJPY'], 'monthly rebalance',
  '{"ranking":"policy rate known at the rebalance date","long":3,"short":3,"parameters_tuned":false}'::jsonb,
  '{"datasets":["macro.policy_rate_observations for FED, BOJ, ECB, BOE, RBA, RBNZ, BOC, SNB"],"ready":false,"missing":["ECB","BOE","RBA","RBNZ","BOC","SNB"]}'::jsonb);
