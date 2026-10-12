import test from 'node:test';
import assert from 'node:assert/strict';
import { parseCot, cotAvailableAt } from '../supabase/functions/cot-ingestion/cot.ts';
const head = 'report_date_as_yyyy_mm_dd,cftc_contract_market_code,open_interest_all,lev_money_positions_long,lev_money_positions_short,asset_mgr_positions_long,asset_mgr_positions_short,dealer_positions_long_all,dealer_positions_short_all';
const good = '"2026-10-06T00:00:00.000","099741","870291","135367","179628","499449","309568","48187","224701"';
test('parses a valid row and maps the currency', () => {
  const { rows, rejected } = parseCot(head + '\n' + good + '\n');
  assert.equal(rejected, 0);
  assert.equal(rows[0].currency_code, 'EUR'); assert.equal(rows[0].report_date, '2026-10-06'); assert.equal(rows[0].lev_long, 135367);
});
test('availability is Monday after the Tuesday report', () => { assert.equal(cotAvailableAt('2026-10-06'), '2026-10-12T00:00:00.000Z'); });
test('rejects unknown contracts, blanks and negatives; never stores zero for a blank', () => {
  const bad = ['"2026-10-06T00:00:00.000","999999","1","1","1","1","1","1","1"', '"2026-10-06T00:00:00.000","097741","","1","1","1","1","1","1"', '"2026-10-06T00:00:00.000","097741","5","-1","1","1","1","1","1"'].join('\n');
  const { rows, rejected } = parseCot(head + '\n' + bad + '\n');
  assert.equal(rows.length, 0); assert.equal(rejected, 3);
});
test('duplicate contract and date keeps one row', () => { assert.equal(parseCot(head + '\n' + good + '\n' + good + '\n').rows.length, 1); });
test('missing columns throws', () => { assert.throws(() => parseCot('a,b\n1,2\n'), /CFTC_UNEXPECTED_COLUMNS/); });
