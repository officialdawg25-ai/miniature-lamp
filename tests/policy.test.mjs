import test from 'node:test';
import assert from 'node:assert/strict';
import { parseFredObservations, availableAt, buildFedRows, rateChanges, daysOld } from '../supabase/functions/policy-rate-ingestion/policy.ts';

test('FRED parsing drops missing markers and keeps real zeros', () => {
  const obs = parseFredObservations({ observations: [{ date: '2024-01-03', value: '5.50' }, { date: '2024-01-02', value: '.' }, { date: '2024-01-01', value: '0' }, { date: 'bad', value: '1' }, { date: '2024-01-04', value: 'x' }] });
  assert.deepEqual(obs, [{ date: '2024-01-01', value: 0 }, { date: '2024-01-03', value: 5.5 }]);
  assert.throws(() => parseFredObservations({}), /NO_OBSERVATIONS/);
});

test('availability is the end of the effective day, never earlier', () => {
  assert.equal(availableAt('2024-12-31'), '2025-01-01T00:00:00.000Z');
  assert.ok(Date.parse(availableAt('2024-03-15')) > Date.parse('2024-03-15T23:59:59Z'));
});

test('Fed rows use the upper bound as the rate and attach the lower bound only when present', () => {
  const rows = buildFedRows([{ date: '2024-01-02', value: 5.5 }, { date: '2024-01-03', value: 5.5 }], [{ date: '2024-01-02', value: 5.25 }], 'bank', 'src', '2026-01-01T00:00:00Z');
  assert.equal(rows.length, 2);
  assert.equal(rows[0].rate, 5.5); assert.equal(rows[0].rate_lower, 5.25);
  assert.equal(rows[1].rate_lower, null);
  assert.equal(rows[0].ts, '2024-01-02T00:00:00Z');
  assert.ok(rows.every((r) => Date.parse(r.available_at) >= Date.parse(r.ts)));
  assert.equal(rows[0].central_bank_id, 'bank');
});

test('rate changes list only dates where the level differs from the previous observation', () => {
  const ch = rateChanges([{ date: 'a1', value: 0.25 }, { date: 'a2', value: 0.25 }, { date: 'a3', value: 0.5 }, { date: 'a4', value: 0.5 }, { date: 'a5', value: 0.25 }]);
  assert.deepEqual(ch, [{ date: 'a3', previous: 0.25, next: 0.5, change: 0.25 }, { date: 'a5', previous: 0.5, next: 0.25, change: -0.25 }]);
  assert.deepEqual(rateChanges([{ date: 'x', value: 1 }]), []);
});

test('days-old counts whole calendar days', () => {
  assert.equal(daysOld('2026-10-01', Date.parse('2026-10-08T12:00:00Z')), 7);
  assert.equal(daysOld('2026-10-08', Date.parse('2026-10-08T00:00:00Z')), 0);
});

// ---- Bank of Japan daily call rate ------------------------------------------------------------------------------
import { parseBojDaily, buildBojRows, BOJ_SERIES } from '../supabase/functions/policy-rate-ingestion/policy.ts';

const bojPayload = (dates, values, next) => ({ STATUS: 200, NEXTPOSITION: next, RESULTSET: [{ SERIES_CODE: BOJ_SERIES, VALUES: { SURVEY_DATES: dates, VALUES: values } }] });

test('BoJ parsing reads nested dates and values and skips empty or NA cells', () => {
  const r = parseBojDaily(bojPayload([20260105, 20260106, 20260107, 20260108, 20260109], [0.2, null, 'NA', 0, '0.25'], null), BOJ_SERIES);
  assert.deepEqual(r.obs, [{ date: '2026-01-05', value: 0.2 }, { date: '2026-01-08', value: 0 }, { date: '2026-01-09', value: 0.25 }]);
  assert.equal(r.rejected, 2);
  assert.equal(r.seriesFound, true);
  assert.equal(r.nextPosition, null);
});

test('BoJ parsing also accepts top-level SURVEY_DATES and rejects impossible calendar dates', () => {
  const p = { RESULTSET: { SERIES_CODE: BOJ_SERIES, SURVEY_DATES: ['20260230', '20260301'], VALUES: [0.1, 0.2] } };
  const r = parseBojDaily(p, BOJ_SERIES);
  assert.deepEqual(r.obs, [{ date: '2026-03-01', value: 0.2 }]);
  assert.equal(r.rejected, 1);
});

test('BoJ parsing reports a missing series, mismatched arrays and paging', () => {
  assert.equal(parseBojDaily({ RESULTSET: [] }, BOJ_SERIES).seriesFound, false);
  assert.equal(parseBojDaily(bojPayload([20260105, 20260106], [0.1], null), BOJ_SERIES).obs.length, 0);
  assert.equal(parseBojDaily(bojPayload([20260105], [0.1], 251), BOJ_SERIES).nextPosition, 251);
});

test('BoJ rows become available two days after their date, never earlier', () => {
  const rows = buildBojRows([{ date: '2026-10-08', value: 0.5 }], 'boj', 'src', '2026-10-11T00:00:00Z');
  assert.equal(rows[0].available_at, '2026-10-10T00:00:00.000Z');
  assert.equal(rows[0].rate_lower, null);
  assert.equal(rows[0].series_id, 'STRDCLUCON');
});
