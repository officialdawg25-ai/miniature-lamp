import { assertEquals, assertAlmostEquals } from "jsr:@std/assert@1";
import { calculateTechnicalMetrics } from "./technical.ts";

Deno.test("requires at least 21 valid close bars", () => {
  assertEquals(calculateTechnicalMetrics(Array.from({ length: 20 }, (_, i) => ({ ts: new Date(i * 86400000).toISOString(), close: 100 + i }))), null);
});

Deno.test("returns a positive bounded technical score for rising prices", () => {
  const bars = Array.from({ length: 30 }, (_, i) => ({ ts: new Date(i * 86400000).toISOString(), close: 100 + i })).reverse();
  const result = calculateTechnicalMetrics(bars);
  if (!result) throw new Error("expected metrics");
  if (result.technicalScore <= 0 || result.technicalScore > 100) throw new Error("score should be positive and bounded");
  assertEquals(result.barsUsed, 30);
});

Deno.test("rejects non-positive or non-finite closes", () => {
  const bars = Array.from({ length: 21 }, (_, i) => ({ ts: new Date(i * 86400000).toISOString(), close: i === 5 ? 0 : 100 + i })).reverse();
  assertEquals(calculateTechnicalMetrics(bars), null);
});

Deno.test("flat series has zero momentum and volatility", () => {
  const bars = Array.from({ length: 21 }, (_, i) => ({ ts: new Date(i * 86400000).toISOString(), close: 100 })).reverse();
  const result = calculateTechnicalMetrics(bars);
  if (!result) throw new Error("expected metrics");
  assertAlmostEquals(result.technicalScore, 0, 1e-8);
  assertAlmostEquals(result.annualizedVolatility, 0, 1e-8);
});
