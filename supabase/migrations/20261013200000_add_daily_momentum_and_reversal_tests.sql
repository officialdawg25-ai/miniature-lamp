-- Batch 6: gold time-series momentum and FX large-move reversal on daily bars; rules frozen in the ledger before this runner existed.
-- Data handling fixed before any result: gold weekday bars only (weekend quotes from 2024 on are not tradable at the broker) and only bars whose day had ended when retrieved.
create or replace function intelligence.gold_daily_tsmom_days()
returns table(trade_date date, pos integer, close_t numeric, close_next numeric, gross numeric, net numeric, net_stress numeric)
language sql stable set search_path to '' as $function$
  with b as (
    select (b.ts at time zone 'UTC')::date d, b.close from market.price_bars b join core.instruments i on i.id = b.instrument_id
    where i.symbol = 'XAUUSD' and b.timeframe = 'daily' and extract(isodow from b.ts at time zone 'UTC') between 1 and 5 and b.ts + interval '1 day' <= b.retrieved_at),
  s as (select d, close, lag(close, 252) over (order by d) c252, lead(close) over (order by d) cn, lead(d) over (order by d) dn from b),
  p as (select d, close, cn, dn, sign(close - c252)::int pos from s where c252 is not null and cn is not null),
  t as (select d, pos, close, cn, dn, pos * (cn - close) gross, abs(pos - coalesce(lag(pos) over (order by d), 0)) turn from p)
  select d, pos, close, cn, round(gross, 6), round(gross - 0.20 * turn, 6),
         round(gross - 0.40 * turn - abs(pos) * close * 0.05 * (dn - d) / 365.0, 6)
  from t order by d;
$function$;
revoke all on function intelligence.gold_daily_tsmom_days() from public, anon, authenticated;

create or replace function intelligence.fx_daily_reversal_trades()
returns table(symbol text, trade_date date, side integer, entry numeric, exit_price numeric, move_bp numeric, gross_bp numeric, cost_bp numeric, net_bp numeric)
language sql stable set search_path to '' as $function$
  with cost(sym, pips, pip) as (values ('EURUSD', 1.0, 0.0001), ('GBPUSD', 1.2, 0.0001), ('AUDUSD', 1.2, 0.0001), ('NZDUSD', 2.0, 0.0001),
                                       ('USDCAD', 1.9, 0.0001), ('USDCHF', 1.5, 0.0001), ('USDJPY', 1.2, 0.01)),
  b as (select i.symbol sym, (b.ts at time zone 'UTC')::date d, b.close from market.price_bars b join core.instruments i on i.id = b.instrument_id
        where b.timeframe = 'daily' and i.symbol in (select sym from cost)),
  r as (select sym, d, close, close / lag(close) over w - 1 ret, lead(close) over w cn from b window w as (partition by sym order by d)),
  s as (select sym, d, close, ret, cn, stddev_samp(ret) over w sd, count(ret) over w k from r
        window w as (partition by sym order by d rows between 20 preceding and 1 preceding))
  select s.sym, s.d, -sign(s.ret)::int, s.close, s.cn, round(s.ret * 10000, 4),
         round(-sign(s.ret) * (s.cn / s.close - 1) * 10000, 4), round((c.pips + 0.6) * c.pip / s.close * 10000, 4),
         round(-sign(s.ret) * (s.cn / s.close - 1) * 10000 - (c.pips + 0.6) * c.pip / s.close * 10000, 4)
  from s join cost c on c.sym = s.sym
  where s.k = 20 and s.cn is not null and s.ret is not null and abs(s.ret) > 2 * s.sd
  order by s.d, s.sym;
$function$;
revoke all on function intelligence.fx_daily_reversal_trades() from public, anon, authenticated;

create or replace function intelligence.run_batch6(p_key text, p_persist boolean default false)
returns jsonb language plpgsql set search_path to '' as $function$
declare net double precision[]; dates date[]; net2 double precision[]; trades jsonb; bench jsonb; bpass boolean;
begin
  if p_key = 'xauusd-daily-time-series-momentum' then
    select array_agg(x.net::float8 order by x.trade_date), array_agg(x.trade_date order by x.trade_date), array_agg(x.net_stress::float8 order by x.trade_date),
           jsonb_agg(jsonb_build_array(x.trade_date, x.pos, x.net) order by x.trade_date)
      into net, dates, net2, trades from intelligence.gold_daily_tsmom_days() x;
    select jsonb_build_object('short_days', count(*) filter (where x.pos = -1), 'short_days_gross_mean', avg(x.gross) filter (where x.pos = -1),
             'long_days', count(*) filter (where x.pos = 1), 'long_days_gross_mean', avg(x.gross) filter (where x.pos = 1),
             'buy_and_hold_gross_mean', avg(x.close_next - x.close_t)),
           coalesce(avg(x.gross) filter (where x.pos = -1) > 0, false)
      into bench, bpass from intelligence.gold_daily_tsmom_days() x;
    return intelligence.judge_and_store(p_key, 'XAUUSD', 'USD per ounce per day', net, dates, net2, 300, 0.025, bench, bpass, trades, p_persist);
  elsif p_key = 'fx-usd-pairs-daily-large-move-reversal' then
    select array_agg(x.net_bp::float8 order by x.trade_date, x.symbol), array_agg(x.trade_date order by x.trade_date, x.symbol),
           array_agg((x.gross_bp - 2 * x.cost_bp)::float8 order by x.trade_date, x.symbol), jsonb_agg(to_jsonb(x) order by x.trade_date, x.symbol)
      into net, dates, net2, trades from intelligence.fx_daily_reversal_trades() x;
    select jsonb_build_object('pairs', jsonb_object_agg(q.symbol, jsonb_build_object('n', q.n, 'mean_net_bp', q.m)), 'pairs_positive', count(*) filter (where q.m > 0)),
           count(*) filter (where q.m > 0) >= 5
      into bench, bpass from (select x.symbol, count(*) n, avg(x.net_bp) m from intelligence.fx_daily_reversal_trades() x group by 1) q;
    return intelligence.judge_and_store(p_key, 'FX7', 'basis points per trade', net, dates, net2, 300, 0.025, bench, bpass, trades, p_persist);
  end if;
  raise exception 'no batch-6 runner for %', p_key;
end $function$;
revoke all on function intelligence.run_batch6(text, boolean) from public, anon, authenticated;
