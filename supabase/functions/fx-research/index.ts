import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { buildPanel, evaluate, type Raw, type StrategyId } from "./fx.ts";

// Runs one pre-registered G8 FX portfolio test on the stored daily panel and returns the full result. Authenticated with the shared cron secret.
// Research only: it reads data and optionally stores the run against a ledger hypothesis; it places no orders and changes no status.
const CODE_VERSION = "fx-research-v1";
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const headers = { "Content-Type": "application/json; charset=utf-8" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });
const STRATEGIES: StrategyId[] = ["carry", "trend", "carry_trend", "carry_vol"];

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  const secret = req.headers.get("x-cron-secret");
  if (!secret) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const { data: valid, error: vErr } = await sb.rpc("verify_cron_secret", { p_secret: secret });
  if (vErr) return json(500, { ok: false, error: "SECRET_CHECK_FAILED" });
  if (valid !== true) return json(401, { ok: false, error: "UNAUTHORIZED" });

  const body = await req.json().catch(() => ({}));
  const strategy = String(body.strategy ?? "") as StrategyId;
  if (!STRATEGIES.includes(strategy)) return json(400, { ok: false, error: "UNSUPPORTED_STRATEGY", supported: STRATEGIES });
  const reps = Math.min(Math.max(Math.trunc(Number(body.reps ?? 500)), 50), 2000);
  const params = { cost_bp: Number(body.cost_bp ?? 2), haircut_annual: Number(body.haircut_annual ?? 0.005), family: Math.trunc(Number(body.family ?? 6)), reps, seed: Math.trunc(Number(body.seed ?? 20261013)) };
  const persistKey = body.persist === true ? String(body.hypothesis_key ?? "") : "";

  try {
    const { data: raw, error } = await sb.rpc("research_fx_panel");
    if (error || !raw) return json(500, { ok: false, error: "PANEL_UNAVAILABLE", message: error?.message?.slice(0, 100) ?? "empty" });
    const panel = buildPanel(raw as Raw);
    const result = evaluate(panel, strategy, { costBp: params.cost_bp, haircut: params.haircut_annual, reps, seed: params.seed, family: params.family });
    let stored: string | null = null;
    if (persistKey) {
      const { data: h } = await sb.schema("intelligence").from("research_hypotheses").select("id").eq("key", persistKey).maybeSingle();
      if (!h) return json(404, { ok: false, error: "HYPOTHESIS_NOT_FOUND", result });
      const dataSummary = { first_date: panel.dates[0], last_date: panel.dates[panel.dates.length - 1], days: panel.dates.length };
      const { data: saved, error: e2 } = await sb.schema("intelligence").from("backtest_runs").insert({ code_version: CODE_VERSION, symbol: "G8", params: { strategy, ...params }, data_summary: dataSummary, result, hypothesis_id: h.id }).select("id").single();
      if (e2) return json(500, { ok: false, error: "RUN_NOT_STORED", message: e2.message.slice(0, 100), result });
      stored = saved.id;
    }
    return json(200, { ok: true, code_version: CODE_VERSION, params, stored_run_id: stored, result });
  } catch (e) {
    return json(500, { ok: false, error: "FX_RESEARCH_FAILED", message: e instanceof Error ? e.message.slice(0, 120) : "unknown" });
  }
});
