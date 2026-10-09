import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { normalizeProviderBar } from "./validation.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

function respond(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: cors });
}

Deno.serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return respond(405, { ok: false, code: "METHOD_NOT_ALLOWED", request_id: requestId });

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const apiKey = Deno.env.get("TWELVE_DATA_API_KEY");
    if (!url || !serviceKey) return respond(500, { ok: false, code: "SERVER_CONFIGURATION_MISSING", request_id: requestId });
    if (!apiKey) return respond(503, { ok: false, code: "PROVIDER_KEY_MISSING", provider: "Twelve Data", request_id: requestId });

    const auth = req.headers.get("authorization");
    if (!auth?.startsWith("Bearer ")) return respond(401, { ok: false, code: "UNAUTHORIZED", request_id: requestId });

    const sb = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: authData, error: authError } = await sb.auth.getUser(auth.slice(7));
    if (authError || !authData.user) return respond(401, { ok: false, code: "UNAUTHORIZED", request_id: requestId });

    const { data: access, error: accessError } = await sb.from("institutional_access")
      .select("user_id").eq("user_id", authData.user.id).eq("is_active", true).maybeSingle();
    if (accessError) return respond(500, { ok: false, code: "AUTHORIZATION_CHECK_FAILED", request_id: requestId });
    if (!access) return respond(403, { ok: false, code: "INSTITUTIONAL_ACCESS_REQUIRED", request_id: requestId });

    const { data: instrument, error: instrumentError } = await sb.schema("core").from("instruments")
      .select("id,symbol").eq("symbol", "XAUUSD").eq("active", true).maybeSingle();
    if (instrumentError) return respond(500, { ok: false, code: "INSTRUMENT_LOOKUP_FAILED", request_id: requestId });
    if (!instrument) return respond(422, { ok: false, code: "XAUUSD_INSTRUMENT_NOT_REGISTERED", request_id: requestId });

    const { data: source, error: sourceError } = await sb.schema("core").from("data_sources")
      .select("id").eq("name", "Twelve Data").eq("active", true).maybeSingle();
    if (sourceError) return respond(500, { ok: false, code: "PROVIDER_REGISTRY_LOOKUP_FAILED", request_id: requestId });
    if (!source) return respond(422, { ok: false, code: "TWELVE_DATA_SOURCE_NOT_REGISTERED", request_id: requestId });

    const endpoint = new URL("https://api.twelvedata.com/time_series");
    endpoint.searchParams.set("symbol", "XAU/USD");
    endpoint.searchParams.set("interval", "1day");
    endpoint.searchParams.set("outputsize", "5000");
    endpoint.searchParams.set("format", "JSON");
    endpoint.searchParams.set("apikey", apiKey);

    const response = await fetch(endpoint, { headers: { Accept: "application/json" } });
    if (!response.ok) return respond(502, { ok: false, code: "PROVIDER_HTTP_ERROR", http_status: response.status, request_id: requestId });
    const payload = await response.json();
    if (payload?.status === "error" || !Array.isArray(payload?.values)) {
      console.error(JSON.stringify({ event: "xauusd_provider_rejected", request_id: requestId, provider_code: payload?.code ?? null }));
      return respond(502, { ok: false, code: "PROVIDER_SERIES_UNAVAILABLE", request_id: requestId });
    }

    const rows: Record<string, unknown>[] = [];
    let rejected = 0;
    for (const bar of payload.values) {
      const normalized = normalizeProviderBar(bar);
      if (!normalized) {
        rejected++;
        continue;
      }
      rows.push({
        instrument_id: instrument.id, timeframe: "daily", ts: normalized.date + "T00:00:00Z",
        open: normalized.open, high: normalized.high, low: normalized.low, close: normalized.close,
        volume: normalized.volume, spread: null, source_id: source.id,
        metadata: { provider: "twelve_data", provider_symbol: "XAU/USD", interval: "1day", request_id: requestId },
      });
    }
    if (rows.length === 0) return respond(502, { ok: false, code: "NO_VALID_BARS", provider_rows: payload.values.length, rejected, request_id: requestId });

    // Provider order is newest-first; write in bounded chunks and rely on the natural key for idempotency.
    let written = 0;
    for (let i = 0; i < rows.length; i += 500) {
      const { error } = await sb.schema("market").from("price_bars")
        .upsert(rows.slice(i, i + 500), { onConflict: "instrument_id,timeframe,ts" });
      if (error) {
        console.error(JSON.stringify({ event: "xauusd_database_write_failed", request_id: requestId, db_code: error.code ?? null }));
        return respond(500, { ok: false, code: "DATABASE_WRITE_FAILED", request_id: requestId });
      }
      written += Math.min(500, rows.length - i);
    }

    const sortedDates = rows.map(r => String(r.ts)).sort();
    return respond(200, {
      ok: true, request_id: requestId, symbol: "XAUUSD", provider: "Twelve Data",
      timeframe: "daily", provider_rows: payload.values.length, valid_rows: written,
      rejected_rows: rejected, earliest_bar: sortedDates[0], latest_bar: sortedDates[sortedDates.length - 1],
      caveat: "Provider daily bars are timestamped at UTC midnight as session labels; this is not an exact exchange close timestamp.",
    });
  } catch (error) {
    console.error(JSON.stringify({ event: "xauusd_ingestion_failed", request_id: requestId, message: error instanceof Error ? error.message.slice(0, 160) : "unknown" }));
    return respond(500, { ok: false, code: "INGESTION_FAILED", request_id: requestId });
  }
});
