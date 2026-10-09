import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { classify, getPeriod, localDateTimeToUtc, parseEvents } from "./calendar-parser.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BLS_ICS_URL = "https://www.bls.gov/schedule/news_release/bls.ics";
const BLS_SOURCE_ID = "e70d35d5-a4b2-4336-b4b2-3312bf51cd25";
const sb = createClient(SUPABASE_URL, SERVICE_ROLE);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
  "Vary": "Origin",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const dryRun = body.dry_run !== false;
    const response = await fetch(BLS_ICS_URL, {
      method: "GET",
      redirect: "follow",
      signal: AbortSignal.timeout(20000),
      headers: {
        "Accept": "text/calendar, text/plain;q=0.9, */*;q=0.8",
        "User-Agent": "Mozilla/5.0 (compatible; InstitutionalMacroCalendar/1.0; +https://www.bls.gov/)",
        "Referer": "https://www.bls.gov/schedule/",
      },
    });
    if (!response.ok) {
      return json({
        error: "BLS official calendar request failed",
        http_status: response.status,
        source_url: BLS_ICS_URL,
        diagnostic: "The official endpoint refused the request; no calendar rows were written.",
      }, 502);
    }
    const ics = await response.text();
    if (!ics.includes("BEGIN:VCALENDAR") || !ics.includes("BEGIN:VEVENT")) {
      return json({ error: "BLS calendar response did not look like a valid iCalendar feed", content_type: response.headers.get("content-type"), source_url: BLS_ICS_URL }, 502);
    }

    const retrievedAt = new Date().toISOString();
    const events = parseEvents(ics);
    const candidates = [];
    const rejected: Array<{ summary: string; reason: string; source_datetime?: string | null; source_timezone?: string | null }> = [];
    let unsupportedEventsSkipped = 0;
    for (const e of events) {
      const summary = e.SUMMARY ?? "";
      const classification = classify(summary);
      if (!classification) { unsupportedEventsSkipped++; continue; }
      if (!e.DTSTART) { rejected.push({ summary, reason: "missing DTSTART", source_datetime: null, source_timezone: e.DTSTART_TZID ?? null }); continue; }
      const startValue = e.DTSTART.replace(/Z$/, "");
      const timezone = e.DTSTART_TZID ?? "America/New_York";
      const scheduled = localDateTimeToUtc(startValue, timezone);
      if (!scheduled) {
        rejected.push({ summary, reason: "unparseable or invalid scheduled time", source_datetime: e.DTSTART, source_timezone: timezone });
        continue;
      }
      const explicitPeriod = getPeriod(summary);
      const period = explicitPeriod ?? getPeriod(summary, startValue, classification.periodLagMonths);
      if (!period) {
        rejected.push({ summary, reason: "could not derive a valid reference period", source_datetime: e.DTSTART, source_timezone: timezone });
        continue;
      }
      candidates.push({
        source_id: BLS_SOURCE_ID,
        provider: "BLS",
        release_name: classification.releaseName,
        release_key: `${classification.prefix}|${period}`,
        scheduled_release_time: scheduled,
        period_label: period,
        retrieved_at: retrievedAt,
        raw_payload: {
          source: "BLS official release calendar ICS",
          source_url: BLS_ICS_URL,
          uid: e.UID ?? null,
          summary,
          source_timezone: timezone,
          source_datetime: e.DTSTART,
          period_derivation: explicitPeriod ? "explicit_summary" : "inferred_from_release_month_lag",
          release_month_lag: explicitPeriod ? null : classification.periodLagMonths,
          url: e.URL ?? null,
          description: e.DESCRIPTION ?? null,
        },
      });
    }

    const unique = new Map<string, typeof candidates[number]>();
    for (const row of candidates) unique.set(`${row.provider}|${row.release_key}|${row.scheduled_release_time}`, row);
    const rows = [...unique.values()];
    if (!rows.length) {
      return json({
        status: "no_supported_events",
        dry_run: dryRun,
        events_seen: events.length,
        records_seen: 0,
        records_rejected: rejected.length,
        rejected: rejected.slice(0, 20),
        source_url: BLS_ICS_URL,
        records_written: 0,
        diagnostic: "No calendar rows were written. Verify supported event titles and reference-period derivation.",
      });
    }

    let insertedOrUpdated = 0;
    if (!dryRun) {
      const { data, error } = await sb.schema("macro").from("provider_release_calendars")
        .upsert(rows, { onConflict: "provider,release_key,scheduled_release_time" })
        .select("id");
      if (error) throw error;
      insertedOrUpdated = data?.length ?? 0;
    }

    return json({
      status: "completed",
      dry_run: dryRun,
      source_url: BLS_ICS_URL,
      events_seen: events.length,
      records_seen: rows.length,
      records_rejected: rejected.length,
      records_written: insertedOrUpdated,
      records_skipped: unsupportedEventsSkipped,
      unsupported_events_skipped: unsupportedEventsSkipped,
      rejected: rejected.slice(0, 20),
      preview: rows.slice(0, 20),
    });
  } catch (e) {
    const err = e as Error;
    return json({ error: "BLS release calendar ingestion failed", message: err?.message ?? String(e), records_written: 0 }, 500);
  }
});