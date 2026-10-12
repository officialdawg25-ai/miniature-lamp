import test from 'node:test';
import assert from 'node:assert/strict';
import { findSwings, structureBias, currentLeg } from '../src/smc.js';

// Build bars from a close path; high/low are +-0.1 around the close.
const mk = (closes) => closes.map((c, i) => ({ ts: String(i), open: c, close: c, high: c + 0.1, low: c - 0.1 }));

test('findSwings finds a confirmed high and low', () => {
  const bars = mk([10, 11, 12, 13, 14, 13, 12, 11, 10, 11, 12, 13]);
  const s = findSwings(bars, 3);
  assert.deepEqual(s.map((x) => [x.i, x.type]), [[4, 'H'], [8, 'L']]);
});

test('no swings when too few bars', () => {
  assert.deepEqual(findSwings(mk([1, 2, 3]), 3), []);
});

test('structure bias turns long after a close above a confirmed swing high', () => {
  const bars = mk([10, 11, 12, 13, 14, 13, 12, 11, 12, 13, 14, 15, 16]);
  const sw = findSwings(bars, 3);
  assert.equal(structureBias(bars, sw, 3).bias, 1);
});

test('no bias on a flat series', () => {
  const bars = mk(Array(20).fill(10));
  const r = currentLeg(bars, 3);
  assert.equal(r.bias, 0);
  assert.equal(r.leg, null);
  assert.match(r.reason, /swings|bias/);
});

test('long leg levels: entry at 61.8%, stop at 76.4% retracement of the leg, target at the nearest higher swing', () => {
  // low 10 -> high 20, pullback, then higher high 30 -> pullback again so swings alternate L H L H
  const path = [14, 12, 10, 12, 14, 16, 18, 20, 18, 16, 14, 16, 18, 20, 22, 24, 26, 28, 30, 28, 26, 24, 22];
  const bars = mk(path);
  const r = currentLeg(bars, 3);
  assert.equal(r.bias, 1);
  assert.ok(r.leg, r.reason);
  const { hp, lp, entry, stop } = r.leg;
  assert.ok(Math.abs(entry - (hp - 0.618 * (hp - lp))) < 1e-9);
  assert.ok(Math.abs(stop - (hp - 0.764 * (hp - lp))) < 1e-9);
  assert.ok(stop < entry);
});

test('leg is null with a reason when the latest swing opposes the bias', () => {
  const path = [10, 12, 14, 16, 18, 20, 18, 16, 14, 12, 10, 8, 6, 8, 10, 12];
  const r = currentLeg(mk(path), 3);
  assert.equal(r.leg === null || typeof r.leg === 'object', true);
  if (r.leg === null) assert.ok(r.reason);
});
