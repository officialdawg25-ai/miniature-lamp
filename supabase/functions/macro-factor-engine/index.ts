import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import {
  VINTAGE_METHODOLOGY, buildFactorSeries, factorFor as vintageFactorFor, normalizeBias, scoreWindow,
  type ComponentScore,
} from "./vintage.ts";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers });

type Observation = {
  id: string;
  provider: string;
  provider_series_code: string;
  indicator_id: string | null;
  observation_period_end: string | null;
  period_label: string;
  value: number | string | null;
  unit: string | null;
  first_seen_at: string;
  point_in_time_ready: boolean;
};

type Indicator = {
  id: string;
  code: string;
  name: string;
  currency_code: string | null;
  category: string;
  directional_bias: string | null;
  transformation: string | null;
  frequency: string;
  active: boolean;
};

const factorFor = vintageFactorFor;

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
    if (!authorization?.startsWith("Bearer ")) return json(401, { ok: false, code: "UNAUTHORIZED", request_id: requestId });

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await supabase.auth.getUser(authorization.slice(7));
    if (authError || !authData.user) return json(401, { ok: false, code: "UNAUTHORIZED", request_id: requestId });

    const { data: access, error: accessError } = await supabase
      .from("institutional_access").select("user_id")
      .eq("user_id", authData.user.id).eq("is_active", true).maybeSingle();
    if (accessError) return json(500, { ok: false, code: "AUTHORIZATION_CHECK_FAILED", request_id: requestId });
    if (!access) return json(403, { ok: false, code: "INSTITUTIONAL_ACCESS_REQUIRED", request_id: requestId });

    const body = await req.json().catch(() => ({}));
    const persistVintage = body?.persist_vintage === true;

    const { data: indicators, error: indicatorError } = await supabase.schema("macro")
      .from("economic_indicators")
      .select("id,code,name,currency_code,category,directional_bias,transformation,frequency,active")
      .eq("active", true);
    if (indicatorError || !indicators) return json(500, { ok: false, code: "INDICATOR_LOOKUP_FAILED", request_id: requestId });

    const { data: observations, error: observationError } = await supabase.schema("macro")
      .from("provider_observations")
      .select("id,provider,provider_series_code,indicator_id,observation_period_end,period_label,value,unit,first_seen_at,point_in_time_ready")
      .eq("point_in_time_ready", true)
      .not("indicator_id", "is", null)
      .not("value", "is", null)
      .order("observation_period_end", { ascending: true })
      .limit(5000);
    if (observationError || !observations) return json(500, { ok: false, code: "OBSERVATION_LOOKUP_FAILED", request_id: requestId });

    const indicatorById = new Map<string, Indicator>((indicators as Indicator[]).map(i => [i.id, i]));
    const grouped = new Map<string, Observation[]>();
    for (const raw of observations as Observation[]) {
      if (!raw.indicator_id || !raw.point_in_time_ready) continue;
      const indicator = indicatorById.get(raw.indicator_id);
      if (!indicator || !indicator.currency_code) continue;
      const key = indicator.id;
      if (!grouped.has(key)) grouped.set(key, []);
      grouped.get(key)!.push(raw);
    }

    const generated: Record<string, unknown>[] = [];
    const skipped: Record<string, unknown>[] = [];
    const MIN_HISTORY = 12;
    for (const [indicatorId, rows] of grouped) {
      const indicator = indicatorById.get(indicatorId)!;
      const factor = factorFor(indicator.category);
      const rawBias = (indicator.directional_bias ?? "").toLowerCase().trim();
      const bias = [
        "positive", "higher_is_policy_hawkish"].includes(rawBias) ? "positive"
        : ["inverse", "lower_is_growth_bullish"].includes(rawBias) ? "inverse" : "";
      const rawValues = rows
        .map(row => ({ row, value: Number(row.value) }))
        .filter(item => Number.isFinite(item.value) && item.row.observation_period_end)
        .sort((a, b) => String(a.row.observation_period_end).localeCompare(String(b.row.observation_period_end)));
      // CPI/PCE index levels are transformed to period-over-period percentage changes
      // before scoring; scoring raw index levels would confuse price-level drift with inflation.
      const isInflationIndex = factor === "inflation" && /level|index/i.test(indicator.transformation ?? "");
      const values = isInflationIndex
        ? rawValues.slice(1).map((item, index) => ({
            row: item.row,
            value: rawValues[index].value !== 0 ? ((item.value / rawValues[index].value) - 1) * 100 : Number.NaN
          }))
        : rawValues;

      if (!factor) {
        skipped.push({ indicator: indicator.code, reason: "UNSUPPORTED_FACTOR_CATEGORY" });
        continue;
      }
      if (bias !== "positive" && bias !== "inverse") {
        skipped.push({ indicator: indicator.code, reason: "DIRECTIONAL_BIAS_NOT_CONFIGURED" });
        continue;
      }
      if (values.length < MIN_HISTORY) {
        skipped.push({ indicator: indicator.code, reason: "INSUFFICIENT_POINT_IN_TIME_HISTORY", eligible_observations: values.length, minimum_required: MIN_HISTORY });
        continue;
      }

      const latest = values[values.length - 1];
      const history = values.slice(Math.max(0, values.length - 13), values.length - 1).map(x => x.value);
      const mean = history.reduce((sum, value) => sum + value, 0) / history.length;
      const variance = history.reduce((sum, value) => sum + (value - mean) ** 2, 0) / history.length;
      const sd = Math.sqrt(variance);
      if (!Number.isFinite(sd) || sd <= 0) {
        skipped.push({ indicator: indicator.code, reason: "ZERO_OR_INVALID_HISTORICAL_VARIANCE" });
        continue;
      }

      let z = (latest.value - mean) / sd;
      if (bias === "inverse") z *= -1;
      const boundedZ = Math.max(-3, Math.min(3, z));
      const score = Math.max(0, Math.min(100, 50 + (boundedZ / 3) * 50));
      const asOf = latest.row.first_seen_at;
      generated.push({
        currency_code: indicator.currency_code,
        factor,
        as_of: asOf,
        score: Number(score.toFixed(4)),
        raw_value: latest.value,
        zscore: Number(boundedZ.toFixed(6)),
        confidence: Number(Math.min(0.75, values.length / 40).toFixed(4)),
        methodology_version: "macro-factor-v1",
        feature_snapshot: {
          engine: "point_in_time_macro_factor_engine",
          indicator_code: indicator.code,
          indicator_name: indicator.name,
          category: indicator.category,
          unit: latest.row.unit,
          period_label: latest.row.period_label,
          observation_period_end: latest.row.observation_period_end,
          first_seen_at: asOf,
          provider: latest.row.provider,
          provider_series_code: latest.row.provider_series_code,
          history_count: values.length,
          baseline_observations: history.length,
          historical_mean: Number(mean.toFixed(8)),
          historical_stddev: Number(sd.toFixed(8)),
          directional_bias: bias,
          score_mapping: "50 + (clamp(directional_zscore,-3,3)/3)*50",
          limitations: [
            "Factor score is a transparent standardized indicator signal, not a market-return forecast.",
            "Only provider observations explicitly marked point_in_time_ready are eligible.",
            "As-of uses first_seen_at; historical point-in-time availability is not inferred from observation period."
          ]
        }
      });
    }

    if (generated.length) {
      const { error: writeError } = await supabase.schema("macro").from("factor_observations")
        .upsert(generated, { onConflict: "currency_code,factor,as_of,methodology_version" });
      if (writeError) {
        console.error(JSON.stringify({ event: "macro_factor_write_failed", request_id: requestId, db_code: writeError.code ?? null }));
        return json(500, { ok: false, code: "FACTOR_WRITE_FAILED", request_id: requestId });
      }
    }

    // ---- Vintage (as-of) methodology -------------------------------------------------------------
    // Reads macro.pit_alfred_observations (availability established at scheduled_time or better) through
    // macro.pit_event_windows, so each score uses only values known at that release. Dry run unless
    // persist_vintage === true.
    const vintageSkipped: Record<string, unknown>[] = [];
    const perFactor = new Map<string, { currency: string; series: ComponentScore[][]; indicators: string[] }>();
    const { data: codes, error: codesError } = await supabase.schema("macro").rpc("pit_indicator_codes");
    if (codesError) {
      vintageSkipped.push({ reason: "PIT_INDICATOR_LOOKUP_FAILED", db_code: codesError.code ?? null });
    }
    for (const code of ((codes ?? []) as string[])) {
      const indicator = (indicators as Indicator[]).find((i) => i.code === code);
      if (!indicator || !indicator.currency_code) { vintageSkipped.push({ indicator: code, reason: "INDICATOR_NOT_ACTIVE_OR_NO_CURRENCY" }); continue; }
      const factor = vintageFactorFor(indicator.category);
      const bias = normalizeBias(indicator.directional_bias);
      if (!factor) { vintageSkipped.push({ indicator: code, reason: "UNSUPPORTED_FACTOR_CATEGORY" }); continue; }
      if (bias === "") { vintageSkipped.push({ indicator: code, reason: "DIRECTIONAL_BIAS_NOT_CONFIGURED" }); continue; }
      const { data: windows, error: windowError } = await supabase.schema("macro")
        .rpc("pit_event_windows", { p_indicator_code: code, p_window: 18 });
      if (windowError || !windows) { vintageSkipped.push({ indicator: code, reason: "WINDOW_LOOKUP_FAILED", db_code: windowError?.code ?? null }); continue; }
      const isInflationIndex = factor === "inflation" && /level|index/i.test(indicator.transformation ?? "");
      const component: ComponentScore[] = [];
      let insufficient = 0;
      const skipReasons: Record<string, number> = {};
      for (const w of windows as { as_of: string; observation_dates: string[]; vals: (number | string)[] }[]) {
        const result = scoreWindow(w.observation_dates, w.vals.map(Number), bias, isInflationIndex);
        if (result.ok) component.push({ indicator: code, as_of: new Date(w.as_of).toISOString(), score: result.score, zscore: result.zscore, history_count: result.history_count });
        else { insufficient++; skipReasons[result.reason] = (skipReasons[result.reason] ?? 0) + 1; }
      }
      if (!component.length) {
        vintageSkipped.push({ indicator: code, reason: "INSUFFICIENT_POINT_IN_TIME_HISTORY", release_events: (windows as unknown[]).length, events_skipped: insufficient, minimum_observations: MIN_HISTORY + (isInflationIndex ? 2 : 1), skip_reasons: skipReasons });
        continue;
      }
      const key = indicator.currency_code + "|" + factor;
      const entry = perFactor.get(key) ?? { currency: indicator.currency_code, series: [], indicators: [] };
      entry.series.push(component); entry.indicators.push(code);
      perFactor.set(key, entry);
    }

    const vintageRows: Record<string, unknown>[] = [];
    for (const [key, entry] of perFactor) {
      const factor = key.split("|")[1];
      for (const point of buildFactorSeries(entry.series)) {
        vintageRows.push({
          currency_code: entry.currency, factor, as_of: point.as_of, score: point.score, raw_value: null,
          zscore: point.zscore, confidence: point.confidence, methodology_version: VINTAGE_METHODOLOGY,
          feature_snapshot: {
            engine: "vintage_as_of_macro_factor_engine",
            components: point.components,
            availability_basis: "BLS official release schedule (scheduled_time); actual publication time not independently verified",
            limitations: [
              "Standardized indicator signal, not a market-return forecast.",
              "Availability uses scheduled release times; vintage rows are not point_in_time_eligible under the verified-timestamp constraint.",
              "Components older than 100 days are not carried forward."
            ]
          }
        });
      }
    }
    let vintageUpserted = 0;
    if (persistVintage && vintageRows.length) {
      for (let i = 0; i < vintageRows.length; i += 200) {
        const { error: vErr } = await supabase.schema("macro").from("factor_observations")
          .upsert(vintageRows.slice(i, i + 200), { onConflict: "currency_code,factor,as_of,methodology_version" });
        if (vErr) {
          console.error(JSON.stringify({ event: "macro_vintage_write_failed", request_id: requestId, db_code: vErr.code ?? null }));
          return json(500, { ok: false, code: "VINTAGE_FACTOR_WRITE_FAILED", request_id: requestId });
        }
        vintageUpserted += Math.min(200, vintageRows.length - i);
      }
    }

    return json(200, {
      ok: true,
      request_id: requestId,
      engine: "point_in_time_macro_factor_engine",
      methodology_version: "macro-factor-v1",
      eligible_observations_read: observations.length,
      indicators_evaluated: grouped.size,
      factor_observations_upserted: generated.length,
      skipped,
      note: generated.length === 0
        ? "No factor scores were fabricated. Configure indicator directional_bias and ingest sufficient point-in-time-ready history before factors can be generated."
        : "Factor scores are standardized indicator signals, not forecasts. Composite scores and ML outputs remain gated on broader validated coverage.",
      vintage: {
        methodology_version: VINTAGE_METHODOLOGY,
        dry_run: !persistVintage,
        indicators_scored: perFactor.size ? [...perFactor.values()].flatMap((e) => e.indicators) : [],
        factor_points_computed: vintageRows.length,
        factor_observations_upserted: vintageUpserted,
        latest_factor_points: vintageRows.slice(-3).map((r) => ({ factor: r.factor, as_of: r.as_of, score: r.score })),
        skipped: vintageSkipped,
        note: vintageRows.length === 0
          ? "No vintage factor points were produced. Import ALFRED vintages, apply scheduled availability, and ensure at least 13 observations (14 for index levels) are known at a release."
          : (persistVintage ? "Vintage factor points were persisted." : "Preview only: nothing was written. Send persist_vintage=true to store these points."),
      },
    });
  } catch (error) {
    console.error(JSON.stringify({ event: "macro_factor_engine_failed", request_id: requestId, message: error instanceof Error ? error.message.slice(0, 160) : "unknown" }));
    return json(500, { ok: false, code: "MACRO_FACTOR_ENGINE_FAILED", request_id: requestId });
  }
});
