export type ProviderBar = {
  datetime?: unknown;
  open?: unknown;
  high?: unknown;
  low?: unknown;
  close?: unknown;
  volume?: unknown;
};

export type NormalizedBar = {
  date: string;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number | null;
};

function positiveFiniteNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

/** Normalize one Twelve Data daily OHLC row; null means reject the row. */
export function normalizeProviderBar(input: ProviderBar): NormalizedBar | null {
  const date = typeof input.datetime === "string" ? input.datetime : "";
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;

  const parsedDate = new Date(date + "T00:00:00Z");
  if (Number.isNaN(parsedDate.getTime()) || parsedDate.toISOString().slice(0, 10) !== date) return null;

  const open = positiveFiniteNumber(input.open);
  const high = positiveFiniteNumber(input.high);
  const low = positiveFiniteNumber(input.low);
  const close = positiveFiniteNumber(input.close);
  if (open === null || high === null || low === null || close === null) return null;
  if (high < Math.max(open, close) || low > Math.min(open, close) || high < low) return null;

  return { date, open, high, low, close, volume: positiveFiniteNumber(input.volume) };
}
