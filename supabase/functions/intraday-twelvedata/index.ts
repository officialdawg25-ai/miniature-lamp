import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { SYMBOLS, VendorError, formatEndDate, parseTimeSeries } from "./twelve.ts";

// Backfills 15-minute bars backwards in time from Twelve Data, one request per call, so it never bursts against the free-plan limit and
// adds negligible load. Authenticated with the shared cron secret. Dry run by default. Idempotent upserts.
// The API key is an Edge Function secret (TWELVE_DATA_API_KEY) and never appears in logs or responses.
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const API_KEY = Deno.env.get("TWELVE_DATA_API_KEY");
const headers = { "Content-Type": "application/json; charset=utf-8" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  const secret = req.headers.get("x-cron-secret");
  if (!secret) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const { data: valid, error: vErr } = await sb.rpc("verify_cron_secret", { p_secret: secret });
  if (vErr) return json(500, { ok: false, error: "SECRET_CHECK_FAILED" });
  if (valid !== true) return json(401, { ok: false, error: "UNAUTHORIZED" });
  if (!API_KEY) return json(503, { ok: false, error: "TWELVE_DATA_API_KEY_NOT_CONFIGURED" });

  const body = await req.json().catch(() => ({}));
  const symbol = String(body.symbol ?? "").toUpperCase();
  const dryRun = body.dry_run !== false;
  const targetStart = String(body.target_start ?? "2023-10-01");
  if (!(symbol in SYMBOLS)) return json(400, { ok: false, error: "UNSUPPORTED_SYMBOL", supported: Object.keys(SYMBOLS) });
  if (!/^\d{4}-\d{2}-\d{2}$/.test(targetStart)) return json(400, { ok: false, error: "INVALID_TARGET_START" });

  try {
    const { data: inst } = await sb.schema("core").from("instruments").select("id").eq("symbol", symbol).maybeSingle();
    const { data: src } = await sb.schema("core").from("data_sources").select("id").eq("name", "Twelve Data").eq("active", true).maybeSingle();
    if (!inst || !src) return json(500, { ok: false, error: "INSTRUMENT_OR_SOURCE_NOT_REGISTERED" });

    const { data: oldest } = await sb.schema("market").from("price_bars").select("ts").eq("instrument_id", inst.id).eq("timeframe", "15m").eq("source_id", src.id).order("ts", { ascending: true }).limit(1).maybeSingle();
    const end = oldest ? new Date(Date.parse(oldest.ts) - 60000).toISOString() : new Date().toISOString();
    if (end.slice(0, 10) <= targetStart) return json(200, { ok: true, done: true, reason: "target_start_reached", symbol, oldest_stored: oldest?.ts ?? null });

    const params = new URLSearchParams({ symbol: SYMBOLS[symbol], interval: "15min", outputsize: "5000", end_date: formatEndDate(end), timezone: "UTC", order: "DESC", apikey: API_KEY });
    const r = await fetch(`https://api.twelvedata.com/time_series?${params}`, { signal: AbortSignal.timeout(30000) });
    const payload = await r.json().catch(() => null);
    if (!payload) return json(502, { ok: false, error: "VENDOR_NOT_JSON", http_status: r.status });
    let parsed;
    try { parsed = parseTimeSeries(payload); }
    catch (e) {
      if (e instanceof VendorError) return json(e.code === 429 ? 429 : 502, { ok: false, error: "VENDOR_ERROR", vendor_code: e.code, message: e.message, retry_later: e.code === 429 });
      throw e;
    }
    const { bars, rejected } = parsed;
    if (!bars.length) return json(200, { ok: true, done: true, reason: "no_more_data", symbol, rejected });

    let upserted = 0;
    if (!dryRun) {
      const now = new Date().toISOString();
      const rows = bars.map((b) => ({ instrument_id: inst.id, timeframe: "15m", ts: b.ts, open: b.open, high: b.high, low: b.low, close: b.close, volume: null, spread: null, source_id: src.id, retrieved_at: now, metadata: { source: "twelve_data", spread: "not provided", volume: "not provided" } }));
      for (let i = 0; i < rows.length; i += 500) {
        const { error, data } = await sb.schema("market").from("price_bars").upsert(rows.slice(i, i + 500), { onConflict: "instrument_id,timeframe,ts" }).select("ts");
        if (error) return json(500, { ok: false, error: "BAR_WRITE_FAILED", database_error_code: error.code ?? null, rows_upserted_before_failure: upserted });
        upserted += data?.length ?? 0;
      }
    }
    return json(200, {
      ok: true, dry_run: dryRun, done: bars.length < 5000, symbol, bars_received: bars.length, bars_upserted: upserted, rejected,
      first_bar: bars[0].ts, last_bar: bars[bars.length - 1].ts,
    });
  } catch (e) {
    return json(500, { ok: false, error: "TWELVE_INGESTION_FAILED", message: e instanceof Error ? e.message.replace(/apikey=\S+/gi, "apikey=***").slice(0, 120) : "unknown" });
  }
});
