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

// ---- Japan Ministry of Finance JGB benchmark yields ---------------------------------------------------------
// Verified format (probe of jgbcme_all.csv): line 1 is a title, line 2 is "Date,1Y,2Y,...,40Y", data rows are
// "YYYY/M/D,v1,v2,..." with "-" for a tenor that is not available on that date. Values are percent.
export const MOF_JGB_URL = "https://www.mof.go.jp/english/policy/jgbs/reference/interest_rate/historical/jgbcme_all.csv";
export const JP_TENORS = [2, 5, 10] as const;
export const MAX_PLAUSIBLE_YIELD = 30;
export const MIN_PLAUSIBLE_YIELD = -2;

export type JgbObs = { date: string; tenor: number; value: number };

export function parseMofJgbCsv(text: string, start: string, tenors: readonly number[] = JP_TENORS): { obs: JgbObs[]; rejected: number; header_found: boolean } {
  const lines = text.replace(/^\uFEFF/, "").split(/\r?\n/);
  const headerIndex = lines.findIndex((l) => /^Date\s*,/i.test(l.trim()));
  if (headerIndex < 0) throw new Error("MOF_JGB_HEADER_NOT_FOUND");
  const header = lines[headerIndex].split(",").map((h) => h.trim());
  const columnFor = new Map<number, number>();
  for (const t of tenors) {
    const idx = header.indexOf(`${t}Y`);
    if (idx < 0) throw new Error(`MOF_JGB_TENOR_COLUMN_MISSING_${t}Y`);
    columnFor.set(t, idx);
  }
  const obs: JgbObs[] = [];
  let rejected = 0;
  for (const line of lines.slice(headerIndex + 1)) {
    if (!line.trim()) continue;
    const cells = line.split(",").map((c) => c.trim());
    const m = /^(\d{4})\/(\d{1,2})\/(\d{1,2})$/.exec(cells[0] ?? "");
    if (!m) { rejected++; continue; }
    const date = `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}`;
    if (date < start) continue;
    for (const [tenor, idx] of columnFor) {
      const raw = cells[idx];
      if (raw === undefined || raw === "" || raw === "-") continue; // not available that day; never turned into zero
      const value = Number(raw);
      if (!Number.isFinite(value) || value < MIN_PLAUSIBLE_YIELD || value > MAX_PLAUSIBLE_YIELD) { rejected++; continue; }
      obs.push({ date, tenor, value });
    }
  }
  obs.sort((a, b) => a.date.localeCompare(b.date) || a.tenor - b.tenor);
  return { obs, rejected, header_found: true };
}

export function buildJpYieldRows(obs: JgbObs[], sourceId: string, retrievedAt: string): YieldRow[] {
  return obs.map((o) => ({
    market_code: "JP", tenor_years: o.tenor, ts: o.date + "T00:00:00Z", yield: o.value, real_yield: null,
    source_id: sourceId, retrieved_at: retrievedAt,
    metadata: {
      provider: "Ministry of Finance Japan", dataset: "JGB benchmark yields (jgbcme_all.csv)", units: "percent",
      availability_basis: AVAILABILITY_BASIS, available_at: availableAt(o.date), revisions_assumed_none: true,
    },
  }));
}

// ---- Source discovery helpers (used by probe_links) ---------------------------------------------------------
// Lists the CSV files an HTML page links to, resolved against the page URL. Only https links are returned.
export function extractCsvLinks(html: string, baseUrl: string, max = 12): string[] {
  const out: string[] = [];
  const re = /href\s*=\s*["']([^"'#]+\.csv)(?:\?[^"']*)?["']/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    try {
      const url = new URL(m[1], baseUrl);
      if (url.protocol !== "https:") continue;
      const href = url.toString();
      if (!out.includes(href)) out.push(href);
    } catch { /* ignore malformed hrefs */ }
    if (out.length >= max) break;
  }
  return out;
}

export function tailLines(text: string, n = 3, width = 200): string[] {
  const lines = text.split(/\r?\n/).filter((l) => l.trim().length > 0);
  return lines.slice(Math.max(0, lines.length - n)).map((l) => l.slice(0, width));
}
