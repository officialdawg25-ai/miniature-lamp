import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// Edge Functions deploy separately and cannot import from each other, so scheduled-refresh carries copies of the tested modules.
// These tests fail if a copy drifts from its source.
const same = (a, b) => assert.equal(readFileSync(a, 'utf8'), readFileSync(b, 'utf8'), `${a} differs from ${b}`);

test('scheduled-refresh yields.ts is identical to yield-ingestion yields.ts', () => {
  same('supabase/functions/scheduled-refresh/yields.ts', 'supabase/functions/yield-ingestion/yields.ts');
});

test('scheduled-refresh policy.ts is identical to policy-rate-ingestion policy.ts', () => {
  same('supabase/functions/scheduled-refresh/policy.ts', 'supabase/functions/policy-rate-ingestion/policy.ts');
});

test('live-candles twelve.ts is identical to intraday-twelvedata twelve.ts', () => {
  same('supabase/functions/live-candles/twelve.ts', 'supabase/functions/intraday-twelvedata/twelve.ts');
});

test('fx-research backtest.ts is identical to backtest-runner backtest.ts', () => {
  same('supabase/functions/fx-research/backtest.ts', 'supabase/functions/backtest-runner/backtest.ts');
});
