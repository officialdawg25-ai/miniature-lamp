import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { NewsError, parseFeed, parseGdelt, type NewsRow } from "./news.ts";

// News ingestion from keyless sources. Authenticated with the shared cron secret. Dry run by default.
//   source "central_banks": official press and policy feeds (RSS or Atom). Each feed is fetched separately and a failing feed is reported, not fatal.
//   source "gdelt": English headlines about central banks, rates, inflation, currencies and gold from the GDELT DOC API (one request per 5 seconds allowed).
// Neither source provides sentiment, so none is stored. Articles are keyed by URL and never overwritten; created_at records when the platform first saw each one.
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const headers = { "Content-Type": "application/json; charset=utf-8" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });
const UA = { "User-Agent": "Mozilla/5.0 (compatible; institutional-ai-news/1.0)" };

const FEEDS: { id: string; currency: string; publisher: string; url: string }[] = [
  { id: "fed", currency: "USD", publisher: "Federal Reserve", url: "https://www.federalreserve.gov/feeds/press_all.xml" },
  { id: "ecb", currency: "EUR", publisher: "European Central Bank", url: "https://www.ecb.europa.eu/rss/press.html" },
  { id: "boe", currency: "GBP", publisher: "Bank of England", url: "https://www.bankofengland.co.uk/rss/news" },
  { id: "boj", currency: "JPY", publisher: "Bank of Japan", url: "https://www.boj.or.jp/en/rss/whatsnew.xml" },
  { id: "rba", currency: "AUD", publisher: "Reserve Bank of Australia", url: "https://www.rba.gov.au/rss/rss-cb-media-releases.xml" },
  { id: "boc", currency: "CAD", publisher: "Bank of Canada", url: "https://www.bankofcanada.ca/feed/" },
  { id: "snb", currency: "CHF", publisher: "Swiss National Bank", url: "https://www.snb.ch/public/en/rss/pressrel" },
  { id: "rbnz", currency: "NZD", publisher: "Reserve Bank of New Zealand", url: "https://www.rbnz.govt.nz/feeds/news" },
];
const GDELT_QUERIES = [
  '("central bank" OR "interest rates" OR inflation OR "Federal Reserve" OR "Bank of Japan" OR "European Central Bank") sourcelang:english',
  '(forex OR currency OR yen OR sterling OR "gold price" OR "dollar index") sourcelang:english',
];

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  const secret = req.headers.get("x-cron-secret");
  if (!secret) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const { data: valid, error: vErr } = await sb.rpc("verify_cron_secret", { p_secret: secret });
  if (vErr) return json(500, { ok: false, error: "SECRET_CHECK_FAILED" });
  if (valid !== true) return json(401, { ok: false, error: "UNAUTHORIZED" });

  const body = await req.json().catch(() => ({}));
  const dryRun = body.dry_run !== false;
  const source = String(body.source ?? "central_banks");
  const hours = Math.min(Math.max(Number(body.hours ?? 12), 1), 72);
  if (source !== "central_banks" && source !== "gdelt") return json(400, { ok: false, error: "UNSUPPORTED_SOURCE", supported: ["central_banks", "gdelt"] });

  const rows = new Map<string, NewsRow>();
  const report: Record<string, unknown>[] = [];
  try {
    if (source === "central_banks") {
      const cutoff = Date.now() - 14 * 86400000; // feeds carry history; keep the last two weeks
      for (const f of FEEDS) {
        try {
          const r = await fetch(f.url, { headers: UA, signal: AbortSignal.timeout(15000) });
          if (!r.ok) { report.push({ feed: f.id, ok: false, http_status: r.status }); continue; }
          const parsed = parseFeed(await r.text(), f.currency, f.publisher);
          const fresh = parsed.rows.filter((x) => Date.parse(x.published_at) >= cutoff);
          for (const x of fresh) rows.set(x.url, x);
          report.push({ feed: f.id, ok: true, items: parsed.rows.length, kept: fresh.length, rejected: parsed.rejected });
        } catch (e) {
          report.push({ feed: f.id, ok: false, error: e instanceof NewsError ? e.message : e instanceof Error ? e.message.slice(0, 80) : "unknown" });
        }
      }
    } else {
      for (let i = 0; i < GDELT_QUERIES.length; i++) {
        if (i > 0) await new Promise((r) => setTimeout(r, 5500));
        const params = new URLSearchParams({ query: GDELT_QUERIES[i], mode: "artlist", maxrecords: "250", format: "json", sort: "datedesc", timespan: `${hours}h` });
        const r = await fetch(`https://api.gdeltproject.org/api/v2/doc/doc?${params}`, { headers: UA, signal: AbortSignal.timeout(25000) });
        const text = await r.text();
        if (!r.ok) { report.push({ query: i, ok: false, http_status: r.status, message: text.slice(0, 80) }); continue; }
        let payload: unknown = null;
        try { payload = JSON.parse(text); } catch { report.push({ query: i, ok: false, message: text.slice(0, 80) }); continue; }
        const parsed = parseGdelt(payload);
        for (const x of parsed.rows) rows.set(x.url, x);
        report.push({ query: i, ok: true, articles: parsed.rows.length, rejected: parsed.rejected });
      }
    }
    const list = [...rows.values()];
    let inserted = 0;
    if (!dryRun && list.length) {
      const name = source === "gdelt" ? "GDELT" : "Central bank press feeds";
      for (let i = 0; i < list.length; i += 200) {
        const { data, error } = await sb.rpc("news_upsert_rows", { p_rows: list.slice(i, i + 200), p_source: name });
        if (error) return json(500, { ok: false, error: "NEWS_WRITE_FAILED", database_error_code: error.code ?? null, inserted_before_failure: inserted });
        inserted += Number(data ?? 0);
      }
    }
    return json(200, { ok: true, dry_run: dryRun, source, articles: list.length, inserted, report, sample: list.slice(-2).map((x) => ({ title: x.title, at: x.published_at, source: x.source, tags: x.tickers.map((t) => t.ticker) })) });
  } catch (e) {
    return json(500, { ok: false, error: "NEWS_INGESTION_FAILED", message: e instanceof Error ? e.message.slice(0, 120) : "unknown" });
  }
});
