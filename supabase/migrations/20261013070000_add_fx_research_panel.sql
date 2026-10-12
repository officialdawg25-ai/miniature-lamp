-- Aligned daily panel for cross-sectional FX research: closes of the seven USD pairs and the policy rate of each of the eight banks as known on each date.
-- Dates are those on which all seven pairs have a daily close. A rate is used from the date its record became available (available_at), never earlier.
-- Service role only; called by the fx-research Edge Function.
create or replace function public.research_fx_panel()
returns jsonb language sql stable security definer set search_path to '' as $function$
  with d as (
    select b.ts::date dt,
      max(b.close) filter (where i.symbol = 'EURUSD') eurusd, max(b.close) filter (where i.symbol = 'GBPUSD') gbpusd, max(b.close) filter (where i.symbol = 'AUDUSD') audusd,
      max(b.close) filter (where i.symbol = 'NZDUSD') nzdusd, max(b.close) filter (where i.symbol = 'USDCAD') usdcad, max(b.close) filter (where i.symbol = 'USDCHF') usdchf,
      max(b.close) filter (where i.symbol = 'USDJPY') usdjpy
    from market.price_bars b join core.instruments i on i.id = b.instrument_id
    where b.timeframe = 'daily' and i.symbol in ('EURUSD', 'GBPUSD', 'AUDUSD', 'NZDUSD', 'USDCAD', 'USDCHF', 'USDJPY') group by 1
  ), full_days as (
    select * from d where eurusd is not null and gbpusd is not null and audusd is not null and nzdusd is not null and usdcad is not null and usdchf is not null and usdjpy is not null
  ), r as (
    select f.*, b.code, (select o.rate from macro.policy_rate_observations o where o.central_bank_id = b.id and o.available_at::date <= f.dt order by o.available_at desc, o.ts desc limit 1) rate
    from full_days f cross join macro.central_banks b where b.code in ('FED', 'ECB', 'BOE', 'RBA', 'RBNZ', 'BOC', 'SNB', 'BOJ')
  )
  select jsonb_build_object(
    'dates', (select jsonb_agg(dt order by dt) from full_days),
    'close', jsonb_build_object('EURUSD', (select jsonb_agg(eurusd order by dt) from full_days), 'GBPUSD', (select jsonb_agg(gbpusd order by dt) from full_days),
      'AUDUSD', (select jsonb_agg(audusd order by dt) from full_days), 'NZDUSD', (select jsonb_agg(nzdusd order by dt) from full_days),
      'USDCAD', (select jsonb_agg(usdcad order by dt) from full_days), 'USDCHF', (select jsonb_agg(usdchf order by dt) from full_days), 'USDJPY', (select jsonb_agg(usdjpy order by dt) from full_days)),
    'rate', (select jsonb_object_agg(x.code, x.s) from (select code, jsonb_agg(rate order by dt) s from r group by code) x));
$function$;
revoke all on function public.research_fx_panel() from public, anon, authenticated;
grant execute on function public.research_fx_panel() to service_role;
