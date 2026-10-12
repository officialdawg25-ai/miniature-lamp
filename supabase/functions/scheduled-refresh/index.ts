import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import * as Y from "./yields.ts";
import * as P from "./policy.ts";

// Daily refresh of rates data, called by pg_cron through pg_net. This function has no user session: it is authenticated only by the shared
// secret in the x-cron-secret header, which public.verify_cron_secret checks against the Vault. It refreshes a short recent window (an
// idempotent upsert of the same rows the manual ingestion functions build) and records every run, with a freshness check, in
// market.ingestion_audit. It never touches the trading schema and sends no orders.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FRED_API_KEY = Deno.env.get("FRED_API_KEY");
const sb = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false, autoRefreshToken: false } });
const headers = { "Content-Type": "application/json; charset=utf-8" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });

async function upsert(schema: string, table: string, rows: Record<string, unknown>[], onConflict: string): Promise<number> {
  let n = 0;
  for (let i = 0; i < rows.length; i += 500) {
    const { error, data } = await sb.schema(schema).from(table).upsert(rows.slice(i, i + 500), { onConflict }).select("id");
    if (error) throw new Error(`${table}_WRITE_FAILED_${error.code ?? "UNKNOWN"}`);
    n += data?.length ?? 0;
  }
  return n;
}

async function fetchFred(seriesId: string, start: string): Promise<Y.Obs[]> {
  const params = new URLSearchParams({ series_id: seriesId, api_key: FRED_API_KEY!, file_type: "json", observation_start: start, sort_order: "asc", limit: "100000" });
  const response = await fetch(`https://api.stlouisfed.org/fred/series/observations?${params}`, { signal: AbortSignal.timeout(25000) });
  if (!response.ok) throw new Error(`FRED_${seriesId}_HTTP_${response.status}`);
  return P.parseFredObservations(await response.json());
}

async function sourceId(name: string): Promise<string> {
  const { data, error } = await sb.schema("core").from("data_sources").select("id").eq("name", name).eq("active", true).maybeSingle();
  if (error || !data) throw new Error(`SOURCE_NOT_REGISTERED_${name.replace(/\W+/g, "_")}`);
  return data.id as string;
}

async function bankId(code: string): Promise<string> {
  const { data, error } = await sb.schema("macro").from("central_banks").select("id").eq("code", code).eq("active", true).maybeSingle();
  if (error || !data) throw new Error(`CENTRAL_BANK_NOT_FOUND_${code}`);
  return data.id as string;
}

type Step = { step: string; ok: boolean; rows_upserted?: number; latest?: string | null; days_old?: number | null; stale?: boolean; error?: string };

Deno.serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  const secret = req.headers.get("x-cron-secret");
  if (!secret) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const { data: valid, error: verifyError } = await sb.rpc("verify_cron_secret", { p_secret: secret });
  if (verifyError) return json(500, { ok: false, error: "SECRET_CHECK_FAILED" });
  if (valid !== true) return json(401, { ok: false, error: "UNAUTHORIZED" });
  if (!FRED_API_KEY) return json(503, { ok: false, error: "FRED_API_KEY_NOT_CONFIGURED" });

  const body = await req.json().catch(() => ({}));
  const windowDays = Math.min(Math.max(Math.floor(Number(body.window_days ?? 45)), 10), 400);
  const start = new Date(Date.now() - windowDays * 86400000).toISOString().slice(0, 10);
  const startYm = start.slice(0, 4) + start.slice(5, 7);
  const endYm = new Date().toISOString().slice(0, 4) + new Date().toISOString().slice(5, 7);
  const now = Date.now();
  const steps: Step[] = [];

  const { data: auditRow } = await sb.schema("market").from("ingestion_audit").insert({ request_id: requestId, provider: "scheduled-refresh", status: "running" }).select("id").maybeSingle();

  const freshness = (latest: string | null, maxDays: number): Pick<Step, "latest" | "days_old" | "stale"> => {
    if (!latest) return { latest: null, days_old: null, stale: true };
    const age = P.daysOld(latest, now);
    return { latest, days_old: age, stale: age > maxDays };
  };

  // 1) US Treasury nominal and real yields (FRED)
  try {
    const [n10, n2, r10] = await Promise.all([fetchFred(Y.US_SERIES.nominal10, start), fetchFred(Y.US_SERIES.nominal2, start), fetchFred(Y.US_SERIES.real10, start)]);
    const rows = Y.buildUsYieldRows({ nominal10: n10, nominal2: n2, real10: r10 }, await sourceId("Federal Reserve FRED"), new Date().toISOString());
    const n = await upsert("market", "yield_observations", rows as unknown as Record<string, unknown>[], "market_code,tenor_years,ts");
    steps.push({ step: "us_yields", ok: true, rows_upserted: n, ...freshness(n10.length ? n10[n10.length - 1].date : null, 5) });
  } catch (e) { steps.push({ step: "us_yields", ok: false, error: e instanceof Error ? e.message.slice(0, 120) : "FAILED" }); }

  // 2) Japan JGB yields (Ministry of Finance): historical file plus the current-month file
  try {
    const hist = await fetch(Y.MOF_JGB_URL, { signal: AbortSignal.timeout(30000) });
    if (!hist.ok) throw new Error(`MOF_HISTORICAL_HTTP_${hist.status}`);
    const historical = Y.parseMofJgbCsv(new TextDecoder("utf-8", { fatal: false }).decode(await hist.arrayBuffer()), start, undefined, "jgbcme_all.csv");
    let current: { obs: Y.JgbObs[] } = { obs: [] };
    try {
      const cur = await fetch(Y.MOF_JGB_CURRENT_URL, { signal: AbortSignal.timeout(20000) });
      if (cur.ok) current = Y.parseMofJgbCsv(new TextDecoder("utf-8", { fatal: false }).decode(await cur.arrayBuffer()), start, undefined, "jgbcme.csv");
    } catch { /* the historical file alone is still valid; staleness is reported below */ }
    const merged = Y.mergeJgbObs(historical.obs, current.obs);
    if (!merged.obs.length) throw new Error("MOF_NO_OBSERVATIONS_IN_WINDOW");
    const rows = Y.buildJpYieldRows(merged.obs, await sourceId("Ministry of Finance Japan"), new Date().toISOString());
    const n = await upsert("market", "yield_observations", rows as unknown as Record<string, unknown>[], "market_code,tenor_years,ts");
    steps.push({ step: "jp_yields", ok: true, rows_upserted: n, ...freshness(merged.obs[merged.obs.length - 1].date, 7) });
  } catch (e) { steps.push({ step: "jp_yields", ok: false, error: e instanceof Error ? e.message.slice(0, 120) : "FAILED" }); }

  // 3) Federal Reserve target range (FRED)
  try {
    const [upper, lower] = await Promise.all([fetchFred(P.FED_SERIES.upper, start), fetchFred(P.FED_SERIES.lower, start)]);
    if (!upper.length) throw new Error("FED_NO_OBSERVATIONS_IN_WINDOW");
    const rows = P.buildFedRows(upper, lower, await bankId("FED"), await sourceId("Federal Reserve FRED"), new Date().toISOString());
    const n = await upsert("macro", "policy_rate_observations", rows as unknown as Record<string, unknown>[], "central_bank_id,ts");
    steps.push({ step: "fed_policy_rate", ok: true, rows_upserted: n, ...freshness(upper[upper.length - 1].date, 7) });
  } catch (e) { steps.push({ step: "fed_policy_rate", ok: false, error: e instanceof Error ? e.message.slice(0, 120) : "FAILED" }); }

  // 4) Bank of Japan uncollateralized overnight call rate
  try {
    const all: Y.Obs[] = [];
    let position = 1, pages = 0;
    while (position && pages < 5) {
      const url = new URL("https://www.stat-search.boj.or.jp/api/v1/getDataCode");
      url.searchParams.set("format", "json"); url.searchParams.set("lang", "en"); url.searchParams.set("db", "FM01");
      url.searchParams.set("startDate", startYm); url.searchParams.set("endDate", endYm); url.searchParams.set("code", P.BOJ_SERIES);
      url.searchParams.set("startPosition", String(position));
      const response = await fetch(url, { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(20000) });
      const payload = await response.json().catch(() => null) as Record<string, unknown> | null;
      if (!response.ok || !payload || (payload.STATUS && String(payload.STATUS) !== "200")) throw new Error(`BOJ_HTTP_${response.status}`);
      const parsed = P.parseBojDaily(payload, P.BOJ_SERIES);
      if (!parsed.seriesFound) throw new Error("BOJ_RESPONSE_NOT_RECOGNISED");
      all.push(...parsed.obs); pages++;
      position = parsed.nextPosition ?? 0;
    }
    const merged = [...new Map(all.map((o) => [o.date, o])).values()].sort((a, b) => a.date.localeCompare(b.date));
    if (!merged.length) throw new Error("BOJ_NO_OBSERVATIONS_IN_WINDOW");
    const rows = P.buildBojRows(merged, await bankId("BOJ"), await sourceId("Bank of Japan"), new Date().toISOString());
    const n = await upsert("macro", "policy_rate_observations", rows as unknown as Record<string, unknown>[], "central_bank_id,ts");
    steps.push({ step: "boj_call_rate", ok: true, rows_upserted: n, ...freshness(merged[merged.length - 1].date, 7) });
  } catch (e) { steps.push({ step: "boj_call_rate", ok: false, error: e instanceof Error ? e.message.slice(0, 120) : "FAILED" }); }

  const failed = steps.filter((s) => !s.ok);
  const stale = steps.filter((s) => s.ok && s.stale);
  const total = steps.reduce((a, s) => a + (s.rows_upserted ?? 0), 0);
  const details = { window_days: windowDays, start, steps, failed: failed.map((s) => s.step), stale: stale.map((s) => s.step) };
  if (auditRow?.id) {
    await sb.schema("market").from("ingestion_audit").update({
      status: failed.length ? "failed" : "succeeded", completed_at: new Date().toISOString(), records_processed: total,
      error_code: failed.length ? "STEPS_FAILED" : null, error_stage: failed.length ? failed.map((s) => s.step).join(",") : null,
      instruments: steps.map((s) => s.step), details,
    }).eq("id", auditRow.id);
  }
  console.log(JSON.stringify({ event: "scheduled_refresh", request_id: requestId, failed: details.failed, stale: details.stale, rows: total }));
  return json(200, { ok: failed.length === 0, request_id: requestId, rows_upserted: total, failed: details.failed, stale: details.stale, steps });
});
