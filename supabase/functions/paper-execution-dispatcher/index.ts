import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

// Thin wrapper over the database function public.dispatch_paper_execution. Every check (account membership, human approval, a fresh risk-gate
// evaluation and the simulated fill) happens in one database transaction as the signed-in user. This function uses only the caller's own token:
// it holds no service key and the service role has no access to the trading schema. No broker order is ever sent.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const reply = (status: number, body: Record<string, unknown>) => new Response(JSON.stringify(body), { status, headers: cors });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "POST required" });

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anonKey) return reply(500, { error: "server configuration missing" });

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return reply(401, { error: "authenticated user required" });
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data: { user }, error: userError } = await userClient.auth.getUser();
  if (userError || !user) return reply(401, { error: "invalid authentication" });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply(400, { error: "invalid JSON body" }); }
  const id = body?.execution_request_id;
  if (typeof id !== "string" || !UUID.test(id)) return reply(400, { error: "execution_request_id must be a UUID" });

  const { data, error } = await userClient.rpc("dispatch_paper_execution", { p_execution_request_id: id });
  if (error) {
    const message = String(error.message ?? "dispatch failed");
    const status = /access denied|authenticated user required/i.test(message) ? 403 : /not found/i.test(message) ? 404 : 409;
    return reply(status, { error: message, execution_request_id: id, broker_dispatched: false });
  }
  const result = (data ?? {}) as Record<string, unknown>;
  const state = String(result.broker_dispatch_state ?? "");
  return reply(state === "rejected" || state === "paper_rejected" ? 409 : 200, { ...result, broker_dispatched: false });
});
