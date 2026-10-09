import { assertEquals } from "jsr:@std/assert@1";
import { normalizeProviderBar } from "./validation.ts";

Deno.test("normalizes a valid gold daily bar", () => {
  assertEquals(normalizeProviderBar({
    datetime: "2026-10-08", open: "3900.10", high: "3942.00",
    low: "3881.50", close: "3922.25", volume: "1200",
  }), {
    date: "2026-10-08", open: 3900.1, high: 3942,
    low: 3881.5, close: 3922.25, volume: 1200,
  });
});

Deno.test("rejects missing, non-positive and non-finite prices", () => {
  for (const input of [
    { datetime: "2026-10-08", open: null, high: 3, low: 1, close: 2 },
    { datetime: "2026-10-08", open: 1, high: 3, low: 0, close: 2 },
    { datetime: "2026-10-08", open: "Infinity", high: 3, low: 1, close: 2 },
  ]) assertEquals(normalizeProviderBar(input), null);
});

Deno.test("rejects inconsistent OHLC ranges", () => {
  assertEquals(normalizeProviderBar({ datetime: "2026-10-08", open: 10, high: 9, low: 8, close: 9 }), null);
  assertEquals(normalizeProviderBar({ datetime: "2026-10-08", open: 10, high: 12, low: 11, close: 9 }), null);
  assertEquals(normalizeProviderBar({ datetime: "2026-10-08", open: 10, high: 12, low: 8, close: 13 }), null);
});

Deno.test("rejects invalid calendar dates and malformed timestamps", () => {
  assertEquals(normalizeProviderBar({ datetime: "2026-02-30", open: 10, high: 12, low: 8, close: 11 }), null);
  assertEquals(normalizeProviderBar({ datetime: "2026-10-08T00:00:00Z", open: 10, high: 12, low: 8, close: 11 }), null);
});

Deno.test("treats missing, zero or negative volume as unavailable without rejecting price data", () => {
  for (const volume of [undefined, null, 0, -1, ""]) {
    const row = normalizeProviderBar({ datetime: "2026-10-08", open: 10, high: 12, low: 8, close: 11, volume });
    assertEquals(row?.volume, null);
  }
});
