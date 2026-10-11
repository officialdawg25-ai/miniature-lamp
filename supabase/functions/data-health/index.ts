import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Vary": "Origin",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
});

// Datasets reported with exact row counts so the UI can distinguish "empty" from "failed".
const DATASETS: [string, string, string][] = [
  ["macro", "economic_indicators", "Indicator registry"],
  ["macro", "provider_observations", "Raw provider observations"],
  ["macro", "alfred_vintage_observations", "ALFRED vintage evidence"],
  ["macro", "provider_release_calendars", "Release calendars"],
  ["macro", "factor_observations", "Macro factor scores"],
  ["macro", "central_banks", "Central banks"],
  ["macro", "policy_decisions", "Policy decisions"],
  ["market", "yield_observations", "Yield observations"],
  ["intelligence", "regime_states", "Regime states"],
  ["intelligence", "pair_scores", "Instrument research scores"],
];

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "GET") return json({ error: "GET required" }, 405);
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) return json({ error: "Server configuration incomplete" }, 500);

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) return json({ error: "Authentication required" }, 401);

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await admin.auth.getUser(authHeader.slice(7));
    if (userError || !userData.user) return json({ error: "Invalid or expired session" }, 401);

    // Authentication alone is not sufficient: require explicit institutional approval.
    const { data: accessRow, error: accessError } = await admin
      .from("institutional_access").select("user_id,access_role")
      .eq("user_id", userData.user.id).eq("is_active", true).maybeSingle();
    if (accessError) return json({ error: "Authorization check failed" }, 500);
    if (!accessRow) return json({ error: "Institutional access not approved" }, 403);

    const [instrumentsRes, barsCountRes, closesCountRes, obsRes, releasesCountRes, pitCountRes, indicatorsRes, jobsRes, runsRes, scoresRes, yieldSummaryRes, ...datasetRes] = await Promise.all([
      admin.schema("core").from("instruments").select("id,symbol,name").eq("active", true).order("symbol"),
      admin.schema("market").from("price_bars").select("instrument_id", { count: "exact", head: true }),
      admin.schema("market").from("price_closes").select("instrument_id", { count: "exact", head: true }),
      admin.schema("macro").from("provider_observations")
        .select("indicator_id,provider,observation_period_end,retrieved_at,point_in_time_ready").limit(5000),
      admin.schema("macro").from("economic_releases").select("id", { count: "exact", head: true }),
      admin.schema("macro").from("provider_observations").select("id", { count: "exact", head: true }).eq("point_in_time_ready", true),
      admin.schema("macro").from("economic_indicators").select("id,code,name,category,country_code,frequency,directional_bias").eq("active", true).order("code"),
      admin.schema("macro").from("ingestion_jobs")
        .select("provider,job_name,function_slug,cadence,enabled,last_run_at,next_run_at,metadata").order("provider"),
      admin.schema("macro").from("ingestion_runs")
        .select("provider,status,started_at,completed_at,records_seen,records_inserted,records_updated,records_rejected,error_message")
        .order("started_at", { ascending: false }).limit(20),
      admin.schema("intelligence").from("pair_scores")
        .select("instrument_id,as_of,technical_score,composite_score,fundamental_score,explanation")
        .order("as_of", { ascending: false }).limit(200),
      admin.schema("market").rpc("yield_differential_summary"),
      ...DATASETS.map(([schema, table]) => admin.schema(schema).from(table).select("*", { count: "exact", head: true })),
    ]);

    const instruments = instrumentsRes.data ?? [];
    const errors_history: { source: string; message: string }[] = [];
    const instrumentStats = await Promise.all(instruments.map(async (instrument: { id: string; symbol: string }) => {
      const [countRes, latestRes, closeCountRes, latestCloseRes] = await Promise.all([
        admin.schema("market").from("price_bars").select("instrument_id", { count: "exact", head: true }).eq("instrument_id", instrument.id),
        admin.schema("market").from("price_bars").select("ts,close,retrieved_at").eq("instrument_id", instrument.id).order("ts", { ascending: false }).limit(1).maybeSingle(),
        admin.schema("market").from("price_closes").select("instrument_id", { count: "exact", head: true }).eq("instrument_id", instrument.id),
        admin.schema("market").from("price_closes").select("ts,close,retrieved_at,metadata").eq("instrument_id", instrument.id).order("ts", { ascending: false }).limit(1).maybeSingle(),
      ]);
      return {
        symbol: instrument.symbol,
        bars: countRes.count ?? 0,
        latest_bar: latestRes.data?.ts ?? null,
        last_retrieved: latestRes.data?.retrieved_at ?? null,
        last_close: latestRes.data?.close == null ? null : Number(latestRes.data.close),
        close_observations: closeCountRes.count ?? 0,
        latest_close_observation: latestCloseRes.data?.ts ?? null,
        latest_close_retrieved_at: latestCloseRes.data?.retrieved_at ?? null,
        close_only_last_close: latestCloseRes.data?.close == null ? null : Number(latestCloseRes.data.close),
        close_only_metadata: latestCloseRes.data?.metadata ?? null,
        _errors: [
          countRes.error ? { source: "instrument_bar_count:" + instrument.symbol, message: countRes.error.message } : null,
          latestRes.error ? { source: "instrument_latest_bar:" + instrument.symbol, message: latestRes.error.message } : null,
          closeCountRes.error ? { source: "instrument_close_count:" + instrument.symbol, message: closeCountRes.error.message } : null,
          latestCloseRes.error ? { source: "instrument_latest_close:" + instrument.symbol, message: latestCloseRes.error.message } : null,
        ].filter(Boolean),
      };
    }));

    // Recent daily closes for the research charts (instrument pages only; bounded payload).
    const HISTORY_SYMBOLS = new Set(["USDJPY", "XAUUSD"]);
    const history: Record<string, { ts: string; close: number }[]> = {};
    await Promise.all(instruments.filter((i: { symbol: string }) => HISTORY_SYMBOLS.has(i.symbol)).map(async (instrument: { id: string; symbol: string }) => {
      const stats = instrumentStats.find((row) => row.symbol === instrument.symbol);
      const table = stats && stats.bars > 0 ? "price_bars" : "price_closes";
      const { data, error } = await admin.schema("market").from(table).select("ts,close")
        .eq("instrument_id", instrument.id).order("ts", { ascending: false }).limit(260);
      if (error) errors_history.push({ source: "history:" + instrument.symbol, message: error.message });
      else history[instrument.symbol] = (data ?? []).map((r: { ts: string; close: number | string }) => ({ ts: r.ts, close: Number(r.close) })).reverse();
    }));

    const datasets = DATASETS.map(([schema, table, label], i) => ({
      dataset: `${schema}.${table}`,
      label,
      rows: datasetRes[i].error ? null : (datasetRes[i].count ?? 0),
      error: datasetRes[i].error ? datasetRes[i].error!.message : null,
    }));

    const errors = [
      ["instruments", instrumentsRes.error], ["price_bars_count", barsCountRes.error], ["price_closes_count", closesCountRes.error],
      ["provider_observations", obsRes.error], ["economic_releases_count", releasesCountRes.error], ["point_in_time_count", pitCountRes.error],
      ["economic_indicators", indicatorsRes.error], ["ingestion_jobs", jobsRes.error], ["ingestion_runs", runsRes.error], ["pair_scores", scoresRes.error], ["yield_differential_summary", yieldSummaryRes.error],
    ].filter(([, error]) => error).map(([source, error]) => ({ source, message: (error as Error).message }));
    for (const d of datasets) if (d.error) errors.push({ source: "dataset:" + d.dataset, message: d.error });
    for (const row of instrumentStats) errors.push(...row._errors);
    errors.push(...errors_history);

    // Aggregate coverage per indicator from observations (capped read; totals above are exact).
    const observations = obsRes.data ?? [];
    const providerSummary: Record<string, { provider: string; observations: number; latest_retrieved_at: string | null; latest_period: string | null }> = {};
    const coverage = new Map<string, { observations: number; point_in_time_ready: number; first_period: string | null; last_period: string | null }>();
    for (const row of observations) {
      const provider = row.provider ?? "UNKNOWN";
      const p = providerSummary[provider] ??= { provider, observations: 0, latest_retrieved_at: null, latest_period: null };
      p.observations++;
      if (!p.latest_retrieved_at || row.retrieved_at > p.latest_retrieved_at) p.latest_retrieved_at = row.retrieved_at;
      if (!p.latest_period || row.observation_period_end > p.latest_period) p.latest_period = row.observation_period_end;
      if (row.indicator_id) {
        const c = coverage.get(row.indicator_id) ?? { observations: 0, point_in_time_ready: 0, first_period: null, last_period: null };
        c.observations++;
        if (row.point_in_time_ready) c.point_in_time_ready++;
        if (!c.first_period || row.observation_period_end < c.first_period) c.first_period = row.observation_period_end;
        if (!c.last_period || row.observation_period_end > c.last_period) c.last_period = row.observation_period_end;
        coverage.set(row.indicator_id, c);
      }
    }
    const indicatorCoverage = (indicatorsRes.data ?? [])
      .map((ind: { id: string; code: string; name: string; category: string; country_code: string | null; frequency: string; directional_bias: string | null }) => ({
        code: ind.code, name: ind.name, category: ind.category, country: ind.country_code, frequency: ind.frequency,
        directional_bias: ind.directional_bias, ...(coverage.get(ind.id) ?? { observations: 0, point_in_time_ready: 0, first_period: null, last_period: null }),
      }))
      .filter((row: { observations: number }) => row.observations > 0);

    const symbolById = new Map<string, string>(instruments.map((i: { id: string; symbol: string }) => [i.id, i.symbol]));
    const latestScores = new Map<string, Record<string, unknown>>();
    for (const row of scoresRes.data ?? []) {
      const symbol = symbolById.get(row.instrument_id);
      if (!symbol || latestScores.has(symbol)) continue; // rows are ordered newest first
      const explanation = (row.explanation ?? {}) as Record<string, unknown>;
      latestScores.set(symbol, {
        symbol, as_of: row.as_of, technical_score: row.technical_score == null ? null : Number(row.technical_score),
        composite_score: row.composite_score == null ? null : Number(row.composite_score),
        fundamental_score: row.fundamental_score == null ? null : Number(row.fundamental_score),
        engine: explanation.engine ?? null, source: explanation.source ?? null, bars_used: explanation.bars_used ?? null,
        limitations: Array.isArray(explanation.limitations) ? explanation.limitations : [],
      });
    }

    const pitCount = pitCountRes.error ? null : (pitCountRes.count ?? 0);
    const totalObs = datasets.find((d) => d.dataset === "macro.provider_observations")?.rows ?? null;
    return json({
      status: errors.length ? "partial" : "ok",
      generated_at: new Date().toISOString(),
      user: { id: userData.user.id, email: userData.user.email ?? null },
      market: {
        instruments: instruments.length,
        bars_loaded: barsCountRes.count ?? 0,
        close_observations_loaded: closesCountRes.count ?? 0,
        by_symbol: instrumentStats.map(({ _errors, ...row }) => row),
        history,
      },
      macro: {
        observations_loaded: totalObs ?? observations.length,
        releases_loaded: releasesCountRes.count ?? 0,
        by_provider: Object.values(providerSummary),
        indicator_coverage: indicatorCoverage,
        point_in_time_eligible_count: pitCount,
        eligibility_note: pitCount === 0
          ? "No provider observation is marked point-in-time ready. Raw provider values are not used for factor scoring until authoritative release timing and revision lineage are validated."
          : "Only observations explicitly marked point-in-time ready are eligible for factor scoring.",
      },
      datasets,
      yields: yieldSummaryRes.error ? null : yieldSummaryRes.data,
      intelligence: {
        regime_states: datasets.find((d) => d.dataset === "intelligence.regime_states")?.rows ?? 0,
        pair_scores: datasets.find((d) => d.dataset === "intelligence.pair_scores")?.rows ?? 0,
        latest_pair_scores: [...latestScores.values()],
      },
      ingestion: { jobs: jobsRes.data ?? [], recent_runs: runsRes.data ?? [] },
      errors,
    });
  } catch (error) {
    console.error(JSON.stringify({ event: "data_health_failed", message: error instanceof Error ? error.message.slice(0, 160) : "unknown" }));
    return json({ error: "Data health query failed" }, 500);
  }
});
