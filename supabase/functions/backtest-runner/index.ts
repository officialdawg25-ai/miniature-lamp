import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { alignAsOf, alignAsOfMaxAge, runBacktest, subtractSeries, type Num } from "./backtest.ts";

const CODE_VERSION = "backtest-v5";
// The stored gold series changes construction on this date (weekday-only two-decimal closes before, seven-day long-decimal
// closes after, same provider). The level is continuous across it, but the two halves are not the same series.
const GOLD_CONSTRUCTION_BREAK_MS = Date.parse("2013-03-27T00:00:00Z");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const sb = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false, autoRefreshToken: false } });
const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Vary": "Origin",
};
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });

async function fetchAll<T>(page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await page(from, from + 999);
    if (error) throw new Error(error.message);
    out.push(...(data ?? []));
    if (!data || data.length < 1000) break;
  }
  return out;
}

Deno.serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED", request_id: requestId });
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return json(401, { ok: false, error: "UNAUTHORIZED", request_id: requestId });
  const { data: authData, error: authError } = await sb.auth.getUser(authorization.slice(7));
  if (authError || !authData.user) return json(401, { ok: false, error: "UNAUTHORIZED", request_id: requestId });
  const { data: access, error: accessError } = await sb.from("institutional_access")
    .select("user_id").eq("user_id", authData.user.id).eq("is_active", true).maybeSingle();
  if (accessError) return json(500, { ok: false, error: "AUTHORIZATION_CHECK_FAILED", request_id: requestId });
  if (!access) return json(403, { ok: false, error: "INSTITUTIONAL_ACCESS_REQUIRED", request_id: requestId });

  try {
    const body = await req.json().catch(() => ({}));
    const persist = body.persist === true;
    const symbol = String(body.symbol ?? "USDJPY").toUpperCase();
    if (symbol !== "USDJPY" && symbol !== "XAUUSD") return json(400, { ok: false, error: "UNSUPPORTED_SYMBOL", request_id: requestId });
    const isGold = symbol === "XAUUSD";
    const signalKind = String(body.signal ?? "yield");
    if (signalKind !== "yield" && signalKind !== "policy") return json(400, { ok: false, error: "UNSUPPORTED_SIGNAL", supported: ["yield", "policy"], request_id: requestId });
    if (isGold && signalKind === "policy") return json(400, { ok: false, error: "POLICY_SIGNAL_IS_USDJPY_ONLY", request_id: requestId });
    const isPolicy = !isGold && signalKind === "policy";
    const defaultCost = isGold ? 2 : 1;
    const costBp = Number.isFinite(Number(body.cost_bp)) ? Math.min(Math.max(Number(body.cost_bp), 0), 20) : defaultCost;
    const reps = Math.min(Math.max(Math.floor(Number(body.reps ?? 500)), 100), 1000);
    const seed = Math.floor(Number(body.seed ?? 42));
    const start = String(body.start_date ?? "2021-01-01");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(start)) return json(400, { ok: false, error: "INVALID_START_DATE", request_id: requestId });
    const params = { symbol, start_date: start, cost_bp: costBp, reps, seed, init_train_days: 504, test_block_days: 63, holdout_days: 252, timeframe: "daily", signal: isGold ? "us_10y_real_yield" : isPolicy ? "us_jp_policy_rate_differential" : "us_jp_10y_differential" };

    const { data: instrument, error: instrumentError } = await sb.schema("core").from("instruments").select("id").eq("symbol", symbol).eq("active", true).maybeSingle();
    if (instrumentError || !instrument) return json(500, { ok: false, error: "INSTRUMENT_NOT_FOUND", request_id: requestId });

    const num = (v: number | string | null): number | null => (v === null ? null : Number.isFinite(Number(v)) ? Number(v) : null);
    let datesMs: number[], close: number[], diff10: Num[], carry: number[];
    let extra: Record<string, unknown> = {};
    let weekendRowsDropped = 0;
    let yieldRowCount = 0;

    if (isGold) {
      // Gold closes live in price_closes. The stored series also has Saturday/Sunday rows, which spot gold does not trade on,
      // so only Monday-Friday closes are used (matching the FX trading calendar).
      const all = await fetchAll<{ ts: string; close: number | string }>((from, to) =>
        sb.schema("market").from("price_closes").select("ts,close").eq("instrument_id", instrument.id).eq("timeframe", "daily")
          .gte("ts", start + "T00:00:00Z").order("ts", { ascending: true }).range(from, to));
      const weekdays = all.filter((r) => { const d = new Date(r.ts).getUTCDay(); return d >= 1 && d <= 5; });
      weekendRowsDropped = all.length - weekdays.length;
      datesMs = weekdays.map((b) => Date.parse(b.ts));
      close = weekdays.map((b) => Number(b.close));
      // Real yield (US 10Y TIPS) is stored on the US 10Y rows. It counts as known only from its stored availability time.
      const ry = await fetchAll<{ ts: string; real_yield: number | string | null; metadata: { available_at?: string } | null }>((from, to) =>
        sb.schema("market").from("yield_observations").select("ts,real_yield,metadata").eq("market_code", "US").eq("tenor_years", 10)
          .not("real_yield", "is", null).order("ts", { ascending: true }).range(from, to));
      yieldRowCount = ry.length;
      const feats = ry.map((r) => {
        const av = r.metadata?.available_at ? Date.parse(r.metadata.available_at) : Date.parse(r.ts) + 2 * 86400000;
        return { availableAtMs: av, value: num(r.real_yield) as Num };
      }).sort((x, y) => x.availableAtMs - y.availableAtMs);
      diff10 = alignAsOf(feats, datesMs);
      carry = new Array(close.length).fill(0);
      extra = { weekend_rows_dropped: weekendRowsDropped };
    } else {
      const bars = await fetchAll<{ ts: string; close: number | string }>((from, to) =>
        sb.schema("market").from("price_bars").select("ts,close").eq("instrument_id", instrument.id).eq("timeframe", "daily")
          .gte("ts", start + "T00:00:00Z").order("ts", { ascending: true }).range(from, to));
      const yields = await fetchAll<{ as_of: string; diff_10y: number | string | null; us_2y: number | string | null; jp_2y: number | string | null; jp_stale: boolean | null }>((from, to) =>
        sb.schema("market").from("v_yield_differential_asof").select("as_of,diff_10y,us_2y,jp_2y,jp_stale").order("as_of", { ascending: true }).range(from, to));
      if (yields.length < 300) return json(422, { ok: false, error: "INSUFFICIENT_YIELD_HISTORY", rows: yields.length, request_id: requestId });
      yieldRowCount = yields.length;
      datesMs = bars.map((b) => Date.parse(b.ts));
      close = bars.map((b) => Number(b.close));
      // A pairing whose Japan value is stale counts as unavailable (null) rather than being carried forward silently.
      const diffFeatures = yields.map((r) => ({ availableAtMs: Date.parse(r.as_of), value: r.jp_stale ? null : num(r.diff_10y) as Num }));
      // Carry proxy: per-day interest-rate differential (US 2Y - Japan 2Y) earned by a long USDJPY position.
      const carryFeatures = yields.map((r) => {
        const us = num(r.us_2y), jp = num(r.jp_2y);
        return { availableAtMs: Date.parse(r.as_of), value: r.jp_stale || us === null || jp === null ? null : (us - jp) / 100 / 252 };
      });
      diff10 = alignAsOf(diffFeatures, datesMs);
      carry = alignAsOf(carryFeatures, datesMs).map((c) => c ?? 0);
      extra = { yield_rows_stale: yields.filter((r) => r.jp_stale).length };
      if (isPolicy) {
        // Signal = Fed target (upper bound) minus the Bank of Japan overnight call rate, each aligned as-of its own
        // availability time. A rate not refreshed for longer than the age limit counts as missing. The carry proxy above is
        // unchanged so results stay comparable with the yield-differential run.
        const { data: banks, error: banksError } = await sb.schema("macro").from("central_banks").select("id,code").in("code", ["FED", "BOJ"]);
        if (banksError || !banks || banks.length !== 2) return json(500, { ok: false, error: "CENTRAL_BANKS_NOT_FOUND", request_id: requestId });
        const feats: Record<string, { availableAtMs: number; value: Num }[]> = {};
        const counts: Record<string, number> = {};
        for (const b of banks) {
          const rows = await fetchAll<{ available_at: string; rate: number | string }>((from, to) =>
            sb.schema("macro").from("policy_rate_observations").select("available_at,rate").eq("central_bank_id", b.id)
              .order("available_at", { ascending: true }).range(from, to));
          feats[b.code as string] = rows.map((r) => ({ availableAtMs: Date.parse(r.available_at), value: num(r.rate) as Num }));
          counts[b.code as string] = rows.length;
        }
        if ((counts.FED ?? 0) < 300 || (counts.BOJ ?? 0) < 300) return json(422, { ok: false, error: "INSUFFICIENT_POLICY_RATE_HISTORY", rows: counts, request_id: requestId });
        const day = 86400000;
        const fed = alignAsOfMaxAge(feats.FED, datesMs, 14 * day);
        const boj = alignAsOfMaxAge(feats.BOJ, datesMs, 10 * day);
        diff10 = subtractSeries(fed, boj);
        extra = { ...extra, policy_rows_fed: counts.FED, policy_rows_boj: counts.BOJ, fed_max_age_days: 14, boj_max_age_days: 10 };
      }
    }

    const needed = params.init_train_days + params.test_block_days * 2 + params.holdout_days + 1;
    if (close.length < needed) return json(422, { ok: false, error: "INSUFFICIENT_PRICE_HISTORY", bars: close.length, needed, request_id: requestId });
    if (close.some((c) => !Number.isFinite(c) || c <= 0)) return json(422, { ok: false, error: "INVALID_PRICE_VALUES", request_id: requestId });

    const result = runBacktest({ close, diff10, signalSign: isGold ? -1 : 1 }, carry, { initTrain: params.init_train_days, testBlock: params.test_block_days, holdout: params.holdout_days, costBp, reps, seed, signalName: isGold ? "real_yield" : isPolicy ? "policy_diff" : undefined });
    const bars = { length: close.length };
    const yields = { length: yieldRowCount };

    const dataSummary = {
      first_price_date: new Date(datesMs[0]).toISOString().slice(0, 10), last_price_date: new Date(datesMs[datesMs.length - 1]).toISOString().slice(0, 10), price_days: bars.length,
      first_close: close[0], last_close: close[close.length - 1], buy_and_hold_price_return: close[close.length - 1] / close[0] - 1,
      yield_rows: yields.length, ...extra,
      days_with_signal: diff10.filter((v) => v !== null).length,
      close_checksum: Math.round(close.reduce((a, b) => a + b, 0) * 1000),
      gold_series_construction_break_included: isGold && datesMs[0] < GOLD_CONSTRUCTION_BREAK_MS,
    };
    const years = close.length / 252;
    const longWindow = years >= 8;
    const common = [
      longWindow
        ? `About ${years.toFixed(1)} years of daily data. That is more than a five-year window, but only a strong, stable edge can still be confirmed, and 'no evidence' is not proof that no edge exists.`
        : `About ${years.toFixed(1)} years of daily data gives low statistical power: only a strong edge can be confirmed. 'No evidence' is not proof that no edge exists.`,
      "This is research output, not a trading signal or a forecast.",
    ];
    const regime = (asset: string) => longWindow
      ? `The sample spans several market regimes, so one walk-forward summary averages over very different conditions. Check whether any result comes from a single period. ${asset} also trended in places, so compare with buy-and-hold, not with zero.`
      : `The sample is one market regime: ${asset} trended strongly, so any long-biased rule benefits. Compare with buy-and-hold, not with zero.`;
    const caveats = isGold ? [
      regime("Gold"),
      "The rate rules use a fixed prior set in advance: a rising real yield favours a short gold position and a falling one a long. The direction is not fitted.",
      "Gold has no carry term here, so only the price move is earned. Spot gold carries financing and storage-type costs that are not modelled.",
      "The stored gold series has weekend rows, which spot gold does not trade on; they are excluded, and the closes are daily values from a single provider, not exchange settlement prices.",
      "Real-yield availability times are conservative (two days after each date), so results are if anything understated on timing.",
      ...common,
    ] : isPolicy ? [
      "The signal is the Fed target (upper bound) minus the Bank of Japan overnight call rate. The BoJ figure is a market rate that tracks the policy rate, not the policy target itself.",
      "Policy rates move in a handful of steps, so the number of independent changes behind this signal is small even though there are many daily observations. That limits what any test can conclude.",
      regime("USDJPY"),
      "Carry is the same proxy as the yield-differential run (US 2Y minus Japan 2Y yields), so the two runs are comparable.",
      "This is another hypothesis tested on the same price history. Every run, stored or not, adds to the multiple-testing problem; the correction here counts only the nine rules inside this run.",
      ...common,
    ] : [
      regime("USDJPY"),
      "Carry is a proxy from US 2Y minus Japan 2Y yields; real swap rates differ and include broker markup.",
      "Yield availability times are conservative (two days after each date); real publication is faster, so results are if anything understated on timing.",
      ...common,
    ];

    if (isGold && datesMs[0] < GOLD_CONSTRUCTION_BREAK_MS) {
      caveats.unshift("DATA QUALITY: this window starts before 2013-03-27, when the stored gold series changes construction (Monday-Friday two-decimal closes before; seven-day long-decimal closes after, with slightly lower weekday volatility). The level is continuous at the join, but the two halves are not the same series. Start from 2015 or later for a single-construction test.");
    }

    let storedId: string | null = null;
    if (persist) {
      const { data: saved, error: saveError } = await sb.schema("intelligence").from("backtest_runs")
        .insert({ created_by: authData.user.id, code_version: CODE_VERSION, symbol, params, data_summary: dataSummary, result }).select("id").single();
      if (saveError) {
        console.error(JSON.stringify({ event: "backtest_store_failed", request_id: requestId, db_code: saveError.code ?? null }));
        return json(500, { ok: false, error: "BACKTEST_STORE_FAILED", database_error_code: saveError.code ?? null, request_id: requestId });
      }
      storedId = saved.id;
    }
    return json(200, { ok: true, status: "completed", request_id: requestId, code_version: CODE_VERSION, persisted: persist, stored_run_id: storedId, params, data_summary: dataSummary, result, caveats });
  } catch (error) {
    console.error(JSON.stringify({ event: "backtest_failed", request_id: requestId, message: error instanceof Error ? error.message.slice(0, 160) : "unknown" }));
    return json(500, { ok: false, status: "failed", request_id: requestId, error: "BACKTEST_FAILED" });
  }
});
