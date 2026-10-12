import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { CalendarError, parseCalendar, parseFaireconomy, type CalendarRow } from "./calendar.ts";

// Economic calendar ingestion. Source 'faireconomy' (default): the free Forex Factory weekly feed, forecast and previous only, no actuals.
// Source 'fmp': Financial Modeling Prep, which returns actuals but needs a paid plan (the free key is refused with HTTP 402). One or two requests per call. Authenticated with the shared cron secret.
// Dry run by default. The vendor key is an Edge Function secret (FMP_API_KEY) and never appears in logs or responses.
// Point-in-time: the database records when each estimate and actual was first seen, so a backtest can never use a value before the platform had it.
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const API_KEY = Deno.env.get("FMP_API_KEY");
const headers = { "Content-Type": "application/json; charset=utf-8" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });
const day = (d: Date) => d.toISOString().slice(0, 10);

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  const secret = req.headers.get("x-cron-secret");
  if (!secret) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const { data: valid, error: vErr } = await sb.rpc("verify_cron_secret", { p_secret: secret });
  if (vErr) return json(500, { ok: false, error: "SECRET_CHECK_FAILED" });
  if (valid !== true) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const body = await req.json().catch(() => ({}));
  const dryRun = body.dry_run !== false;
  const source = String(body.source ?? "faireconomy");
  if (source !== "faireconomy" && source !== "fmp") return json(400, { ok: false, error: "UNSUPPORTED_SOURCE", supported: ["faireconomy", "fmp"] });
  if (source === "fmp" && !API_KEY) return json(503, { ok: false, error: "FMP_API_KEY_NOT_CONFIGURED" });
  const now = new Date();
  const from = String(body.from ?? day(new Date(now.getTime() - 3 * 86400000)));
  const to = String(body.to ?? day(new Date(now.getTime() + 21 * 86400000)));
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to) || from > to) return json(400, { ok: false, error: "INVALID_RANGE" });

  try {
    let rows: CalendarRow[] = [], rejected = 0;
    if (source === "faireconomy") {
      for (const week of ["thisweek", "nextweek"]) {
        const r = await fetch(`https://nfs.faireconomy.media/ff_calendar_${week}.json`, { signal: AbortSignal.timeout(20000), headers: { "User-Agent": "Mozilla/5.0 institutional-ai-calendar" } });
        if (!r.ok) {
          if (week === "nextweek" && r.status === 404) continue; // next week is not published until late in the week
          return json(502, { ok: false, error: "VENDOR_ERROR", http_status: r.status, week });
        }
        const parsed = parseFaireconomy(await r.json().catch(() => null));
        rows = rows.concat(parsed.rows); rejected += parsed.rejected;
      }
    } else {
      const url = `https://financialmodelingprep.com/stable/economic-calendar?from=${from}&to=${to}&apikey=${API_KEY}`;
      const r = await fetch(url, { signal: AbortSignal.timeout(30000) });
      const text = await r.text();
      let payload: unknown = null;
      try { payload = JSON.parse(text); } catch { payload = text.slice(0, 160); }
      if (!r.ok && !Array.isArray(payload)) {
        const msg = typeof payload === "string" ? payload : JSON.stringify(payload).slice(0, 160);
        return json(502, { ok: false, error: "VENDOR_ERROR", http_status: r.status, message: msg.replace(/apikey=\S+/gi, "apikey=***") });
      }
      ({ rows, rejected } = parseCalendar(payload));
    }
    const withEstimate = rows.filter((x) => x.estimate !== null).length, withActual = rows.filter((x) => x.actual !== null).length;
    let upserted = 0;
    if (!dryRun && rows.length) {
      for (let i = 0; i < rows.length; i += 500) {
        const { data, error } = await sb.rpc("macro_upsert_calendar_rows", { p_rows: rows.slice(i, i + 500), p_source: source === "fmp" ? "Financial Modeling Prep" : "Forex Factory feed (Faireconomy)" });
        if (error) return json(500, { ok: false, error: "CALENDAR_WRITE_FAILED", database_error_code: error.code ?? null, rows_upserted_before_failure: upserted });
        upserted += Number(data ?? 0);
      }
    }
    return json(200, {
      ok: true, dry_run: dryRun, source, from, to, rows: rows.length, rejected, with_estimate: withEstimate, with_actual: withActual, upserted,
      countries: [...new Set(rows.map((x) => x.country))].sort(), sample: rows.slice(0, 3),
    });
  } catch (e) {
    if (e instanceof CalendarError) return json(502, { ok: false, error: "VENDOR_ERROR", message: e.message });
    return json(500, { ok: false, error: "CALENDAR_INGESTION_FAILED", message: e instanceof Error ? e.message.replace(/apikey=\S+/gi, "apikey=***").slice(0, 120) : "unknown" });
  }
});
