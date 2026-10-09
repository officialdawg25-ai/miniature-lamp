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

export function localDateTimeToUtc(value: string, timezone: string): string | null {
  const match = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?$/.exec(value);
  if (!match) return null;
  const [, ys, mos, ds, hs, mis, ss = "00"] = match;
  const [y, mo, d, h, mi, s] = [Number(ys), Number(mos), Number(ds), Number(hs), Number(mis), Number(ss)];
  const wall = new Date(Date.UTC(y, mo - 1, d, h, mi, s));
  if (wall.getUTCFullYear() !== y || wall.getUTCMonth() + 1 !== mo || wall.getUTCDate() !== d ||
      wall.getUTCHours() !== h || wall.getUTCMinutes() !== mi || wall.getUTCSeconds() !== s) return null;
  if (timezone === "UTC" || timezone === "Etc/UTC" || timezone === "GMT") return wall.toISOString();

  const target = Date.UTC(y, mo - 1, d, h, mi, s);
  let guess = target;
  let formatter: Intl.DateTimeFormat;
  try {
    formatter = new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
    });
  } catch {
    return null;
  }
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
      event.DTSTART_TZID = tz ? tz.slice(tz.indexOf("=") + 1) : (/Z$/.test(value) ? "UTC" : "America/New_York");
    }
  }
  return events;
}

export function classify(summary: string): { releaseName: string; prefix: string } | null {
  const s = summary.toLowerCase();
  if (s.includes("employment situation")) return { releaseName: "Employment Situation", prefix: "EMPLOYMENT_SITUATION" };
  if (s.includes("consumer price index")) return { releaseName: "Consumer Price Index", prefix: "CPI" };
  if (s.includes("producer price index")) return { releaseName: "Producer Price Index", prefix: "PPI" };
  if (s.includes("import and export price indexes")) return { releaseName: "U.S. Import and Export Price Indexes", prefix: "IMPORT_EXPORT_PRICE_INDEXES" };
  if (s.includes("job openings and labor turnover survey")) return { releaseName: "Job Openings and Labor Turnover Survey", prefix: "JOLTS" };
  return null;
}

export function getPeriod(summary: string): string | null {
  const m = /\bfor\s+([A-Za-z]+)\s+(\d{4})\s*$/i.exec(summary);
  if (!m) return null;
  const monthNames = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];
  const month = monthNames.indexOf(m[1].toLowerCase()) + 1;
  if (month < 1) return null;
  return `${m[2]}-${String(month).padStart(2, "0")}`;
}
