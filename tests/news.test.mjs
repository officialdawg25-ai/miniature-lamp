import test from 'node:test';
import assert from 'node:assert/strict';
import { parseNews, parseAvTime, parseGdelt, parseFeed, tagCurrencies, NewsError } from '../supabase/functions/news-ingestion/news.ts';

const art = (o = {}) => ({ title: 'Fed holds rates', url: 'https://example.com/a', time_published: '20261012T093000', summary: 's', source: 'Example', overall_sentiment_score: 0.12, overall_sentiment_label: 'Neutral',
  topics: [{ topic: 'Economy - Monetary', relevance_score: '0.9' }], ticker_sentiment: [{ ticker: 'FOREX:USD', relevance_score: '0.7', ticker_sentiment_score: '-0.2', ticker_sentiment_label: 'Somewhat-Bearish' }], ...o });

test('time parsing is UTC and strict', () => {
  assert.equal(parseAvTime('20261012T093000'), '2026-10-12T09:30:00.000Z');
  assert.equal(parseAvTime('20261012T0930'), '2026-10-12T09:30:00.000Z');
  assert.equal(parseAvTime('20261312T093000'), null);
  assert.equal(parseAvTime('nope'), null);
  assert.equal(parseAvTime(undefined), null);
});

test('parses articles with numeric sentiment and ticker detail', () => {
  const { rows, rejected } = parseNews({ feed: [art()] });
  assert.equal(rejected, 0);
  assert.equal(rows[0].published_at, '2026-10-12T09:30:00.000Z');
  assert.equal(rows[0].sentiment_score, 0.12);
  assert.deepEqual(rows[0].tickers[0], { ticker: 'FOREX:USD', relevance: 0.7, sentiment: -0.2, label: 'Somewhat-Bearish' });
});

test('missing sentiment stays null, bad rows are dropped and counted, duplicates collapse', () => {
  const { rows, rejected } = parseNews({ feed: [art({ overall_sentiment_score: undefined }), art({ url: 'ftp://x' }), art({ title: '' }), art({ time_published: 'x', url: 'https://example.com/b' }), art()] });
  assert.equal(rejected, 3);
  assert.equal(rows.length, 1);
});

test('vendor limit and error messages throw, with the retry flag set for limits', () => {
  assert.throws(() => parseNews({ Information: 'Thank you. Our standard API rate limit is 25 requests per day.' }), (e) => e instanceof NewsError && e.retryLater === true);
  assert.throws(() => parseNews({ 'Error Message': 'Invalid API call apikey=SECRET1' }), (e) => e instanceof NewsError && !e.message.includes('SECRET1') && e.retryLater === false);
  assert.throws(() => parseNews(null), NewsError);
});

test('currency tags come from a visible keyword table', () => {
  assert.deepEqual(tagCurrencies('Fed signals pause as yen slides'), ['USD', 'JPY']);
  assert.deepEqual(tagCurrencies('Local sports results'), []);
  assert.ok(tagCurrencies('Gold hits record').includes('XAU'));
});

test('GDELT rows: UTC time, English only, no sentiment, tags from the title', () => {
  const { rows, rejected } = parseGdelt({ articles: [
    { url: 'https://a.example/1', title: 'ECB holds rates as euro firms', seendate: '20261012T093000Z', domain: 'a.example', language: 'English' },
    { url: 'https://a.example/2', title: 'Nachrichten', seendate: '20261012T093000Z', language: 'German' },
    { url: 'bad', title: 'x', seendate: '20261012T093000Z' },
  ] });
  assert.equal(rejected, 2);
  assert.equal(rows[0].published_at, '2026-10-12T09:30:00.000Z');
  assert.equal(rows[0].sentiment_score, null);
  assert.equal(rows[0].tickers[0].ticker, 'FOREX:EUR');
  assert.deepEqual(parseGdelt({}).rows, []);
});

test('RSS and Atom parsing with the publisher currency always tagged', () => {
  const rss = '<rss><channel><item><title><![CDATA[FOMC statement]]></title><link>https://fed.example/a</link><pubDate>Wed, 15 Oct 2026 18:00:00 GMT</pubDate><description>Rates &amp; outlook</description></item><item><title>No date</title><link>https://fed.example/b</link></item></channel></rss>';
  const r = parseFeed(rss, 'USD', 'Federal Reserve');
  assert.equal(r.rejected, 1);
  assert.equal(r.rows[0].published_at, '2026-10-15T18:00:00.000Z');
  assert.equal(r.rows[0].summary, 'Rates & outlook');
  assert.equal(r.rows[0].tickers[0].ticker, 'FOREX:USD');
  const atom = '<feed><entry><title>Policy decision</title><link href="https://x.example/p"/><updated>2026-10-15T07:00:00Z</updated><summary>s</summary></entry></feed>';
  assert.equal(parseFeed(atom, 'GBP', 'Bank of England').rows[0].url, 'https://x.example/p');
  assert.throws(() => parseFeed('<html></html>', 'USD', 'x'), NewsError);
});
