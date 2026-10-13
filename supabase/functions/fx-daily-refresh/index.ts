import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { PAIRS, ProviderError, parseFxDaily } from "./av.ts";

// Scheduled refresh of the daily FX bars that were previously only refreshed from a signed-in session (market-data-ingestion).
// Same vendor (Alpha Vantage FX_DAILY, compact = last 100 days) and the same source id and row shape, so each daily series keeps
// a single vendor. Bars already stored are never rewritten (insert-only), so history used by past backtests cannot change. Authenticated only by the shared cron secret; every run is recorded in market.ingestion_audit. No trading access.
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const API_KEY = Deno.env.get("ALPHA_VANTAGE_API_KEY");
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  const secret = req.headers.get("x-cron-secret");
  if (!secret) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const { data: valid, error: vErr } = await sb.rpc("verify_cron_secret", { p_secret: secret });
  if (vErr) return json(500, { ok: false, error: "SECRET_CHECK_FAILED" });
  if (valid !== true) return json(401, { ok: false, error: "UNAUTHORIZED" });
  if (!API_KEY) return json(503, { ok: false, error: "ALPHA_VANTAGE_API_KEY_NOT_CONFIGURED" });

  const body = await req.json().catch(() => ({}));
  const symbols: string[] = Array.isArray(body.symbols) ? [...new Set(body.symbols.map(String))] : [];
  if (symbols.length < 1 || symbols.length > 5 || symbols.some((s) => !(s in PAIRS))) return json(400, { ok: false, error: "CHOOSE_ONE_TO_FIVE_SUPPORTED_PAIRS", supported: Object.keys(PAIRS) });

  const { data: src } = await sb.schema("core").from("data_sources").select("id").eq("name", "Alpha Vantage").eq("active", true).maybeSingle();
  if (!src) return json(422, { ok: false, error: "DATA_SOURCE_NOT_FOUND" });
  const { data: insts } = await sb.schema("core").from("instruments").select("id,symbol").in("symbol", symbols);
  const ids = new Map((insts ?? []).map((r: { id: string; symbol: string }) => [r.symbol, r.id]));
  const { data: audit } = await sb.schema("market").from("ingestion_audit").insert({ request_id: requestId, provider: "fx-daily-refresh (Alpha Vantage)", status: "running" }).select("id").maybeSingle();

  const today = new Date().toISOString().slice(0, 10);
  const results: Record<string, unknown>[] = [];
  for (const [i, symbol] of symbols.entries()) {
    if (i > 0) await sleep(15000); // stay under the provider's per-minute limit
    try {
      const instrumentId = ids.get(symbol);
      if (!instrumentId) throw new ProviderError("INSTRUMENT_NOT_FOUND");
      // A series that already holds daily bars from another vendor is never extended with this one.
      const { data: other } = await sb.schema("market").from("price_bars").select("ts").eq("instrument_id", instrumentId).eq("timeframe", "daily").neq("source_id", src.id).limit(1).maybeSingle();
      if (other) throw new ProviderError("OTHER_VENDOR_HOLDS_DAILY_BARS");
      const [from, to] = PAIRS[symbol];
      const url = new URL("https://www.alphavantage.co/query");
      for (const [k, v] of Object.entries({ function: "FX_DAILY", from_symbol: from, to_symbol: to, outputsize: "compact", apikey: API_KEY })) url.searchParams.set(k, v);
      const res = await fetch(url, { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(20000) });
      if (!res.ok) throw new ProviderError(`PROVIDER_HTTP_${res.status}`);
      const { bars, rejected } = parseFxDaily(await res.json().catch(() => null), today);
      if (!bars.length) throw new ProviderError("NO_VALID_BARS");
      const now = new Date().toISOString();
      const rows = bars.map((b) => ({ instrument_id: instrumentId, timeframe: "daily", ts: `${b.date}T00:00:00Z`, open: b.open, high: b.high, low: b.low, close: b.close,
        volume: null, spread: null, source_id: src.id, retrieved_at: now, metadata: { provider: "alpha_vantage", provider_symbol: `${from}${to}`, retrieval: "FX_DAILY compact (scheduled)" } }));
      const { error, data: added } = await sb.schema("market").from("price_bars").upsert(rows, { onConflict: "instrument_id,timeframe,ts", ignoreDuplicates: true }).select("ts");
      if (error) throw new ProviderError(`DATABASE_WRITE_FAILED_${error.code ?? "UNKNOWN"}`);
      results.push({ symbol, ok: true, rows: rows.length, new_bars: added?.length ?? 0, rejected, latest: bars[bars.length - 1].date });
    } catch (e) {
      const code = e instanceof ProviderError ? e.code : "FAILED";
      results.push({ symbol, ok: false, error: code });
      if (code === "PROVIDER_RATE_LIMIT" || code === "PROVIDER_NOTICE") break; // daily quota reached: stop instead of burning more calls
    }
  }
  const failed = results.filter((r) => !r.ok);
  if (audit?.id) await sb.schema("market").from("ingestion_audit").update({
    status: failed.length ? "failed" : "succeeded", completed_at: new Date().toISOString(), instruments: symbols,
    records_processed: results.reduce((a, r) => a + Number(r.rows ?? 0), 0), error_code: failed.length ? "SYMBOLS_FAILED" : null,
    error_stage: failed.length ? failed.map((r) => r.symbol).join(",") : null, details: { results },
  }).eq("id", audit.id);
  return json(200, { ok: failed.length === 0, request_id: requestId, results });
});
