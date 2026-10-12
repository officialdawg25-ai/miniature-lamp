import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { CONTRACTS, parseCot } from "./cot.ts";

// CFTC positioning ingestion. Authenticated with the shared cron secret. Dry run by default; writes are idempotent upserts.
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const headers = { "Content-Type": "application/json; charset=utf-8" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });
const FIELDS = "report_date_as_yyyy_mm_dd,cftc_contract_market_code,open_interest_all,lev_money_positions_long,lev_money_positions_short,asset_mgr_positions_long,asset_mgr_positions_short,dealer_positions_long_all,dealer_positions_short_all";

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
  try {
    const { data: src } = await sb.schema("core").from("data_sources").select("id").eq("name", "CFTC Commitments of Traders").eq("active", true).maybeSingle();
    if (!src) return json(500, { ok: false, error: "CFTC_SOURCE_NOT_REGISTERED" });
    const codes = CONTRACTS.map((c) => `'${c.code}'`).join(",");
    const where = encodeURIComponent(`cftc_contract_market_code in(${codes}) AND report_date_as_yyyy_mm_dd >= '${start}T00:00:00.000'`);
    const url = `https://publicreporting.cftc.gov/resource/gpe5-46if.csv?$select=${FIELDS}&$where=${where}&$order=report_date_as_yyyy_mm_dd&$limit=50000`;
    const r = await fetch(url, { signal: AbortSignal.timeout(40000) });
    if (!r.ok) return json(502, { ok: false, error: "CFTC_FETCH_FAILED", http_status: r.status });
    const { rows, rejected } = parseCot(await r.text());
    if (rows.length < 100) return json(422, { ok: false, error: "TOO_FEW_OBSERVATIONS", observations: rows.length });
    const now = new Date().toISOString();
    const payload = rows.map((x) => ({ ...x, source_id: src.id, retrieved_at: now, metadata: { dataset: "gpe5-46if", availability_basis: "report_date_plus_6_days" } }));
    let upserted = 0;
    if (!dryRun) {
      for (let i = 0; i < payload.length; i += 500) {
        const { error, data } = await sb.schema("macro").from("cot_observations").upsert(payload.slice(i, i + 500), { onConflict: "contract_code,report_date" }).select("id");
        if (error) return json(500, { ok: false, error: "COT_WRITE_FAILED", database_error_code: error.code ?? null, rows_upserted_before_failure: upserted });
        upserted += data?.length ?? 0;
      }
    }
    const per = CONTRACTS.map((c) => {
      const xs = rows.filter((x) => x.contract_code === c.code);
      return { currency: c.currency, rows: xs.length, first: xs[0]?.report_date ?? null, latest: xs[xs.length - 1]?.report_date ?? null };
    });
    return json(200, { ok: true, dry_run: dryRun, start_date: start, rows_built: rows.length, rows_upserted: upserted, skipped_rows: rejected, per_currency: per });
  } catch (e) {
    return json(500, { ok: false, error: "COT_INGESTION_FAILED", message: e instanceof Error ? e.message.slice(0, 100) : "unknown" });
  }
});
