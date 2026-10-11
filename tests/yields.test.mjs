import test from 'node:test';
import assert from 'node:assert/strict';
import { parseFredObservations, buildUsYieldRows, availableAt, probeLines } from '../supabase/functions/yield-ingestion/yields.ts';

test('FRED parsing drops missing markers and keeps real values, sorted', () => {
  const obs = parseFredObservations({ observations: [
    { date: '2024-01-03', value: '3.95' }, { date: '2024-01-01', value: '.' }, { date: '2024-01-02', value: '4.00' },
    { date: 'bad', value: '1' }, { date: '2024-01-04', value: 'x' }, { date: '2024-01-05', value: '' },
  ] });
  assert.deepEqual(obs, [{ date: '2024-01-02', value: 4 }, { date: '2024-01-03', value: 3.95 }]);
});

test('a response without an observations array is an error, not an empty result', () => {
  assert.throws(() => parseFredObservations({ error_message: 'Bad Request' }), /NO_OBSERVATIONS_ARRAY/);
});

test('zero is a valid yield and is kept', () => {
  assert.deepEqual(parseFredObservations({ observations: [{ date: '2024-01-02', value: '0' }] }), [{ date: '2024-01-02', value: 0 }]);
});

test('availability is two UTC days after the observation date', () => {
  assert.equal(availableAt('2024-01-31'), '2024-02-02T00:00:00.000Z');
  assert.equal(availableAt('2024-12-30'), '2025-01-01T00:00:00.000Z');
});

test('US rows: 10y carries real yield only when the same date exists; 2y has none', () => {
  const rows = buildUsYieldRows({
    nominal10: [{ date: '2024-01-02', value: 4.0 }, { date: '2024-01-03', value: 4.1 }],
    nominal2: [{ date: '2024-01-02', value: 4.3 }],
    real10: [{ date: '2024-01-02', value: 1.8 }],
  }, 'src', '2026-10-11T00:00:00Z');
  const ten = rows.filter((r) => r.tenor_years === 10), two = rows.filter((r) => r.tenor_years === 2);
  assert.equal(ten.length, 2); assert.equal(two.length, 1);
  assert.equal(ten[0].real_yield, 1.8); assert.equal(ten[1].real_yield, null);
  assert.equal(ten[1].metadata.real_yield_series_id, null);
  assert.equal(two[0].real_yield, null);
  assert.equal(ten[0].ts, '2024-01-02T00:00:00Z');
  assert.equal(ten[0].metadata.available_at, '2024-01-04T00:00:00.000Z');
  assert.ok(rows.every((r) => r.market_code === 'US' && r.source_id === 'src'));
});

test('probeLines returns a bounded raw preview', () => {
  const text = 'Date,1Y,10Y\r\n2024/1/4,0.1,0.6\r\n\r\n2024/1/5,0.1,0.6\n' + 'x'.repeat(500);
  const lines = probeLines(text, 3, 20);
  assert.equal(lines.length, 3);
  assert.equal(lines[0], 'Date,1Y,10Y');
  assert.ok(lines.every((l) => l.length <= 20));
});
