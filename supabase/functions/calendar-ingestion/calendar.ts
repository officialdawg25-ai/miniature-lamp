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
