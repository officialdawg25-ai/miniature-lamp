// Pure helpers for FRED reference series (implied volatility, credit, inflation breakevens, dollar index, curve).
// No I/O and no runtime imports so they can be unit-tested with plain Node.

// Allow-list: only these series can be probed or stored. Each is an end-of-day market close or a value computed from
// closes, so it is not revised after publication (revisable series such as NFCI are deliberately excluded here).
// lag_days: calendar days after the observation date when the value is treated as known (at 14:00 UTC). Daily market
// closes are posted by FRED the next day (lag 1). The broad dollar index comes from the Fed's weekly H.10 release
// (published the following Monday for the whole prior week), so up to 8 days. EVZCLS was discontinued by CBOE on
// 2025-03-11: history only, never usable by a live rule.
export const SERIES: Record<string, { title: string; family: string; lag_days: number; discontinued?: string }> = {
  VIXCLS: { title: "CBOE Volatility Index (S&P 500 30-day implied volatility)", family: "implied_volatility", lag_days: 1 },
  EVZCLS: { title: "CBOE EuroCurrency ETF Volatility Index (EUR/USD 30-day implied volatility)", family: "implied_volatility", lag_days: 1, discontinued: "2025-03-11" },
  GVZCLS: { title: "CBOE Gold ETF Volatility Index (gold 30-day implied volatility)", family: "implied_volatility", lag_days: 1 },
  BAA10Y: { title: "Moody's Baa corporate yield minus 10-year Treasury", family: "credit_spread", lag_days: 1 },
  T10YIE: { title: "10-year breakeven inflation rate", family: "inflation_expectations", lag_days: 1 },
  T10Y2Y: { title: "10-year minus 2-year Treasury spread", family: "yield_curve", lag_days: 1 },
  DTWEXBGS: { title: "Nominal broad US dollar index (Fed H.10, weekly release)", family: "dollar", lag_days: 8 },
  DFF: { title: "Effective federal funds rate (financing-cost input)", family: "money_market_rate", lag_days: 1 },
};

export type RefObs = { obs_date: string; value: number };

// FRED observations: { observations: [{ date: "2024-01-15", value: "13.2", realtime_start: ... }] }. "." marks a missing
// value (holiday or no trading); those rows are skipped and counted, never stored as zero.
export function parseFredObservations(payload: unknown): { obs: RefObs[]; missing: number } {
  const p = payload as { observations?: unknown };
  if (!Array.isArray(p?.observations)) throw new Error("FRED response has no observations array");
  const out: RefObs[] = [];
  let missing = 0;
  for (const row of p.observations as Record<string, unknown>[]) {
    const d = String(row?.date ?? "");
    const v = String(row?.value ?? "").trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(d)) throw new Error(`bad FRED date ${d.slice(0, 20)}`);
    if (v === "." || v === "") { missing++; continue; }
    const x = Number(v);
    if (!Number.isFinite(x)) throw new Error(`bad FRED value on ${d}`);
    out.push({ obs_date: d, value: x });
  }
  return { obs: out, missing };
}

// Conservative availability: a value for date D is usable from D + lag_days at 14:00 UTC, so no signal can use a daily
// close on the day it was set, nor a weekly-release value before its release.
export function availableAt(obsDate: string, lagDays = 1): string {
  const t = Date.parse(`${obsDate}T00:00:00Z`) + lagDays * 86400000 + 14 * 3600000;
  return new Date(t).toISOString();
}
