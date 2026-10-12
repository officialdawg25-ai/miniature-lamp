import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { VendorError, parseTimeSeries, type Bar } from "./twelve.ts";

// Near-real-time candles for the chart page. Read only: nothing is written to the database. The vendor key stays server side.
// Responses are cached per (symbol, interval) for a few seconds so several viewers or a fast refresh never exceed the vendor's free-plan limit.
// The most recent candle is still forming until its interval ends, and is flagged as such.
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const API_KEY = Deno.env.get("TWELVE_DATA_API_KEY");
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type, x-cron-secret", "Access-Control-Allow-Methods": "POST, OPTIONS", Vary: "Origin" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });

const VENDOR_SYMBOL: Record<string, string> = {
  AUDJPY: "AUD/JPY", AUDUSD: "AUD/USD", EURJPY: "EUR/JPY", EURUSD: "EUR/USD", GBPJPY: "GBP/JPY", GBPUSD: "GBP/USD",
  NZDUSD: "NZD/USD", USDCAD: "USD/CAD", USDCHF: "USD/CHF", USDJPY: "USD/JPY", XAUUSD: "XAU/USD",
};
const INTERVALS: Record<string, { vendor: string; ms: number }> = {
  "1m": { vendor: "1min", ms: 60_000 }, "5m": { vendor: "5min", ms: 300_000 }, "15m": { vendor: "15min", ms: 900_000 },
  "1h": { vendor: "1h", ms: 3_600_000 }, "4h": { vendor: "4h", ms: 14_400_000 }, "1d": { vendor: "1day", ms: 86_400_000 },
};
const CACHE_MS = 10_000;
const cache = new Map<string, { at: number; bars: Bar[] }>();

async function authorised(req: Request): Promise<boolean> {
  const secret = req.headers.get("x-cron-secret");
  if (secret) {
    const { data } = await sb.rpc("verify_cron_secret", { p_secret: secret });
    return data === true;
  }
  const auth = req.headers.get("Authorization");
  if (!auth?.startsWith("Bearer ")) return false;
  const { data: u, error } = await sb.auth.getUser(auth.slice(7));
  if (error || !u.user) return false;
  const { data: row } = await sb.from("institutional_access").select("user_id").eq("user_id", u.user.id).eq("is_active", true).maybeSingle();
  return !!row;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  if (!(await authorised(req))) return json(401, { ok: false, error: "UNAUTHORIZED" });
  if (!API_KEY) return json(503, { ok: false, error: "TWELVE_DATA_API_KEY_NOT_CONFIGURED" });

  const body = await req.json().catch(() => ({}));
  const symbol = String(body.symbol ?? "").toUpperCase();
  const interval = String(body.interval ?? "15m");
  const count = Math.min(Math.max(Math.trunc(Number(body.count ?? 200)), 20), 500);
  if (!(symbol in VENDOR_SYMBOL)) return json(400, { ok: false, error: "UNSUPPORTED_SYMBOL", supported: Object.keys(VENDOR_SYMBOL) });
  if (!(interval in INTERVALS)) return json(400, { ok: false, error: "UNSUPPORTED_INTERVAL", supported: Object.keys(INTERVALS) });

  const key = `${symbol}|${interval}`;
  const hit = cache.get(key);
  try {
    let bars: Bar[], cached = false;
    if (hit && Date.now() - hit.at < CACHE_MS && hit.bars.length >= count) { bars = hit.bars; cached = true; }
    else {
      const params = new URLSearchParams({ symbol: VENDOR_SYMBOL[symbol], interval: INTERVALS[interval].vendor, outputsize: String(500), timezone: "UTC", order: "DESC", apikey: API_KEY });
      const r = await fetch(`https://api.twelvedata.com/time_series?${params}`, { signal: AbortSignal.timeout(15000) });
      const payload = await r.json().catch(() => null);
      if (!payload) return json(502, { ok: false, error: "VENDOR_NOT_JSON", http_status: r.status });
      bars = parseTimeSeries(payload).bars;
      cache.set(key, { at: Date.now(), bars });
    }
    const out = bars.slice(-count);
    const last = out[out.length - 1];
    const forming = last ? Date.now() < Date.parse(last.ts) + INTERVALS[interval].ms : false;
    return json(200, { ok: true, symbol, interval, cached, fetched_at: new Date(hit && cached ? hit.at : Date.now()).toISOString(), last_bar_is_forming: forming, bars: out });
  } catch (e) {
    if (e instanceof VendorError) return json(e.code === 429 ? 429 : 502, { ok: false, error: "VENDOR_ERROR", vendor_code: e.code, message: e.message, retry_later: e.code === 429 });
    return json(500, { ok: false, error: "LIVE_CANDLES_FAILED", message: e instanceof Error ? e.message.replace(/apikey=\S+/gi, "apikey=***").slice(0, 120) : "unknown" });
  }
});
