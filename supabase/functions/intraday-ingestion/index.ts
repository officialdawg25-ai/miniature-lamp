import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import LZMA from "npm:lzma@2.3.2";
import { PRICE_SCALE, buildBars, hourUrl, parseTicks, type Bar } from "./ticks.ts";

// Builds 5-minute bars from Dukascopy hourly tick files for one UTC day and a range of hours. Authenticated with the shared cron secret.
// Dry run by default. Idempotent upserts keyed on (instrument, timeframe, bar time). One call handles a few hours to stay inside the CPU limit.
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const headers = { "Content-Type": "application/json; charset=utf-8" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  const secret = req.headers.get("x-cron-secret");
  if (!secret) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const { data: valid, error: vErr } = await sb.rpc("verify_cron_secret", { p_secret: secret });
  if (vErr) return json(500, { ok: false, error: "SECRET_CHECK_FAILED" });
  if (valid !== true) return json(401, { ok: false, error: "UNAUTHORIZED" });

  const body = await req.json().catch(() => ({}));
  const symbol = String(body.symbol ?? "").toUpperCase();
  const date = String(body.date ?? "");
  const h1 = Math.min(Math.max(Number(body.hour_from ?? 0), 0), 23), h2 = Math.min(Math.max(Number(body.hour_to ?? 23), h1), 23);
  const dryRun = body.dry_run !== false;
  if (!(symbol in PRICE_SCALE)) return json(400, { ok: false, error: "UNSUPPORTED_SYMBOL", supported: Object.keys(PRICE_SCALE) });
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(Date.parse(date))) return json(400, { ok: false, error: "INVALID_DATE" });
  if (h2 - h1 > 5) return json(400, { ok: false, error: "TOO_MANY_HOURS", max_hours_per_call: 6 });

  try {
    const { data: inst } = await sb.schema("core").from("instruments").select("id").eq("symbol", symbol).maybeSingle();
    const { data: src } = await sb.schema("core").from("data_sources").select("id").eq("name", "Dukascopy").eq("active", true).maybeSingle();
    if (!inst || !src) return json(500, { ok: false, error: "INSTRUMENT_OR_SOURCE_NOT_REGISTERED" });

    const bars: Bar[] = [];
    let hoursWithData = 0, hoursEmpty = 0, ticksTotal = 0, dropped = 0, trailing = 0;
    for (let h = h1; h <= h2; h++) {
      const r = await fetch(hourUrl(symbol, date, h), { signal: AbortSignal.timeout(20000) });
      if (r.status === 404) { hoursEmpty++; continue; }
      if (!r.ok) return json(502, { ok: false, error: "SOURCE_FETCH_FAILED", http_status: r.status, hour: h });
      const raw = new Uint8Array(await r.arrayBuffer());
      if (raw.length < 14) { hoursEmpty++; continue; }
      const out = LZMA.decompress(raw as unknown as number[]) as unknown as ArrayLike<number>;
      const bytes = new Uint8Array(out.length);
      for (let i = 0; i < out.length; i++) bytes[i] = out[i] & 255;
      const { ticks, trailingBytes } = parseTicks(bytes);
      trailing += trailingBytes;
      if (!ticks.length) { hoursEmpty++; continue; }
      const built = buildBars(Date.parse(date + "T00:00:00Z") + h * 3600000, ticks, PRICE_SCALE[symbol]);
      bars.push(...built.bars); dropped += built.dropped; ticksTotal += ticks.length; hoursWithData++;
    }
    let upserted = 0;
    if (!dryRun && bars.length) {
      const now = new Date().toISOString();
      const rows = bars.map((b) => ({ instrument_id: inst.id, timeframe: "5m", ts: b.ts, open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume, spread: b.spread, source_id: src.id, retrieved_at: now, metadata: { source: "dukascopy_ticks_bid", volume_is: "tick_count", spread_unit: "price" } }));
      for (let i = 0; i < rows.length; i += 500) {
        const { error, data } = await sb.schema("market").from("price_bars").upsert(rows.slice(i, i + 500), { onConflict: "instrument_id,timeframe,ts" }).select("ts");
        if (error) return json(500, { ok: false, error: "BAR_WRITE_FAILED", database_error_code: error.code ?? null, rows_upserted_before_failure: upserted });
        upserted += data?.length ?? 0;
      }
    }
    return json(200, {
      ok: true, dry_run: dryRun, symbol, date, hours: [h1, h2], hours_with_data: hoursWithData, hours_empty: hoursEmpty, ticks: ticksTotal, dropped_ticks: dropped,
      trailing_bytes: trailing, bars_built: bars.length, bars_upserted: upserted, first_bar: bars[0] ?? null, last_bar: bars[bars.length - 1] ?? null,
    });
  } catch (e) {
    return json(500, { ok: false, error: "INTRADAY_INGESTION_FAILED", message: e instanceof Error ? e.message.slice(0, 120) : "unknown" });
  }
});
