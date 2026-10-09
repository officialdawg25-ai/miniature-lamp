export type CloseBar = { ts: string; close: number };

export type TechnicalMetrics = {
  barsUsed: number;
  asOf: string;
  momentumLogReturn: number;
  dailyVolatility: number;
  annualizedVolatility: number;
  technicalScore: number;
};

export function calculateTechnicalMetrics(barsNewestFirst: CloseBar[]): TechnicalMetrics | null {
  if (!Array.isArray(barsNewestFirst) || barsNewestFirst.length < 21) return null;
  const bars = [...barsNewestFirst].reverse();
  const closes = bars.map((bar) => Number(bar.close));
  if (closes.some((value) => !Number.isFinite(value) || value <= 0)) return null;
  const returns: number[] = [];
  for (let i = 1; i < closes.length; i++) {
    const value = Math.log(closes[i] / closes[i - 1]);
    if (!Number.isFinite(value)) return null;
    returns.push(value);
  }
  const mean = returns.reduce((sum, value) => sum + value, 0) / returns.length;
  const variance = returns.reduce((sum, value) => sum + (value - mean) ** 2, 0) / returns.length;
  const dailyVolatility = Math.sqrt(variance);
  const momentumLogReturn = Math.log(closes[closes.length - 1] / closes[0]);
  if (![dailyVolatility, momentumLogReturn].every(Number.isFinite)) return null;

  // Bounded, transparent trend-strength score. This is not a probability or a forecast.
  const scale = Math.max(dailyVolatility * Math.sqrt(returns.length), 1e-8);
  const technicalScore = Math.max(-100, Math.min(100, 100 * Math.tanh(momentumLogReturn / scale)));
  return {
    barsUsed: bars.length,
    asOf: bars[bars.length - 1].ts,
    momentumLogReturn,
    dailyVolatility,
    annualizedVolatility: dailyVolatility * Math.sqrt(252),
    technicalScore,
  };
}
