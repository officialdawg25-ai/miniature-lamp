import test from 'node:test';
import assert from 'node:assert/strict';
import { parseFxDaily, ProviderError } from '../supabase/functions/fx-daily-refresh/av.ts';

const bar = (o, h, l, c) => ({ '1. open': String(o), '2. high': String(h), '3. low': String(l), '4. close': String(c) });
test('valid bars are returned oldest first and the forming bar is dropped', () => {
  const r = parseFxDaily({ 'Time Series FX (Daily)': { '2026-10-13': bar(1, 1.2, 0.9, 1.1), '2026-10-12': bar(1.1, 1.2, 1.0, 1.15), '2026-10-09': bar(1, 1.1, 0.95, 1.05) } }, '2026-10-13');
  assert.deepEqual(r.bars.map((b) => b.date), ['2026-10-09', '2026-10-12']);
  assert.equal(r.rejected, 0);
});
test('inconsistent rows are rejected and counted', () => {
  const r = parseFxDaily({ 'Time Series FX (Daily)': { '2026-10-09': bar(1, 0.9, 0.8, 1.0), '2026-10-08': bar(1, 1.1, 0.9, 1.0), '2026-10-07': bar(0, 1, 1, 1) } }, '2026-10-13');
  assert.equal(r.bars.length, 1); assert.equal(r.rejected, 2);
});
test('provider notices map to typed errors', () => {
  assert.throws(() => parseFxDaily({ Note: 'limit' }, '2026-10-13'), (e) => e instanceof ProviderError && e.code === 'PROVIDER_RATE_LIMIT');
  assert.throws(() => parseFxDaily({ Information: 'premium' }, '2026-10-13'), (e) => e.code === 'PROVIDER_NOTICE');
  assert.throws(() => parseFxDaily({}, '2026-10-13'), (e) => e.code === 'PROVIDER_NO_SERIES');
});
