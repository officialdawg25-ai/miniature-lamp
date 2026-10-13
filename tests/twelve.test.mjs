import test from 'node:test';
import assert from 'node:assert/strict';
import { parseTimeSeries, formatEndDate, VendorError } from '../supabase/functions/intraday-twelvedata/twelve.ts';

const ok = { status: 'ok', values: [
  { datetime: '2024-01-15 10:15:00', open: '158.50', high: '158.60', low: '158.40', close: '158.55' },
  { datetime: '2024-01-15 10:00:00', open: '158.40', high: '158.52', low: '158.38', close: '158.50' },
] };
test('parses UTC datetimes and sorts ascending', () => {
  const { bars, rejected } = parseTimeSeries(ok);
  assert.equal(rejected, 0); assert.equal(bars[0].ts, '2024-01-15T10:00:00.000Z'); assert.equal(bars[1].close, 158.55);
});
test('drops malformed rows and impossible candles, never repairs them', () => {
  const bad = { status: 'ok', values: [
    { datetime: 'bad', open: '1', high: '1', low: '1', close: '1' },
    { datetime: '2024-01-15 10:00:00', open: '158', high: '157', low: '156', close: '157' },
    { datetime: '2024-01-15 10:15:00', open: '', high: '1', low: '1', close: '1' },
    { datetime: '2024-01-15 10:30:00', open: '158.1', high: '158.2', low: '158.0', close: '158.15' },
  ] };
  const { bars, rejected } = parseTimeSeries(bad);
  assert.equal(bars.length, 1); assert.equal(rejected, 3);
});
test('duplicate timestamps keep one bar', () => { assert.equal(parseTimeSeries({ status: 'ok', values: [ok.values[0], ok.values[0]] }).bars.length, 1); });
test('vendor error is typed and the key is masked', () => {
  assert.throws(() => parseTimeSeries({ status: 'error', code: 429, message: 'limit reached apikey=SECRET123 now' }), (e) => e instanceof VendorError && e.code === 429 && !e.message.includes('SECRET123'));
});
test('missing values array throws', () => { assert.throws(() => parseTimeSeries({ status: 'ok' }), /no values/); });
test('end date formatting', () => { assert.equal(formatEndDate('2024-01-15T10:14:00.000Z'), '2024-01-15 10:14:00'); });
test('daily rows with a date only are stamped at 00:00 UTC', () => {
  const r = parseTimeSeries({ status: 'ok', values: [{ datetime: '2024-01-15', open: '2050.1', high: '2060', low: '2040', close: '2055' }, { datetime: '2024-01-15 7', open: '1', high: '1', low: '1', close: '1' }] });
  assert.equal(r.bars.length, 1); assert.equal(r.bars[0].ts, '2024-01-15T00:00:00.000Z'); assert.equal(r.rejected, 1);
});
