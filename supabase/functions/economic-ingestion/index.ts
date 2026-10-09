import "jsr:@supabase/functions-js/edge-runtime.d.ts";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response(JSON.stringify({error:"POST required"}), {status:405, headers:{"content-type":"application/json"}});
  const body = await req.json().catch(() => ({}));
  const indicator = body.indicator ?? null;
  const release = body.release ?? null;
  return new Response(JSON.stringify({
    status: "accepted",
    message: "Economic ingestion endpoint is online. Provider adapters will write only point-in-time releases; no synthetic market data is generated.",
    indicator,
    release
  }), {headers:{"content-type":"application/json"}});
});