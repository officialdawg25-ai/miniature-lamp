// Alpha Vantage FX_DAILY parsing for the scheduled daily refresh. Kept free of Deno APIs so it can be unit-tested under Node.
export const PAIRS: Record<string, [string, string]> = {
  USDJPY: ["USD", "JPY"], EURUSD: ["EUR", "USD"], GBPUSD: ["GBP", "USD"], USDCHF: ["USD", "CHF"], USDCAD: ["USD", "CAD"],
  AUDUSD: ["AUD", "USD"], NZDUSD: ["NZD", "USD"], EURJPY: ["EUR", "JPY"], GBPJPY: ["GBP", "JPY"], AUDJPY: ["AUD", "JPY"],
};

export type DailyBar = { date: string; open: number; high: number; low: number; close: number };
export class ProviderError extends Error { code: string; constructor(code: string) { super(code); this.code = code; } }

// Returns valid bars, oldest first. Rows with non-positive or internally inconsistent prices are dropped and counted.
// The bar dated today (UTC) is still forming and is never returned.
export function parseFxDaily(body: unknown, todayUtc: string): { bars: DailyBar[]; rejected: number } {
  if (!body || typeof body !== "object") throw new ProviderError("PROVIDER_NO_SERIES");
  const b = body as Record<string, unknown>;
  if (b["Note"]) throw new ProviderError("PROVIDER_RATE_LIMIT");
  if (b["Information"]) throw new ProviderError("PROVIDER_NOTICE");
  if (b["Error Message"]) throw new ProviderError("PROVIDER_REJECTED_REQUEST");
  const series = b["Time Series FX (Daily)"];
  if (!series || typeof series !== "object" || Array.isArray(series)) throw new ProviderError("PROVIDER_NO_SERIES");
  const bars: DailyBar[] = [];
  let rejected = 0;
  for (const [date, v] of Object.entries(series as Record<string, Record<string, string>>)) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date >= todayUtc) { if (date !== todayUtc) rejected++; continue; }
    const open = Number(v?.["1. open"]), high = Number(v?.["2. high"]), low = Number(v?.["3. low"]), close = Number(v?.["4. close"]);
    if (![open, high, low, close].every((x) => Number.isFinite(x) && x > 0) || high < Math.max(open, close) || low > Math.min(open, close)) { rejected++; continue; }
    bars.push({ date, open, high, low, close });
  }
  bars.sort((a, c) => a.date.localeCompare(c.date));
  return { bars, rejected };
}
