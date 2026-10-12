-- Mechanical backtest of the owner's SMC + Fibonacci rules on 15-minute bars. Research only: it reads bars and returns rows, writes nothing.
-- Rules (frozen in the research ledger before the first run):
--  bias        1h break of structure (a close beyond the last confirmed 3-bar swing high or low sets long or short bias)
--  leg         alternating confirmed 15m swings: low then high (long) or high then low (short), where the new swing breaks the previous swing of its kind
--  entry       limit at the 61.8 percent retracement of the leg (the owner's "38.2" measured from the swing low)
--  stop        at the 76.4 percent retracement (the owner's "23.6"), no buffer; slippage on stop fills
--  target      nearest confirmed swing high (long) or low (short) beyond the entry
--  cancel      leg extreme exceeded before a fill, stop level touched before a fill, or 8 bars unfilled
--  session     fills only 07:00-16:00 UTC, flat at the 20:45 bar close; one position at a time
--  prices      bars are treated as mid prices; bid = mid - spread/2, ask = mid + spread/2 with a fixed spread
--  conservative bar rules: no target on the fill bar; if stop and target are in one bar the stop is taken
create or replace function intelligence.smc_fib_backtest(
  p_symbol text, p_spread numeric, p_min_stop numeric, p_max_stop numeric, p_slip numeric, p_units numeric, p_quote_is_jpy boolean,
  p_start timestamptz default '2023-10-01', p_end timestamptz default now()
)
returns table(side text, signal_ts timestamptz, fill_ts timestamptz, exit_ts timestamptz, entry numeric, stop numeric, target numeric,
              exit_price numeric, outcome text, r_multiple numeric, pnl_usd numeric)
language plpgsql
set search_path to 'intelligence', 'market', 'core', 'public', 'pg_catalog'
as $function$
declare
  k constant integer := 3;
  n integer; ts timestamptz[]; o numeric[]; h numeric[]; l numeric[]; c numeric[];
  sh boolean[]; sl boolean[]; i integer; j integer; m integer; q integer;
  hn integer := 0; hts timestamptz[] := '{}'; hh numeric[] := '{}'; hl numeric[] := '{}'; hc numeric[] := '{}'; hend integer[] := '{}';
  hsh boolean[]; hsl boolean[]; last_sh numeric; last_sl numeric; bias integer := 0; bias_pt integer[]; bias_at integer[];
  sw_t text[] := '{}'; sw_p numeric[] := '{}'; sw_i integer[] := '{}'; sn integer := 0;
  st text := 'idle';
  dir integer; E numeric; S numeric; TP numeric; Hp numeric; Lp numeric; R numeric; placed integer; sig_ts timestamptz; fill_i integer; fill_ts timestamptz;
  hs numeric := p_spread / 2; insess boolean; ex numeric; oc text; a integer; leg_ok boolean;
  d numeric;
begin
  select array_agg(x.ts order by x.ts), array_agg(x.open order by x.ts), array_agg(x.high order by x.ts), array_agg(x.low order by x.ts), array_agg(x.close order by x.ts)
  into ts, o, h, l, c
  from (select b2.ts, b2.open, b2.high, b2.low, b2.close from market.price_bars b2 join core.instruments i2 on i2.id = b2.instrument_id
        where i2.symbol = p_symbol and b2.timeframe = '15m' and b2.ts >= p_start and b2.ts < p_end
          and extract(isodow from b2.ts at time zone 'UTC') between 1 and 5
          and not (extract(isodow from b2.ts at time zone 'UTC') = 5 and extract(hour from b2.ts at time zone 'UTC') >= 22)) x;
  n := coalesce(array_length(ts, 1), 0);
  if n < 1000 then raise exception 'not enough 15m bars (%)', n; end if;

  sh := array_fill(false, array[n]); sl := array_fill(false, array[n]);
  for i in k + 1 .. n - k loop
    sh[i] := true; sl[i] := true;
    for j in 1 .. k loop
      if not (h[i] > h[i - j] and h[i] > h[i + j]) then sh[i] := false; end if;
      if not (l[i] < l[i - j] and l[i] < l[i + j]) then sl[i] := false; end if;
    end loop;
  end loop;

  i := 1;
  while i <= n - 3 loop
    if date_trunc('hour', ts[i]) = date_trunc('hour', ts[i + 3]) and ts[i + 3] - ts[i] = interval '45 minutes' and extract(minute from ts[i]) = 0 then
      hn := hn + 1; hts := hts || ts[i]; hh := hh || greatest(h[i], h[i + 1], h[i + 2], h[i + 3]); hl := hl || least(l[i], l[i + 1], l[i + 2], l[i + 3]); hc := hc || c[i + 3]; hend := hend || (i + 3);
      i := i + 4;
    else i := i + 1; end if;
  end loop;
  hsh := array_fill(false, array[greatest(hn, 1)]); hsl := array_fill(false, array[greatest(hn, 1)]);
  for m in k + 1 .. hn - k loop
    hsh[m] := true; hsl[m] := true;
    for j in 1 .. k loop
      if not (hh[m] > hh[m - j] and hh[m] > hh[m + j]) then hsh[m] := false; end if;
      if not (hl[m] < hl[m - j] and hl[m] < hl[m + j]) then hsl[m] := false; end if;
    end loop;
  end loop;
  bias_pt := array_fill(null::integer, array[n]); bias_at := array_fill(0, array[n]);
  for m in 1 .. hn loop
    if m - k >= 1 and hsh[m - k] then last_sh := hh[m - k]; end if;
    if m - k >= 1 and hsl[m - k] then last_sl := hl[m - k]; end if;
    if last_sh is not null and hc[m] > last_sh then bias := 1; last_sh := null; elsif last_sl is not null and hc[m] < last_sl then bias := -1; last_sl := null; end if;
    bias_pt[hend[m]] := bias;
  end loop;
  bias := 0;
  for i in 1 .. n loop
    if bias_pt[i] is not null then bias := bias_pt[i]; end if;
    bias_at[i] := bias;
  end loop;

  for i in 1 .. n loop
    if i - k >= 1 and (sh[i - k] or sl[i - k]) then
      sn := sn + 1;
      if sh[i - k] then sw_t := array_append(sw_t, 'H'::text); sw_p := array_append(sw_p, h[i - k]); else sw_t := array_append(sw_t, 'L'::text); sw_p := array_append(sw_p, l[i - k]); end if;
      sw_i := array_append(sw_i, i - k);
    end if;

    insess := extract(hour from ts[i] at time zone 'UTC') between 7 and 15;

    if st = 'order' then
      if i > placed + 8 then
        side := case when dir = 1 then 'long' else 'short' end; signal_ts := sig_ts; fill_ts := null; exit_ts := ts[i]; entry := E; stop := S; target := TP; exit_price := null; outcome := 'cancelled_expired'; r_multiple := null; pnl_usd := null; return next; st := 'idle';
      elsif dir = 1 then
        if insess and l[i] + hs <= E then
          fill_i := i; fill_ts := ts[i];
          if l[i] - hs <= S then ex := S - p_slip; oc := 'stop'; st := 'closed'; else st := 'pos'; end if;
        elsif l[i] - hs <= S or h[i] > Hp then
          side := 'long'; signal_ts := sig_ts; fill_ts := null; exit_ts := ts[i]; entry := E; stop := S; target := TP; exit_price := null; outcome := 'cancelled_invalidated'; r_multiple := null; pnl_usd := null; return next; st := 'idle';
        end if;
      else
        if insess and h[i] - hs >= E then
          fill_i := i; fill_ts := ts[i];
          if h[i] + hs >= S then ex := S + p_slip; oc := 'stop'; st := 'closed'; else st := 'pos'; end if;
        elsif h[i] + hs >= S or l[i] < Lp then
          side := 'short'; signal_ts := sig_ts; fill_ts := null; exit_ts := ts[i]; entry := E; stop := S; target := TP; exit_price := null; outcome := 'cancelled_invalidated'; r_multiple := null; pnl_usd := null; return next; st := 'idle';
        end if;
      end if;
    elsif st = 'pos' then
      if dir = 1 then
        if l[i] - hs <= S then ex := S - p_slip; oc := 'stop'; st := 'closed';
        elsif h[i] - hs >= TP then ex := TP; oc := 'target'; st := 'closed';
        elsif ts[i] at time zone 'UTC' >= (date_trunc('day', ts[i] at time zone 'UTC') + interval '20 hours 45 minutes') then ex := c[i] - hs; oc := 'time_exit'; st := 'closed'; end if;
      else
        if h[i] + hs >= S then ex := S + p_slip; oc := 'stop'; st := 'closed';
        elsif l[i] + hs <= TP then ex := TP; oc := 'target'; st := 'closed';
        elsif ts[i] at time zone 'UTC' >= (date_trunc('day', ts[i] at time zone 'UTC') + interval '20 hours 45 minutes') then ex := c[i] + hs; oc := 'time_exit'; st := 'closed'; end if;
      end if;
    end if;

    if st = 'closed' then
      side := case when dir = 1 then 'long' else 'short' end; signal_ts := sig_ts; fill_ts := fill_ts; exit_ts := ts[i]; entry := E; stop := S; target := TP; exit_price := ex; outcome := oc;
      r_multiple := round(((ex - E) * dir / abs(E - S))::numeric, 4);
      pnl_usd := round(((ex - E) * dir * p_units * case when p_quote_is_jpy then 1 / E else 1 end)::numeric, 4);
      return next; st := 'idle';
    end if;

    if st = 'idle' and sn >= 3 and i - k >= 1 and (sh[i - k] or sl[i - k]) and bias_at[i] <> 0 then
      leg_ok := false;
      if sh[i - k] and bias_at[i] = 1 and sw_t[sn] = 'H' and sw_t[sn - 1] = 'L' then
        Hp := sw_p[sn]; Lp := sw_p[sn - 1]; a := sn - 2;
        while a >= 1 and sw_t[a] <> 'H' loop a := a - 1; end loop;
        if a >= 1 and Hp > sw_p[a] then leg_ok := true; dir := 1; end if;
      elsif sl[i - k] and bias_at[i] = -1 and sw_t[sn] = 'L' and sw_t[sn - 1] = 'H' then
        Lp := sw_p[sn]; Hp := sw_p[sn - 1]; a := sn - 2;
        while a >= 1 and sw_t[a] <> 'L' loop a := a - 1; end loop;
        if a >= 1 and Lp < sw_p[a] then leg_ok := true; dir := -1; end if;
      end if;
      if leg_ok then
        R := Hp - Lp;
        if dir = 1 then E := Hp - 0.618 * R; S := Hp - 0.764 * R; else E := Lp + 0.618 * R; S := Lp + 0.764 * R; end if;
        d := abs(E - S);
        if (dir = 1 and c[i] + hs <= E) or (dir = -1 and c[i] - hs >= E) then
          side := case when dir = 1 then 'long' else 'short' end; signal_ts := ts[i]; fill_ts := null; exit_ts := null; entry := E; stop := S; target := null; exit_price := null; outcome := 'skipped_price_already_through_entry'; r_multiple := null; pnl_usd := null; return next;
        elsif d < p_min_stop or d > p_max_stop then
          side := case when dir = 1 then 'long' else 'short' end; signal_ts := ts[i]; fill_ts := null; exit_ts := null; entry := E; stop := S; target := null; exit_price := null; outcome := 'skipped_stop_size'; r_multiple := null; pnl_usd := null; return next;
        else
          TP := null;
          for q in reverse sn .. greatest(1, sn - 300) loop
            if dir = 1 and sw_t[q] = 'H' and sw_p[q] > E and (TP is null or sw_p[q] < TP) then TP := sw_p[q]; end if;
            if dir = -1 and sw_t[q] = 'L' and sw_p[q] < E and (TP is null or sw_p[q] > TP) then TP := sw_p[q]; end if;
          end loop;
          st := 'order'; placed := i; sig_ts := ts[i];
        end if;
      end if;
    end if;
  end loop;
end;
$function$;
revoke all on function intelligence.smc_fib_backtest(text, numeric, numeric, numeric, numeric, numeric, boolean, timestamptz, timestamptz) from public, anon, authenticated;
