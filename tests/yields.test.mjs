import test from 'node:test';
import assert from 'node:assert/strict';
import { parseFredObservations, buildUsYieldRows, availableAt, probeLines, parseMofJgbCsv, buildJpYieldRows, extractCsvLinks, tailLines, mergeJgbObs } from '../supabase/functions/yield-ingestion/yields.ts';

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

const MOF = [
  'Interest Rate,,,,,,,,,,,,,,,(Unit : %)',
  'Date,1Y,2Y,3Y,4Y,5Y,6Y,7Y,8Y,9Y,10Y,15Y,20Y,25Y,30Y,40Y',
  '1974/9/24,10.327,9.362,8.83,8.515,8.348,8.29,8.24,8.121,8.127,-,-,-,-,-,-',
  '2021/1/4,-0.13,-0.12,-0.1,-0.09,-0.08,-0.05,-0.02,0.01,0.03,0.025,0.2,0.4,0.6,0.7,0.8',
  '2021/1/5,-0.13,-0.12,-0.1,-0.09,-0.08,-0.05,-0.02,0.01,0.03,-,0.2,0.4,0.6,0.7,0.8',
  '2021/1/6,-0.13,-0.12,-0.1',
  '2021/13/45,1,2,3',
  '2021/1/7,-0.13,-0.12,-0.1,-0.09,-0.08,-0.05,-0.02,0.01,0.03,95,0.2,0.4,0.6,0.7,0.8',
].join('\r\n');

test('MOF parsing uses the verified layout, converts dates, skips "-" and filters by start date', () => {
  const r = parseMofJgbCsv(MOF, '2021-01-01');
  const d = (date, tenor) => r.obs.find((o) => o.date === date && o.tenor === tenor);
  assert.equal(r.header_found, true);
  assert.equal(d('1974-09-24', 2), undefined);        // before the start date
  assert.equal(d('2021-01-04', 2).value, -0.12);       // negative yields are real and kept
  assert.equal(d('2021-01-04', 10).value, 0.025);
  assert.equal(d('2021-01-05', 10), undefined);        // "-" is missing, not zero
  assert.equal(d('2021-01-05', 5).value, -0.08);
  assert.equal(d('2021-01-06', 5), undefined);         // short row: missing cells are skipped
  assert.equal(d('2021-01-07', 10), undefined);        // implausible 95% is rejected
  assert.equal(r.rejected, 2);                         // "bad row" date + 95% value
});

test('MOF parsing fails loudly when the layout changes', () => {
  assert.throws(() => parseMofJgbCsv('<!DOCTYPE html><html></html>', '2021-01-01'), /HEADER_NOT_FOUND/);
  assert.throws(() => parseMofJgbCsv('Date,1Y,3Y\n2021/1/4,1,2', '2021-01-01'), /TENOR_COLUMN_MISSING_2Y/);
});

test('Japan rows carry market, availability and no real yield', () => {
  const rows = buildJpYieldRows([{ date: '2021-01-04', tenor: 10, value: 0.025 }], 'src', '2026-10-11T00:00:00Z');
  assert.equal(rows[0].market_code, 'JP'); assert.equal(rows[0].tenor_years, 10);
  assert.equal(rows[0].real_yield, null); assert.equal(rows[0].ts, '2021-01-04T00:00:00Z');
  assert.equal(rows[0].metadata.available_at, '2021-01-06T00:00:00.000Z');
});

test('CSV links are extracted, resolved against the page, de-duplicated and limited to https', () => {
  const html = '<a href="/english/policy/jgbs/reference/interest_rate/historical/jgbcme_all.csv">All</a>'
    + '<a href="jgbcm.csv?v=2">Current</a><a href=\'jgbcm.csv\'>Dup</a><a href="http://insecure.example/x.csv">no</a>'
    + '<a href="page.html">not csv</a><a href="mailto:a@b.c">m</a>';
  const links = extractCsvLinks(html, 'https://www.mof.go.jp/english/policy/jgbs/reference/interest_rate/index.htm');
  assert.deepEqual(links, [
    'https://www.mof.go.jp/english/policy/jgbs/reference/interest_rate/historical/jgbcme_all.csv',
    'https://www.mof.go.jp/english/policy/jgbs/reference/interest_rate/jgbcm.csv',
  ]);
  assert.equal(extractCsvLinks(html, 'https://x.example/', 1).length, 1);
});

test('tailLines returns the last non-empty lines, bounded in width', () => {
  assert.deepEqual(tailLines('a\nb\n\nc\r\nd\n\n', 2), ['c', 'd']);
  assert.equal(tailLines('x'.repeat(500), 1, 10)[0].length, 10);
});

test('footnotes and blank separator rows are skipped silently, not counted as rejected', () => {
  const text = [
    'Interest Rate (October 2026),,,,,,,,,,,,,,,(Unit : %)',
    'Date,1Y,2Y,3Y,4Y,5Y,6Y,7Y,8Y,9Y,10Y,15Y,20Y,25Y,30Y,40Y',
    '2026/10/1,1.668,1.939,2.077,2.274,2.407,2.534,2.657,2.82,2.952,3.092,3.62,3.91,4.154,4.122,4.125',
    '2026/10/8,1.657,1.936,2.084,2.277,2.414,2.54,2.669,2.824,2.954,3.089,3.618,3.916,4.165,4.136,4.134',
    ',,,,,,,,,,,,,,,',
    '"  If you cannot download the latest csv data, please clear the browser cache.",,,,,,,,,,,,,,,',
  ].join('\n');
  const r = parseMofJgbCsv(text, '2026-10-01', undefined, 'jgbcme.csv');
  assert.equal(r.rejected, 0);
  assert.equal(r.obs.length, 6); // 2 dates x 3 tenors
  assert.equal(r.obs.find((o) => o.date === '2026-10-08' && o.tenor === 10).value, 3.089);
  assert.equal(r.obs[0].file, 'jgbcme.csv');
  const rows = buildJpYieldRows(r.obs, 'src', '2026-10-11T00:00:00Z');
  assert.match(rows[0].metadata.dataset, /jgbcme\.csv/);
});

test('merging keeps both files, prefers the current file on overlap and reports the gap', () => {
  const hist = [{ date: '2026-09-29', tenor: 10, value: 3.082 }, { date: '2026-09-30', tenor: 10, value: 3.057 }];
  const cur = [{ date: '2026-10-01', tenor: 10, value: 3.092 }, { date: '2026-09-30', tenor: 10, value: 3.058 }];
  const m = mergeJgbObs(hist, cur);
  assert.deepEqual(m.obs.map((o) => o.date), ['2026-09-29', '2026-09-30', '2026-10-01']);
  assert.equal(m.obs.find((o) => o.date === '2026-09-30').value, 3.058); // current wins on the overlapping date
  assert.equal(m.overlap_dates, 1);
  assert.equal(m.gap_days, 0); // the current file starts on the last historical date: contiguous, no gap
  assert.equal(mergeJgbObs(hist, [{ date: '2026-10-01', tenor: 10, value: 3.092 }]).gap_days, 1); // adjacent, no overlap
  const far = mergeJgbObs(hist, [{ date: '2026-11-03', tenor: 10, value: 3.1 }]);
  assert.equal(far.gap_days, 34);
  assert.equal(mergeJgbObs(hist, []).gap_days, null);
});

test('an impossible calendar date is rejected', () => {
  const r = parseMofJgbCsv('Date,2Y,5Y,10Y\n2026/2/30,1,2,3\n2026/2/27,1,2,3', '2026-01-01');
  assert.equal(r.rejected, 1);
  assert.equal(r.obs.length, 3);
});
