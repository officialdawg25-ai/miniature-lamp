import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

type Job = { symbol: string; from: string; to: string };
type FailureCode =
  | "METHOD_NOT_ALLOWED"
  | "UNAUTHORIZED"
  | "INVALID_REQUEST"
  | "SERVER_CONFIGURATION_MISSING"
  | "PROVIDER_KEY_MISSING"
  | "INSTRUMENT_NOT_FOUND"
  | "DATA_SOURCE_NOT_FOUND"
  | "PROVIDER_HTTP_ERROR"
  | "PROVIDER_RATE_LIMIT"
  | "PROVIDER_NOTICE"
  | "PROVIDER_REJECTED_REQUEST"
  | "PROVIDER_NO_SERIES"
  | "INVALID_PROVIDER_DATA"
  | "DATABASE_READ_FAILED"
  | "DATABASE_WRITE_FAILED"
  | "INGESTION_FAILED";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

const SYMBOLS: Record<string, [string, string]> = {
  USDJPY: ["USD", "JPY"],
  EURUSD: ["EUR", "USD"],
  GBPUSD: ["GBP", "USD"],
  USDCHF: ["USD", "CHF"],
  USDCAD: ["USD", "CAD"],
  AUDUSD: ["AUD", "USD"],
  NZDUSD: ["NZD", "USD"],
  EURJPY: ["EUR", "JPY"],
  GBPJPY: ["GBP", "JPY"],
  AUDJPY: ["AUD", "JPY"],
};

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function numeric(value: unknown): number {
  const result = Number(value);
  if (!Number.isFinite(result)) throw new Error("INVALID_PROVIDER_DATA");
  return result;
}

function publicFailure(
  status: number,
  code: FailureCode,
  message: string,
  requestId: string,
) {
  return json(status, { ok: false, code, error: message, request_id: requestId });
}

async function fetchDaily(job: Job, apiKey: string) {
  const url = new URL("https://www.alphavantage.co/query");
  url.searchParams.set("function", "FX_DAILY");
  url.searchParams.set("from_symbol", job.from);
  url.searchParams.set("to_symbol", job.to);
  url.searchParams.set("outputsize", "full");
  url.searchParams.set("apikey", apiKey);

  let response: Response;
  try {
    response = await fetch(url, { headers: { Accept: "application/json" } });
  } catch {
    throw Object.assign(new Error("PROVIDER_HTTP_ERROR"), { code: "PROVIDER_HTTP_ERROR" });
  }

  if (!response.ok) {
    throw Object.assign(new Error("PROVIDER_HTTP_ERROR"), { code: "PROVIDER_HTTP_ERROR" });
  }

  let body: Record<string, unknown>;
  try {
    body = await response.json();
  } catch {
    throw Object.assign(new Error("PROVIDER_NO_SERIES"), { code: "PROVIDER_NO_SERIES" });
  }

  if (body["Note"]) {
    throw Object.assign(new Error("PROVIDER_RATE_LIMIT"), { code: "PROVIDER_RATE_LIMIT" });
  }
  if (body["Information"]) {
    throw Object.assign(new Error("PROVIDER_NOTICE"), { code: "PROVIDER_NOTICE" });
  }
  if (body["Error Message"]) {
    throw Object.assign(new Error("PROVIDER_REJECTED_REQUEST"), { code: "PROVIDER_REJECTED_REQUEST" });
  }

  const series = body["Time Series FX (Daily)"];
  if (!series || typeof series !== "object" || Array.isArray(series)) {
    throw Object.assign(new Error("PROVIDER_NO_SERIES"), { code: "PROVIDER_NO_SERIES" });
  }
  return series as Record<string, Record<string, string>>;
}

Deno.serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  let stage = "request";
  let currentSymbol: string | undefined;
  let auditWriter: ((status: "succeeded" | "failed", details: Record<string, unknown>) => Promise<void>) | null = null;

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") {
    return publicFailure(405, "METHOD_NOT_ALLOWED", "Use POST for ingestion.", requestId);
  }

  try {
    stage = "configuration";
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const apiKey = Deno.env.get("ALPHA_VANTAGE_API_KEY");

    if (!supabaseUrl || !serviceRoleKey) {
      console.error(JSON.stringify({ event: "ingestion_failed", request_id: requestId, stage, code: "SERVER_CONFIGURATION_MISSING" }));
      return publicFailure(500, "SERVER_CONFIGURATION_MISSING", "Server database configuration is missing.", requestId);
    }
    if (!apiKey) {
      console.error(JSON.stringify({ event: "ingestion_failed", request_id: requestId, stage, code: "PROVIDER_KEY_MISSING" }));
      return publicFailure(503, "PROVIDER_KEY_MISSING", "The market-data provider key is not configured in Supabase.", requestId);
    }

    const auth = req.headers.get("authorization");
    if (!auth?.startsWith("Bearer ")) {
      return publicFailure(401, "UNAUTHORIZED", "Sign in again and retry ingestion.", requestId);
    }

    stage = "authentication";
    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user }, error: authError } = await supabase.auth.getUser(auth.slice(7));
    if (authError || !user) {
      return publicFailure(401, "UNAUTHORIZED", "Your session could not be verified. Sign in again.", requestId);
    }

    stage = "institutional_authorization";
    const { data: accessRow, error: accessError } = await supabase
      .from("institutional_access")
      .select("user_id,access_role")
      .eq("user_id", user.id)
      .eq("is_active", true)
      .maybeSingle();
    if (accessError) {
      console.error(JSON.stringify({ event: "authorization_check_failed", request_id: requestId }));
      return publicFailure(500, "DATABASE_READ_FAILED", "Could not verify institutional access.", requestId);
    }
    if (!accessRow) {
      return publicFailure(403, "UNAUTHORIZED", "Institutional access is not approved for this account.", requestId);
    }

    stage = "audit_start";
    const { data: auditRow, error: auditInsertError } = await supabase
      .schema("market")
      .from("ingestion_audit")
      .insert({ request_id: requestId, provider: "Alpha Vantage", status: "running", created_by: user.id })
      .select("id")
      .single();
    if (auditInsertError || !auditRow) {
      console.error(JSON.stringify({ event: "ingestion_audit_write_failed", request_id: requestId, stage, code: "AUDIT_START_FAILED", db_code: auditInsertError?.code ?? null }));
    } else {
      auditWriter = async (status, details) => {
        try {
          const { error } = await supabase.schema("market").from("ingestion_audit").update({
            status,
            completed_at: new Date().toISOString(),
            instruments: Array.isArray(details.instruments) ? details.instruments : [],
            records_processed: Number(details.records_processed ?? 0),
            error_code: status === "failed" ? String(details.error_code ?? "INGESTION_FAILED") : null,
            error_stage: status === "failed" ? String(details.stage ?? stage) : null,
            details,
          }).eq("id", auditRow.id);
          if (error) console.error(JSON.stringify({ event: "ingestion_audit_write_failed", request_id: requestId, stage: "audit_finish", db_code: error.code ?? null }));
        } catch {
          console.error(JSON.stringify({ event: "ingestion_audit_write_failed", request_id: requestId, stage: "audit_finish", code: "AUDIT_FINISH_FAILED" }));
        }
      };
    }
    const fail = async (status: number, code: FailureCode, message: string, _requestId = requestId) => {
      if (auditWriter) await auditWriter("failed", { error_code: code, stage, symbol: currentSymbol ?? null });
      console.error(JSON.stringify({ event: "ingestion_failed", request_id: requestId, stage, symbol: currentSymbol ?? null, code }));
      return publicFailure(status, code, message, requestId);
    };

    stage = "request_validation";
    let payload: Record<string, unknown> = {};
    try {
      payload = await req.json();
    } catch {
      return await fail(400, "INVALID_REQUEST", "Request body must be valid JSON.", requestId);
    }
    const requested = Array.isArray(payload.instruments) ? payload.instruments : ["USDJPY"];
    if (requested.length < 1 || requested.length > 10 || requested.some((v) => typeof v !== "string" || !SYMBOLS[v])) {
      return await fail(400, "INVALID_REQUEST", "Choose between one and ten supported FX instruments.", requestId);
    }
    const jobs: Job[] = [...new Set(requested as string[])].map((symbol) => ({
      symbol,
      from: SYMBOLS[symbol][0],
      to: SYMBOLS[symbol][1],
    }));

    stage = "instrument_lookup";
    const { data: instruments, error: instrumentError } = await supabase
      .schema("core")
      .from("instruments")
      .select("id,symbol")
      .in("symbol", jobs.map((job) => job.symbol));
    if (instrumentError) {
      console.error(JSON.stringify({ event: "ingestion_failed", request_id: requestId, stage, code: "DATABASE_READ_FAILED", db_code: instrumentError.code ?? null }));
      return await fail(500, "DATABASE_READ_FAILED", "Could not read the instrument registry.", requestId);
    }
    const instrumentIds = new Map((instruments ?? []).map((row: { symbol: string; id: string }) => [row.symbol, row.id]));
    const missing = jobs.find((job) => !instrumentIds.has(job.symbol));
    if (missing) {
      return await fail(422, "INSTRUMENT_NOT_FOUND", "An instrument is not registered in the platform.", requestId);
    }

    stage = "data_source_lookup";
    const { data: source, error: sourceError } = await supabase
      .schema("core")
      .from("data_sources")
      .select("id")
      .eq("name", "Alpha Vantage")
      .eq("active", true)
      .maybeSingle();
    if (sourceError) {
      console.error(JSON.stringify({ event: "ingestion_failed", request_id: requestId, stage, code: "DATABASE_READ_FAILED", db_code: sourceError.code ?? null }));
      return await fail(500, "DATABASE_READ_FAILED", "Could not read the active provider registry.", requestId);
    }
    if (!source) {
      return await fail(422, "DATA_SOURCE_NOT_FOUND", "The Alpha Vantage provider is not registered as active.", requestId);
    }

    const summary: Array<Record<string, unknown>> = [];
    for (const job of jobs) {
      currentSymbol = job.symbol;
      stage = "provider_fetch";
      let series: Record<string, Record<string, string>>;
      try {
        series = await fetchDaily(job, apiKey);
      } catch (error) {
        const code = (error as { code?: string })?.code as FailureCode | undefined;
        const known = new Set<FailureCode>([
          "PROVIDER_HTTP_ERROR", "PROVIDER_RATE_LIMIT", "PROVIDER_NOTICE",
          "PROVIDER_REJECTED_REQUEST", "PROVIDER_NO_SERIES",
        ]);
        const safeCode = code && known.has(code) ? code : "INGESTION_FAILED";
        const safeMessages: Record<string, string> = {
          PROVIDER_HTTP_ERROR: "The market-data provider could not be reached successfully.",
          PROVIDER_RATE_LIMIT: "The market-data provider rate limit was reached.",
          PROVIDER_NOTICE: "The market-data provider returned a service notice.",
          PROVIDER_REJECTED_REQUEST: "The market-data provider rejected the requested FX series.",
          PROVIDER_NO_SERIES: "The provider response did not contain a daily FX series.",
          INGESTION_FAILED: "Market-data retrieval failed.",
        };
        console.error(JSON.stringify({ event: "ingestion_failed", request_id: requestId, stage, symbol: currentSymbol, code: safeCode }));
        const status = safeCode === "PROVIDER_RATE_LIMIT" || safeCode === "PROVIDER_NOTICE" ? 429 : 502;
        return await fail(status, safeCode, safeMessages[safeCode], requestId);
      }

      stage = "normalize_provider_data";
      const instrumentId = instrumentIds.get(job.symbol);
      const rows: Array<Record<string, unknown>> = [];
      try {
        for (const [date, values] of Object.entries(series)) {
          if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) continue;
          const open = numeric(values["1. open"]);
          const high = numeric(values["2. high"]);
          const low = numeric(values["3. low"]);
          const close = numeric(values["4. close"]);
          if (open <= 0 || high <= 0 || low <= 0 || close <= 0 ||
              high < Math.max(open, close) || low > Math.min(open, close) || high < low) continue;
          rows.push({
            instrument_id: instrumentId,
            timeframe: "daily",
            ts: `${date}T00:00:00Z`,
            open, high, low, close,
            volume: null,
            spread: null,
            source_id: source.id,
            metadata: { provider: "alpha_vantage", provider_symbol: `${job.from}${job.to}`, retrieval: "FX_DAILY" },
          });
        }
      } catch {
        console.error(JSON.stringify({ event: "ingestion_failed", request_id: requestId, stage, symbol: currentSymbol, code: "INVALID_PROVIDER_DATA" }));
        return await fail(502, "INVALID_PROVIDER_DATA", "Provider price data failed validation.", requestId);
      }
      if (rows.length === 0) {
        console.error(JSON.stringify({ event: "ingestion_failed", request_id: requestId, stage, symbol: currentSymbol, code: "INVALID_PROVIDER_DATA" }));
        return await fail(502, "INVALID_PROVIDER_DATA", "The provider returned no valid daily price rows.", requestId);
      }

      stage = "database_upsert";
      let upserted = 0;
      for (let offset = 0; offset < rows.length; offset += 500) {
        const chunk = rows.slice(offset, offset + 500);
        const { error: writeError } = await supabase
          .schema("market")
          .from("price_bars")
          .upsert(chunk, { onConflict: "instrument_id,timeframe,ts" });
        if (writeError) {
          console.error(JSON.stringify({ event: "ingestion_failed", request_id: requestId, stage, symbol: currentSymbol, code: "DATABASE_WRITE_FAILED", db_code: writeError.code ?? null }));
          return await fail(500, "DATABASE_WRITE_FAILED", "Price history could not be written to the database.", requestId);
        }
        upserted += chunk.length;
      }

      summary.push({
        instrument: job.symbol,
        status: "ok",
        rows: upserted,
        earliest_date: rows[rows.length - 1]?.ts,
        latest_date: rows[0]?.ts,
      });
    }

    if (auditWriter) await auditWriter("succeeded", {
      instruments: summary,
      records_processed: summary.reduce((total, item) => total + Number(item.rows ?? 0), 0),
    });
    console.log(JSON.stringify({
      event: "ingestion_succeeded",
      request_id: requestId,
      user_id: user.id,
      instruments: summary.map((item) => ({ symbol: item.instrument, rows: item.rows })),
    }));
    return json(200, { ok: true, request_id: requestId, summary });
  } catch (error) {
    if (auditWriter) await auditWriter("failed", { error_code: "INGESTION_FAILED", stage, symbol: currentSymbol ?? null });
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error(JSON.stringify({ event: "ingestion_failed", request_id: requestId, stage, symbol: currentSymbol ?? null, code: "INGESTION_FAILED", error_name: error instanceof Error ? error.name : "UnknownError", error_message: message.slice(0, 200) }));
    return publicFailure(500, "INGESTION_FAILED", "Ingestion failed unexpectedly. Use the request ID to find its server log.", requestId);
  }
});
