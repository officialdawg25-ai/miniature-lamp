// Cross-sectional and time-series FX portfolio research on the G8 currencies, USD as numeraire. Pure functions, no I/O.
// Currency order: EUR, GBP, AUD, NZD, CAD, CHF, JPY, USD (index 7). A weight vector has 8 entries and sums to zero: the USD entry is the implied financing leg.
// Timing: a rebalance is decided on the last trading day of a month using data up to and including that day, and the weights apply from the next day.
// Carry accrues from the policy rate known on the previous day. Costs and a financing haircut are charged in every strategy. Nothing here is tuned.
import { deflatedSharpe, metrics, mulberry32, sharpeOf, type Metrics } from "./backtest.ts";

export const CCY = ["EUR", "GBP", "AUD", "NZD", "CAD", "CHF", "JPY", "USD"] as const;
const BANK = ["ECB", "BOE", "RBA", "RBNZ", "BOC", "SNB", "BOJ", "FED"] as const;
const PAIRS: [string, 1 | -1][] = [["EURUSD", 1], ["GBPUSD", 1], ["AUDUSD", 1], ["NZDUSD", 1], ["USDCAD", -1], ["USDCHF", -1], ["USDJPY", -1]];

export type Raw = { dates: string[]; close: Record<string, number[]>; rate: Record<string, (number | null)[]> };
export type Panel = { dates: string[]; ret: number[][]; rate: (number | null)[][]; gap: number[] };

// ret[t][c] is the log return of currency c against USD from day t-1 to t (a USDXXX pair is inverted). Day 0 has no return.
export function buildPanel(raw: Raw): Panel {
  const n = raw.dates.length;
  const ret: number[][] = [], rate: (number | null)[][] = [], gap: number[] = [];
  for (let t = 0; t < n; t++) {
    const row = new Array(8).fill(0);
    if (t > 0) {
      PAIRS.forEach(([p, s], c) => {
        const a = raw.close[p]?.[t - 1], b = raw.close[p]?.[t];
        if (!(a > 0) || !(b > 0)) throw new Error(`missing close for ${p} on ${raw.dates[t]}`);
        row[c] = s * Math.log(b / a);
      });
    }
    ret.push(row);
    rate.push(BANK.map((b) => raw.rate[b]?.[t] ?? null));
    gap.push(t === 0 ? 0 : Math.round((Date.parse(raw.dates[t]) - Date.parse(raw.dates[t - 1])) / 86400000));
  }
  return { dates: raw.dates, ret, rate, gap };
}

export const isRebalance = (p: Panel, i: number): boolean => i < p.dates.length - 1 && p.dates[i].slice(0, 7) !== p.dates[i + 1].slice(0, 7);

const withUsd = (w7: number[]): number[] => { const w = [...w7.slice(0, 7), 0]; w[7] = -w.slice(0, 7).reduce((a, b) => a + b, 0); return w; };
const sd = (x: number[]): number => { const m = x.reduce((a, b) => a + b, 0) / x.length; return Math.sqrt(x.reduce((a, b) => a + (b - m) ** 2, 0) / Math.max(x.length - 1, 1)); };

// Carry: go long the k highest policy rates and short the k lowest among the eight currencies. Needs all eight rates; otherwise flat.
export function carryWeights(rates: (number | null)[], k = 3): number[] | null {
  if (rates.length !== 8 || rates.some((r) => r === null)) return null;
  const order = rates.map((r, i) => ({ r: r as number, i })).sort((a, b) => b.r - a.r || a.i - b.i);
  const w = new Array(8).fill(0);
  for (let j = 0; j < k; j++) { w[order[j].i] = 1 / k; w[order[7 - j].i] = -1 / k; }
  return w;
}

// Time-series trend: for each currency against USD, the sign of its trailing 252-day return, sized by 10% annual volatility over 60 days (capped at 3x), spread over 7 currencies.
export function trendWeights(p: Panel, i: number): number[] | null {
  if (i < 252) return null;
  const w7: number[] = [];
  for (let c = 0; c < 7; c++) {
    let r12 = 0; for (let j = i - 251; j <= i; j++) r12 += p.ret[j][c];
    const vol = sd(p.ret.slice(i - 59, i + 1).map((r) => r[c])) * Math.sqrt(252);
    w7.push((r12 >= 0 ? 1 : -1) * Math.min(3, vol > 0 ? 0.10 / vol : 3) / 7);
  }
  return withUsd(w7);
}

// Carry with a trend filter: keep a carry leg only when the currency's own 63-day return against USD agrees with its carry direction.
// The USD leg is judged by the broad dollar: minus the average 63-day return of the other seven.
export function carryTrendWeights(p: Panel, i: number): number[] | null {
  const base = carryWeights(p.rate[i]);
  if (!base || i < 63) return null;
  const m = new Array(8).fill(0);
  for (let c = 0; c < 7; c++) { for (let j = i - 62; j <= i; j++) m[c] += p.ret[j][c]; }
  m[7] = -m.slice(0, 7).reduce((a, b) => a + b, 0) / 7;
  return base.map((w, k) => (w !== 0 && Math.sign(w) === Math.sign(m[k]) ? w : 0));
}

export type StrategyId = "carry" | "trend" | "carry_trend" | "carry_vol";

// Weights held during each day (index t uses the decision made at the last rebalance before t).
export function weightPath(p: Panel, id: StrategyId): number[][] {
  const n = p.dates.length, zero = () => new Array(8).fill(0);
  let unscaledGross: number[] | null = null;
  if (id === "carry_vol") unscaledGross = dailyPnl(p, weightPath(p, "carry"), 0, 0).gross;
  const out: number[][] = Array.from({ length: n }, zero);
  let cur = zero();
  for (let t = 1; t < n; t++) {
    const i = t - 1;
    if (isRebalance(p, i)) {
      let w: number[] | null = null;
      if (id === "carry") w = carryWeights(p.rate[i]);
      else if (id === "trend") w = trendWeights(p, i);
      else if (id === "carry_trend") w = carryTrendWeights(p, i);
      else if (id === "carry_vol") {
        const base = carryWeights(p.rate[i]);
        if (base && unscaledGross && i >= 60) {
          const vol = sd(unscaledGross.slice(i - 59, i + 1)) * Math.sqrt(252);
          const scale = vol > 0 ? Math.min(2, 0.08 / vol) : 1;
          w = base.map((x) => x * scale);
        }
      }
      cur = w ?? zero();
    }
    out[t] = cur;
  }
  return out;
}

// Daily P&L as a fraction of notional 1. price: sum over the seven currencies of weight times return. carry: sum over all eight of weight times the policy rate known the day before.
// cost: spread in basis points per unit of traded weight on the seven FX legs. haircut: annual financing and markup charge per unit of gross FX exposure.
export function dailyPnl(p: Panel, W: number[][], costBp: number, haircutAnnual: number): { net: number[]; gross: number[]; turnover: number[] } {
  const n = p.dates.length, net = new Array(n).fill(0), gross = new Array(n).fill(0), turnover = new Array(n).fill(0);
  for (let t = 1; t < n; t++) {
    const w = W[t], prev = W[t - 1];
    let price = 0, carry = 0, exposure = 0, trade = 0;
    for (let c = 0; c < 7; c++) { price += w[c] * p.ret[t][c]; exposure += Math.abs(w[c]); trade += Math.abs(w[c] - prev[c]); }
    const rates = p.rate[t - 1];
    if (exposure > 0 && rates.every((r) => r !== null)) for (let k = 0; k < 8; k++) carry += (w[k] * (rates[k] as number) / 100) * p.gap[t] / 365;
    gross[t] = price + carry;
    turnover[t] = trade;
    net[t] = price + carry - trade * costBp / 1e4 - exposure * haircutAnnual * p.gap[t] / 365;
  }
  return { net, gross, turnover };
}

export type Verdict = { passed: boolean; checks: { name: string; value: number | null; threshold: string; pass: boolean }[] };

// The acceptance rules are fixed before any run (see the hypotheses in the ledger). `family` is the number of tests in the family for multiplicity.
export function evaluate(p: Panel, id: StrategyId, opt: { costBp: number; haircut: number; reps: number; seed: number; family: number }) {
  const W = weightPath(p, id);
  const first = W.findIndex((w) => w.some((x) => x !== 0));
  const { net, turnover } = dailyPnl(p, W, opt.costBp, opt.haircut);
  const series = net.slice(first), n = series.length;
  const cut = (a: number) => net.slice(Math.max(first, a));
  const half = Math.floor(n / 2);
  const m: Metrics = metrics(series);
  const m1 = metrics(series.slice(0, half)), m2 = metrics(series.slice(half));
  const last5 = metrics(net.slice(Math.max(first, p.dates.findIndex((d) => d >= "2021-10-01"))));
  const dbl = metrics(dailyPnl(p, W, opt.costBp * 2, opt.haircut).net.slice(first));
  const observed = sharpeOf(series);
  const rnd = mulberry32(opt.seed);
  let ge = 0;
  for (let b = 0; b < opt.reps; b++) {
    const shift = 63 + Math.floor(rnd() * (n - 126));
    const shifted = W.map((_, t) => (t < first ? W[t] : W[first + ((t - first + shift) % n)]));
    if (sharpeOf(dailyPnl(p, shifted, opt.costBp, opt.haircut).net.slice(first)) >= observed) ge++;
  }
  const pValue = (ge + 1) / (opt.reps + 1);
  const dsr = deflatedSharpe(m.sharpe, opt.family, n, m.skew, m.kurtosis);
  const years = n / 252, rebalances = W.reduce((c, w, t) => c + (t > 0 && w.some((x, k) => x !== W[t - 1][k]) ? 1 : 0), 0);
  const checks = [
    { name: "net Sharpe after costs and financing haircut", value: m.sharpe, threshold: ">= 0.50", pass: m.sharpe >= 0.5 },
    { name: "timing-permutation p-value (Bonferroni over the family)", value: pValue, threshold: `<= ${(0.05 / opt.family).toFixed(4)}`, pass: pValue <= 0.05 / opt.family },
    { name: "first-half Sharpe", value: m1.sharpe, threshold: "> 0", pass: m1.sharpe > 0 },
    { name: "second-half Sharpe", value: m2.sharpe, threshold: "> 0", pass: m2.sharpe > 0 },
    { name: "Sharpe at double the trading costs", value: dbl.sharpe, threshold: ">= 0.30", pass: dbl.sharpe >= 0.3 },
    { name: "deflated Sharpe probability", value: dsr, threshold: ">= 0.95", pass: dsr >= 0.95 },
    { name: "maximum drawdown", value: m.max_drawdown, threshold: ">= -0.30", pass: m.max_drawdown >= -0.3 },
  ];
  return {
    strategy: id, first_date: p.dates[first], last_date: p.dates[p.dates.length - 1], days: n, rebalances, avg_annual_turnover: (turnover.reduce((a, b) => a + b, 0) / years),
    metrics: m, first_half: m1, second_half: m2, last_5y: last5, double_cost: dbl, p_value: pValue, deflated_sharpe: dsr,
    verdict: { passed: checks.every((c) => c.pass), checks } as Verdict, series_ann_return_by_year: byYear(p.dates.slice(first), series),
  };
}

function byYear(dates: string[], x: number[]): Record<string, number> {
  const o: Record<string, number> = {};
  dates.forEach((d, i) => { const y = d.slice(0, 4); o[y] = (o[y] ?? 0) + x[i]; });
  for (const y of Object.keys(o)) o[y] = Math.round(o[y] * 1e4) / 1e4;
  return o;
}
