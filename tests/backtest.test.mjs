import test from 'node:test';
import assert from 'node:assert/strict';
import {
  alignAsOf, rollingZ, changeOver, momentum, positionsFor, forwardReturns, simulate, metrics, walkForward,
  runBacktest, alignAsOfMaxAge, subtractSeries, bootstrapSharpeCI, shiftPermutationP, deflatedSharpe, normCdf, normInv, mulberry32, CONFIGS,
} from '../supabase/functions/backtest-runner/backtest.ts';

const gauss = (rnd) => Math.sqrt(-2 * Math.log(1 - rnd())) * Math.cos(2 * Math.PI * rnd());
const approx = (a, b, tol = 1e-9) => assert.ok(Math.abs(a - b) <= tol, `${a} vs ${b}`);

// Synthetic market: random-walk differential and prices. `edge` plants a genuine predictor: the return from t to t+1
// depends on the sign of the 20-day change of the differential known at t (legitimate, no look-ahead).
function market(seed, n = 1500, edge = 0) {
  const rnd = mulberry32(seed);
  const diff10 = [2];
  for (let t = 1; t < n; t++) diff10.push(diff10[t - 1] + 0.03 * gauss(rnd));
  const close = [100];
  for (let t = 0; t < n - 1; t++) {
    const f = t >= 20 ? diff10[t] - diff10[t - 20] : 0;
    const r = edge * Math.sign(f) + 0.005 * gauss(rnd);
    close.push(close[t] * (1 + r));
  }
  return { close, diff10 };
}
const OPTS = { initTrain: 504, testBlock: 63, holdout: 252, costBp: 1, reps: 300, seed: 7 };

test('as-of alignment never returns a value that is not yet available', () => {
  const f = [{ availableAtMs: 100, value: 1 }, { availableAtMs: 200, value: 2 }, { availableAtMs: 300, value: null }];
  assert.deepEqual(alignAsOf(f, [50, 100, 150, 199, 200, 250, 300, 400]), [null, 1, 1, 1, 2, 2, null, null]);
});

test('features use only data up to and including the current day', () => {
  const rnd = mulberry32(3);
  const x = Array.from({ length: 400 }, () => gauss(rnd));
  const t0 = 300;
  const z = rollingZ(x, 63), ch = changeOver(x, 20);
  const y = x.slice(); for (let t = t0 + 1; t < y.length; t++) y[t] = 999; // change only the future
  assert.equal(rollingZ(y, 63)[t0], z[t0]);
  assert.equal(changeOver(y, 20)[t0], ch[t0]);
  const px = x.map((v, i) => 100 + i + v), py = px.slice(); for (let t = t0 + 1; t < py.length; t++) py[t] = -5;
  assert.equal(momentum(py, 60)[t0], momentum(px, 60)[t0]);
});

test('costs are charged on position changes only, including the first entry', () => {
  const zero = [0, 0, 0, 0];
  const c = 10 / 1e4;
  assert.deepEqual(simulate([1, 1, 1, 1], zero, zero, 10).map((v) => +v.toFixed(8)), [-c, 0, 0, 0]);
  assert.deepEqual(simulate([1, -1, 1, 1], zero, zero, 10).map((v) => +v.toFixed(8)), [-c, -2 * c, -2 * c, 0]);
  assert.deepEqual(simulate([0, 0, 0, 0], [0.1, 0.1, 0.1, 0.1], zero, 10), [0, 0, 0, 0]);
});

test('a position earns the return from its own close to the next close, plus carry', () => {
  const net = simulate([1, -1], [0.01, 0.02], [0.001, 0.001], 0);
  approx(net[0], 0.011); approx(net[1], -0.021);
});

test('metrics: Sharpe, drawdown and hit rate on a known series', () => {
  const m = metrics([0.01, -0.01, 0.01, -0.01]);
  approx(m.sharpe, 0); approx(m.hit_rate, 0.5);
  // equity: 1.01, 0.9999, 1.009899, 0.99980001; the peak stays 1.01, so the deepest drawdown is the last point
  approx(m.max_drawdown, 0.99980001 / 1.01 - 1, 1e-9);
  const steady = metrics(Array.from({ length: 252 }, (_, i) => 0.001 + (i % 2 ? 0.0001 : -0.0001)));
  assert.ok(steady.sharpe > 50);
});

test('walk-forward selection never sees data from the block it will be tested on', () => {
  const s = market(11); const ret = forwardReturns(s.close);
  const positions = {}; for (const c of CONFIGS) positions[c.id] = positionsFor(c, s).slice(0, ret.length);
  const carry = new Array(ret.length).fill(0);
  const seen = [];
  const wf = walkForward(positions, ret, carry, OPTS, (trainEnd, ids) => { seen.push(trainEnd); return { id: ids[0], sharpe: 0 }; });
  for (const sel of wf.selections) assert.ok(seen.includes(sel.start)); // trained on [0, start) only
  assert.ok(Math.max(...seen) <= wf.holdoutStart);                    // the holdout is never used for selection
  // Default selection: changing returns at or after a block's start must not change that block's choice.
  const base = walkForward(positions, ret, carry, OPTS);
  const ret2 = ret.slice(); for (let t = 800; t < ret2.length; t++) ret2[t] = 0.5;
  const alt = walkForward(positions, ret2, carry, OPTS);
  // A block that starts at or before day 800 is selected from returns strictly before it, so altering returns from day
  // 800 onward cannot change its choice. (Later blocks legitimately train on the altered days.)
  const early = base.selections.filter((x) => x.start <= 800);
  assert.ok(early.length >= 4);
  for (const sel of early) assert.equal(alt.selections.find((y) => y.start === sel.start).cfg, sel.cfg);
});

test('the holdout configuration does not depend on holdout returns', () => {
  const s = market(5); const ret = forwardReturns(s.close);
  const positions = {}; for (const c of CONFIGS) positions[c.id] = positionsFor(c, s).slice(0, ret.length);
  const carry = new Array(ret.length).fill(0);
  const a = walkForward(positions, ret, carry, OPTS);
  const ret2 = ret.slice(); for (let t = a.holdoutStart; t < ret2.length; t++) ret2[t] = -0.2;
  const b = walkForward(positions, ret2, carry, OPTS);
  assert.equal(a.holdoutCfg, b.holdoutCfg);
  assert.deepEqual(a.selections, b.selections);
});

test('pure noise: the harness does not find an edge (false-positive rate stays low)', () => {
  let significant = 0, evidence = 0; const seeds = 30;
  for (let sd = 1; sd <= seeds; sd++) {
    const s = market(1000 + sd);
    const r = runBacktest(s, new Array(s.close.length).fill(0), { ...OPTS, seed: sd });
    if (r.oos.permutation_p < 0.05) significant++;
    if (r.verdict.has_evidence) evidence++;
  }
  assert.ok(significant <= 8, `timing test flagged ${significant}/${seeds} noise markets`);
  assert.ok(evidence <= 1, `full verdict claimed evidence in ${evidence}/${seeds} noise markets`);
});

test('a planted, legitimate predictor is detected', () => {
  let detected = 0, picked = 0; const seeds = 10;
  for (let sd = 1; sd <= seeds; sd++) {
    const s = market(2000 + sd, 1500, 0.0007);
    const r = runBacktest(s, new Array(s.close.length).fill(0), { ...OPTS, seed: sd });
    if (r.oos.permutation_p < 0.05 && r.oos.sharpe_ci.lo > 0) detected++;
    const own = r.selections['diff_change_20'] ?? 0, total = Object.values(r.selections).reduce((a, b) => a + b, 0);
    if (own / total >= 0.5) picked++;
  }
  assert.ok(detected >= 8, `detected ${detected}/${seeds}`);
  assert.ok(picked >= 8, `walk-forward chose the planted configuration in ${picked}/${seeds}`);
});

test('what leakage looks like: using the next return as the position gives an absurd Sharpe the pipeline cannot produce', () => {
  const s = market(77); const ret = forwardReturns(s.close);
  const leaked = ret.map((r) => Math.sign(r));
  const leakedSharpe = metrics(simulate(leaked, ret, new Array(ret.length).fill(0), 1)).sharpe;
  assert.ok(leakedSharpe > 15);
  let maxHonest = 0;
  for (let sd = 1; sd <= 10; sd++) { const m = market(3000 + sd); const r = runBacktest(m, new Array(m.close.length).fill(0), { ...OPTS, seed: sd }); maxHonest = Math.max(maxHonest, r.oos.sharpe); }
  assert.ok(maxHonest < 3, `honest pipeline reached Sharpe ${maxHonest} on noise`);
});

test('deflated Sharpe falls as more strategies are tried', () => {
  const one = deflatedSharpe(1.0, 1, 750, 0, 3), nine = deflatedSharpe(1.0, 9, 750, 0, 3), many = deflatedSharpe(1.0, 100, 750, 0, 3);
  assert.ok(one > nine && nine > many);
  approx(deflatedSharpe(0, 1, 750, 0, 3), 0.5, 1e-6);
});

test('normal distribution helpers invert each other', () => {
  for (const p of [0.001, 0.025, 0.2, 0.5, 0.9, 0.975, 0.999]) approx(normCdf(normInv(p)), p, 2e-6);
});

test('bootstrap interval brackets the point estimate and the timing test is calibrated on noise', () => {
  const rnd = mulberry32(9);
  const net = Array.from({ length: 800 }, () => 0.0004 + 0.005 * gauss(rnd));
  const sh = metrics(net).sharpe, ci = bootstrapSharpeCI(net, 10, 400, 1);
  assert.ok(ci.lo < sh && sh < ci.hi);
  const pos = Array.from({ length: 800 }, () => (rnd() > 0.5 ? 1 : -1));
  const ret = Array.from({ length: 800 }, () => 0.005 * gauss(rnd));
  const p = shiftPermutationP(pos, ret, new Array(800).fill(0), 0, 300, 2);
  assert.ok(p > 0.01);
});

// ---- gold / inverse-signal support -------------------------------------------------------------------------------
test('signalSign -1 flips rate-signal positions and leaves momentum unchanged', () => {
  const s = market(21); const neg = { ...s, signalSign: -1 };
  for (const c of CONFIGS) {
    const a = positionsFor(c, s), b = positionsFor(c, neg);
    for (let t = 0; t < a.length; t++) {
      if (c.family === 'momentum') assert.equal(a[t], b[t]);
      else assert.equal(b[t], -a[t] || 0);
    }
  }
});

test('signalSign defaults to +1 (USDJPY behaviour is unchanged)', () => {
  const s = market(22);
  for (const c of CONFIGS) assert.deepEqual(positionsFor(c, s), positionsFor(c, { ...s, signalSign: 1 }));
});

test('signalName only relabels outputs; numbers are identical', () => {
  const s = market(23);
  const carry = new Array(s.close.length).fill(0);
  const a = runBacktest(s, carry, OPTS), b = runBacktest(s, carry, { ...OPTS, signalName: 'real_yield' });
  assert.equal(a.oos.sharpe, b.oos.sharpe);
  assert.deepEqual(a.fixed_configs_in_sample.map((c) => c.sharpe), b.fixed_configs_in_sample.map((c) => c.sharpe));
  assert.ok(b.fixed_configs_in_sample.some((c) => c.id === 'real_yield_change_20'));
  assert.ok(b.fixed_configs_in_sample.every((c) => !c.id.startsWith('diff_')));
  assert.ok(Object.keys(b.selections).every((k) => !k.startsWith('diff_')));
});

test('an inverse relationship (higher signal -> lower price) is only found with the matching prior', () => {
  let right = 0, wrong = 0; const seeds = 6;
  for (let sd = 1; sd <= seeds; sd++) {
    const s = market(300 + sd, 1500, -0.0007);            // planted: returns follow minus the sign of the 20-day change
    const carry = new Array(s.close.length).fill(0);
    const ok = runBacktest({ ...s, signalSign: -1 }, carry, { ...OPTS, seed: sd });
    const bad = runBacktest({ ...s, signalSign: 1 }, carry, { ...OPTS, seed: sd });
    if (ok.oos.sharpe > 0.5) right++;
    if (bad.oos.sharpe > 0.5) wrong++;
  }
  assert.ok(right >= 4, `matching prior found the edge in ${right}/${seeds}`);
  assert.ok(wrong <= 1, `wrong prior still looked good in ${wrong}/${seeds}`);
});

// ---- max-age alignment and series subtraction (policy-rate differential) -------------------------------------------
import { alignAsOfMaxAge as maxAge, subtractSeries as sub } from '../supabase/functions/backtest-runner/backtest.ts';

test('max-age alignment returns missing once a value is older than the limit, and never a future value', () => {
  const day = 86400000;
  const f = [{ availableAtMs: 10 * day, value: 1 }, { availableAtMs: 20 * day, value: 2 }];
  const dates = [5, 10, 15, 19, 20, 29, 30, 31].map((d) => d * day);
  assert.deepEqual(maxAge(f, dates, 10 * day), [null, 1, 1, 1, 2, 2, 2, null]);
});

test('max-age alignment with a huge limit matches plain as-of alignment', () => {
  const f = [{ availableAtMs: 100, value: 1 }, { availableAtMs: 200, value: 2 }, { availableAtMs: 300, value: null }];
  const d = [50, 100, 150, 199, 200, 250, 300, 400];
  assert.deepEqual(maxAge(f, d, 1e15), alignAsOf(f, d));
});

test('series subtraction is missing when either side is missing', () => {
  assert.deepEqual(sub([4, null, 3, 5], [1, 2, null, 2.5]), [3, null, null, 2.5]);
});

test('a policy-differential signal never uses a rate before it was available or after it went stale', () => {
  const day = 86400000;
  const fed = [{ availableAtMs: 0, value: 4 }, { availableAtMs: 50 * day, value: 4.25 }];
  const boj = [{ availableAtMs: 0, value: 0.25 }, { availableAtMs: 60 * day, value: 0.75 }];
  const dates = [5, 49, 50, 59, 60, 61].map((d) => d * day);
  const diff = sub(maxAge(fed, dates, 14 * day), maxAge(boj, dates, 10 * day));
  // day 5: both fresh -> 4 - 0.25. day 49: Fed value is 49 days old -> missing. day 50: BoJ value is 50 days old -> missing.
  // day 59: BoJ still stale -> missing. day 60: new BoJ value 0.75 and Fed 4.25 (10 days old) -> 3.5. day 61: same.
  assert.deepEqual(diff, [3.75, null, null, null, 3.5, 3.5]);
});
