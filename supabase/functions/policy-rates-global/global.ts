// Pure helpers for the G8 policy-rate ingestion. No I/O and no runtime imports so they can be unit-tested with plain Node.
export type Obs = { date: string; value: number };

// BIS central bank policy rates (dataflow WS_CBPOL), daily, one country per request. Fields are quoted and may contain commas and
// line breaks, so the file is parsed as CSV rather than split on lines.
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [], field = "", inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else inQuotes = false; }
      else field += c;
    } else if (c === '"') inQuotes = true;
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field); field = "";
      if (row.length > 1 || row[0] !== "") rows.push(row);
      row = [];
    } else field += c;
  }
  if (field !== "" || row.length) { row.push(field); rows.push(row); }
  return rows;
}

export function parseBisPolicyRates(csv: string, area: string): { obs: Obs[]; rejected: number } {
  const rows = parseCsv(csv);
  if (!rows.length) throw new Error("BIS_EMPTY_RESPONSE");
  const head = rows[0];
  const ti = head.indexOf("TIME_PERIOD"), vi = head.indexOf("OBS_VALUE"), ai = head.indexOf("REF_AREA");
  if (ti < 0 || vi < 0 || ai < 0) throw new Error("BIS_UNEXPECTED_COLUMNS");
  const byDate = new Map<string, number>();
  let rejected = 0;
  for (const r of rows.slice(1)) {
    if (r[ai] !== area) { rejected++; continue; }
    const date = r[ti];
    const raw = (r[vi] ?? "").trim();
    const value = Number(raw);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || raw === "" || !Number.isFinite(value)) { rejected++; continue; }
    byDate.set(date, value);
  }
  return { obs: [...byDate.entries()].map(([date, value]) => ({ date, value })).sort((a, b) => a.date.localeCompare(b.date)), rejected };
}

// A rate dated D counts as known from the end of D (D+1 00:00Z): the same rule as the Fed series, never earlier than the effective date.
export function availableAt(date: string): string {
  const d = new Date(date + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString();
}

export type Row = {
  central_bank_id: string; ts: string; rate: number; rate_lower: null; series_id: string; available_at: string;
  source_id: string; retrieved_at: string; metadata: Record<string, unknown>;
};

export function buildRows(obs: Obs[], centralBankId: string, sourceId: string, seriesId: string, retrievedAt: string, provider: string, definition: string): Row[] {
  return obs.map((o) => ({
    central_bank_id: centralBankId, ts: o.date + "T00:00:00Z", rate: o.value, rate_lower: null, series_id: seriesId,
    available_at: availableAt(o.date), source_id: sourceId, retrieved_at: retrievedAt,
    metadata: { provider, series_id: seriesId, units: "percent per annum", availability_basis: "end_of_effective_utc_day", definition },
  }));
}

export type Bank = { code: string; currency: string; source: "BIS" | "FRED"; series: string; area?: string; definition: string };
export const BANKS: Bank[] = [
  { code: "ECB", currency: "EUR", source: "FRED", series: "ECBDFR", definition: "ECB deposit facility rate" },
  { code: "BOE", currency: "GBP", source: "BIS", series: "WS_CBPOL.D.GB", area: "GB", definition: "Bank of England official Bank Rate" },
  { code: "RBA", currency: "AUD", source: "BIS", series: "WS_CBPOL.D.AU", area: "AU", definition: "RBA cash rate target" },
  { code: "RBNZ", currency: "NZD", source: "BIS", series: "WS_CBPOL.D.NZ", area: "NZ", definition: "RBNZ official cash rate" },
  { code: "BOC", currency: "CAD", source: "BIS", series: "WS_CBPOL.D.CA", area: "CA", definition: "Bank of Canada target for the overnight rate" },
  { code: "SNB", currency: "CHF", source: "BIS", series: "WS_CBPOL.D.CH", area: "CH", definition: "SNB policy rate (mid-point of target range before 13 June 2019)" },
];

export function daysOld(latestDate: string, nowMs: number): number {
  return Math.floor((nowMs - Date.parse(latestDate + "T00:00:00Z")) / 86400000);
}
