// Pure helpers for Dukascopy hourly tick files (.bi5, LZMA-compressed). No I/O and no runtime imports so they can be unit-tested with plain Node.
// Each decompressed tick is 20 bytes, big-endian: uint32 milliseconds since the start of the hour, uint32 ask, uint32 bid, float32 ask volume, float32 bid volume.
export type Tick = { ms: number; ask: number; bid: number };
export type Bar = { ts: string; open: number; high: number; low: number; close: number; volume: number; spread: number };

export function parseTicks(buf: Uint8Array): { ticks: Tick[]; trailingBytes: number } {
  const n = Math.floor(buf.length / 20);
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const ticks: Tick[] = [];
  for (let i = 0; i < n; i++) {
    const o = i * 20;
    ticks.push({ ms: view.getUint32(o), ask: view.getUint32(o + 4), bid: view.getUint32(o + 8) });
  }
  return { ticks, trailingBytes: buf.length - n * 20 };
}

// Bars are built from the bid price. `volume` is the tick count (Dukascopy volumes are indicative, not exchange volume).
// `spread` is the mean ask minus bid in price units. Ticks with a non-positive price or ask below bid are dropped and counted.
export function buildBars(hourStartMs: number, ticks: Tick[], scale: number, barMinutes = 5): { bars: Bar[]; dropped: number } {
  const size = barMinutes * 60000;
  const byBar = new Map<number, { o: number; h: number; l: number; c: number; n: number; spreadSum: number }>();
  let dropped = 0;
  const ordered = [...ticks].sort((a, b) => a.ms - b.ms);
  for (const t of ordered) {
    const bid = t.bid / scale, ask = t.ask / scale;
    if (!(bid > 0) || !(ask >= bid) || t.ms >= 3600000) { dropped++; continue; }
    const key = Math.floor((hourStartMs + t.ms) / size) * size;
    const b = byBar.get(key);
    if (!b) byBar.set(key, { o: bid, h: bid, l: bid, c: bid, n: 1, spreadSum: ask - bid });
    else { b.h = Math.max(b.h, bid); b.l = Math.min(b.l, bid); b.c = bid; b.n++; b.spreadSum += ask - bid; }
  }
  const r = (x: number) => Math.round(x * 1e6) / 1e6;
  const bars = [...byBar.entries()].sort((a, b) => a[0] - b[0]).map(([k, b]) => ({
    ts: new Date(k).toISOString(), open: r(b.o), high: r(b.h), low: r(b.l), close: r(b.c), volume: b.n, spread: r(b.spreadSum / b.n),
  }));
  return { bars, dropped };
}

// Dukascopy path: months are zero-based.
export function hourUrl(symbol: string, date: string, hour: number): string {
  const [y, m, d] = date.split("-").map(Number);
  return `https://datafeed.dukascopy.com/datafeed/${symbol}/${y}/${String(m - 1).padStart(2, "0")}/${String(d).padStart(2, "0")}/${String(hour).padStart(2, "0")}h_ticks.bi5`;
}

export const PRICE_SCALE: Record<string, number> = { USDJPY: 1000, XAUUSD: 1000 };
