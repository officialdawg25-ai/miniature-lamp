import test from 'node:test';
import assert from 'node:assert/strict';
import { scoreWindow as scoreRaw, buildFactorSeries, factorFor, normalizeBias, MIN_HISTORY } from '../supabase/functions/macro-factor-engine/vintage.ts';

// Test helper: consecutive month-start dates ending in 2025-09, so the dates are real months.
const monthDates = (n, endY = 2025, endM = 9) => Array.from({ length: n }, (_, i) => { const idx = endY * 12 + (endM - 1) - (n - 1 - i); return `${Math.floor(idx / 12)}-${String(idx % 12 + 1).padStart(2, '0')}-01`; });
const scoreWindow = (vals, bias, idx) => scoreRaw(monthDates(vals.length), vals, bias, idx);
const ramp = (n, start = 3.5, step = 0.05) => Array.from({ length: n }, (_, i) => start + i * step);

test('factor and bias mapping', () => {
  assert.equal(factorFor('labor'), 'labour');
  assert.equal(factorFor('inflation'), 'inflation');
  assert.equal(factorFor('central bank'), null);
  assert.equal(normalizeBias('lower_is_growth_bullish'), 'inverse');
  assert.equal(normalizeBias('higher_is_policy_hawkish'), 'positive');
  assert.equal(normalizeBias(''), '');
});

test('insufficient history fails closed with the required counts', () => {
  const r = scoreWindow(ramp(MIN_HISTORY), 'positive', false);
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'INSUFFICIENT_POINT_IN_TIME_HISTORY');
  assert.equal(r.eligible_observations, MIN_HISTORY);
  assert.equal(r.minimum_required, MIN_HISTORY + 1);
});

test('zero variance is rejected, not scored', () => {
  const r = scoreWindow(new Array(MIN_HISTORY + 1).fill(4), 'positive', false);
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'ZERO_OR_INVALID_HISTORICAL_VARIANCE');
});

test('inverse bias flips the direction and stays within 0..100', () => {
  const v = [...ramp(MIN_HISTORY), 9];
  const pos = scoreWindow(v, 'positive', false);
  const inv = scoreWindow(v, 'inverse', false);
  assert.ok(pos.ok && inv.ok);
  assert.ok(pos.score > 50 && inv.score < 50);
  assert.ok(pos.score <= 100 && inv.score >= 0);
  assert.equal(pos.zscore, -inv.zscore);
});

test('index levels are converted to percentage changes (needs one extra observation)', () => {
  const levels = Array.from({ length: MIN_HISTORY + 1 }, (_, i) => 300 * 1.002 ** i);
  assert.equal(scoreWindow(levels, 'positive', true).ok, false);
  const more = [...levels, 300 * 1.002 ** (MIN_HISTORY + 1) * 1.01];
  const r = scoreWindow(more, 'positive', true);
  assert.ok(r.ok);
  assert.ok(r.score > 50);
});

test('only the 12 observations before the latest form the baseline', () => {
  const a = scoreWindow([100, 0, ...ramp(MIN_HISTORY), 5], 'positive', false);
  const b = scoreWindow([-50, 7, ...ramp(MIN_HISTORY), 5], 'positive', false);
  assert.ok(a.ok && b.ok);
  assert.equal(a.score, b.score);
});

test('factor series uses latest score at or before each event and drops stale components', () => {
  const cpi = [
    { indicator: 'CPI', as_of: '2024-01-10T13:30:00Z', score: 60, zscore: 0.6, history_count: 20 },
    { indicator: 'CPI', as_of: '2024-02-13T13:30:00Z', score: 70, zscore: 1.2, history_count: 21 },
  ];
  const core = [{ indicator: 'CORE', as_of: '2024-02-14T13:30:00Z', score: 40, zscore: -0.6, history_count: 20 }];
  const pts = buildFactorSeries([cpi, core]);
  assert.equal(pts.length, 3);
  assert.equal(pts[0].score, 60);               // only CPI known
  assert.equal(pts[1].score, 70);               // CORE not yet released: no look-ahead
  assert.equal(pts[2].score, 55);               // CPI(70) and CORE(40)
  const stale = buildFactorSeries([[{ indicator: 'X', as_of: '2024-01-01T00:00:00Z', score: 80, zscore: 1, history_count: 20 }],
                                   [{ indicator: 'Y', as_of: '2024-06-01T00:00:00Z', score: 20, zscore: -1, history_count: 20 }]]);
  assert.equal(stale[1].score, 20);             // X is older than 100 days and ignored
});

test('a missing month never becomes a two-month change for index levels', () => {
  // Feb-Sep 2025, then Nov 2025-Jun 2026: October 2025 is absent.
  const dates = [...monthDates(8, 2025, 9), ...monthDates(8, 2026, 6)];
  assert.equal(dates.includes('2025-10-01'), false);
  let level = 300;
  const levels = dates.map((_, i) => (level *= 1 + 0.002 + (i % 3) * 0.0005));
  const r = scoreRaw(dates, levels, 'positive', true);
  assert.equal(r.ok, true);
  // 15 adjacent pairs minus the single pair that spans the gap.
  assert.equal(r.history_count, 14);
});

test('the first month after a gap is not scored for index levels', () => {
  const before = monthDates(16, 2025, 9);
  const after = ['2025-11-01'];
  const dates = [...before, ...after];
  const levels = dates.map((_, i) => 300 * 1.002 ** i + (i % 2) * 0.3);
  const r = scoreRaw(dates, levels, 'positive', true);
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'LATEST_OBSERVATION_NOT_COMPARABLE');
});

test('plain level series tolerate a missing month', () => {
  const dates = [...monthDates(8, 2025, 9), ...monthDates(8, 2026, 6)];
  const vals = dates.map((_, i) => 4 + (i % 5) * 0.1);
  const r = scoreRaw(dates, vals, 'inverse', false);
  assert.equal(r.ok, true);
});
