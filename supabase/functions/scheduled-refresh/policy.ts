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

// `days` is how many whole days after the observation date the value counts as known (1 = end of that day).
export function availableAt(date: string, days = 1): string {
  const d = new Date(date + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + days);
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

// ---- Bank of Japan: uncollateralized overnight call rate, daily average (FM01, series STRDCLUCON) ----------------------
export const BOJ_SERIES = "STRDCLUCON";
// A daily average is only known after that day ends and the statistics are published, so a value dated D counts as known
// from D+2 00:00Z. This is a market rate that tracks the policy rate; it is not the policy target itself.
export const BOJ_AVAILABILITY_BASIS = "conservative_end_of_next_utc_day";

function isoDate(raw: unknown): string | null {
  const t = String(raw ?? "").trim();
  const m = /^(\d{4})(\d{2})(\d{2})$/.exec(t) ?? /^(\d{4})-(\d{2})-(\d{2})$/.exec(t);
  if (!m) return null;
  const d = new Date(`${m[1]}-${m[2]}-${m[3]}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === `${m[1]}-${m[2]}-${m[3]}` ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

// BoJ time-series API payload: RESULTSET[i] has SERIES_CODE and its dates and values either at the top level or under
// VALUES: { SURVEY_DATES: [...], VALUES: [...] }. Empty, "NA" and non-numeric cells are skipped, never stored as zero.
export function parseBojDaily(payload: unknown, code: string): { obs: Obs[]; rejected: number; nextPosition: number | null; seriesFound: boolean } {
  const p = payload as { RESULTSET?: unknown; NEXTPOSITION?: unknown };
  const raw = p?.RESULTSET;
  const sets = (Array.isArray(raw) ? raw : raw && typeof raw === "object" ? [raw] : []) as Record<string, unknown>[];
  const next = Number(p?.NEXTPOSITION);
  const nextPosition = Number.isInteger(next) && next > 0 ? next : null;
  const set = sets.find((r) => String(r["SERIES_CODE"] ?? r["SERIES CODE"] ?? "") === code);
  if (!set) return { obs: [], rejected: 0, nextPosition, seriesFound: false };
  const nested = set.VALUES && typeof set.VALUES === "object" && !Array.isArray(set.VALUES) ? (set.VALUES as Record<string, unknown>) : null;
  const dates = (set.SURVEY_DATES ?? nested?.SURVEY_DATES) as unknown;
  const values = (nested?.VALUES ?? (Array.isArray(set.VALUES) ? set.VALUES : null)) as unknown;
  if (!Array.isArray(dates) || !Array.isArray(values) || dates.length !== values.length) return { obs: [], rejected: Math.max(Array.isArray(dates) ? dates.length : 0, Array.isArray(values) ? values.length : 0), nextPosition, seriesFound: true };
  const out: Obs[] = [];
  let rejected = 0;
  for (let i = 0; i < dates.length; i++) {
    const date = isoDate(dates[i]);
    const cell = values[i];
    const txt = typeof cell === "number" ? String(cell) : String(cell ?? "").trim();
    const v = txt === "" || txt.toUpperCase() === "NA" ? NaN : Number(txt);
    if (!date || !Number.isFinite(v)) { rejected++; continue; }
    out.push({ date, value: v });
  }
  const byDate = new Map(out.map((o) => [o.date, o]));
  return { obs: [...byDate.values()].sort((a, b) => a.date.localeCompare(b.date)), rejected, nextPosition, seriesFound: true };
}

export function buildBojRows(obs: Obs[], centralBankId: string, sourceId: string, retrievedAt: string): PolicyRow[] {
  return obs.map((o) => ({
    central_bank_id: centralBankId, ts: o.date + "T00:00:00Z", rate: o.value, rate_lower: null,
    series_id: BOJ_SERIES, available_at: availableAt(o.date, 2), source_id: sourceId, retrieved_at: retrievedAt,
    metadata: { provider: "BOJ", series_id: BOJ_SERIES, database: "FM01", units: "percent per annum", availability_basis: BOJ_AVAILABILITY_BASIS, definition: "uncollateralized overnight call rate, daily average (market rate tracking the policy rate; not the policy target)" },
  }));
}
