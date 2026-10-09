import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BLS_ICS_URL = "https://www.bls.gov/schedule/news_release/bls.ics";
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

function unfoldIcs(text: string): string[] {
  const unfolded: string[] = [];
  for (const line of text.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n")) {
    if (/^[ \t]/.test(line) && unfolded.length) unfolded[unfolded.length - 1] += line.slice(1);
    else unfolded.push(line);
  }
  return unfolded;
}

function unescapeIcs(value: string): string {
  return value.replace(/\\n/gi, " ").replace(/\\,/g, ",").replace(/\\;/g, ";").replace(/\\\\/g, "\\");
}

function localDateTimeToUtc(value: string, timezone: string): string | null {
  const match = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?$/.exec(value);
  if (!match) return null;
  const [, ys, mos, ds, hs, mis, ss = "00"] = match;
  const parts = [Number(ys), Number(mos), Number(ds), Number(hs), Number(mis), Number(ss)];
  const [y, mo, d, h, mi, s] = parts;
  // Validate the wall-clock date before timezone conversion.
  const wall = new Date(Date.UTC(y, mo - 1, d, h, mi, s));
  if (wall.getUTCFullYear() !== y || wall.getUTCMonth() + 1 !== mo || wall.getUTCDate() !== d ||
      wall.getUTCHours() !== h || wall.getUTCMinutes() !== mi || wall.getUTCSeconds() !== s) return null;
  if (timezone === "UTC" || timezone === "Etc/UTC" || timezone === "GMT") return wall.toISOString();

  // Resolve an IANA wall-clock time to UTC by iteratively applying the zone offset.
  const target = Date.UTC(y, mo - 1, d, h, mi, s);
  let guess = target;
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
  });
  for (let i = 0; i < 4; i++) {
    const partsMap = Object.fromEntries(formatter.formatToParts(new Date(guess)).map(p => [p.type, p.value]));
    const represented = Date.UTC(Number(partsMap.year), Number(partsMap.month) - 1, Number(partsMap.day),
      Number(partsMap.hour), Number(partsMap.minute), Number(partsMap.second));
    const delta = target - represented;
    if (delta === 0) return new Date(guess).toISOString();
    guess += delta;
  }
  return null;
}

function parseEvents(ics: string) {
  const lines = unfoldIcs(ics);
  const events: Array<Record<string, string>> = [];
  let event: Record<string, string> | null = null;
  for (const line of lines) {
    if (line === "BEGIN:VEVENT") { event = {}; continue; }
    if (line === "END:VEVENT") { if (event) events.push(event); event = null; continue; }
    if (!event) continue;
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    const lhs = line.slice(0, colon);
    const value = line.slice(colon + 1);
    const [key, ...params] = lhs.split(";");
    const normalizedKey = key.toUpperCase();
    if (normalizedKey === "SUMMARY" || normalizedKey === "UID" || normalizedKey === "URL" || normalizedKey === "DESCRIPTION") {
      event[normalizedKey] = unescapeIcs(value);
    }
    if (normalizedKey === "DTSTART") {
      event.DTSTART = value;
      const tz = params.find(p => p.toUpperCase().startsWith("TZID="));
      event.DTSTART_TZID = tz ? tz.slice(tz.indexOf("=") + 1) : (/Z$/.test(value) ? "UTC" : "America/New_York");
    }
  }
  return events;
}

function classify(summary: string): { releaseName: string; prefix: string } | null {
  const s = summary.toLowerCase();
  if (s.includes("employment situation")) return { releaseName: "Employment Situation", prefix: "EMPLOYMENT_SITUATION" };
  if (s.includes("consumer price index")) return { releaseName: "Consumer Price Index", prefix: "CPI" };
  if (s.includes("producer price index")) return { releaseName: "Producer Price Index", prefix: "PPI" };
  if (s.includes("import and export price indexes")) return { releaseName: "U.S. Import and Export Price Indexes", prefix: "IMPORT_EXPORT_PRICE_INDEXES" };
  if (s.includes("job openings and labor turnover survey")) return { releaseName: "Job Openings and Labor Turnover Survey", prefix: "JOLTS" };
  return null;
}

function getPeriod(summary: string): string | null {
  const m = /\bfor\s+([A-Za-z]+)\s+(\d{4})\s*$/i.exec(summary);
  if (!m) return null;
  const month = new Date(Date.parse(`1 ${m[1]} 2000`)).getMonth() + 1;
  if (!month || Number.isNaN(month)) return null;
  return `${m[2]}-${String(month).padStart(2, "0")}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const dryRun = body.dry_run !== false;
    const response = await fetch(BLS_ICS_URL, { headers: { "Accept": "text/calendar,text/plain;q=0.9,*/*;q=0.8" } });
    if (!response.ok) return json({ error: "BLS official calendar request failed", http_status: response.status }, 502);
    const ics = await response.text();
    if (!ics.includes("BEGIN:VCALENDAR") || !ics.includes("BEGIN:VEVENT")) {
      return json({ error: "BLS calendar response did not look like a valid iCalendar feed" }, 502);
    }

    const retrievedAt = new Date().toISOString();
    const events = parseEvents(ics);
    const candidates = [];
    const rejected: Array<{ summary: string; reason: string }> = [];
    for (const e of events) {
      const summary = e.SUMMARY ?? "";
      const classification = classify(summary);
      if (!classification) continue;
      if (!e.DTSTART) { rejected.push({ summary, reason: "missing DTSTART" }); continue; }
      const startValue = e.DTSTART.replace(/Z$/, "");
      const scheduled = localDateTimeToUtc(startValue, e.DTSTART_TZID ?? "America/New_York");
      if (!scheduled) { rejected.push({ summary, reason: "unparseable or invalid scheduled time" }); continue; }
      const period = getPeriod(summary);
      if (!period) { rejected.push({ summary, reason: "could not parse reference period from official summary" }); continue; }
      candidates.push({
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
          source_timezone: e.DTSTART_TZID ?? "America/New_York",
          source_datetime: e.DTSTART,
          url: e.URL ?? null,
          description: e.DESCRIPTION ?? null,
        },
      });
    }

    // Deduplicate within the feed on the database's actual unique key.
    const unique = new Map<string, typeof candidates[number]>();
    for (const row of candidates) unique.set(`${row.provider}| ${row.release_key}|${row.scheduled_release_time}`, row);
    const rows = [...unique.values()];
    if (!rows.length) return json({ status: "no_supported_events", dry_run: dryRun, events_seen: events.length, records_seen: 0, rejected, source_url: BLS_ICS_URL });

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
      records_skipped: Math.max(0, events.length - rows.length - rejected.length),
      rejected,
      preview: rows.slice(0, 20),
    });
  } catch (e) {
    const err = e as Error;
    return json({ error: "BLS release calendar ingestion failed", message: err?.message ?? String(e) }, 500);
  }
});
