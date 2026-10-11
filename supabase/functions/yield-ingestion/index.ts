import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { AVAILABILITY_BASIS, MOF_JGB_URL, US_SERIES, buildJpYieldRows, buildUsYieldRows, parseFredObservations, parseMofJgbCsv, probeLines, type Obs } from "./yields.ts";

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

// Candidate Japan Ministry of Finance JGB yield CSV locations. Probe only: nothing from these is parsed or stored
// until the real header and formats have been inspected from a probe run.
const JGB_PROBE_URLS = [
  "https://www.mof.go.jp/english/policy/jgbs/reference/interest_rate/jgbcm.csv",
  "https://www.mof.go.jp/english/policy/jgbs/reference/interest_rate/historical/jgbcme_all.csv",
];

async function fetchFred(seriesId: string, start: string): Promise<{ ok: true; obs: Obs[] } | { ok: false; status: number; error: string }> {
  const params = new URLSearchParams({ series_id: seriesId, api_key: FRED_API_KEY!, file_type: "json", observation_start: start, sort_order: "asc", limit: "100000" });
  const response = await fetch(`https://api.stlouisfed.org/fred/series/observations?${params}`);
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) return { ok: false, status: response.status, error: String(payload?.error_message ?? "FRED_REQUEST_FAILED").slice(0, 120) };
  try { return { ok: true, obs: parseFredObservations(payload) }; }
  catch (e) { return { ok: false, status: response.status, error: e instanceof Error ? e.message : "PARSE_FAILED" }; }
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

    if (body.action === "probe_jgb") {
      const results: Record<string, unknown>[] = [];
      for (const url of JGB_PROBE_URLS) {
        try {
          const response = await fetch(url, { signal: AbortSignal.timeout(15000) });
          const bytes = new Uint8Array(await response.arrayBuffer());
          const text = new TextDecoder("utf-8", { fatal: false }).decode(bytes.slice(0, 4000));
          results.push({ url, http_status: response.status, content_type: response.headers.get("content-type"), bytes: bytes.length, preview: probeLines(text) });
        } catch (e) {
          results.push({ url, error: e instanceof Error ? e.message.slice(0, 120) : "FETCH_FAILED" });
        }
      }
      return json(200, { ok: true, status: "completed", action: "probe_jgb", request_id: requestId, stored: false, results });
    }

    const dryRun = body.dry_run !== false;
    const start = String(body.start_date ?? "2021-01-01");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(start) || start < "2000-01-01" || start > new Date().toISOString().slice(0, 10)) {
      return json(400, { ok: false, error: "INVALID_START_DATE", request_id: requestId });
    }

    if (body.market === "JP") {
      const { data: jpSource, error: jpSourceError } = await sb.schema("core").from("data_sources")
        .select("id").eq("name", "Ministry of Finance Japan").eq("active", true).maybeSingle();
      if (jpSourceError || !jpSource) return json(500, { ok: false, error: "MOF_SOURCE_NOT_REGISTERED", request_id: requestId });
      const response = await fetch(MOF_JGB_URL, { signal: AbortSignal.timeout(25000) });
      if (!response.ok) return json(502, { ok: false, error: "MOF_JGB_FETCH_FAILED", http_status: response.status, request_id: requestId });
      const text = new TextDecoder("utf-8", { fatal: false }).decode(await response.arrayBuffer());
      let parsed;
      try { parsed = parseMofJgbCsv(text, start); }
      catch (e) { return json(502, { ok: false, error: e instanceof Error ? e.message : "MOF_JGB_PARSE_FAILED", request_id: requestId }); }
      if (!parsed.obs.length) return json(502, { ok: false, error: "MOF_JGB_NO_OBSERVATIONS_IN_RANGE", request_id: requestId });
      const jpRows = buildJpYieldRows(parsed.obs, jpSource.id, new Date().toISOString());
      let jpUpserted = 0;
      if (!dryRun) {
        for (let i = 0; i < jpRows.length; i += 500) {
          const { error: writeError, data: written } = await sb.schema("market").from("yield_observations")
            .upsert(jpRows.slice(i, i + 500), { onConflict: "market_code,tenor_years,ts" }).select("id");
          if (writeError) {
            console.error(JSON.stringify({ event: "jp_yield_write_failed", request_id: requestId, db_code: writeError.code ?? null }));
            return json(500, { ok: false, error: "YIELD_WRITE_FAILED", database_error_code: writeError.code ?? null, rows_upserted_before_failure: jpUpserted, request_id: requestId });
          }
          jpUpserted += written?.length ?? 0;
        }
      }
      const byTenor: Record<string, unknown> = {};
      for (const t of [2, 5, 10]) {
        const rowsT = parsed.obs.filter((o) => o.tenor === t);
        byTenor[`${t}Y`] = { observations: rowsT.length, first: rowsT[0]?.date ?? null, latest: rowsT.length ? rowsT[rowsT.length - 1] : null };
      }
      const latestDate = parsed.obs[parsed.obs.length - 1].date;
      return json(200, {
        ok: true, status: "completed", market: "JP", request_id: requestId, dry_run: dryRun, start_date: start,
        rows_built: jpRows.length, rows_upserted: jpUpserted, rejected_cells: parsed.rejected,
        latest_date: latestDate, days_since_latest: Math.floor((Date.now() - Date.parse(latestDate + "T00:00:00Z")) / 86400000),
        tenors: byTenor, availability_basis: AVAILABILITY_BASIS,
        note: "Japan JGB benchmark yields (2Y, 5Y, 10Y) from the Ministry of Finance. Missing '-' cells are skipped, never stored as zero.",
      });
    }
    if (!FRED_API_KEY) return json(503, { ok: false, error: "FRED_API_KEY_NOT_CONFIGURED", required_secret: "FRED_API_KEY", request_id: requestId });

    const { data: source, error: sourceError } = await sb.schema("core").from("data_sources")
      .select("id").eq("name", "Federal Reserve FRED").eq("active", true).maybeSingle();
    if (sourceError || !source) return json(500, { ok: false, error: "FRED_SOURCE_NOT_REGISTERED", request_id: requestId });

    const [n10, n2, r10] = await Promise.all([fetchFred(US_SERIES.nominal10, start), fetchFred(US_SERIES.nominal2, start), fetchFred(US_SERIES.real10, start)]);
    const failed = [[US_SERIES.nominal10, n10], [US_SERIES.nominal2, n2], [US_SERIES.real10, r10]].filter(([, r]) => !(r as { ok: boolean }).ok);
    if (failed.length) {
      // Nothing is stored when any series fails: a partially updated curve would misstate the yield curve.
      return json(502, { ok: false, error: "FRED_SERIES_FETCH_FAILED", request_id: requestId, dry_run: dryRun,
        failures: failed.map(([id, r]) => ({ series_id: id, ...(r as object) })) });
    }
    const series = { nominal10: (n10 as { obs: Obs[] }).obs, nominal2: (n2 as { obs: Obs[] }).obs, real10: (r10 as { obs: Obs[] }).obs };
    const rows = buildUsYieldRows(series, source.id, new Date().toISOString());

    let upserted = 0;
    if (!dryRun) {
      for (let i = 0; i < rows.length; i += 500) {
        const { error: writeError, data: written } = await sb.schema("market").from("yield_observations")
          .upsert(rows.slice(i, i + 500), { onConflict: "market_code,tenor_years,ts" }).select("id");
        if (writeError) {
          console.error(JSON.stringify({ event: "yield_write_failed", request_id: requestId, db_code: writeError.code ?? null }));
          return json(500, { ok: false, error: "YIELD_WRITE_FAILED", database_error_code: writeError.code ?? null, rows_upserted_before_failure: upserted, request_id: requestId });
        }
        upserted += written?.length ?? 0;
      }
    }
    const last = (o: Obs[]) => (o.length ? o[o.length - 1] : null);
    return json(200, {
      ok: true, status: "completed", request_id: requestId, dry_run: dryRun, start_date: start,
      rows_built: rows.length, rows_upserted: upserted,
      series: {
        [US_SERIES.nominal10]: { observations: series.nominal10.length, latest: last(series.nominal10) },
        [US_SERIES.nominal2]: { observations: series.nominal2.length, latest: last(series.nominal2) },
        [US_SERIES.real10]: { observations: series.real10.length, latest: last(series.real10) },
      },
      availability_basis: AVAILABILITY_BASIS,
      note: "US yields only. Japan JGB yields are not ingested until the Ministry of Finance CSV format has been verified with probe_jgb. A yield differential cannot be computed yet.",
    });
  } catch (error) {
    return json(500, { ok: false, status: "failed", request_id: requestId, error: String(error instanceof Error ? error.message : error).slice(0, 160) });
  }
});
