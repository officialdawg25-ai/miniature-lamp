import test from 'node:test'; import assert from 'node:assert/strict';
import { parseCsv, parseBisPolicyRates, availableAt, buildRows } from '../supabase/functions/policy-rates-global/global.ts';
const csv = 'FREQ,REF_AREA,TITLE,TIME_PERIOD,OBS_VALUE,OBS_STATUS\r\nD,NZ,"Official, cash rate;\nsecond line",2024-01-01,5.5,A\r\nD,NZ,"x",2024-01-02,5.5,A\r\nD,NZ,"x",2024-01-03,,A\r\nD,NZ,"x",not-a-date,1,A\r\nD,XX,"x",2024-01-04,9,A\r\n';
test('parses quoted multiline fields', () => { const r = parseCsv(csv); assert.equal(r.length, 6); assert.equal(r[1][2], 'Official, cash rate;\nsecond line'); });
test('keeps valid rows, rejects blanks, bad dates and other areas', () => {
  const { obs, rejected } = parseBisPolicyRates(csv, 'NZ');
  assert.deepEqual(obs, [{ date: '2024-01-01', value: 5.5 }, { date: '2024-01-02', value: 5.5 }]);
  assert.equal(rejected, 3);
});
test('empty value is never zero', () => { assert.ok(!parseBisPolicyRates(csv, 'NZ').obs.some(o => o.date === '2024-01-03')); });
test('missing columns throws', () => { assert.throws(() => parseBisPolicyRates('A,B\n1,2\n', 'NZ'), /BIS_UNEXPECTED_COLUMNS/); });
test('availability is end of effective day', () => { assert.equal(availableAt('2024-01-01'), '2024-01-02T00:00:00.000Z'); });
test('rows carry availability >= ts', () => { const r = buildRows([{date:'2024-01-01',value:5}],'b','s','S','2026-01-01T00:00:00Z','BIS','d')[0]; assert.ok(r.available_at >= r.ts); });
