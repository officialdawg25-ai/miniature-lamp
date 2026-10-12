import test from 'node:test';
import assert from 'node:assert/strict';
import { parseCalendar, surprise, CalendarError } from '../supabase/functions/calendar-ingestion/calendar.ts';

const row = (o = {}) => ({ date: '2026-10-14 12:30:00', country: 'us', event: 'CPI (MoM) (Sep)', currency: 'usd', previous: 0.3, estimate: 0.3, actual: null, impact: 'High', ...o });

test('parses a valid row to UTC with normalised fields', () => {
  const { rows, rejected } = parseCalendar([row()]);
  assert.equal(rejected, 0);
  assert.equal(rows[0].scheduled_at, '2026-10-14T12:30:00.000Z');
  assert.equal(rows[0].country, 'US');
  assert.equal(rows[0].currency, 'USD');
  assert.equal(rows[0].impact, 'high');
  assert.equal(rows[0].actual, null);
  assert.equal(rows[0].estimate, 0.3);
});

test('missing numbers stay null, they are never filled with zero', () => {
  const { rows } = parseCalendar([row({ previous: '', estimate: undefined, actual: null })]);
  assert.equal(rows[0].previous, null);
  assert.equal(rows[0].estimate, null);
  assert.equal(rows[0].actual, null);
});

test('malformed rows are dropped and counted', () => {
  const { rows, rejected } = parseCalendar([row({ date: 'nope' }), row({ event: '' }), row({ country: '' }), row()]);
  assert.equal(rows.length, 1);
  assert.equal(rejected, 3);
});

test('duplicate events collapse and unknown impact becomes null', () => {
  const { rows } = parseCalendar([row({ impact: 'weird' }), row({ impact: 'weird' })]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].impact, null);
});

test('vendor error payloads throw and mask the key', () => {
  assert.throws(() => parseCalendar({ 'Error Message': 'Restricted Endpoint apikey=SECRET123 not on plan' }), (e) => e instanceof CalendarError && !e.message.includes('SECRET123'));
  assert.throws(() => parseCalendar('not a list'), CalendarError);
});

test('surprise needs both actual and estimate', () => {
  assert.equal(surprise({ actual: 0.4, estimate: 0.3 }), 0.1);
  assert.equal(surprise({ actual: null, estimate: 0.3 }), null);
  assert.equal(surprise({ actual: 0.4, estimate: null }), null);
});
