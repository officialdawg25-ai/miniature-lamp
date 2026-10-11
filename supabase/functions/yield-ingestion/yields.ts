// Pure helpers for yield ingestion. No I/O and no runtime imports so they can be unit-tested with plain Node.

export type Obs = { date: string; value: number };

export const US_SERIES = { nominal10: "DGS10", nominal2: "DGS2", real10: "DFII10" } as const;
export const AVAILABILITY_BASIS = "conservative_end_of_next_utc_day";

// FRED observations: {"observations":[{"date":"2024-01-02","value":"3.95"}, {"date":"2024-01-01","value":"."}]}
// "." marks a missing value and is dropped, never turned into zero.
export function parseFredObservations(payload: unknown): Obs[] {
  const list = (payload as { observations?: unknown })?.observations;
  if (!Array.isArray(list)) throw new Error("FRED_RESPONSE_HAS_NO_OBSERVATIONS_ARRAY");
  const out: Obs[] = [];
  for (const row of list as { date?: unknown; value?: unknown }[]) {
    const date = String(row?.date ?? "");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) continue;
    const raw = String(row?.value ?? "").trim();
    if (raw === "" || raw === ".") continue;
    const value = Number(raw);
    if (!Number.isFinite(value)) continue;
    out.push({ date, value });
  }
  return out.sort((a, b) => a.date.localeCompare(b.date));
}

// Conservative availability: a value dated D is treated as known from the end of the next UTC day (D+2 00:00Z).
// The published H.15 series normally appears sooner; the extra margin avoids any look-ahead in daily research.
export function availableAt(date: string): string {
  const d = new Date(date + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + 2);
  return d.toISOString();
}

export type YieldRow = {
  market_code: string; tenor_years: number; ts: string; yield: number; real_yield: number | null;
  source_id: string; retrieved_at: string; metadata: Record<string, unknown>;
};

export function buildUsYieldRows(
  series: { nominal10: Obs[]; nominal2: Obs[]; real10: Obs[] },
  sourceId: string,
  retrievedAt: string,
): YieldRow[] {
  const real = new Map(series.real10.map((o) => [o.date, o.value]));
  const rows: YieldRow[] = [];
  for (const o of series.nominal10) {
    const r = real.get(o.date);
    rows.push({
      market_code: "US", tenor_years: 10, ts: o.date + "T00:00:00Z", yield: o.value, real_yield: r ?? null,
      source_id: sourceId, retrieved_at: retrievedAt,
      metadata: {
        provider: "FRED", series_id: US_SERIES.nominal10, real_yield_series_id: r === undefined ? null : US_SERIES.real10,
        units: "percent", availability_basis: AVAILABILITY_BASIS, available_at: availableAt(o.date),
        revisions_assumed_none: true,
      },
    });
  }
  for (const o of series.nominal2) {
    rows.push({
      market_code: "US", tenor_years: 2, ts: o.date + "T00:00:00Z", yield: o.value, real_yield: null,
      source_id: sourceId, retrieved_at: retrievedAt,
      metadata: {
        provider: "FRED", series_id: US_SERIES.nominal2, units: "percent",
        availability_basis: AVAILABILITY_BASIS, available_at: availableAt(o.date), revisions_assumed_none: true,
      },
    });
  }
  return rows;
}

// First lines of a raw CSV for format verification. Nothing is parsed into rows or stored.
export function probeLines(text: string, n = 6, width = 220): string[] {
  return text.split(/\r?\n/).filter((l) => l.length > 0).slice(0, n).map((l) => l.slice(0, width));
}
