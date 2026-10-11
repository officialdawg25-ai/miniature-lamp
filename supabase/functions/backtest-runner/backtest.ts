// Walk-forward backtest core. Pure functions only (no I/O, no runtime imports) so they can be unit-tested with plain Node.
//
// Conventions
//  - Index t is a trading day. A position decided with information available at the start of day t is held from the
//    close of day t to the close of day t+1, so it earns ret[t] = close[t+1] / close[t] - 1.
//  - Features at index t may only use data with index <= t (rolling statistics below look at t and earlier only) and
//    only values whose availability time is not later than day t (see alignAsOf).

export type Num = number | null;

// ---- as-of alignment -----------------------------------------------------------------------------------------
// For every date (ms at 00:00 UTC) returns the latest feature value whose availableAtMs <= that date. Features must be
// sorted by availableAtMs ascending. A value that is not yet available is never returned.
export function alignAsOf(features: { availableAtMs: number; value: Num }[], datesMs: number[]): Num[] {
  const out: Num[] = new Array(datesMs.length).fill(null);
  let j = -1;
  for (let i = 0; i < datesMs.length; i++) {
    while (j + 1 < features.length && features[j + 1].availableAtMs <= datesMs[i]) j++;
    out[i] = j >= 0 ? features[j].value : null;
  }
  return out;
}

// ---- features (each value at t uses data up to and including t only) ----------------------------------------
export function rollingZ(x: Num[], window: number): Num[] {
  const out: Num[] = new Array(x.length).fill(null);
  for (let t = window; t < x.length; t++) {
    const cur = x[t];
    if (cur === null) continue;
    let n = 0, sum = 0;
    for (let k = t - window; k < t; k++) { const v = x[k]; if (v !== null) { n++; sum += v; } }
    if (n < Math.ceil(window * 0.8)) continue;
    const mean = sum / n;
    let ss = 0;
    for (let k = t - window; k < t; k++) { const v = x[k]; if (v !== null) ss += (v - mean) ** 2; }
    const sd = Math.sqrt(ss / n);
    out[t] = sd > 0 ? (cur - mean) / sd : null;
  }
  return out;
}

export function changeOver(x: Num[], k: number): Num[] {
  return x.map((v, t) => (t >= k && v !== null && x[t - k] !== null ? v - (x[t - k] as number) : null));
}

export function momentum(close: number[], lookback: number): Num[] {
  return close.map((c, t) => (t >= lookback && close[t - lookback] > 0 ? c / close[t - lookback] - 1 : null));
}

export type Config = { id: string; family: "diff_level" | "diff_change" | "momentum"; param: number };
export const CONFIGS: Config[] = [
  ...[63, 126, 252].map((p) => ({ id: `diff_level_${p}`, family: "diff_level" as const, param: p })),
  ...[5, 20, 60].map((p) => ({ id: `diff_change_${p}`, family: "diff_change" as const, param: p })),
  ...[20, 60, 120].map((p) => ({ id: `momentum_${p}`, family: "momentum" as const, param: p })),
];

export type Series = { close: number[]; diff10: Num[] };

// Position in {-1, 0, +1} for every day: +1 long USDJPY, -1 short, 0 when the feature is not yet available.
export function positionsFor(cfg: Config, s: Series): number[] {
  const feature: Num[] =
    cfg.family === "diff_level" ? rollingZ(s.diff10, cfg.param)
    : cfg.family === "diff_change" ? changeOver(s.diff10, cfg.param)
    : momentum(s.close, cfg.param);
  return feature.map((f) => (f === null || f === 0 ? 0 : f > 0 ? 1 : -1));
}

export function forwardReturns(close: number[]): number[] {
  const r: number[] = [];
  for (let t = 0; t < close.length - 1; t++) r.push(close[t + 1] / close[t] - 1);
  return r;
}

// ---- simulation -----------------------------------------------------------------------------------------------
// net[t] = pos[t] * (ret[t] + carry[t]) - cost * |pos[t] - pos[t-1]|, with pos[-1] = 0 so the first entry pays too.
// carry[t] is the per-day interest-rate carry earned by a long position (negative when it costs to be long).
export function simulate(pos: number[], ret: number[], carry: number[], costBp: number): number[] {
  const cost = costBp / 1e4;
  const net: number[] = [];
  for (let t = 0; t < ret.length; t++) {
    const prev = t === 0 ? 0 : pos[t - 1];
    net.push(pos[t] * (ret[t] + (carry[t] ?? 0)) - cost * Math.abs(pos[t] - prev));
  }
  return net;
}

export type Metrics = { n: number; ann_return: number; ann_vol: number; sharpe: number; max_drawdown: number; hit_rate: number; skew: number; kurtosis: number };

export function metrics(net: number[], ppy = 252): Metrics {
  const n = net.length;
  if (n < 2) return { n, ann_return: 0, ann_vol: 0, sharpe: 0, max_drawdown: 0, hit_rate: 0, skew: 0, kurtosis: 3 };
  const mean = net.reduce((a, b) => a + b, 0) / n;
  const sd = Math.sqrt(net.reduce((a, b) => a + (b - mean) ** 2, 0) / (n - 1));
  let eq = 1, peak = 1, mdd = 0;
  for (const r of net) { eq *= 1 + r; peak = Math.max(peak, eq); mdd = Math.min(mdd, eq / peak - 1); }
  const m3 = net.reduce((a, b) => a + (b - mean) ** 3, 0) / n;
  const m4 = net.reduce((a, b) => a + (b - mean) ** 4, 0) / n;
  const s2 = net.reduce((a, b) => a + (b - mean) ** 2, 0) / n;
  return {
    n, ann_return: mean * ppy, ann_vol: sd * Math.sqrt(ppy), sharpe: sd > 0 ? (mean / sd) * Math.sqrt(ppy) : 0,
    max_drawdown: mdd, hit_rate: net.filter((r) => r > 0).length / n,
    skew: s2 > 0 ? m3 / s2 ** 1.5 : 0, kurtosis: s2 > 0 ? m4 / s2 ** 2 : 3,
  };
}

// ---- walk-forward ---------------------------------------------------------------------------------------------
export type WalkForwardOptions = { initTrain: number; testBlock: number; holdout: number; costBp: number };
export type Selection = { start: number; end: number; cfg: string; train_sharpe: number };

// The configuration for each test block is chosen using ONLY returns before that block (expanding window). The last
// `holdout` days are never used for selection; the final configuration (best over all pre-holdout data) is applied to
// them once. selectFn is injectable so tests can verify that no test data reaches selection.
export function walkForward(
  positions: Record<string, number[]>, ret: number[], carry: number[], opts: WalkForwardOptions,
  selectFn: (trainEnd: number, ids: string[]) => { id: string; sharpe: number } = (trainEnd, ids) => {
    let best = { id: ids[0], sharpe: -Infinity };
    for (const id of ids) {
      const s = metrics(simulate(positions[id].slice(0, trainEnd), ret.slice(0, trainEnd), carry.slice(0, trainEnd), opts.costBp)).sharpe;
      if (s > best.sharpe) best = { id, sharpe: s };
    }
    return best;
  },
): { stitched: number[]; selections: Selection[]; oosStart: number; holdoutStart: number; holdoutCfg: string | null } {
  const ids = Object.keys(positions);
  const n = ret.length;
  const holdoutStart = Math.max(opts.initTrain, n - opts.holdout);
  const stitched: number[] = new Array(n).fill(0);
  const selections: Selection[] = [];
  for (let start = opts.initTrain; start < holdoutStart; start += opts.testBlock) {
    const end = Math.min(start + opts.testBlock, holdoutStart);
    const pick = selectFn(start, ids);
    for (let t = start; t < end; t++) stitched[t] = positions[pick.id][t];
    selections.push({ start, end, cfg: pick.id, train_sharpe: pick.sharpe });
  }
  let holdoutCfg: string | null = null;
  if (holdoutStart < n) {
    holdoutCfg = selectFn(holdoutStart, ids).id;
    for (let t = holdoutStart; t < n; t++) stitched[t] = positions[holdoutCfg][t];
  }
  return { stitched, selections, oosStart: opts.initTrain, holdoutStart, holdoutCfg };
}

// ---- statistics -----------------------------------------------------------------------------------------------
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}

// Circular block bootstrap confidence interval for the annualized Sharpe ratio.
export function bootstrapSharpeCI(net: number[], blockLen: number, reps: number, seed: number, ppy = 252): { lo: number; hi: number } {
  const n = net.length;
  if (n < blockLen * 2) return { lo: NaN, hi: NaN };
  const rnd = mulberry32(seed);
  const out: number[] = [];
  for (let b = 0; b < reps; b++) {
    const sample: number[] = [];
    while (sample.length < n) { const s = Math.floor(rnd() * n); for (let k = 0; k < blockLen && sample.length < n; k++) sample.push(net[(s + k) % n]); }
    out.push(metrics(sample, ppy).sharpe);
  }
  out.sort((a, b) => a - b);
  return { lo: out[Math.floor(reps * 0.025)], hi: out[Math.floor(reps * 0.975)] };
}

// Timing-null p-value: how often does the same position series, circularly shifted in time (which keeps its
// frequency and persistence but breaks the alignment with returns), reach at least the observed Sharpe?
export function shiftPermutationP(pos: number[], ret: number[], carry: number[], costBp: number, reps: number, seed: number, minShift = 21): number {
  const n = pos.length;
  if (n <= minShift * 2) return NaN;
  const observed = metrics(simulate(pos, ret, carry, costBp)).sharpe;
  const rnd = mulberry32(seed);
  let ge = 0;
  for (let b = 0; b < reps; b++) {
    const shift = minShift + Math.floor(rnd() * (n - 2 * minShift));
    const shifted = pos.map((_, t) => pos[(t + shift) % n]);
    if (metrics(simulate(shifted, ret, carry, costBp)).sharpe >= observed) ge++;
  }
  return (ge + 1) / (reps + 1);
}

// Standard normal CDF and inverse (Acklam).
export function normCdf(x: number): number {
  const t = 1 / (1 + 0.2316419 * Math.abs(x));
  const d = 0.3989423 * Math.exp((-x * x) / 2);
  const p = d * t * (0.3193815 + t * (-0.3565638 + t * (1.781478 + t * (-1.821256 + t * 1.330274))));
  return x > 0 ? 1 - p : p;
}
export function normInv(p: number): number {
  const a = [-3.969683028665376e1, 2.209460984245205e2, -2.759285104469687e2, 1.38357751867269e2, -3.066479806614716e1, 2.506628277459239];
  const b = [-5.447609879822406e1, 1.615858368580409e2, -1.556989798598866e2, 6.680131188771972e1, -1.328068155288572e1];
  const c = [-7.784894002430293e-3, -3.223964580411365e-1, -2.400758277161838, -2.549732539343734, 4.374664141464968, 2.938163982698783];
  const d = [7.784695709041462e-3, 3.224671290700398e-1, 2.445134137142996, 3.754408661907416];
  const lo = 0.02425, hi = 1 - lo;
  if (p < lo) { const q = Math.sqrt(-2 * Math.log(p)); return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1); }
  if (p > hi) { const q = Math.sqrt(-2 * Math.log(1 - p)); return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1); }
  const q = p - 0.5, r = q * q;
  return ((((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q) / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
}

// Deflated Sharpe ratio (Bailey and Lopez de Prado): probability that the true Sharpe is above what the best of
// `trials` unskilled strategies would show by luck. Sharpe values here are per-period (not annualized).
export function deflatedSharpe(sharpeAnnual: number, trials: number, nObs: number, skew: number, kurtosis: number, ppy = 252): number {
  if (nObs < 3) return NaN;
  const sr = sharpeAnnual / Math.sqrt(ppy);
  const gamma = 0.5772156649;
  const varSr = (1 - skew * sr + ((kurtosis - 1) / 4) * sr * sr) / (nObs - 1);
  const sr0 = trials <= 1 ? 0 : Math.sqrt(Math.max(varSr, 1e-12)) * ((1 - gamma) * normInv(1 - 1 / trials) + gamma * normInv(1 - 1 / (trials * Math.E)));
  const denom = Math.sqrt(Math.max(1 - skew * sr + ((kurtosis - 1) / 4) * sr * sr, 1e-12));
  return normCdf(((sr - sr0) * Math.sqrt(nObs - 1)) / denom);
}

// ---- full pipeline --------------------------------------------------------------------------------------------
export type RunOptions = { initTrain: number; testBlock: number; holdout: number; costBp: number; reps: number; seed: number; bootstrapBlock?: number };

export type RunResult = {
  days: number; oos_days: number; holdout_days: number; trials: number;
  oos: Metrics & { sharpe_ci: { lo: number; hi: number }; permutation_p: number; deflated_sharpe: number; pct_time_long: number; turnover_per_year: number };
  holdout: Metrics & { cfg: string | null };
  buy_and_hold: { oos: Metrics; holdout: Metrics; full: Metrics };
  selections: Record<string, number>;
  cost_sensitivity: { cost_bp: number; oos_sharpe: number }[];
  fixed_configs_in_sample: { id: string; sharpe: number; ann_return: number }[];
  verdict: { has_evidence: boolean; reasons: string[] };
};

export function runBacktest(series: Series, carryDaily: number[], opts: RunOptions): RunResult {
  const ret = forwardReturns(series.close);
  const n = ret.length;
  const carry = carryDaily.slice(0, n);
  const positions: Record<string, number[]> = {};
  for (const cfg of CONFIGS) positions[cfg.id] = positionsFor(cfg, series).slice(0, n);

  const wf = walkForward(positions, ret, carry, { initTrain: opts.initTrain, testBlock: opts.testBlock, holdout: opts.holdout, costBp: opts.costBp });
  const net = simulate(wf.stitched, ret, carry, opts.costBp);
  const a = wf.oosStart, b = wf.holdoutStart;
  const oosNet = net.slice(a, b), holdNet = net.slice(b);
  const oosPos = wf.stitched.slice(a, b), oosRet = ret.slice(a, b), oosCarry = carry.slice(a, b);

  const m = metrics(oosNet);
  const ci = bootstrapSharpeCI(oosNet, opts.bootstrapBlock ?? 10, opts.reps, opts.seed);
  const p = shiftPermutationP(oosPos, oosRet, oosCarry, opts.costBp, opts.reps, opts.seed + 1);
  const dsr = deflatedSharpe(m.sharpe, CONFIGS.length, oosNet.length, m.skew, m.kurtosis);
  let turnover = 0;
  for (let t = a; t < b; t++) turnover += Math.abs(wf.stitched[t] - (t === 0 ? 0 : wf.stitched[t - 1]));
  const years = oosNet.length / 252;

  const ones = new Array(n).fill(1);
  const bhNet = simulate(ones, ret, carry, opts.costBp);
  const bh = { oos: metrics(bhNet.slice(a, b)), holdout: metrics(bhNet.slice(b)), full: metrics(bhNet) };

  const selections: Record<string, number> = {};
  for (const s of wf.selections) selections[s.cfg] = (selections[s.cfg] ?? 0) + 1;
  const sens = [0, 1, 2, 5].map((c) => ({ cost_bp: c, oos_sharpe: metrics(simulate(wf.stitched, ret, carry, c).slice(a, b)).sharpe }));
  const fixed = CONFIGS.map((c) => { const mm = metrics(simulate(positions[c.id], ret, carry, opts.costBp)); return { id: c.id, sharpe: mm.sharpe, ann_return: mm.ann_return }; });

  const holdoutM = metrics(holdNet);
  const reasons: string[] = [];
  if (!(ci.lo > 0)) reasons.push("The 95% confidence interval for the out-of-sample Sharpe ratio includes zero.");
  if (!(p < 0.05)) reasons.push("The timing-shift test does not reject luck (p >= 0.05).");
  if (!(dsr > 0.95)) reasons.push(`After correcting for ${CONFIGS.length} strategies tried, the deflated Sharpe probability is not above 0.95.`);
  if (!(m.sharpe > bh.oos.sharpe)) reasons.push("The out-of-sample Sharpe ratio does not beat buy-and-hold.");
  if (holdNet.length > 0 && !(holdoutM.sharpe > 0)) reasons.push("The untouched holdout period has a non-positive Sharpe ratio.");
  return {
    days: n, oos_days: oosNet.length, holdout_days: holdNet.length, trials: CONFIGS.length,
    oos: { ...m, sharpe_ci: ci, permutation_p: p, deflated_sharpe: dsr, pct_time_long: oosPos.filter((x) => x > 0).length / Math.max(oosPos.length, 1), turnover_per_year: turnover / Math.max(years, 1e-9) },
    holdout: { ...holdoutM, cfg: wf.holdoutCfg },
    buy_and_hold: bh, selections, cost_sensitivity: sens, fixed_configs_in_sample: fixed,
    verdict: { has_evidence: reasons.length === 0, reasons },
  };
}
