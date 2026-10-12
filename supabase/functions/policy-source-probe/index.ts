import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

// Read-only source discovery for central-bank policy rates. Authenticated with the same shared secret as scheduled-refresh.
// It reads FRED series metadata and the last observations only; nothing is stored.
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const FRED_API_KEY = Deno.env.get("FRED_API_KEY");
const headers = { "Content-Type": "application/json; charset=utf-8" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });

async function probe(id: string) {
  const info = new URLSearchParams({ series_id: id, api_key: FRED_API_KEY!, file_type: "json" });
  const obs = new URLSearchParams({ series_id: id, api_key: FRED_API_KEY!, file_type: "json", sort_order: "desc", limit: "3" });
  const [a, b] = await Promise.all([
    fetch(`https://api.stlouisfed.org/fred/series?${info}`, { signal: AbortSignal.timeout(15000) }),
    fetch(`https://api.stlouisfed.org/fred/series/observations?${obs}`, { signal: AbortSignal.timeout(15000) }),
  ]);
  const ia = await a.json().catch(() => ({})), ib = await b.json().catch(() => ({}));
  const s = ia?.seriess?.[0];
  if (!a.ok || !s) return { series_id: id, found: false, http_status: a.status, error: String(ia?.error_message ?? "NOT_FOUND").slice(0, 80) };
  return {
    series_id: id, found: true, title: s.title, frequency: s.frequency_short, units: s.units_short,
    start: s.observation_start, end: s.observation_end, last_updated: s.last_updated,
    latest_observations: (ib?.observations ?? []).map((o: { date: string; value: string }) => ({ date: o.date, value: o.value })),
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  const secret = req.headers.get("x-cron-secret");
  if (!secret) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const { data: valid, error } = await sb.rpc("verify_cron_secret", { p_secret: secret });
  if (error) return json(500, { ok: false, error: "SECRET_CHECK_FAILED" });
  if (valid !== true) return json(401, { ok: false, error: "UNAUTHORIZED" });
  if (!FRED_API_KEY) return json(503, { ok: false, error: "FRED_API_KEY_NOT_CONFIGURED" });
  const body = await req.json().catch(() => ({}));
  if (Array.isArray(body.urls)) {
    // Fetches a few allow-listed public statistics URLs and reports status, type and the first lines. Nothing is stored.
    const allowed = new Set(["stats.bis.org", "data.snb.ch", "www.bankofengland.co.uk"]);
    const out = await Promise.all(body.urls.slice(0, 8).map(async (u: unknown) => {
      try {
        const url = new URL(String(u));
        if (url.protocol !== "https:" || !allowed.has(url.hostname)) return { url: String(u).slice(0, 120), error: "HOST_NOT_ALLOWED" };
        const r = await fetch(url, { headers: { Accept: "text/csv,application/json,*/*" }, signal: AbortSignal.timeout(20000) });
        const text = await r.text();
        const lines = text.split(/\r?\n/).filter(Boolean);
        return { url: url.toString().slice(0, 160), http_status: r.status, content_type: r.headers.get("content-type"), bytes: text.length, line_count: lines.length, first_lines: lines.slice(0, 4).map((l) => l.slice(0, 200)), last_lines: lines.slice(-3).map((l) => l.slice(0, 200)) };
      } catch (e) { return { url: String(u).slice(0, 120), error: e instanceof Error ? e.message.slice(0, 80) : "FETCH_FAILED" }; }
    }));
    return json(200, { ok: true, stored: false, results: out });
  }
  const ids = (Array.isArray(body.series) ? body.series : []).map(String).filter((x: string) => /^[A-Za-z0-9_]{3,40}$/.test(x)).slice(0, 25);
  if (!ids.length) return json(400, { ok: false, error: "SERIES_REQUIRED" });
  const results = await Promise.all(ids.map((id: string) => probe(id).catch((e) => ({ series_id: id, found: false, error: e instanceof Error ? e.message.slice(0, 80) : "FAILED" }))));
  return json(200, { ok: true, stored: false, results });
});
