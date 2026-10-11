import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { AVAILABILITY_BASIS, FED_SERIES, buildFedRows, daysOld, parseFredObservations, rateChanges, type Obs } from "./policy.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FRED_API_KEY = Deno.env.get("FRED_API_KEY");
const sb = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false, autoRefreshToken: false } });
const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
  "Vary": "Origin",
};
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });

async function fetchFred(seriesId: string, start: string): Promise<{ ok: true; obs: Obs[] } | { ok: false; status: number; error: string }> {
  const params = new URLSearchParams({ series_id: seriesId, api_key: FRED_API_KEY!, file_type: "json", observation_start: start, sort_order: "asc", limit: "100000" });
  const response = await fetch(`https://api.stlouisfed.org/fred/series/observations?${params}`);
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) return { ok: false, status: response.status, error: String(payload?.error_message ?? "FRED_REQUEST_FAILED").slice(0, 120) };
  try { return { ok: true, obs: parseFredObservations(payload) }; }
  catch (e) { return { ok: false, status: response.status, error: e instanceof Error ? e.message : "PARSE_FAILED" }; }
}

// Series metadata only (title, frequency, units, last observation, last update). Used to choose a Japan series from facts.
async function fredSeriesInfo(seriesId: string) {
  const params = new URLSearchParams({ series_id: seriesId, api_key: FRED_API_KEY!, file_type: "json" });
  const response = await fetch(`https://api.stlouisfed.org/fred/series?${params}`, { signal: AbortSignal.timeout(15000) });
  const payload = await response.json().catch(() => ({}));
  const s = payload?.seriess?.[0];
  if (!response.ok || !s) return { series_id: seriesId, http_status: response.status, found: false, error: String(payload?.error_message ?? "NOT_FOUND").slice(0, 100) };
  return { series_id: seriesId, found: true, title: s.title, frequency: s.frequency, units: s.units, observation_start: s.observation_start, observation_end: s.observation_end, last_updated: s.last_updated, notes_excerpt: String(s.notes ?? "").slice(0, 240) };
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
    if (!FRED_API_KEY) return json(503, { ok: false, error: "FRED_API_KEY_NOT_CONFIGURED", required_secret: "FRED_API_KEY", request_id: requestId });

    // Source discovery for the Bank of Japan policy rate. Reads metadata only; nothing is stored.
    if (body.action === "probe_boj") {
      const candidates = ["IRSTCI01JPM156N", "IRSTCB01JPM156N", "INTDSRJPM193N", "IR3TIB01JPM156N", "JPNIRSTCI01STSAM"];
      const fred = await Promise.all(candidates.map((id) => fredSeriesInfo(id).catch((e) => ({ series_id: id, found: false, error: e instanceof Error ? e.message.slice(0, 80) : "FAILED" }))));
      // Bank of Japan time-series search: daily call-rate (policy-target) series.
      let boj: Record<string, unknown> = {};
      try {
        const url = new URL("https://www.stat-search.boj.or.jp/api/v1/getDataLayer");
        url.searchParams.set("format", "json"); url.searchParams.set("lang", "en"); url.searchParams.set("db", "FM01");
        url.searchParams.set("frequency", "D"); url.searchParams.set("layer", "*"); url.searchParams.set("startDate", "202609"); url.searchParams.set("endDate", "202610");
        const response = await fetch(url, { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(15000) });
        const text = await response.text();
        let payload: Record<string, unknown> | null = null;
        try { payload = JSON.parse(text); } catch { /* not JSON */ }
        const raw = payload?.RESULTSET;
        const rows = (Array.isArray(raw) ? raw : raw && typeof raw === "object" ? [raw] : []) as Record<string, unknown>[];
        boj = {
          http_status: response.status, api_status: payload?.STATUS ?? null, message: payload?.MESSAGE ?? null, series_returned: rows.length,
          series: rows.slice(0, 15).map((r) => ({ code: r["SERIES CODE"] ?? r.SERIES_CODE, name: r.NAME_OF_TIME_SERIES ?? r.NAME_OF_TIME_SERIES_EN, unit: r.UNIT, frequency: r.FREQUENCY, start: r.START_OF_THE_TIME_SERIES, end: r.END_OF_THE_TIME_SERIES, last_update: r.LAST_UPDATE })),
          preview_if_not_json: payload ? undefined : text.slice(0, 300),
        };
      } catch (e) { boj = { error: e instanceof Error ? e.message.slice(0, 120) : "FETCH_FAILED" }; }
      return json(200, { ok: true, status: "completed", action: "probe_boj", request_id: requestId, stored: false, fred_candidates: fred, boj_stat_search: boj });
    }

    const market = String(body.market ?? "US").toUpperCase();
    if (market !== "US") return json(400, { ok: false, error: "UNSUPPORTED_MARKET", supported: ["US"], note: "Japan is added after the source probe.", request_id: requestId });
    const dryRun = body.dry_run !== false;
    const start = String(body.start_date ?? "2020-01-01");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(start)) return json(400, { ok: false, error: "INVALID_START_DATE", request_id: requestId });

    const { data: source, error: sourceError } = await sb.schema("core").from("data_sources")
      .select("id").eq("name", "Federal Reserve FRED").eq("active", true).maybeSingle();
    if (sourceError || !source) return json(500, { ok: false, error: "FRED_SOURCE_NOT_REGISTERED", request_id: requestId });
    const { data: bank, error: bankError } = await sb.schema("macro").from("central_banks").select("id").eq("code", "FED").eq("active", true).maybeSingle();
    if (bankError || !bank) return json(500, { ok: false, error: "CENTRAL_BANK_NOT_FOUND", code: "FED", request_id: requestId });

    const [upper, lower] = await Promise.all([fetchFred(FED_SERIES.upper, start), fetchFred(FED_SERIES.lower, start)]);
    const failed = [[FED_SERIES.upper, upper], [FED_SERIES.lower, lower]].filter(([, r]) => !(r as { ok: boolean }).ok);
    if (failed.length) return json(502, { ok: false, error: "FRED_SERIES_FETCH_FAILED", request_id: requestId, failures: failed.map(([id, r]) => ({ series_id: id, ...(r as object) })) });
    const up = (upper as { obs: Obs[] }).obs, lo = (lower as { obs: Obs[] }).obs;
    if (up.length === 0) return json(422, { ok: false, error: "NO_OBSERVATIONS", request_id: requestId });
    const rows = buildFedRows(up, lo, bank.id, source.id, new Date().toISOString());

    let upserted = 0;
    if (!dryRun) {
      for (let i = 0; i < rows.length; i += 500) {
        const { error: writeError, data: written } = await sb.schema("macro").from("policy_rate_observations")
          .upsert(rows.slice(i, i + 500), { onConflict: "central_bank_id,ts" }).select("id");
        if (writeError) {
          console.error(JSON.stringify({ event: "policy_rate_write_failed", request_id: requestId, db_code: writeError.code ?? null }));
          return json(500, { ok: false, error: "POLICY_RATE_WRITE_FAILED", database_error_code: writeError.code ?? null, rows_upserted_before_failure: upserted, request_id: requestId });
        }
        upserted += written?.length ?? 0;
      }
    }
    const latest = up[up.length - 1];
    const warnings: string[] = [];
    const age = daysOld(latest.date, Date.now());
    if (age > 7) warnings.push(`LATEST_FED_DATE_IS_${age}_DAYS_OLD`);
    return json(200, {
      ok: true, status: "completed", market: "US", request_id: requestId, dry_run: dryRun, start_date: start,
      rows_built: rows.length, rows_upserted: upserted, first_date: up[0].date, latest, days_since_latest: age,
      rate_changes: rateChanges(up), availability_basis: AVAILABILITY_BASIS, warnings,
      note: "Federal funds target range (upper bound is the headline rate). Missing values are skipped, never stored as zero. 'rate_changes' lists dates on which the target changed; scheduled meetings that kept the rate unchanged are not in this source.",
    });
  } catch (error) {
    console.error(JSON.stringify({ event: "policy_rate_failed", request_id: requestId, message: error instanceof Error ? error.message.slice(0, 160) : "unknown" }));
    return json(500, { ok: false, status: "failed", request_id: requestId, error: "POLICY_RATE_INGESTION_FAILED" });
  }
});
