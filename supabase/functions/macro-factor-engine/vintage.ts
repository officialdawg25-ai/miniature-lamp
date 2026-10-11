// Pure scoring helpers for the vintage (as-of) macro factor methodology.
// No I/O and no runtime imports so they can be unit-tested with plain Node.

export const MIN_HISTORY = 12;
export const MAX_STALE_DAYS = 100;
export const VINTAGE_METHODOLOGY = "macro-factor-v2-vintage";

export type Bias = "positive" | "inverse";

export const factorFor = (category: string): string | null => {
  const c = (category ?? "").toLowerCase();
  if (c.includes("inflation") || c.includes("price")) return "inflation";
  if (c.includes("growth") || c.includes("gdp")) return "growth";
  if (c.includes("labor") || c.includes("labour") || c.includes("employment")) return "labour";
  return null;
};

export const normalizeBias = (raw: string | null | undefined): Bias | "" => {
  const r = (raw ?? "").toLowerCase().trim();
  if (["positive", "higher_is_policy_hawkish", "higher_is_growth_bullish"].includes(r)) return "positive";
  if (["inverse", "lower_is_growth_bullish"].includes(r)) return "inverse";
  return "";
};

export type WindowScore =
  | { ok: true; score: number; zscore: number; latest: number; mean: number; sd: number; history_count: number }
  | { ok: false; reason: string; eligible_observations?: number; minimum_required?: number };

export type Point = { date: string; value: number };

// Whole months between two YYYY-MM-DD observation dates (monthly series).
const monthIndex = (d: string): number => Number(d.slice(0, 4)) * 12 + Number(d.slice(5, 7));

// CPI-style index levels are converted to one-month percentage changes. A change is only produced between
// consecutive months: a missing month (for example October 2025) never becomes a two-month change that would
// be compared against one-month baselines.
export const transformPoints = (points: Point[], isInflationIndex: boolean): Point[] => {
  if (!isInflationIndex) return points;
  const out: Point[] = [];
  for (let i = 1; i < points.length; i++) {
    const prev = points[i - 1], cur = points[i];
    if (monthIndex(cur.date) - monthIndex(prev.date) !== 1) continue;
    out.push({ date: cur.date, value: prev.value !== 0 ? (cur.value / prev.value - 1) * 100 : Number.NaN });
  }
  return out;
};

export function scoreWindow(dates: string[], vals: number[], bias: Bias, isInflationIndex: boolean): WindowScore {
  if (dates.length !== vals.length) return { ok: false, reason: "DATES_VALUES_LENGTH_MISMATCH" };
  const raw: Point[] = dates.map((date, i) => ({ date, value: vals[i] }));
  const points = transformPoints(raw, isInflationIndex);
  if (points.some((p) => !Number.isFinite(p.value))) return { ok: false, reason: "NON_FINITE_VALUE_IN_WINDOW" };
  if (points.length < MIN_HISTORY + 1) {
    return { ok: false, reason: "INSUFFICIENT_POINT_IN_TIME_HISTORY", eligible_observations: points.length, minimum_required: MIN_HISTORY + 1 };
  }
  // The newest observation known at this release must itself be scoreable; otherwise an older value would be
  // presented as the current reading.
  if (points[points.length - 1].date !== raw[raw.length - 1].date) {
    return { ok: false, reason: "LATEST_OBSERVATION_NOT_COMPARABLE" };
  }
  const values = points.map((p) => p.value);
  const latest = values[values.length - 1];
  const history = values.slice(values.length - 1 - MIN_HISTORY, values.length - 1);
  const mean = history.reduce((s, v) => s + v, 0) / history.length;
  const sd = Math.sqrt(history.reduce((s, v) => s + (v - mean) ** 2, 0) / history.length);
  if (!Number.isFinite(sd) || sd <= 0) return { ok: false, reason: "ZERO_OR_INVALID_HISTORICAL_VARIANCE" };
  let z = (latest - mean) / sd;
  if (bias === "inverse") z *= -1;
  const bounded = Math.max(-3, Math.min(3, z));
  const score = Math.max(0, Math.min(100, 50 + (bounded / 3) * 50));
  return { ok: true, score, zscore: bounded, latest, mean, sd, history_count: values.length };
}

export type ComponentScore = { indicator: string; as_of: string; score: number; zscore: number; history_count: number };
export type FactorPoint = {
  as_of: string; score: number; zscore: number; confidence: number;
  components: { indicator: string; as_of: string; score: number }[];
};

// Combine per-indicator scores into a factor series. At each event time only the latest score at or before
// that time is used, and scores older than MAX_STALE_DAYS are ignored (no carrying stale evidence forward).
export function buildFactorSeries(series: ComponentScore[][]): FactorPoint[] {
  const events = [...new Set(series.flat().map((c) => c.as_of))].sort();
  const points: FactorPoint[] = [];
  for (const at of events) {
    const used: ComponentScore[] = [];
    for (const s of series) {
      let pick: ComponentScore | null = null;
      for (const c of s) if (c.as_of <= at && (!pick || c.as_of > pick.as_of)) pick = c;
      if (pick && (Date.parse(at) - Date.parse(pick.as_of)) / 86400000 <= MAX_STALE_DAYS) used.push(pick);
    }
    if (!used.length) continue;
    const avg = (f: (c: ComponentScore) => number) => used.reduce((s, c) => s + f(c), 0) / used.length;
    points.push({
      as_of: at,
      score: Number(avg((c) => c.score).toFixed(4)),
      zscore: Number(avg((c) => c.zscore).toFixed(6)),
      confidence: Number(Math.min(0.75, avg((c) => c.history_count) / 40).toFixed(4)),
      components: used.map((c) => ({ indicator: c.indicator, as_of: c.as_of, score: Number(c.score.toFixed(4)) })),
    });
  }
  return points;
}
