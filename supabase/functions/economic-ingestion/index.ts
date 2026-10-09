import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers });
}

Deno.serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers });
  if (req.method !== "POST") return reply(405, { ok: false, code: "METHOD_NOT_ALLOWED", request_id: requestId });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = req.headers.get("authorization");
  if (!url || !serviceKey) return reply(500, { ok: false, code: "SERVER_CONFIGURATION_MISSING", request_id: requestId });
  if (!authorization?.startsWith("Bearer ")) return reply(401, { ok: false, code: "UNAUTHORIZED", request_id: requestId });

  const sb = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await sb.auth.getUser(authorization.slice(7));
  if (error || !data.user) return reply(401, { ok: false, code: "UNAUTHORIZED", request_id: requestId });

  const { data: access, error: accessError } = await sb.schema("private").from("institutional_access")
    .select("user_id").eq("user_id", data.user.id).eq("is_active", true).maybeSingle();
  if (accessError) return reply(500, { ok: false, code: "ACCESS_CHECK_FAILED", request_id: requestId });
  if (!access) return reply(403, { ok: false, code: "INSTITUTIONAL_ACCESS_REQUIRED", request_id: requestId });

  // Do not report success or persist macro values until a provider-specific adapter
  // supplies verifiable release timestamps and revision history.
  return reply(501, {
    ok: false,
    code: "PROVIDER_ADAPTER_NOT_CONFIGURED",
    message: "No provider-specific point-in-time economic release adapter is configured. No observations were written.",
    request_id: requestId,
  });
});
