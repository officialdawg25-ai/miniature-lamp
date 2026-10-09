export function unfoldIcs(text: string): string[] {
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

function normalizeTimezone(timezone: string): string {
  const value = timezone.trim().replace(/^"(.*)"$/, "$1");
  const aliases: Record<string, string> = {
    "US-Eastern": "America/New_York",
    "US/Eastern": "America/New_York",
    "Eastern": "America/New_York",
    "Eastern Standard Time": "America/New_York",
    "US-Central": "America/Chicago",
    "US/Central": "America/Chicago",
    "Central Standard Time": "America/Chicago",
    "US-Mountain": "America/Denver",
    "US/Mountain": "America/Denver",
    "Mountain Standard Time": "America/Denver",
    "US-Pacific": "America/Los_Angeles",
    "US/Pacific": "America/Los_Angeles",
    "Pacific Standard Time": "America/Los_Angeles",
    "GMT": "UTC",
    "Etc/UTC": "UTC",
  };
  return aliases[value] ?? value;
}

export function localDateTimeToUtc(value: string, timezone: string): string | null {
  const match = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?$/.exec(value);
  if (!match) return null;
  const [, ys, mos, ds, hs, mis, ss = "00"] = match;
  const [y, mo, d, h, mi, s] = [Number(ys), Number(mos), Number(ds), Number(hs), Number(mis), Number(ss)];
  const wall = new Date(Date.UTC(y, mo - 1, d, h, mi, s));
  if (wall.getUTCFullYear() !== y || wall.getUTCMonth() + 1 !== mo || wall.getUTCDate() !== d ||
      wall.getUTCHours() !== h || wall.getUTCMinutes() !== mi || wall.getUTCSeconds() !== s) return null;
  const zone = normalizeTimezone(timezone);
  if (zone === "UTC") return wall.toISOString();

  const target = Date.UTC(y, mo - 1, d, h, mi, s);
  let guess = target;
  let formatter: Intl.DateTimeFormat;
  try {
    formatter = new Intl.DateTimeFormat("en-CA", {
      timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
    });
  } catch {
    return null;
  }
  for (let i = 0; i < 6; i++) {
    const partsMap = Object.fromEntries(formatter.formatToParts(new Date(guess)).map(p => [p.type, p.value]));
    const represented = Date.UTC(Number(partsMap.year), Number(partsMap.month) - 1, Number(partsMap.day),
      Number(partsMap.hour), Number(partsMap.minute), Number(partsMap.second));
    const delta = target - represented;
    if (delta === 0) return new Date(guess).toISOString();
    guess += delta;
  }
  return null;
}

export function parseEvents(ics: string): Array<Record<string, string>> {
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
      event.DTSTART_TZID = tz ? tz.slice(tz.indexOf("=") + 1).replace(/^"(.*)"$/, "$1") : (/Z$/.test(value) ? "UTC" : "America/New_York");
    }
  }
  return events;
}

export function classify(summary: string): { releaseName: string; prefix: string; periodLagMonths: number } | null {
  const s = summary.toLowerCase();
  // This is a separate annual/special report, not the monthly Employment Situation release.
  if (s.includes("employment situation of veterans")) return null;
  if (s.includes("employment situation")) return { releaseName: "Employment Situation", prefix: "EMPLOYMENT_SITUATION", periodLagMonths: 1 };
  if (s.includes("consumer price index")) return { releaseName: "Consumer Price Index", prefix: "CPI", periodLagMonths: 1 };
  if (s.includes("producer price index")) return { releaseName: "Producer Price Index", prefix: "PPI", periodLagMonths: 1 };
  if (s.includes("import and export price indexes")) return { releaseName: "U.S. Import and Export Price Indexes", prefix: "IMPORT_EXPORT_PRICE_INDEXES", periodLagMonths: 1 };
  if (s.includes("job openings and labor turnover survey")) return { releaseName: "Job Openings and Labor Turnover Survey", prefix: "JOLTS", periodLagMonths: 2 };
  return null;
}

export function getPeriod(summary: string, releaseDateTime?: string, fallbackLagMonths = 1): string | null {
  const m = /\bfor\s+([A-Za-z]+)\s+(\d{4})\s*$/i.exec(summary);
  const monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];
  if (m) {
    const month = monthNames.indexOf(m[1].toLowerCase()) + 1;
    if (month < 1) return null;
    return `${m[2]}-${String(month).padStart(2, "0")}`;
  }

  // BLS calendar summaries often contain only the release title. Derive the reference
  // month from the scheduled release month using the release series' documented cadence:
  // most monthly reports lag one month; JOLTS typically lags two months.
  const dateMatch = /^(\d{4})(\d{2})(\d{2})T/.exec(releaseDateTime ?? "");
  if (!dateMatch || !Number.isInteger(fallbackLagMonths) || fallbackLagMonths < 0 || fallbackLagMonths > 3) return null;
  const year = Number(dateMatch[1]);
  const month = Number(dateMatch[2]);
  const day = Number(dateMatch[3]);
  const releaseDate = new Date(Date.UTC(year, month - 1, day));
  if (releaseDate.getUTCFullYear() !== year || releaseDate.getUTCMonth() + 1 !== month || releaseDate.getUTCDate() !== day) return null;
  const periodDate = new Date(Date.UTC(year, month - 1 - fallbackLagMonths, 1));
  return `${periodDate.getUTCFullYear()}-${String(periodDate.getUTCMonth() + 1).padStart(2, "0")}`;
}
