// Pure helpers for Twelve Data time_series responses. No I/O and no runtime imports so they can be unit-tested with plain Node.
export type Bar = { ts: string; open: number; high: number; low: number; close: number };

export const SYMBOLS: Record<string, string> = { USDJPY: "USD/JPY", XAUUSD: "XAU/USD" };

export class VendorError extends Error {
  code: number | null;
  constructor(code: number | null, message: string) { super(message); this.code = code; }
}

// Response: { status: "ok", values: [{ datetime: "2024-01-15 10:00:00", open: "...", ... }] } or { status: "error", code, message }.
// With timezone=UTC the datetime is UTC. Rows that are malformed or violate high >= low are dropped and counted, never repaired.
export function parseTimeSeries(payload: unknown): { bars: Bar[]; rejected: number } {
  const p = payload as { status?: string; code?: number; message?: string; values?: unknown };
  if (p?.status === "error") throw new VendorError(typeof p.code === "number" ? p.code : null, String(p.message ?? "vendor error").replace(/apikey=\S+/gi, "apikey=***").slice(0, 160));
  if (!Array.isArray(p?.values)) throw new VendorError(null, "response has no values array");
  const byTs = new Map<string, Bar>();
  let rejected = 0;
  for (const row of p.values as Record<string, unknown>[]) {
    const dt = String(row?.datetime ?? "");
    // Daily rows carry only a date; that bar is stamped at 00:00 UTC.
    const m = /^(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2}:\d{2}))?$/.exec(dt);
    const [o, h, l, c] = ["open", "high", "low", "close"].map((k) => (row?.[k] === "" || row?.[k] == null ? NaN : Number(row[k])));
    if (!m || ![o, h, l, c].every((x) => Number.isFinite(x) && x > 0) || h < Math.max(o, c, l) || l > Math.min(o, c, h)) { rejected++; continue; }
    const ts = new Date(`${m[1]}T${m[2] ?? "00:00:00"}Z`).toISOString();
    byTs.set(ts, { ts, open: o, high: h, low: l, close: c });
  }
  return { bars: [...byTs.values()].sort((a, b) => a.ts.localeCompare(b.ts)), rejected };
}

export function formatEndDate(iso: string): string {
  return iso.slice(0, 19).replace("T", " ");
}
