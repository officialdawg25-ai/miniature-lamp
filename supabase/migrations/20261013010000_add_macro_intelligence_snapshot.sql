-- One read-only snapshot for the macro pages: policy rates, yields, CFTC positioning, release calendar and latest US indicator prints.
-- Everything is read from stored, point-in-time rows; nothing is computed from data that was not yet available.
create or replace function public.get_macro_intelligence()
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare uid uuid := (select auth.uid()); result jsonb;
begin
  if uid is null or not (select private.is_institutional_user()) then raise exception 'institutional access required' using errcode = '42501'; end if;
  select jsonb_build_object(
    'generated_at', now(),
    'policy', coalesce((
      select jsonb_agg(jsonb_build_object('code', b.code, 'name', b.name, 'currency', b.currency_code, 'latest', l.rate, 'as_of', l.ts,
        'previous_rate', pr.rate, 'previous_changed_at', pr.ts,
        'change_12m', l.rate - y.rate,
        'series', (select coalesce(jsonb_agg(jsonb_build_array(m.ts, m.rate) order by m.ts), '[]'::jsonb) from (
            select distinct on (date_trunc('month', o.ts)) o.ts, o.rate from macro.policy_rate_observations o
            where o.central_bank_id = b.id and o.ts >= now() - interval '5 years' order by date_trunc('month', o.ts), o.ts desc) m)
      ) order by b.code)
      from macro.central_banks b
      left join lateral (select o.rate, o.ts from macro.policy_rate_observations o where o.central_bank_id = b.id order by o.ts desc limit 1) l on true
      left join lateral (select o.rate, o.ts from macro.policy_rate_observations o where o.central_bank_id = b.id and o.rate is distinct from l.rate order by o.ts desc limit 1) pr on true
      left join lateral (select o.rate from macro.policy_rate_observations o where o.central_bank_id = b.id and o.ts <= now() - interval '12 months' order by o.ts desc limit 1) y on true
      where b.active), '[]'::jsonb),
    'yields', coalesce((
      select jsonb_agg(jsonb_build_object('market', t.market_code, 'tenor', t.tenor_years, 'yield', t.yield, 'real_yield', t.real_yield, 'as_of', t.ts,
        'change_20', t.yield - t.prior) order by t.market_code, t.tenor_years)
      from (select distinct on (o.market_code, o.tenor_years) o.market_code, o.tenor_years, o.yield, o.real_yield, o.ts,
              (select o2.yield from market.yield_observations o2 where o2.market_code = o.market_code and o2.tenor_years = o.tenor_years and o2.ts < o.ts order by o2.ts desc offset 19 limit 1) prior
            from market.yield_observations o order by o.market_code, o.tenor_years, o.ts desc) t), '[]'::jsonb),
    'spread_10y', (select jsonb_build_object('as_of', u.ts, 'us', u.yield, 'jp', j.yield, 'diff', u.yield - j.yield,
        'series', (select coalesce(jsonb_agg(jsonb_build_array(s.ts, s.d) order by s.ts), '[]'::jsonb) from (
            select u2.ts, u2.yield - j2.yield d from market.yield_observations u2 join market.yield_observations j2 on j2.market_code = 'JP' and j2.tenor_years = 10 and j2.ts = u2.ts
            where u2.market_code = 'US' and u2.tenor_years = 10 and u2.ts >= now() - interval '2 years' and extract(isodow from u2.ts) = 3 order by u2.ts) s))
      from market.yield_observations u join market.yield_observations j on j.market_code = 'JP' and j.tenor_years = 10 and j.ts = u.ts
      where u.market_code = 'US' and u.tenor_years = 10 order by u.ts desc limit 1),
    'cot', coalesce((
      select jsonb_agg(jsonb_build_object('currency', c.currency_code, 'report_date', c.report_date, 'available_at', c.available_at, 'open_interest', c.open_interest,
        'lev_net', c.net, 'lev_net_pct_oi', round(c.net::numeric / nullif(c.open_interest, 0) * 100, 2), 'week_change', c.net - c.prev_net,
        'percentile_5y', c.pctl, 'asset_net', c.asset_net, 'dealer_net', c.dealer_net,
        'series', (select coalesce(jsonb_agg(jsonb_build_array(s.report_date, s.net) order by s.report_date), '[]'::jsonb) from (
            select o.report_date, o.lev_long - o.lev_short net from macro.cot_observations o where o.currency_code = c.currency_code and o.available_at <= now() order by o.report_date desc limit 104) s))
        order by c.currency_code)
      from (select o.*, o.lev_long - o.lev_short net, o.asset_long - o.asset_short asset_net, o.dealer_long - o.dealer_short dealer_net,
              lag(o.lev_long - o.lev_short) over (partition by o.currency_code order by o.report_date) prev_net,
              (select round(avg(case when (p.lev_long - p.lev_short) <= (o.lev_long - o.lev_short) then 1.0 else 0 end) * 100) from macro.cot_observations p
                 where p.currency_code = o.currency_code and p.report_date between o.report_date - interval '5 years' and o.report_date) pctl,
              row_number() over (partition by o.currency_code order by o.report_date desc) rn
            from macro.cot_observations o where o.available_at <= now()) c where c.rn = 1), '[]'::jsonb),
    'calendar', jsonb_build_object(
      'upcoming', coalesce((select jsonb_agg(jsonb_build_object('name', r.release_name, 'at', r.scheduled_release_time, 'period', r.period_label, 'provider', r.provider) order by r.scheduled_release_time)
        from (select * from macro.provider_release_calendars where scheduled_release_time >= now() order by scheduled_release_time limit 25) r), '[]'::jsonb),
      'recent', coalesce((select jsonb_agg(jsonb_build_object('name', r.release_name, 'at', r.scheduled_release_time, 'period', r.period_label, 'provider', r.provider) order by r.scheduled_release_time desc)
        from (select * from macro.provider_release_calendars where scheduled_release_time < now() order by scheduled_release_time desc limit 10) r), '[]'::jsonb),
      'has_consensus', false),
    'indicators', coalesce((
      select jsonb_agg(jsonb_build_object('code', i.code, 'name', i.name, 'category', i.category, 'unit', coalesce(p.unit, i.unit), 'frequency', i.frequency,
        'latest', p.value, 'period', p.period_label, 'period_end', p.observation_period_end, 'previous', p.prev_value, 'retrieved_at', p.retrieved_at) order by i.category, i.code)
      from macro.economic_indicators i
      join (select distinct on (o.indicator_id) o.indicator_id, o.value, o.unit, o.period_label, o.observation_period_end, o.retrieved_at,
              (select o2.value from macro.provider_observations o2 where o2.indicator_id = o.indicator_id and o2.observation_period_end < o.observation_period_end order by o2.observation_period_end desc, o2.observation_revision desc limit 1) prev_value
            from macro.provider_observations o order by o.indicator_id, o.observation_period_end desc, o.observation_revision desc) p on p.indicator_id = i.id), '[]'::jsonb)
  ) into result;
  return result;
end $function$;
revoke all on function public.get_macro_intelligence() from public, anon;
grant execute on function public.get_macro_intelligence() to authenticated;
