import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { SERIES, availableAt, parseFredObservations } from "./ref.ts";

// FRED reference series: "probe" reports each allow-listed series' metadata without storing anything; "ingest" stores
// observations for one series. Authenticated with the shared cron secret. Dry run by default; idempotent upserts.
// The FRED key is an Edge Function secret (FRED_API_KEY) and never appears in logs or responses.
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const FRED_API_KEY = Deno.env.get("FRED_API_KEY");
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });
const mask = (s: string) => s.replace(/api_key=\w+/gi, "api_key=***").slice(0, 160);

async function fred(path: string, params: Record<string, string>) {
  const q = new URLSearchParams({ ...params, api_key: FRED_API_KEY!, file_type: "json" });
  const r = await fetch(`https://api.stlouisfed.org/fred/${path}?${q}`, { signal: AbortSignal.timeout(30000) });
  const payload = await r.json().catch(() => null);
  if (!r.ok || !payload) throw new Error(`FRED_${r.status}: ${mask(String(payload?.error_message ?? "request failed"))}`);
  return payload;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  const secret = req.headers.get("x-cron-secret");
  if (!secret) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const { data: valid, error: vErr } = await sb.rpc("verify_cron_secret", { p_secret: secret });
  if (vErr) return json(500, { ok: false, error: "SECRET_CHECK_FAILED" });
  if (valid !== true) return json(401, { ok: false, error: "UNAUTHORIZED" });
  if (!FRED_API_KEY) return json(503, { ok: false, error: "FRED_API_KEY_NOT_CONFIGURED" });

  const body = await req.json().catch(() => ({}));
  try {
    if (body.action === "probe") {
      const out: Record<string, unknown>[] = [];
      for (const id of Object.keys(SERIES)) {
        try {
          const s = (await fred("series", { series_id: id })).seriess?.[0] ?? {};
          out.push({ series_id: id, title: s.title, units: s.units, frequency: s.frequency, observation_start: s.observation_start,
            observation_end: s.observation_end, last_updated: s.last_updated, notes: String(s.notes ?? "").slice(0, 400) });
        } catch (e) { out.push({ series_id: id, error: e instanceof Error ? mask(e.message) : "PROBE_FAILED" }); }
      }
      return json(200, { ok: true, action: "probe", stored: false, series: out });
    }

    const id = String(body.series_id ?? "").toUpperCase();
    if (!(id in SERIES)) return json(400, { ok: false, error: "SERIES_NOT_ALLOWED", allowed: Object.keys(SERIES) });
    const start = String(body.start_date ?? "1990-01-01");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(start)) return json(400, { ok: false, error: "INVALID_START_DATE" });
    const dryRun = body.dry_run !== false;

    const meta = (await fred("series", { series_id: id })).seriess?.[0] ?? {};
    const parsed = parseFredObservations(await fred("series/observations", { series_id: id, observation_start: start, sort_order: "asc", limit: "100000" }));
    let upserted = 0;
    if (!dryRun) {
      const { error: mErr } = await sb.schema("market").from("reference_series").upsert({
        series_id: id, provider: "FRED", title: SERIES[id].title, family: SERIES[id].family, units: meta.units ?? null, frequency: meta.frequency ?? null,
        observation_start: meta.observation_start ?? null, provider_last_updated: meta.last_updated ? new Date(String(meta.last_updated).replace(" ", "T").replace(/([+-]\d\d)$/, "$1:00")).toISOString() : null,
        revisable: false, availability_rule: `observation date + ${SERIES[id].lag_days} day(s), 14:00 UTC`, probed_at: new Date().toISOString(),
        metadata: { fred_title: meta.title ?? null, notes: String(meta.notes ?? "").slice(0, 1000), discontinued: SERIES[id].discontinued ?? null,
          licensing: "third-party copyright (CBOE / Moody's / Federal Reserve) redistributed by FRED; research use, no redistribution" },
      }, { onConflict: "series_id" });
      if (mErr) return json(500, { ok: false, error: "SERIES_WRITE_FAILED", database_error_code: mErr.code ?? null });
      const now = new Date().toISOString();
      const rows = parsed.obs.map((o) => ({ series_id: id, obs_date: o.obs_date, value: o.value, available_at: availableAt(o.obs_date, SERIES[id].lag_days), retrieved_at: now }));
      for (let i = 0; i < rows.length; i += 1000) {
        const { error, data } = await sb.schema("market").from("reference_observations").upsert(rows.slice(i, i + 1000), { onConflict: "series_id,obs_date" }).select("obs_date");
        if (error) return json(500, { ok: false, error: "OBSERVATION_WRITE_FAILED", database_error_code: error.code ?? null, rows_upserted_before_failure: upserted });
        upserted += data?.length ?? 0;
      }
    }
    return json(200, { ok: true, dry_run: dryRun, series_id: id, observations: parsed.obs.length, missing_skipped: parsed.missing, upserted,
      first: parsed.obs[0]?.obs_date ?? null, last: parsed.obs[parsed.obs.length - 1]?.obs_date ?? null });
  } catch (e) {
    return json(502, { ok: false, error: "REFERENCE_INGESTION_FAILED", message: e instanceof Error ? mask(e.message) : "unknown" });
  }
});
