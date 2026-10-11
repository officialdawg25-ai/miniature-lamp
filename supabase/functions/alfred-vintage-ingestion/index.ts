import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

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
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers });

type SeriesConfig = { indicator_code: string; alfred_series_id: string; bls_series_code: string; bls_archive_url: string; release_match: "cpi" | "employment" };
const ALLOWED: SeriesConfig[] = [
  { indicator_code: "US_UNEMPLOYMENT", alfred_series_id: "UNRATE", bls_series_code: "LNS14000000", bls_archive_url: "https://www.bls.gov/bls/news-release/empsit.htm", release_match: "employment" },
  { indicator_code: "US_CPI_HEADLINE", alfred_series_id: "CPIAUCSL", bls_series_code: "CUSR0000SA0", bls_archive_url: "https://www.bls.gov/bls/news-release/cpi.htm", release_match: "cpi" },
  { indicator_code: "US_CPI_CORE", alfred_series_id: "CPILFESL", bls_series_code: "CUSR0000SA0L1E", bls_archive_url: "https://www.bls.gov/bls/news-release/cpi.htm", release_match: "cpi" },
];

function calendarMatches(config: SeriesConfig, rows: any[], vintageDate: string) {
  const day = vintageDate.slice(0, 10);
  const match = rows.find((r) => {
    const releaseDate = String(r.scheduled_release_time).slice(0, 10);
    const title = String(r.release_name ?? "").toLowerCase();
    const categoryMatch = config.release_match === "cpi"
      ? title.includes("consumer price") || title.includes("cpi")
      : title.includes("employment situation");
    return releaseDate === day && categoryMatch;
  });
  return match ?? null;
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
    const dryRun = body.dry_run !== false;
    if (body.action === "promote_availability") {
      // Records BLS-scheduled availability on already-imported vintage rows. Never marks rows point-in-time eligible.
      const { data: promoted, error: promoteError } = await sb.schema("macro")
        .rpc("promote_alfred_scheduled_availability", { p_dry_run: dryRun });
      if (promoteError) return json(500, { ok: false, status: "failed", error: "AVAILABILITY_PROMOTION_FAILED", database_error_code: promoteError.code ?? null, request_id: requestId });
      return json(200, { ok: true, status: "completed", action: "promote_availability", request_id: requestId, ...promoted });
    }
    const startYear = Number(body.start_year ?? 2021);
    const endYear = Number(body.end_year ?? new Date().getUTCFullYear());
    const requestedCodes = Array.isArray(body.indicator_codes) && body.indicator_codes.length
      ? [...new Set(body.indicator_codes.map((x: unknown) => String(x)))]
      : ALLOWED.map((x) => x.indicator_code);
    if (!Number.isInteger(startYear) || !Number.isInteger(endYear) || startYear < 2000 ||
        endYear > new Date().getUTCFullYear() || startYear > endYear || endYear - startYear > 10) {
      return json(400, { ok: false, error: "INVALID_YEAR_RANGE", request_id: requestId });
    }
    const configs = requestedCodes.map((code: string) => ALLOWED.find((x) => x.indicator_code === code));
    if (configs.some((x: SeriesConfig | undefined) => !x) || configs.length > 3) {
      return json(400, { ok: false, error: "INDICATOR_NOT_ALLOWLISTED", allowed_indicator_codes: ALLOWED.map(x => x.indicator_code), request_id: requestId });
    }
    if (!FRED_API_KEY) return json(503, { ok: false, error: "FRED_API_KEY_NOT_CONFIGURED", required_secret: "FRED_API_KEY", request_id: requestId });
    const since = `${startYear}-01-01`;
    const today = new Date().toISOString().slice(0, 10);
    const requestedEnd = `${endYear}-12-31`;
    const through = requestedEnd < today ? requestedEnd : today;
    const diagnostics: Record<string, unknown>[] = [];
    let rowsFetched = 0;
    let rowsUpserted = 0;
    let calendarMatched = 0;
    let calendarUnmatched = 0;
    const batchSize = 500;

    for (const config of configs as SeriesConfig[]) {
      const { data: indicator, error: indicatorError } = await sb.schema("macro").from("economic_indicators")
        .select("id,code").eq("code", config.indicator_code).eq("active", true).maybeSingle();
      if (indicatorError) {
        diagnostics.push({ indicator_code: config.indicator_code, status: "indicator_lookup_failed", database_error_code: indicatorError.code ?? null });
        continue;
      }
      if (!indicator) {
        diagnostics.push({ indicator_code: config.indicator_code, status: "indicator_not_configured" });
        continue;
      }
      const { data: mapping, error: mappingError } = await sb.schema("macro").from("provider_mappings")
        .select("id,provider_series_code").eq("indicator_id", indicator.id).eq("provider", "BLS")
        .eq("provider_series_code", config.bls_series_code).eq("active", true).maybeSingle();
      if (mappingError) {
        diagnostics.push({ indicator_code: config.indicator_code, status: "mapping_lookup_failed", expected_bls_series_code: config.bls_series_code, database_error_code: mappingError.code ?? null });
        continue;
      }
      if (!mapping) {
        diagnostics.push({ indicator_code: config.indicator_code, status: "bls_series_mapping_not_verified", expected_bls_series_code: config.bls_series_code });
        continue;
      }
      const vintagesUrl = new URL("https://api.stlouisfed.org/fred/series/vintagedates");
      vintagesUrl.search = new URLSearchParams({
        series_id: config.alfred_series_id,
        api_key: FRED_API_KEY,
        file_type: "json",
        realtime_start: since,
        realtime_end: through,
        limit: "10000",
        sort_order: "asc",
      }).toString();
      const vintagesResponse = await fetch(vintagesUrl);
      const vintagesPayload = await vintagesResponse.json().catch(() => ({}));
      if (!vintagesResponse.ok || !Array.isArray(vintagesPayload.vintage_dates)) {
        diagnostics.push({
          indicator_code: config.indicator_code,
          status: "alfred_vintage_dates_fetch_failed",
          http_status: vintagesResponse.status,
          provider_error: vintagesPayload.error_message ?? null,
        });
        continue;
      }
      const vintageDates: string[] = [...new Set<string>(vintagesPayload.vintage_dates
        .map((d: unknown) => String(d))
        .filter((d: string) => /^\d{4}-\d{2}-\d{2}$/.test(d) && d >= since && d <= through))];
      const { data: calendarRows, error: calendarError } = await sb.schema("macro").from("provider_release_calendars")
        .select("id,release_name,release_key,scheduled_release_time,raw_payload")
        .eq("provider", "BLS")
        .gte("scheduled_release_time", `${startYear}-01-01T00:00:00Z`)
        .lte("scheduled_release_time", `${endYear}-12-31T23:59:59Z`);
      if (calendarError) throw calendarError;
      const records: Record<string, unknown>[] = [];
      let seriesMatched = 0, seriesUnmatched = 0, rejectedInvalidDates = 0, rejectedVintageOutOfRange = 0, rejectedInvalidValue = 0, snapshotsFetched = 0, snapshotFetchFailures = 0;
      const sampleSourceObservations: Record<string, unknown>[] = [];
      const snapshotFailureSamples: Record<string, unknown>[] = [];
      const snapshotRawSamples: Record<string, unknown>[] = [];
      // output_type=2 returns one row per observation date with SERIESID_YYYYMMDD columns per vintage.
      const params = new URLSearchParams({
        series_id: config.alfred_series_id, api_key: FRED_API_KEY, file_type: "json", output_type: "2",
        realtime_start: since, realtime_end: through, observation_start: since,
        observation_end: today, limit: "100000", sort_order: "asc",
      });
      const response = await fetch(`https://api.stlouisfed.org/fred/series/observations?${params.toString()}`);
      const snapshot = await response.json().catch(() => ({}));
      if (!response.ok || !Array.isArray(snapshot.observations)) {
        snapshotFetchFailures++;
        snapshotFailureSamples.push({ http_status: response.status, provider_error: snapshot.error_message ?? snapshot.error ?? null, response_has_observations_array: Array.isArray(snapshot.observations), output_type: 2 });
      } else {
        snapshotsFetched = 1;
        const allowedVintageDates = new Set(vintageDates);
        const vintageColumnPattern = new RegExp(`^${config.alfred_series_id}_(\\d{8}|\\d{4}-\\d{2}-\\d{2})$`);
        for (const obs of snapshot.observations) {
          const observationDate = String(obs.date ?? "");
          if (!/^\d{4}-\d{2}-\d{2}$/.test(observationDate)) { rejectedInvalidDates++; continue; }
          if (snapshotRawSamples.length < 2) snapshotRawSamples.push({ observation_date: observationDate, keys: Object.keys(obs).slice(0, 12), vintage_column_count: Object.keys(obs).filter((key) => vintageColumnPattern.test(key)).length });
          for (const [key, rawVintageValue] of Object.entries(obs)) {
            const columnMatch = key.match(vintageColumnPattern);
            if (!columnMatch) continue;
            const rawVintage = columnMatch[1];
            const vintageDate = rawVintage.includes("-") ? rawVintage : `${rawVintage.slice(0,4)}-${rawVintage.slice(4,6)}-${rawVintage.slice(6,8)}`;
            if (!/^\d{4}-\d{2}-\d{2}$/.test(vintageDate)) { rejectedInvalidDates++; continue; }
            if (!allowedVintageDates.has(vintageDate) || vintageDate < since || vintageDate > today) { rejectedVintageOutOfRange++; continue; }
            const rawValue = String(rawVintageValue ?? "");
            const value = rawValue === "." || rawValue === "" ? null : Number(rawValue);
            if (value !== null && !Number.isFinite(value)) { rejectedInvalidValue++; continue; }
            const matched = calendarMatches(config, calendarRows ?? [], vintageDate);
            const matchedId = matched?.id ?? null;
            if (matchedId) seriesMatched++; else seriesUnmatched++;
            if (sampleSourceObservations.length < 3) sampleSourceObservations.push({ observation_date: observationDate, vintage_date: vintageDate, value: rawVintageValue ?? null, source_column: key });
            records.push({
              indicator_id: indicator.id, indicator_code: config.indicator_code, alfred_series_id: config.alfred_series_id, bls_series_code: config.bls_series_code,
              observation_date: observationDate, observation_value: value, vintage_start: vintageDate, vintage_end: vintageDate,
              alfred_realtime_start: vintageDate, alfred_realtime_end: vintageDate, source_provider: "ALFRED",
              source_available_date: vintageDate, source_available_at: null,
              availability_time_precision: "date_only",
              availability_evidence_url: null,
              availability_validated_at: null,
              source_observation_url: `https://api.stlouisfed.org/fred/series/observations?series_id=${config.alfred_series_id}&output_type=2&realtime_start=${startYear}-01-01&realtime_end=${through}&observation_start=${startYear}-01-01&observation_end=${today}`,
              bls_archive_url: config.bls_archive_url, matched_bls_calendar_id: matchedId,
              evidence_status: value === null ? "value_missing" : (matchedId ? "calendar_date_matched" : "unmatched_calendar_date"),
              point_in_time_eligible: false,
              validation_notes: {
                evidence_type: "alfred_output_type_2_vintage_column_plus_bls_release_calendar",
                alfred_vintage_date: vintageDate, alfred_observation_realtime_start: null, alfred_observation_realtime_end: null,
                alfred_response_column: key, bls_calendar_date_match: Boolean(matchedId), bls_release_name: matched?.release_name ?? null,
                warning: "ALFRED vintage date is a historical data snapshot date; BLS calendar matching is corroborative only. Row remains ineligible pending controlled release-time validation."
              },
              retrieved_at: new Date().toISOString()
            });
          }
        }
      }
      rowsFetched += records.length;
      calendarMatched += seriesMatched;
      calendarUnmatched += seriesUnmatched;
      if (!dryRun) {
        for (let i = 0; i < records.length; i += batchSize) {
          const batch = records.slice(i, i + batchSize);
          const { error: writeError, data: written } = await sb.schema("macro").from("alfred_vintage_observations")
            .upsert(batch, { onConflict: "indicator_code,alfred_series_id,observation_date,vintage_start,vintage_end" })
            .select("id");
          if (writeError) throw writeError;
          rowsUpserted += written?.length ?? batch.length;
        }
      }
      diagnostics.push({
        indicator_code: config.indicator_code,
        alfred_series_id: config.alfred_series_id,
        bls_series_code: config.bls_series_code,
        status: "parsed",
        vintage_dates_returned: vintagesPayload.vintage_dates.length,
        vintage_dates_in_requested_range: vintageDates.length,
        snapshots_fetched: snapshotsFetched,
        vintage_dates_observed_in_snapshot: [...new Set(records.map((r) => String(r.vintage_start)))].length,
        snapshot_output_type: 2,
        provider_observation_count: Number(snapshot.count ?? snapshot.observations?.length ?? 0),
        provider_limit: snapshot.limit ?? null,
        vintage_columns_parsed: records.length,
        sample_raw_observations: snapshotRawSamples,
        snapshot_fetch_failures: snapshotFetchFailures,
        snapshot_failure_samples: snapshotFailureSamples,
        source_observations_returned: records.length,
        eligible_for_review: records.length,
        rejected_invalid_dates: rejectedInvalidDates,
        rejected_vintage_out_of_range: rejectedVintageOutOfRange,
        rejected_invalid_values: rejectedInvalidValue,
        sample_source_observations: sampleSourceObservations,
        calendar_date_matched: seriesMatched,
        calendar_date_unmatched: seriesUnmatched,
      });
    }
    return json(200, {
      ok: true,
      status: "completed",
      request_id: requestId,
      dry_run: dryRun,
      start_year: startYear,
      end_year: endYear,
      rows_fetched: rowsFetched,
      rows_upserted: rowsUpserted,
      calendar_date_matched: calendarMatched,
      calendar_date_unmatched: calendarUnmatched,
      point_in_time_eligible_rows_written: 0,
      diagnostics,
      warning: "ALFRED realtime periods preserve vintage evidence; BLS calendar date matching is corroborative, not proof of the exact data release timestamp. All imported rows remain point_in_time_eligible=false pending controlled validation.",
    });
  } catch (error) {
    return json(500, { ok: false, status: "failed", request_id: requestId, error: String(error instanceof Error ? error.message : error) });
  }
});
