import test from 'node:test';
import assert from 'node:assert/strict';
import { buildPanel, carryWeights, trendWeights, carryTrendWeights, weightPath, dailyPnl, isRebalance } from '../supabase/functions/fx-research/fx.ts';

// Synthetic raw panel: weekday dates, constant prices unless overridden, constant rates.
function raw(n, o = {}) {
  const dates = []; let d = Date.parse('2020-01-01T00:00:00Z');
  while (dates.length < n) { const day = new Date(d).getUTCDay(); if (day !== 0 && day !== 6) dates.push(new Date(d).toISOString().slice(0, 10)); d += 86400000; }
  const close = {}; for (const p of ['EURUSD', 'GBPUSD', 'AUDUSD', 'NZDUSD', 'USDCAD', 'USDCHF', 'USDJPY']) close[p] = dates.map((_, i) => (o.close?.[p] ? o.close[p](i) : 1));
  const rate = {}; const base = { ECB: 1, BOE: 2, RBA: 3, RBNZ: 4, BOC: 0.5, SNB: 0, BOJ: -0.1, FED: 2.5, ...(o.rates ?? {}) };
  for (const b of Object.keys(base)) rate[b] = dates.map(() => base[b]);
  return { dates, close, rate };
}

test('carry picks the three highest and three lowest, equal weight, sums to zero', () => {
  const w = carryWeights([1, 2, 3, 4, 0.5, 0, -0.1, 2.5]);
  assert.deepEqual(w.map((x) => +x.toFixed(4)), [0, 0, 0.3333, 0.3333, -0.3333, -0.3333, -0.3333, 0.3333]);
  assert.ok(Math.abs(w.reduce((a, b) => a + b, 0)) < 1e-12);
  assert.equal(w[3] > 0 && w[2] > 0 && w[7] > 0, true); // NZD, AUD, USD high
  assert.equal(w[6] < 0 && w[5] < 0 && w[4] < 0, true); // JPY, CHF, CAD low
  assert.equal(carryWeights([1, 2, null, 4, 5, 6, 7, 8]), null);
});

test('USDJPY is inverted so a rising USDJPY is a falling yen', () => {
  const r = raw(5, { close: { USDJPY: (i) => 100 * Math.exp(0.01 * i) } });
  const p = buildPanel(r);
  assert.ok(Math.abs(p.ret[1][6] + 0.01) < 1e-12);
  const r2 = buildPanel(raw(5, { close: { EURUSD: (i) => Math.exp(0.01 * i) } }));
  assert.ok(Math.abs(r2.ret[1][0] - 0.01) < 1e-12);
});

test('weights apply from the day after the month-end decision, never the same day', () => {
  const p = buildPanel(raw(80));
  const W = weightPath(p, 'carry');
  const firstEnd = p.dates.findIndex((_, i) => isRebalance(p, i));
  for (let t = 0; t <= firstEnd; t++) assert.ok(W[t].every((x) => x === 0), `day ${t} should be flat`);
  assert.ok(W[firstEnd + 1].some((x) => x !== 0));
});

test('carry income: flat prices, held long high rate and short low rate earns the rate spread', () => {
  const p = buildPanel(raw(300));
  const W = weightPath(p, 'carry');
  const { gross } = dailyPnl(p, W, 0, 0);
  const days = p.dates.length;
  const held = gross.slice(60).reduce((a, b) => a + b, 0);
  // top three AUD 3, NZD 4, USD 2.5 average 3.1667; bottom JPY -0.1, CHF 0, CAD 0.5 average 0.1333; spread 3.0333% a year over about 240 calendar-adjusted weekdays
  const calendarDays = (Date.parse(p.dates[days - 1]) - Date.parse(p.dates[60])) / 86400000;
  assert.ok(Math.abs(held - 0.030333 * calendarDays / 365) < 0.0008, `got ${held}`);
});

test('costs and the financing haircut only ever reduce P&L', () => {
  const p = buildPanel(raw(300));
  const W = weightPath(p, 'carry');
  const a = dailyPnl(p, W, 0, 0).net.reduce((x, y) => x + y, 0), b = dailyPnl(p, W, 2, 0.005).net.reduce((x, y) => x + y, 0);
  assert.ok(b < a);
});

test('trend needs 252 days, goes long a persistent riser and short a persistent faller', () => {
  const p = buildPanel(raw(400, { close: { EURUSD: (i) => Math.exp(0.001 * i), GBPUSD: (i) => Math.exp(-0.001 * i) } }));
  assert.equal(trendWeights(p, 100), null);
  const w = trendWeights(p, 300);
  assert.ok(w[0] > 0 && w[1] < 0);
  assert.ok(Math.abs(w.reduce((a, b) => a + b, 0)) < 1e-12);
});

test('carry-trend filter drops a leg whose own trend disagrees', () => {
  // AUD has a high rate (long carry) but has been falling: the leg must be removed. NZD rising keeps its leg.
  const p = buildPanel(raw(200, { close: { AUDUSD: (i) => Math.exp(-0.002 * i), NZDUSD: (i) => Math.exp(0.002 * i) } }));
  const i = 150;
  const base = carryWeights(p.rate[i]);
  const f = carryTrendWeights(p, i);
  assert.ok(base[2] > 0 && f[2] === 0);
  assert.ok(base[3] > 0 && f[3] > 0);
});
