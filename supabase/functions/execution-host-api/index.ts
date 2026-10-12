import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

// Demo-only API for the MT5 execution host. The host sends its secret in x-host-token; only the SHA-256 hash is stored in the database.
// The host pulls work (claim) and reports results; nothing here connects to a broker. There is no live mode.
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
const headers = { "Content-Type": "application/json; charset=utf-8" };
const json = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers });

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "POST_REQUIRED" });
  const token = req.headers.get("x-host-token") ?? "";
  if (token.length < 32 || token.length > 200) return json(401, { ok: false, error: "UNAUTHORIZED" });
  const { data: host, error: hostError } = await sb.rpc("host_resolve", { p_token_hash: await sha256Hex(token) });
  if (hostError) return json(500, { ok: false, error: "HOST_CHECK_FAILED" });
  const h = Array.isArray(host) ? host[0] : host;
  if (!h?.host_id) return json(401, { ok: false, error: "UNAUTHORIZED" });

  const raw = await req.text();
  if (raw.length > 200_000) return json(413, { ok: false, error: "BODY_TOO_LARGE" });
  let body: Record<string, unknown> = {};
  try { body = raw ? JSON.parse(raw) : {}; } catch { return json(400, { ok: false, error: "INVALID_JSON" }); }

  try {
    if (body.action === "ping") return json(200, { ok: true, mode: "demo", host_id: h.host_id });
    if (body.action === "sync_specs") {
      const { data, error } = await sb.rpc("host_upsert_specs", { p_host_id: h.host_id, p_specs: body.specs ?? [] });
      if (error) return json(400, { ok: false, error: "SPECS_REJECTED", message: error.message.slice(0, 160) });
      return json(200, { ok: true, specs_upserted: data });
    }
    if (body.action === "claim") {
      const { data, error } = await sb.rpc("host_claim_requests", { p_host_id: h.host_id, p_limit: Math.min(Math.max(Number(body.limit ?? 5) || 5, 1), 20) });
      if (error) return json(500, { ok: false, error: "CLAIM_FAILED", message: error.message.slice(0, 160) });
      return json(200, { ok: true, mode: "demo", requests: data });
    }
    if (body.action === "report") {
      const state = String(body.state ?? "");
      const id = String(body.request_id ?? "");
      if (!/^[0-9a-f-]{36}$/.test(id) || !["sent", "acknowledged", "rejected"].includes(state)) return json(400, { ok: false, error: "INVALID_REPORT" });
      const { data, error } = await sb.rpc("host_report", { p_host_id: h.host_id, p_request_id: id, p_state: state, p_detail: typeof body.detail === "object" && body.detail ? body.detail : {} });
      if (error) return json(409, { ok: false, error: "REPORT_REFUSED", message: error.message.slice(0, 160) });
      return json(200, { ok: true, result: data });
    }
    return json(400, { ok: false, error: "UNKNOWN_ACTION", actions: ["ping", "sync_specs", "claim", "report"] });
  } catch (e) {
    return json(500, { ok: false, error: "HOST_API_FAILED", message: e instanceof Error ? e.message.slice(0, 100) : "unknown" });
  }
});
