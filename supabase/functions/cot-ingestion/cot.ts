// Pure helpers for CFTC Traders in Financial Futures ingestion. No I/O and no runtime imports so they can be unit-tested with plain Node.
export const CONTRACTS = [
  { code: "099741", currency: "EUR" }, { code: "097741", currency: "JPY" }, { code: "096742", currency: "GBP" },
  { code: "232741", currency: "AUD" }, { code: "090741", currency: "CAD" }, { code: "092741", currency: "CHF" }, { code: "112741", currency: "NZD" },
] as const;

export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [], field = "", inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else inQuotes = false; }
      else field += c;
    } else if (c === '"') inQuotes = true;
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field); field = "";
      if (row.length > 1 || row[0] !== "") rows.push(row);
      row = [];
    } else field += c;
  }
  if (field !== "" || row.length) { row.push(field); rows.push(row); }
  return rows;
}

export type CotRow = {
  contract_code: string; currency_code: string; report_date: string; available_at: string;
  open_interest: number; lev_long: number; lev_short: number; asset_long: number; asset_short: number; dealer_long: number; dealer_short: number;
};

const FIELDS = ["open_interest_all", "lev_money_positions_long", "lev_money_positions_short", "asset_mgr_positions_long", "asset_mgr_positions_short", "dealer_positions_long_all", "dealer_positions_short_all"] as const;

// A Tuesday report is treated as known from the following Monday 00:00Z (D+6).
export function cotAvailableAt(reportDate: string): string {
  const d = new Date(reportDate + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + 6);
  return d.toISOString();
}

export function parseCot(csv: string): { rows: CotRow[]; rejected: number } {
  const t = parseCsv(csv);
  if (!t.length) throw new Error("CFTC_EMPTY_RESPONSE");
  const head = t[0];
  const idx = (n: string) => head.indexOf(n);
  const di = idx("report_date_as_yyyy_mm_dd"), ci = idx("cftc_contract_market_code");
  const fi = FIELDS.map(idx);
  if (di < 0 || ci < 0 || fi.some((i) => i < 0)) throw new Error("CFTC_UNEXPECTED_COLUMNS");
  const out = new Map<string, CotRow>();
  let rejected = 0;
  for (const r of t.slice(1)) {
    const contract = (r[ci] ?? "").trim();
    const meta = CONTRACTS.find((c) => c.code === contract);
    const date = (r[di] ?? "").slice(0, 10);
    const vals = fi.map((i) => (r[i] ?? "").trim());
    const nums = vals.map((v) => (v === "" ? NaN : Number(v)));
    if (!meta || !/^\d{4}-\d{2}-\d{2}$/.test(date) || nums.some((n) => !Number.isFinite(n) || n < 0)) { rejected++; continue; }
    out.set(contract + "|" + date, {
      contract_code: contract, currency_code: meta.currency, report_date: date, available_at: cotAvailableAt(date),
      open_interest: nums[0], lev_long: nums[1], lev_short: nums[2], asset_long: nums[3], asset_short: nums[4], dealer_long: nums[5], dealer_short: nums[6],
    });
  }
  return { rows: [...out.values()].sort((a, b) => a.report_date.localeCompare(b.report_date) || a.contract_code.localeCompare(b.contract_code)), rejected };
}
