import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { alignAsOf, runBacktest, type Num } from "./backtest.ts";

const CODE_VERSION = "backtest-v1";
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
    const costBp = Number.isFinite(Number(body.cost_bp)) ? Math.min(Math.max(Number(body.cost_bp), 0), 20) : 1;
    const reps = Math.min(Math.max(Math.floor(Number(body.reps ?? 500)), 100), 1000);
    const seed = Math.floor(Number(body.seed ?? 42));
    const start = String(body.start_date ?? "2021-01-01");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(start)) return json(400, { ok: false, error: "INVALID_START_DATE", request_id: requestId });
    const params = { symbol: "USDJPY", start_date: start, cost_bp: costBp, reps, seed, init_train_days: 504, test_block_days: 63, holdout_days: 252, timeframe: "daily" };

    const { data: instrument, error: instrumentError } = await sb.schema("core").from("instruments").select("id").eq("symbol", "USDJPY").eq("active", true).maybeSingle();
    if (instrumentError || !instrument) return json(500, { ok: false, error: "INSTRUMENT_NOT_FOUND", request_id: requestId });

    const bars = await fetchAll<{ ts: string; close: number | string }>((from, to) =>
      sb.schema("market").from("price_bars").select("ts,close").eq("instrument_id", instrument.id).eq("timeframe", "daily")
        .gte("ts", start + "T00:00:00Z").order("ts", { ascending: true }).range(from, to));
    const yields = await fetchAll<{ as_of: string; diff_10y: number | string | null; us_2y: number | string | null; jp_2y: number | string | null; jp_stale: boolean | null }>((from, to) =>
      sb.schema("market").from("v_yield_differential_asof").select("as_of,diff_10y,us_2y,jp_2y,jp_stale").order("as_of", { ascending: true }).range(from, to));

    const needed = params.init_train_days + params.test_block_days * 2 + params.holdout_days + 1;
    if (bars.length < needed) return json(422, { ok: false, error: "INSUFFICIENT_PRICE_HISTORY", bars: bars.length, needed, request_id: requestId });
    if (yields.length < 300) return json(422, { ok: false, error: "INSUFFICIENT_YIELD_HISTORY", rows: yields.length, request_id: requestId });

    const datesMs = bars.map((b) => Date.parse(b.ts));
    const close = bars.map((b) => Number(b.close));
    if (close.some((c) => !Number.isFinite(c) || c <= 0)) return json(422, { ok: false, error: "INVALID_PRICE_VALUES", request_id: requestId });

    // A pairing whose Japan value is stale counts as unavailable (null) rather than being carried forward silently.
    const num = (v: number | string | null): number | null => (v === null ? null : Number.isFinite(Number(v)) ? Number(v) : null);
    const diffFeatures = yields.map((r) => ({ availableAtMs: Date.parse(r.as_of), value: r.jp_stale ? null : num(r.diff_10y) as Num }));
    // Carry proxy: per-day interest-rate differential (US 2Y - Japan 2Y) earned by a long USDJPY position.
    const carryFeatures = yields.map((r) => {
      const us = num(r.us_2y), jp = num(r.jp_2y);
      return { availableAtMs: Date.parse(r.as_of), value: r.jp_stale || us === null || jp === null ? null : (us - jp) / 100 / 252 };
    });
    const diff10 = alignAsOf(diffFeatures, datesMs);
    const carry = alignAsOf(carryFeatures, datesMs).map((c) => c ?? 0);

    const result = runBacktest({ close, diff10 }, carry, { initTrain: params.init_train_days, testBlock: params.test_block_days, holdout: params.holdout_days, costBp, reps, seed });

    const dataSummary = {
      first_price_date: bars[0].ts.slice(0, 10), last_price_date: bars[bars.length - 1].ts.slice(0, 10), price_days: bars.length,
      first_close: close[0], last_close: close[close.length - 1], buy_and_hold_price_return: close[close.length - 1] / close[0] - 1,
      yield_rows: yields.length, yield_rows_stale: yields.filter((r) => r.jp_stale).length,
      days_with_differential: diff10.filter((v) => v !== null).length,
      close_checksum: Math.round(close.reduce((a, b) => a + b, 0) * 1000),
    };
    const caveats = [
      "The sample is one market regime: USDJPY trended strongly higher, so any long-biased rule benefits. Compare with buy-and-hold, not with zero.",
      "Carry is a proxy from US 2Y minus Japan 2Y yields; real swap rates differ and include broker markup.",
      "Yield availability times are conservative (two days after each date); real publication is faster, so results are if anything understated on timing.",
      "About 5 years of daily data gives low statistical power: only a strong edge can be confirmed. 'No evidence' is not proof that no edge exists.",
      "This is research output, not a trading signal or a forecast.",
    ];

    let storedId: string | null = null;
    if (persist) {
      const { data: saved, error: saveError } = await sb.schema("intelligence").from("backtest_runs")
        .insert({ created_by: authData.user.id, code_version: CODE_VERSION, symbol: "USDJPY", params, data_summary: dataSummary, result }).select("id").single();
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
