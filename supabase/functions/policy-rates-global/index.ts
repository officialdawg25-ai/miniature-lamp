import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { BANKS, buildRows, daysOld, parseBisPolicyRates, type Bank, type Obs } from "./global.ts";

// Policy-rate ingestion for ECB, BoE, RBA, RBNZ, BoC and SNB. Authenticated with the shared cron secret (same as scheduled-refresh).
// Defaults to a dry run. Writes are idempotent upserts keyed on (central bank, day).
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const FRED_API_KEY = Deno.env.get("FRED_API_KEY");
const headers = { "Content-Type": "application/json; charset=utf-8" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });

async function fredObs(series: string, start: string): Promise<Obs[]> {
  const p = new URLSearchParams({ series_id: series, api_key: FRED_API_KEY!, file_type: "json", observation_start: start, sort_order: "asc", limit: "100000" });
  const r = await fetch(`https://api.stlouisfed.org/fred/series/observations?${p}`, { signal: AbortSignal.timeout(30000) });
  const payload = await r.json().catch(() => ({}));
  if (!r.ok || !Array.isArray(payload?.observations)) throw new Error(`FRED_${r.status}`);
  const out: Obs[] = [];
  for (const o of payload.observations as { date: string; value: string }[]) {
    const v = Number(o.value);
    if (/^\d{4}-\d{2}-\d{2}$/.test(o.date) && o.value !== "." && o.value !== "" && Number.isFinite(v)) out.push({ date: o.date, value: v });
  }
  return out;
}

async function bisObs(bank: Bank, start: string): Promise<{ obs: Obs[]; rejected: number }> {
  const url = `https://stats.bis.org/api/v2/data/dataflow/BIS/WS_CBPOL/1.0/${bank.series.replace("WS_CBPOL.", "")}?format=csv&detail=dataonly&startPeriod=${start}`;
  const r = await fetch(url, { signal: AbortSignal.timeout(40000) });
  if (!r.ok) throw new Error(`BIS_${r.status}`);
  const parsed = parseBisPolicyRates(await r.text(), bank.area!);
  return { obs: parsed.obs.filter((o) => o.date >= start), rejected: parsed.rejected };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  const secret = req.headers.get("x-cron-secret");
  if (!secret) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const { data: valid, error: vErr } = await sb.rpc("verify_cron_secret", { p_secret: secret });
  if (vErr) return json(500, { ok: false, error: "SECRET_CHECK_FAILED" });
  if (valid !== true) return json(401, { ok: false, error: "UNAUTHORIZED" });

  const body = await req.json().catch(() => ({}));
  const dryRun = body.dry_run !== false;
  const start = String(body.start_date ?? "2008-01-01");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(start)) return json(400, { ok: false, error: "INVALID_START_DATE" });
  const wanted = Array.isArray(body.banks) ? new Set(body.banks.map(String)) : null;
  const banks = BANKS.filter((b) => !wanted || wanted.has(b.code));
  const sources: Record<string, string> = {};
  for (const name of ["Bank for International Settlements", "Federal Reserve FRED"]) {
    const { data } = await sb.schema("core").from("data_sources").select("id").eq("name", name).eq("active", true).maybeSingle();
    if (data) sources[name] = data.id;
  }
  const results: Record<string, unknown>[] = [];
  for (const bank of banks) {
    try {
      const { data: cb } = await sb.schema("macro").from("central_banks").select("id").eq("code", bank.code).eq("active", true).maybeSingle();
      const srcName = bank.source === "BIS" ? "Bank for International Settlements" : "Federal Reserve FRED";
      if (!cb || !sources[srcName]) { results.push({ bank: bank.code, ok: false, error: "BANK_OR_SOURCE_NOT_REGISTERED" }); continue; }
      let obs: Obs[]; let rejected = 0;
      if (bank.source === "FRED") {
        if (!FRED_API_KEY) { results.push({ bank: bank.code, ok: false, error: "FRED_API_KEY_NOT_CONFIGURED" }); continue; }
        obs = await fredObs(bank.series, start);
      } else { const b = await bisObs(bank, start); obs = b.obs; rejected = b.rejected; }
      if (obs.length < 100) { results.push({ bank: bank.code, ok: false, error: "TOO_FEW_OBSERVATIONS", observations: obs.length }); continue; }
      const rows = buildRows(obs, cb.id, sources[srcName], bank.series, new Date().toISOString(), bank.source, bank.definition);
      let upserted = 0;
      if (!dryRun) {
        for (let i = 0; i < rows.length; i += 1000) {
          const { error, data } = await sb.schema("macro").from("policy_rate_observations").upsert(rows.slice(i, i + 1000), { onConflict: "central_bank_id,ts" }).select("id");
          if (error) throw new Error(`WRITE_${error.code ?? "FAILED"}`);
          upserted += data?.length ?? 0;
        }
      }
      let changes = 0;
      for (let i = 1; i < obs.length; i++) if (obs[i].value !== obs[i - 1].value) changes++;
      const latest = obs[obs.length - 1];
      results.push({
        bank: bank.code, ok: true, source: bank.source, series: bank.series, rows_built: rows.length, rows_upserted: upserted,
        first: obs[0], latest, days_old: daysOld(latest.date, Date.now()), rate_changes: changes,
        min: Math.min(...obs.map((o) => o.value)), max: Math.max(...obs.map((o) => o.value)), skipped_cells: rejected,
      });
    } catch (e) { results.push({ bank: bank.code, ok: false, error: e instanceof Error ? e.message.slice(0, 100) : "FAILED" }); }
  }
  return json(200, { ok: results.every((r) => r.ok), dry_run: dryRun, start_date: start, results });
});
