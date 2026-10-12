// Pure helpers for news ingestion: GDELT headlines, central-bank RSS or Atom feeds and Alpha Vantage NEWS_SENTIMENT (premium only, kept for a paid key). No I/O so they can be unit-tested with plain Node.
export type NewsRow = {
  url: string; title: string; summary: string | null; published_at: string; source: string | null; language: string;
  sentiment_score: number | null; sentiment_label: string | null; relevance_score: number | null;
  topics: { topic: string; relevance: number | null }[];
  tickers: { ticker: string; relevance: number | null; sentiment: number | null; label: string | null }[];
};

export class NewsError extends Error {
  retryLater: boolean;
  constructor(message: string, retryLater = false) { super(message); this.retryLater = retryLater; }
}

const num = (v: unknown): number | null => {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

// time_published looks like 20261012T093000 (UTC). Anything else is dropped, never guessed.
export function parseAvTime(s: unknown): string | null {
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?$/.exec(String(s ?? ""));
  if (!m) return null;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? 0)));
  return Number.isNaN(d.getTime()) || d.getUTCMonth() !== +m[2] - 1 ? null : d.toISOString();
}

// Vendor limit messages arrive as 200 responses with an "Information" or "Note" field. They throw so the caller can back off.
export function parseNews(payload: unknown): { rows: NewsRow[]; rejected: number } {
  const p = payload as { feed?: unknown; Information?: string; Note?: string; "Error Message"?: string } | null;
  if (!p || typeof p !== "object") throw new NewsError("response is not an object");
  if (!Array.isArray(p.feed)) {
    const msg = String(p["Error Message"] ?? p.Information ?? p.Note ?? "response has no feed").replace(/apikey=\S+/gi, "apikey=***").slice(0, 200);
    throw new NewsError(msg, /rate limit|requests per|premium|call frequency/i.test(msg));
  }
  const byUrl = new Map<string, NewsRow>();
  let rejected = 0;
  for (const a of p.feed as Record<string, unknown>[]) {
    const url = String(a?.url ?? "").trim(), title = String(a?.title ?? "").trim(), published_at = parseAvTime(a?.time_published);
    if (!/^https?:\/\//.test(url) || !title || !published_at) { rejected++; continue; }
    const topics = Array.isArray(a.topics) ? (a.topics as Record<string, unknown>[]).map((t) => ({ topic: String(t?.topic ?? ""), relevance: num(t?.relevance_score) })).filter((t) => t.topic) : [];
    const tickers = Array.isArray(a.ticker_sentiment)
      ? (a.ticker_sentiment as Record<string, unknown>[]).map((t) => ({ ticker: String(t?.ticker ?? ""), relevance: num(t?.relevance_score), sentiment: num(t?.ticker_sentiment_score), label: t?.ticker_sentiment_label ? String(t.ticker_sentiment_label) : null })).filter((t) => t.ticker)
      : [];
    byUrl.set(url, {
      url, title: title.slice(0, 500), summary: a.summary ? String(a.summary).slice(0, 2000) : null, published_at, source: a.source ? String(a.source).slice(0, 120) : null, language: "en",
      sentiment_score: num(a.overall_sentiment_score), sentiment_label: a.overall_sentiment_label ? String(a.overall_sentiment_label) : null, relevance_score: null, topics, tickers,
    });
  }
  return { rows: [...byUrl.values()].sort((x, y) => x.published_at.localeCompare(y.published_at)), rejected };
}

// ---- Keyless sources -------------------------------------------------------------------------------------------------------------------------
// No sentiment is available from these sources, so sentiment stays null. Currency tags come from a transparent keyword table, shown to the user as tags.
const CURRENCY_KEYWORDS: [string, RegExp][] = [
  ["USD", /\b(fed|federal reserve|fomc|powell|dollar|treasur(?:y|ies)|u\.s\. (?:inflation|jobs|economy)|us (?:inflation|cpi|payrolls?|jobs))\b/i],
  ["EUR", /\b(ecb|european central bank|lagarde|euro(?:zone| area)?|eurozone)\b/i],
  ["GBP", /\b(bank of england|boe|sterling|pound|uk inflation|gilts?)\b/i],
  ["JPY", /\b(bank of japan|boj|yen|ueda|japan(?:ese)? (?:inflation|government bonds?|jgbs?)|jgbs?)\b/i],
  ["AUD", /\b(rba|reserve bank of australia|aussie|australian dollar)\b/i],
  ["NZD", /\b(rbnz|reserve bank of new zealand|kiwi|new zealand dollar)\b/i],
  ["CAD", /\b(bank of canada|boc|loonie|canadian dollar)\b/i],
  ["CHF", /\b(snb|swiss national bank|swiss franc)\b/i],
  ["XAU", /\b(gold|bullion|xau)\b/i],
];
export function tagCurrencies(text: string): string[] {
  return CURRENCY_KEYWORDS.filter(([, re]) => re.test(text)).map(([c]) => c);
}

const tagTickers = (c: string[]) => c.map((x) => ({ ticker: `FOREX:${x}`, relevance: 0.5, sentiment: null, label: "keyword_tag" }));

// GDELT DOC 2.0 artlist: { articles: [{ url, title, seendate: "20261012T093000Z", domain, language }] }
export function parseGdelt(payload: unknown, forcedTags: string[] = []): { rows: NewsRow[]; rejected: number } {
  const p = payload as { articles?: unknown } | null;
  if (!p || typeof p !== "object") throw new NewsError("response is not an object");
  if (!Array.isArray(p.articles)) return { rows: [], rejected: 0 }; // GDELT returns {} when nothing matches
  const byUrl = new Map<string, NewsRow>();
  let rejected = 0;
  for (const a of p.articles as Record<string, unknown>[]) {
    const url = String(a?.url ?? "").trim(), title = String(a?.title ?? "").trim(), published_at = parseAvTime(String(a?.seendate ?? "").replace(/Z$/, ""));
    if (!/^https?:\/\//.test(url) || !title || !published_at) { rejected++; continue; }
    if (a.language && String(a.language).toLowerCase() !== "english") { rejected++; continue; }
    const tags = [...new Set([...forcedTags, ...tagCurrencies(title)])];
    byUrl.set(url, { url, title: title.slice(0, 500), summary: null, published_at, source: a.domain ? String(a.domain).slice(0, 120) : null, language: "en", sentiment_score: null, sentiment_label: null, relevance_score: null, topics: [], tickers: tagTickers(tags) });
  }
  return { rows: [...byUrl.values()].sort((x, y) => x.published_at.localeCompare(y.published_at)), rejected };
}

const unxml = (s: string) => s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1").replace(/<[^>]+>/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#0?39;|&apos;/g, "'").replace(/&#8217;/g, "\u2019").replace(/\s+/g, " ").trim();
const tag = (block: string, name: string) => { const m = new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`, "i").exec(block); return m ? m[1] : null; };

// RSS 2.0 (<item>) and Atom (<entry>). Items without a parseable date or link are dropped and counted; the publisher's currency is always added as a tag.
export function parseFeed(xml: string, publisherCurrency: string, publisher: string): { rows: NewsRow[]; rejected: number } {
  if (typeof xml !== "string" || !/<(rss|feed|rdf:RDF)\b/i.test(xml)) throw new NewsError("response is not an RSS or Atom feed");
  const blocks = xml.match(/<(item|entry)\b[\s\S]*?<\/\1>/gi) ?? [];
  const byUrl = new Map<string, NewsRow>();
  let rejected = 0;
  for (const b of blocks) {
    const title = unxml(tag(b, "title") ?? "");
    const linkTag = tag(b, "link");
    const link = (linkTag && unxml(linkTag)) || /<link\b[^>]*href="([^"]+)"/i.exec(b)?.[1] || unxml(tag(b, "guid") ?? "");
    const dateRaw = tag(b, "pubDate") ?? tag(b, "dc:date") ?? tag(b, "published") ?? tag(b, "updated");
    const t = dateRaw ? Date.parse(unxml(dateRaw)) : NaN;
    if (!title || !/^https?:\/\//.test(link) || !Number.isFinite(t)) { rejected++; continue; }
    const desc = unxml(tag(b, "description") ?? tag(b, "summary") ?? "");
    const tags = [...new Set([publisherCurrency, ...tagCurrencies(title)])];
    byUrl.set(link, { url: link, title: title.slice(0, 500), summary: desc ? desc.slice(0, 1000) : null, published_at: new Date(t).toISOString(), source: publisher, language: "en", sentiment_score: null, sentiment_label: null, relevance_score: null, topics: [{ topic: "official_communication", relevance: 1 }], tickers: tagTickers(tags) });
  }
  return { rows: [...byUrl.values()].sort((x, y) => x.published_at.localeCompare(y.published_at)), rejected };
}
