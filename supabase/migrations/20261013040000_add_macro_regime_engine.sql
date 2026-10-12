-- Rules-based US macro regime (growth x inflation, with the Fed's policy phase as context). Version rules_v1.
-- Inputs come from stored provider observations. Those series are not flagged point-in-time safe, so each row says so and must never be used in a backtest.
-- No probability or confidence is invented: both stay null. The rule thresholds are written into every row so the output can be audited.
create or replace function intelligence.compute_macro_regime()
returns uuid language plpgsql set search_path to 'intelligence', 'macro', 'core', 'public', 'pg_catalog' as $function$
declare
  today timestamptz := date_trunc('day', now());
  cpi_now numeric; cpi_prev numeric; cpi_now_p timestamptz; infl_now numeric; infl_3m numeric; infl_dir text;
  un_now numeric; un_3m numeric; un_chg numeric; gdp numeric; gdp_p text; fed_now numeric; fed_6m numeric; fed_chg numeric; fed_phase text;
  growth_ok boolean; r regime_type; why text; rid uuid;
begin
  if exists (select 1 from intelligence.regime_states s where s.as_of = today) then
    select id into rid from intelligence.regime_states s where s.as_of = today limit 1; return rid;
  end if;

  with cpi as (
    select distinct on (date_trunc('month', o.observation_period_end)) date_trunc('month', o.observation_period_end) m, o.value, o.observation_period_end pe
    from macro.provider_observations o join macro.economic_indicators i on i.id = o.indicator_id
    where i.code = 'US_CPI_HEADLINE' order by date_trunc('month', o.observation_period_end), o.observation_revision desc),
  y as (select c.m, c.pe, (c.value / nullif(p.value, 0) - 1) * 100 yoy from cpi c join cpi p on p.m = c.m - interval '12 months')
  select (select yoy from y order by m desc limit 1), (select pe from y order by m desc limit 1),
         (select yoy from y where m = (select max(m) - interval '3 months' from y)) into infl_now, cpi_now_p, infl_3m;

  select value into un_now from (select distinct on (o.observation_period_end) o.value, o.observation_period_end pe from macro.provider_observations o join macro.economic_indicators i on i.id = o.indicator_id
    where i.code = 'US_UNEMPLOYMENT' order by o.observation_period_end desc, o.observation_revision desc limit 1) u;
  select value into un_3m from (select o.value from macro.provider_observations o join macro.economic_indicators i on i.id = o.indicator_id
    where i.code = 'US_UNEMPLOYMENT' and date_trunc('month', o.observation_period_end) = (select date_trunc('month', max(o2.observation_period_end)) - interval '3 months' from macro.provider_observations o2 join macro.economic_indicators i2 on i2.id = o2.indicator_id where i2.code = 'US_UNEMPLOYMENT')
    order by o.observation_revision desc limit 1) u;
  select value, period_label into gdp, gdp_p from (select o.value, o.period_label from macro.provider_observations o join macro.economic_indicators i on i.id = o.indicator_id
    where i.code = 'US_REAL_GDP_GROWTH' order by o.observation_period_end desc, o.observation_revision desc limit 1) g;

  select rate into fed_now from macro.policy_rate_observations o join macro.central_banks b on b.id = o.central_bank_id where b.code = 'FED' order by o.ts desc limit 1;
  select rate into fed_6m from macro.policy_rate_observations o join macro.central_banks b on b.id = o.central_bank_id where b.code = 'FED' and o.ts <= now() - interval '6 months' order by o.ts desc limit 1;
  fed_chg := fed_now - fed_6m;
  fed_phase := case when fed_chg is null then 'unknown' when fed_chg >= 0.25 then 'tightening' when fed_chg <= -0.25 then 'easing' else 'on_hold' end;

  un_chg := un_now - un_3m;
  infl_dir := case when infl_now is null or infl_3m is null then null when infl_now - infl_3m > 0.1 then 'rising' when infl_now - infl_3m < -0.1 then 'falling' else 'flat' end;

  if gdp is null or un_chg is null or infl_dir is null then
    r := 'unknown'; why := 'a required input is missing';
  else
    growth_ok := gdp > 0 and un_chg < 0.3;
    if gdp < 0 and un_chg >= 0.5 then r := 'recession'; why := 'GDP growth negative and unemployment up 0.5pp or more over 3 months';
    elsif infl_dir = 'flat' then
      r := case fed_phase when 'tightening' then 'monetary_tightening' when 'easing' then 'monetary_easing' else 'transition' end;
      why := 'inflation trend flat, so the Fed policy phase decides';
    elsif growth_ok and infl_dir = 'rising' then r := 'growth_inflation'; why := 'growth intact and inflation rising';
    elsif growth_ok and infl_dir = 'falling' then r := 'growth_disinflation'; why := 'growth intact and inflation falling';
    elsif not growth_ok and infl_dir = 'rising' then r := 'stagflation'; why := 'growth weak and inflation rising';
    else r := 'deflationary_slowdown'; why := 'growth weak and inflation falling';
    end if;
  end if;

  insert into intelligence.regime_states(as_of, regime, probability, confidence, model_version_id, feature_snapshot)
  values (today, r, null, null, null, jsonb_build_object(
    'method', 'rules_v1', 'region', 'US', 'reason', why, 'point_in_time_safe', false,
    'note', 'Classification of the latest stored values; not valid for backtesting because the source series are not point-in-time flagged.',
    'thresholds', jsonb_build_object('inflation_trend_pp', 0.1, 'unemployment_rise_pp', 0.3, 'recession_unemployment_pp', 0.5, 'fed_phase_pp_6m', 0.25),
    'inputs', jsonb_build_object('cpi_yoy_now', round(infl_now, 3), 'cpi_yoy_3m_ago', round(infl_3m, 3), 'cpi_latest_period', cpi_now_p, 'inflation_direction', infl_dir,
      'unemployment_now', un_now, 'unemployment_3m_ago', un_3m, 'unemployment_change_3m', un_chg, 'real_gdp_growth', gdp, 'gdp_period', gdp_p,
      'fed_rate', fed_now, 'fed_change_6m', fed_chg, 'fed_phase', fed_phase)))
  returning id into rid;
  return rid;
end $function$;
revoke all on function intelligence.compute_macro_regime() from public, anon, authenticated;

create or replace function public.get_regime_state()
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid());
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  return jsonb_build_object('generated_at', now(),
    'latest', (select to_jsonb(s) - 'model_version_id' - 'created_at' from intelligence.regime_states s order by s.as_of desc limit 1),
    'history', coalesce((select jsonb_agg(jsonb_build_object('as_of', h.as_of, 'regime', h.regime) order by h.as_of desc) from (select * from intelligence.regime_states order by as_of desc limit 30) h), '[]'::jsonb));
end $function$;
revoke all on function public.get_regime_state() from public, anon;
grant execute on function public.get_regime_state() to authenticated;

select cron.schedule('daily-macro-regime', '40 7 * * *', $job$ select intelligence.compute_macro_regime(); $job$);
