import test from 'node:test';
import assert from 'node:assert/strict';
import { SERIES, availableAt, parseFredObservations } from '../supabase/functions/reference-series-ingestion/ref.ts';

test('missing FRED values are skipped and counted, never stored as zero', () => {
  const r = parseFredObservations({ observations: [{ date: '2024-01-01', value: '.' }, { date: '2024-01-02', value: '13.20' }, { date: '2024-01-03', value: '' }] });
  assert.deepEqual(r.obs, [{ obs_date: '2024-01-02', value: 13.2 }]);
  assert.equal(r.missing, 2);
});
test('malformed payloads and values throw', () => {
  assert.throws(() => parseFredObservations({}), /no observations/);
  assert.throws(() => parseFredObservations({ observations: [{ date: '2024-01-02', value: 'abc' }] }), /bad FRED value/);
  assert.throws(() => parseFredObservations({ observations: [{ date: '02/01/2024', value: '1' }] }), /bad FRED date/);
});
test('a daily close is available from the next day at 14:00 UTC', () => {
  assert.equal(availableAt('2024-01-31'), '2024-02-01T14:00:00.000Z');
  assert.equal(availableAt('2024-12-31'), '2025-01-01T14:00:00.000Z');
});
test('allow-list holds only non-revised daily market series', () => {
  assert.ok(!('NFCI' in SERIES) && !('STLFSI4' in SERIES));
  assert.ok('EVZCLS' in SERIES && 'GVZCLS' in SERIES && 'VIXCLS' in SERIES);
});
test('weekly H.10 dollar index waits for its release; discontinued EVZ is flagged', () => {
  assert.equal(availableAt('2024-01-01', SERIES.DTWEXBGS.lag_days), '2024-01-09T14:00:00.000Z');
  assert.equal(SERIES.EVZCLS.discontinued, '2025-03-11');
  assert.equal(SERIES.VIXCLS.lag_days, 1);
});
