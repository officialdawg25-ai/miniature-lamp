import test from 'node:test';
import assert from 'node:assert/strict';
import { parseTicks, buildBars, hourUrl } from '../supabase/functions/intraday-ingestion/ticks.ts';

function tickBuf(rows) {
  const b = new Uint8Array(rows.length * 20); const v = new DataView(b.buffer);
  rows.forEach(([ms, ask, bid], i) => { v.setUint32(i * 20, ms); v.setUint32(i * 20 + 4, ask); v.setUint32(i * 20 + 8, bid); v.setFloat32(i * 20 + 12, 1); v.setFloat32(i * 20 + 16, 1); });
  return b;
}
test('parses 20-byte big-endian ticks and reports trailing bytes', () => {
  const b = tickBuf([[0, 158463, 158453], [1500, 158465, 158455]]);
  const { ticks, trailingBytes } = parseTicks(new Uint8Array([...b, 1, 2, 3]));
  assert.equal(ticks.length, 2); assert.equal(trailingBytes, 3); assert.equal(ticks[1].bid, 158455);
});
test('builds 5 minute bars from bid with tick-count volume and mean spread', () => {
  const hour = Date.parse('2024-01-15T10:00:00Z');
  const { bars } = buildBars(hour, parseTicks(tickBuf([[0, 158463, 158453], [60000, 158480, 158470], [120000, 158440, 158430], [300000, 158500, 158490]])).ticks, 1000);
  assert.equal(bars.length, 2);
  assert.deepEqual([bars[0].open, bars[0].high, bars[0].low, bars[0].close, bars[0].volume], [158.453, 158.47, 158.43, 158.43, 3]);
  assert.equal(bars[0].ts, '2024-01-15T10:00:00.000Z'); assert.equal(bars[1].ts, '2024-01-15T10:05:00.000Z');
  assert.equal(bars[0].spread, 0.01);
});
test('drops crossed, non-positive and out-of-hour ticks', () => {
  const hour = Date.parse('2024-01-15T10:00:00Z');
  const { bars, dropped } = buildBars(hour, parseTicks(tickBuf([[0, 100, 200], [10, 0, 0], [3600000, 5, 5], [20, 1001, 1000]])).ticks, 1000);
  assert.equal(dropped, 3); assert.equal(bars.length, 1);
});
test('source path uses zero-based months', () => { assert.equal(hourUrl('USDJPY', '2024-01-15', 10), 'https://datafeed.dukascopy.com/datafeed/USDJPY/2024/00/15/10h_ticks.bi5'); });
