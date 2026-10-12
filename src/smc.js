// Chart annotation for the owner's SMC + Fibonacci rules. Pure functions, no I/O. This describes what the visible candles show; it is not a trading signal.
// Rules mirror intelligence.smc_fib_backtest: 3-bar confirmed swings, bias from the last break of structure,
// leg = latest confirmed swing and the preceding opposite swing, Fib 0 at the leg start and 100 at its extreme,
// entry at 61.8% retracement, stop at 76.4%, target = nearest confirmed swing beyond the entry in the bias direction.
export const K = 3;

export function findSwings(bars, k = K) {
  const out = [];
  for (let i = k; i < bars.length - k; i++) {
    let hi = true, lo = true;
    for (let j = 1; j <= k; j++) {
      if (!(bars[i].high > bars[i - j].high && bars[i].high > bars[i + j].high)) hi = false;
      if (!(bars[i].low < bars[i - j].low && bars[i].low < bars[i + j].low)) lo = false;
    }
    if (hi) out.push({ i, type: 'H', price: bars[i].high });
    else if (lo) out.push({ i, type: 'L', price: bars[i].low });
  }
  return out;
}

// Bias flips to long when a close breaks the last confirmed swing high, to short when it breaks the last confirmed swing low.
// A swing is only usable k bars after it forms, because that is when it is confirmed.
export function structureBias(bars, swings, k = K) {
  let bias = 0, lastH = null, lastL = null, breakAt = null;
  const byConfirm = new Map();
  for (const s of swings) byConfirm.set(s.i + k, s);
  for (let i = 0; i < bars.length; i++) {
    const s = byConfirm.get(i);
    if (s) { if (s.type === 'H') lastH = s.price; else lastL = s.price; }
    if (lastH != null && bars[i].close > lastH) { bias = 1; breakAt = { i, price: lastH }; lastH = null; }
    else if (lastL != null && bars[i].close < lastL) { bias = -1; breakAt = { i, price: lastL }; lastL = null; }
  }
  return { bias, breakAt };
}

export function currentLeg(bars, k = K) {
  const swings = findSwings(bars, k);
  const { bias, breakAt } = structureBias(bars, swings, k);
  const base = { swings, bias, breakAt, leg: null, reason: null };
  if (swings.length < 3) return { ...base, reason: 'Not enough confirmed swings in view.' };
  if (bias === 0) return { ...base, reason: 'No break of structure yet, so there is no bias.' };
  const want = bias === 1 ? 'H' : 'L';
  // The most recent valid leg: a confirmed swing of the bias type that broke the previous swing of its kind, preceded by an opposite swing.
  let last = null, prev = null;
  for (let q = swings.length - 1; q >= 2 && !last; q--) {
    if (swings[q].type !== want || swings[q - 1].type === want) continue;
    let a = q - 2;
    while (a >= 0 && swings[a].type !== want) a--;
    if (a >= 0 && (bias === 1 ? swings[q].price > swings[a].price : swings[q].price < swings[a].price)) { last = swings[q]; prev = swings[q - 1]; }
  }
  if (!last) return { ...base, reason: 'No completed leg in the direction of the bias in view.' };
  const hp = bias === 1 ? last.price : prev.price, lp = bias === 1 ? prev.price : last.price, range = hp - lp;
  if (!(range > 0)) return { ...base, reason: 'Degenerate leg.' };
  const entry = bias === 1 ? hp - 0.618 * range : lp + 0.618 * range;
  const stop = bias === 1 ? hp - 0.764 * range : lp + 0.764 * range;
  let target = null;
  for (const s of swings) {
    if (bias === 1 && s.type === 'H' && s.price > entry && (target == null || s.price < target)) target = s.price;
    if (bias === -1 && s.type === 'L' && s.price < entry && (target == null || s.price > target)) target = s.price;
  }
  const px = bars[bars.length - 1].close;
  const beyond = bars.slice(last.i + 1).some((b) => (bias === 1 ? b.high > hp : b.low < lp));
  const state = beyond ? 'extended' : (bias === 1 && px < stop) || (bias === -1 && px > stop) ? 'invalidated'
    : (bias === 1 ? px <= entry : px >= entry) ? 'in_zone_or_through' : 'waiting_for_pullback';
  return { ...base, leg: { dir: bias, from: prev, to: last, hp, lp, entry, stop, target, state } };
}
