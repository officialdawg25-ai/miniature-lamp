import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { calculateTechnicalMetrics, type CloseBar } from "./technical.ts";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers });
}

Deno.serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return json(405, { ok: false, code: "METHOD_NOT_ALLOWED", request_id: requestId });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return json(500, { ok: false, code: "SERVER_CONFIGURATION_MISSING", request_id: requestId });
    }

    const authorization = req.headers.get("authorization");
    if (!authorization?.startsWith("Bearer ")) {
      return json(401, { ok: false, code: "UNAUTHORIZED", request_id: requestId });
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await supabase.auth.getUser(authorization.slice(7));
    if (authError || !authData.user) {
      return json(401, { ok: false, code: "UNAUTHORIZED", request_id: requestId });
    }

    const { data: access, error: accessError } = await supabase
      .from("institutional_access")
      .select("user_id")
      .eq("user_id", authData.user.id)
      .eq("is_active", true)
      .maybeSingle();
    if (accessError) {
      console.error(JSON.stringify({ event: "intelligence_authorization_check_failed", request_id: requestId }));
      return json(500, { ok: false, code: "AUTHORIZATION_CHECK_FAILED", request_id: requestId });
    }
    if (!access) return json(403, { ok: false, code: "INSTITUTIONAL_ACCESS_REQUIRED", request_id: requestId });

    const { data: instruments, error: instrumentError } = await supabase
      .schema("core").from("instruments")
      .select("id,symbol")
      .eq("active", true)
      .order("symbol", { ascending: true });
    if (instrumentError || !instruments) {
      return json(500, { ok: false, code: "INSTRUMENT_LOOKUP_FAILED", request_id: requestId });
    }

    const generated: Record<string, unknown>[] = [];
    const skipped: { symbol: string; reason: string; bars_available?: number }[] = [];
    let totalBarsRead = 0;

    for (const instrument of instruments) {
      const { data: rows, error: barsError } = await supabase
        .schema("market").from("price_bars")
        .select("ts,close")
        .eq("instrument_id", instrument.id)
        .eq("timeframe", "daily")
        .order("ts", { ascending: false })
        .limit(61);

      if (barsError) {
        console.error(JSON.stringify({ event: "intelligence_market_read_failed", request_id: requestId, symbol: instrument.symbol, db_code: barsError.code ?? null }));
        return json(500, { ok: false, code: "MARKET_DATA_READ_FAILED", request_id: requestId });
      }
      const bars = (rows ?? []) as CloseBar[];
      totalBarsRead += bars.length;
      const metrics = calculateTechnicalMetrics(bars);
      if (!metrics) {
        skipped.push({
          symbol: instrument.symbol,
          reason: bars.length < 21 ? "INSUFFICIENT_DAILY_BARS" : "INVALID_CLOSE_SERIES",
          bars_available: bars.length,
        });
        continue;
      }

      generated.push({
        instrument_id: instrument.id,
        as_of: metrics.asOf,
        technical_score: Number(metrics.technicalScore.toFixed(6)),
        expected_volatility: Number(metrics.annualizedVolatility.toFixed(8)),
        // Composite/fundamental/regime/ML fields intentionally remain NULL until their inputs are validated.
        composite_score: null,
        fundamental_score: null,
        policy_differential: null,
        yield_differential: null,
        intermarket_score: null,
        sentiment_score: null,
        regime_score: null,
        ml_probability_long: null,
        ml_probability_short: null,
        expected_return: null,
        intervention_risk: null,
        model_disagreement: null,
        explanation: {
          engine: "transparent_price_only_baseline",
          methodology_version: "technical-v1",
          source: "market.price_bars",
          timeframe: "daily",
          bars_used: metrics.barsUsed,
          as_of: metrics.asOf,
          momentum_log_return: Number(metrics.momentumLogReturn.toFixed(10)),
          daily_volatility: Number(metrics.dailyVolatility.toFixed(10)),
          annualized_volatility_decimal: Number(metrics.annualizedVolatility.toFixed(8)),
          technical_score_range: [-100, 100],
          technical_score_definition: "100 * tanh(log_return_over_window / (daily_return_stddev * sqrt(number_of_returns)))",
          limitations: [
            "Technical score is a bounded trend-strength statistic, not a probability, target, or calibrated forecast.",
            "Composite score is withheld because macro, policy, yield, sentiment, intermarket and validated ML inputs are not yet complete.",
            "Annualized volatility is a decimal ratio, not a percentage.",
          ],
        },
      });
    }

    if (generated.length > 0) {
      const { error: writeError } = await supabase.schema("intelligence").from("pair_scores")
        .upsert(generated, { onConflict: "instrument_id,as_of" });
      if (writeError) {
        console.error(JSON.stringify({ event: "intelligence_score_write_failed", request_id: requestId, db_code: writeError.code ?? null }));
        return json(500, { ok: false, code: "INTELLIGENCE_WRITE_FAILED", request_id: requestId });
      }
    }

    // Do not invent macro regimes or currency scores: the audited factor_observations table currently has no rows.
    const { count: factorCount, error: factorError } = await supabase
      .schema("macro").from("factor_observations").select("id", { count: "exact", head: true });
    if (factorError) {
      return json(500, { ok: false, code: "MACRO_COVERAGE_CHECK_FAILED", request_id: requestId });
    }

    return json(200, {
      ok: true,
      request_id: requestId,
      engine: "transparent_price_only_baseline",
      methodology_version: "technical-v1",
      instruments_checked: instruments.length,
      market_bars_read: totalBarsRead,
      pair_scores_upserted: generated.length,
      generated_symbols: generated.map((row) => instruments.find((item) => item.id === row.instrument_id)?.symbol),
      skipped,
      macro_factor_observations: factorCount ?? 0,
      regime_states_generated: 0,
      currency_scores_generated: 0,
      ml_predictions_generated: 0,
      limitations: [
        "Only the technical component is generated from observed price bars.",
        "Macro regime, currency composite, pair composite and ML predictions are withheld until validated input coverage and model artifacts exist.",
      ],
    });
  } catch (error) {
    console.error(JSON.stringify({
      event: "intelligence_engine_failed",
      request_id: requestId,
      message: error instanceof Error ? error.message.slice(0, 160) : "unknown",
    }));
    return json(500, { ok: false, code: "INTELLIGENCE_ENGINE_FAILED", request_id: requestId });
  }
});
