// Pure helpers for policy-rate ingestion. No I/O and no runtime imports so they can be unit-tested with plain Node.

export type Obs = { date: string; value: number };

// US Federal Reserve federal funds target range (daily, FRED): upper and lower bounds, from December 2008.
export const FED_SERIES = { upper: "DFEDTARU", lower: "DFEDTARL" } as const;
// A policy rate value dated D is treated as known from the end of D (D+1 00:00Z). Fed changes are announced the day
// before they take effect and BoJ changes are announced on the day, so this never uses a rate before it was public.
export const AVAILABILITY_BASIS = "end_of_effective_utc_day";

// FRED observations: {"observations":[{"date":"2024-01-02","value":"5.50"},{"date":"2024-01-01","value":"."}]}
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

export function availableAt(date: string): string {
  const d = new Date(date + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString();
}

export type PolicyRow = {
  central_bank_id: string; ts: string; rate: number; rate_lower: number | null; series_id: string; available_at: string;
  source_id: string; retrieved_at: string; metadata: Record<string, unknown>;
};

// Upper bound is the headline rate. The lower bound is attached only when it exists for the same date.
export function buildFedRows(upper: Obs[], lower: Obs[], centralBankId: string, sourceId: string, retrievedAt: string): PolicyRow[] {
  const low = new Map(lower.map((o) => [o.date, o.value]));
  return upper.map((o) => ({
    central_bank_id: centralBankId, ts: o.date + "T00:00:00Z", rate: o.value, rate_lower: low.get(o.date) ?? null,
    series_id: FED_SERIES.upper, available_at: availableAt(o.date), source_id: sourceId, retrieved_at: retrievedAt,
    metadata: { provider: "FRED", series_id: FED_SERIES.upper, lower_series_id: FED_SERIES.lower, units: "percent", availability_basis: AVAILABILITY_BASIS, definition: "federal funds target range, upper bound" },
  }));
}

export type RateChange = { date: string; previous: number; next: number; change: number };

// Dates on which the rate differs from the previous observation. Gaps in the observations are not treated as changes.
export function rateChanges(obs: Obs[]): RateChange[] {
  const out: RateChange[] = [];
  for (let i = 1; i < obs.length; i++) {
    if (obs[i].value !== obs[i - 1].value) out.push({ date: obs[i].date, previous: obs[i - 1].value, next: obs[i].value, change: Math.round((obs[i].value - obs[i - 1].value) * 1e6) / 1e6 });
  }
  return out;
}

// Calendar days between the latest observation and a reference day (UTC).
export function daysOld(latestDate: string, nowMs: number): number {
  return Math.floor((nowMs - Date.parse(latestDate + "T00:00:00Z")) / 86400000);
}
