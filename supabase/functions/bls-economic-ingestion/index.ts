import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BLS_URL = "https://api.bls.gov/publicAPI/v2/timeseries/data/";
const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
  "Vary": "Origin",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
const err = (e: unknown) => {
  if (e && typeof e === "object") {
    const x = e as any;
    return {
      name: x.name ?? "Error",
      message: x.message ?? JSON.stringify(x),
      code: x.code ?? null,
      details: x.details ?? null,
      hint: x.hint ?? null,
    };
  }
  return { name: "Error", message: String(e), code: null, details: null, hint: null };
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  let runId: string | null = null;
  try {
    const body = await req.json().catch(() => ({}));
    const currentYear = new Date().getUTCFullYear();
    const startYear = String(body.start_year ?? currentYear - 1);
    const endYear = String(body.end_year ?? currentYear);
    const dryRun = body.dry_run !== false;

    if (!/^\d{4}$/.test(startYear) || !/^\d{4}$/.test(endYear) || +startYear > +endYear) {
      return json({ error: "Invalid year range" }, 400);
    }
    // Unregistered BLS API requests support up to 25 series and 10 years per request.
    if (+endYear - +startYear > 9) {
      return json({ error: "BLS year range exceeds the unregistered API limit of 10 years" }, 400);
    }

    const { data: mappings, error: mappingError } = await sb.rpc("bls_validated_series");
    if (mappingError) throw mappingError;
    const valid = mappings ?? [];
    const seriesIds = [...new Set(valid
      .map((m: any) => m.provider_series_code)
      .filter((x: any) => typeof x === "string" && /^[A-Z0-9_#-]+$/.test(x)))];

    if (!seriesIds.length) {
      return json({ dry_run: dryRun, status: "no_validated_series", series: [] });
    }
    if (seriesIds.length > 25) {
      return json({ error: "BLS series count exceeds the unregistered API limit of 25", series_count: seriesIds.length }, 400);
    }

    const { data: rid, error: runError } = await sb.rpc("create_macro_ingestion_run", {
      p_provider: "BLS",
      p_started_at: new Date().toISOString(),
      p_status: dryRun ? "dry_run" : "running",
      p_records_seen: 0,
      p_records_inserted: 0,
      p_records_updated: 0,
      p_records_rejected: 0,
      p_metadata: { start_year: startYear, end_year: endYear, series_count: seriesIds.length, dry_run: dryRun },
    });
    if (runError) throw runError;
    runId = rid as string;

    const response = await fetch(BLS_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify({ seriesid: seriesIds, startyear: startYear, endyear: endYear }),
    });
    const payload = await response.json().catch(() => null);
    if (!response.ok || payload?.status !== "REQUEST_SUCCEEDED") {
      const providerError = {
        http_status: response.status,
        provider_status: payload?.status ?? null,
        provider_message: payload?.message ?? payload,
      };
      throw new Error("BLS provider request failed: " + JSON.stringify(providerError));
    }

    const series = payload?.Results?.series ?? [];
    const observations: any[] = [];
    const preview: any[] = [];
    const seriesResults: any[] = [];
    let seen = 0;
    let skippedMissingValues = 0;

    for (const itemSeries of series) {
      const mapping = valid.find((m: any) => m.provider_series_code === itemSeries.seriesID);
      let seriesSeen = 0;
      let seriesMissingValuesSkipped = 0;
      const providerRows = Array.isArray(itemSeries.data) ? itemSeries.data.length : 0;
      for (const item of (itemSeries.data ?? [])) {
        if (!/^M(0[1-9]|1[0-2])$/.test(String(item.period ?? ""))) continue;
        seen++;
        seriesSeen++;
        const rawValue = item.value;
        const isMissingValue = rawValue == null || String(rawValue).trim() === "" || String(rawValue).trim() === "-";
        if (isMissingValue) {
          skippedMissingValues++;
          seriesMissingValuesSkipped++;
        }
        const observation = {
          series_id: itemSeries.seriesID,
          indicator_id: mapping?.indicator_id ?? null,
          year: item.year,
          period: item.period,
          period_name: item.periodName,
          value: item.value,
          footnotes: item.footnotes ?? [],
        };
        observations.push(observation);
        if (preview.length < 25) preview.push(observation);
      }
      seriesResults.push({ series_id: itemSeries.seriesID, indicator_id: mapping?.indicator_id ?? null, provider_rows: providerRows, monthly_records_seen: seriesSeen, skipped_non_monthly: providerRows - seriesSeen, skipped_missing_values: seriesMissingValuesSkipped });
    }

    if (!dryRun) {
      const { data: writeResult, error: writeError } = await sb.rpc("bls_insert_observations", {
        p_run_id: runId,
        p_observations: observations,
        p_retrieved_at: new Date().toISOString(),
      });
      if (writeError) throw writeError;
      const w = writeResult?.[0] ?? {
        records_seen: seen, records_inserted: 0, records_updated: 0,
        records_rejected: 0, rejection_details: [],
      };
      const inserted = Number(w.records_inserted ?? 0);
      const updated = Number(w.records_updated ?? 0);
      const rejected = Number(w.records_rejected ?? 0);
      const failed = rejected > 0;
      const result = {
        run_id: runId,
        status: failed ? "failed" : "completed",
        start_year: startYear,
        end_year: endYear,
        series_ids: seriesIds,
        records_seen: Number(w.records_seen ?? seen),
        records_inserted: inserted,
        records_updated: updated,
        records_rejected: rejected,
        records_skipped_missing_values: skippedMissingValues,
        rejection_details: w.rejection_details ?? [],
        preview,
      };
      const { error: updateError } = await sb.rpc("update_macro_ingestion_run", {
        p_run_id: runId,
        p_status: result.status,
        p_records_seen: result.records_seen,
        p_records_inserted: inserted,
        p_records_updated: updated,
        p_records_rejected: rejected,
        p_error_message: failed ? "BLS persistence rejected one or more observations" : null,
        p_metadata: {
          start_year: startYear, end_year: endYear, series_count: seriesIds.length,
          series_ids: seriesIds, series_results: seriesResults, dry_run: false, response_status: payload.status,
          records_skipped_missing_values: skippedMissingValues,
          rejection_details: w.rejection_details ?? [],
        },
      });
      if (updateError) throw updateError;
      return json(result, failed ? 500 : 200);
    }

    const { error: updateError } = await sb.rpc("update_macro_ingestion_run", {
      p_run_id: runId,
      p_status: "completed",
      p_records_seen: seen,
      p_records_inserted: 0,
      p_records_updated: 0,
      p_records_rejected: 0,
      p_error_message: null,
      p_metadata: {
        start_year: startYear, end_year: endYear, series_count: seriesIds.length,
        series_ids: seriesIds, series_results: seriesResults, dry_run: true, response_status: payload.status, records_skipped_missing_values: skippedMissingValues, preview,
      },
    });
    if (updateError) throw updateError;
    return json({
      run_id: runId, status: "dry_run", start_year: startYear, end_year: endYear,
      series_ids: seriesIds, series_results: seriesResults, records_seen: seen, records_inserted: 0,
      records_updated: 0, records_rejected: 0, records_skipped_missing_values: skippedMissingValues, preview,
    });
  } catch (e) {
    const x = err(e);
    console.error("BLS ingestion failed", { run_id: runId, ...x });
    if (runId) {
      const { error: updateError } = await sb.rpc("update_macro_ingestion_run", {
        p_run_id: runId,
        p_status: "failed",
        p_records_seen: 0,
        p_records_inserted: 0,
        p_records_updated: 0,
        p_records_rejected: 0,
        p_error_message: x.message,
        p_metadata: { failed_run_id: runId, failure: x },
      });
      if (updateError) console.error("Failed to update BLS ingestion run", updateError);
    }
    return json({ run_id: runId, error: x }, 500);
  }
});