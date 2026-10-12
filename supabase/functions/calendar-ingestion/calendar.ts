// Pure helpers for economic-calendar ingestion (Financial Modeling Prep). No I/O so they can be unit-tested with plain Node.
export type CalendarRow = {
  event_key: string; scheduled_at: string; country: string; currency: string | null; event: string;
  impact: "high" | "medium" | "low" | null; previous: number | null; estimate: number | null; actual: number | null;
};

export class CalendarError extends Error {
  constructor(message: string) { super(message); }
}

const num = (v: unknown): number | null => {
  if (v === null || v === undefined || v === "") return null;
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : null;
};

const impactOf = (v: unknown): CalendarRow["impact"] => {
  const s = String(v ?? "").toLowerCase();
  return s === "high" || s === "medium" || s === "low" ? s : null;
};

// Vendor times are UTC. A malformed row is dropped and counted, never repaired. An error payload throws with the vendor message (key masked).
export function parseCalendar(payload: unknown): { rows: CalendarRow[]; rejected: number } {
  if (!Array.isArray(payload)) {
    const p = payload as { "Error Message"?: string; message?: string } | string | null;
    const msg = typeof p === "string" ? p : (p?.["Error Message"] ?? p?.message ?? "response is not a list");
    throw new CalendarError(String(msg).replace(/apikey=\S+/gi, "apikey=***").slice(0, 160));
  }
  const byKey = new Map<string, CalendarRow>();
  let rejected = 0;
  for (const r of payload as Record<string, unknown>[]) {
    const m = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2})?)/.exec(String(r?.date ?? ""));
    const event = String(r?.event ?? "").trim(), country = String(r?.country ?? "").trim().toUpperCase();
    if (!m || !event || !country) { rejected++; continue; }
    const hhmmss = m[2].length === 5 ? m[2] + ":00" : m[2];
    const scheduled_at = new Date(`${m[1]}T${hhmmss}Z`).toISOString();
    const event_key = `${scheduled_at}|${country}|${event}`;
    byKey.set(event_key, { event_key, scheduled_at, country, currency: r?.currency ? String(r.currency).toUpperCase() : null, event, impact: impactOf(r?.impact), previous: num(r?.previous), estimate: num(r?.estimate), actual: num(r?.actual) });
  }
  return { rows: [...byKey.values()].sort((a, b) => a.scheduled_at.localeCompare(b.scheduled_at) || a.event.localeCompare(b.event)), rejected };
}

// Surprise is only defined when both the actual and the consensus exist. Unit differences are not guessed: the raw difference is reported.
export function surprise(row: Pick<CalendarRow, "actual" | "estimate">): number | null {
  return row.actual !== null && row.estimate !== null ? Math.round((row.actual - row.estimate) * 1e6) / 1e6 : null;
}

// Forex Factory weekly JSON feed (nfs.faireconomy.media). Rows look like
// { title, country: "USD", date: "2026-10-14T08:30:00-04:00", impact: "High", forecast: "0.3%", previous: "0.2%" }.
// It carries no actual values, so actual stays null and no surprise is ever derived from it.
const SUFFIX: Record<string, number> = { K: 1e3, M: 1e6, B: 1e9, T: 1e12 };
export function parseFeedNumber(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  const m = /^\s*(-?\d+(?:\.\d+)?)\s*([KMBT%]?)\s*$/i.exec(String(v));
  if (!m) return null;
  const mult = m[2] && m[2] !== "%" ? SUFFIX[m[2].toUpperCase()] : 1;
  const n = Number(m[1]) * mult;
  return Number.isFinite(n) ? Math.round(n * 1e9) / 1e9 : null;
}

export function parseFaireconomy(payload: unknown): { rows: CalendarRow[]; rejected: number } {
  if (!Array.isArray(payload)) throw new CalendarError("feed is not a list");
  const byKey = new Map<string, CalendarRow>();
  let rejected = 0;
  for (const r of payload as Record<string, unknown>[]) {
    const t = Date.parse(String(r?.date ?? ""));
    const event = String(r?.title ?? "").trim(), country = String(r?.country ?? "").trim().toUpperCase();
    if (!Number.isFinite(t) || !event || !country) { rejected++; continue; }
    const scheduled_at = new Date(t).toISOString();
    const event_key = `${scheduled_at}|${country}|${event}`;
    byKey.set(event_key, { event_key, scheduled_at, country, currency: country.length === 3 ? country : null, event, impact: impactOf(r?.impact), previous: parseFeedNumber(r?.previous), estimate: parseFeedNumber(r?.forecast), actual: null });
  }
  return { rows: [...byKey.values()].sort((a, b) => a.scheduled_at.localeCompare(b.scheduled_at) || a.event.localeCompare(b.event)), rejected };
}
