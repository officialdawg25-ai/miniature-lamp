# Phase 0 audit: news, central-bank, expectations and SMC intelligence (2026-10-13)

Scope: master implementation prompt "Institutional-Grade Economic Intelligence ... and Validated Trading Edge Discovery". Phase 0 only: no production structure was changed for this phase. Everything below was read from the repository (branch `claude/trading-platform-discovery-repair-catv5x`) and the production database `ieocpcapgwusbojzrrxr` on 2026-10-13. The broader data and research audit of the same day is in `docs/research-audit-2026-10-13.md` and is not repeated.

## 1. Architecture map (as built)

```
Sources                       Ingestion (Edge Functions, pg_cron)          Stores                                   Consumers
-------                       -----------------------------------          ------                                   ---------
8 central-bank RSS feeds  ->  news-ingestion (2-hourly)                 -> market.news_events (77)               -> get_news -> News page
Forex Factory weekly feed ->  calendar-ingestion (hourly)               -> macro.calendar_events (109, forward)  -> Calendar page
BLS schedule, ALFRED      ->  alfred-vintage-ingestion                  -> macro.alfred_vintage_observations,    -> macro-factor-engine
                                                                           macro.provider_release_calendars      -> macro.factor_observations (109)
FRED / MoF / CB sites     ->  scheduled-refresh, policy-rates-global,  -> macro.policy_rate_observations,       -> compute_macro_regime -> regime_states (1)
                              yield-ingestion, reference-series-ingest.    market.yield_observations,
                                                                           market.reference_observations
CFTC                      ->  cot-ingestion (weekly)                    -> macro.cot_observations
Twelve Data / AV          ->  intraday-twelvedata (hourly), market-data -> market.price_bars                     -> live-candles, SMC chart (src/smc.js)
federalreserve.gov        ->  pg_net (one-off)                          -> macro.fomc_meetings (157)
                                                                                                                 -> generate_decision_records -> decision_records
Research: intelligence.research_hypotheses + hypothesis_status_history + backtest_runs (single-confirmation guard) -> Research ledger page
Execution: risk gate (trading.*), auto risk engine, paper ticket, execution-host-api <- MT5 host (not yet connected)
```

## 2. Capability inventory against the prompt

| Prompt capability | What exists | Status |
|---|---|---|
| 3.1 News ingestion and source management | Official RSS from Fed, ECB, BoE, BoJ, RBA, BoC, SNB, RBNZ; `news_upsert_rows` rejects items dated more than 1 h ahead; URL is the dedup key | **Partial.** 77 items, RSS summaries only (7 with more than 200 characters of text). No content fingerprint, no update/correction lineage, no first-ingested vs last-updated distinction, publisher not stored per row (only a currency keyword tag), no source-reliability class, no event-vs-publication time |
| 3.2 to 3.4 Semantic comprehension; facts vs claims vs interpretation; importance classes | None. `sentiment_score`, `relevance_score`, `embedding` columns exist but are empty for all 77 rows (intentionally: no validated scoring) | **Missing.** No language-model integration and no model API key among the Edge Function secrets |
| 4 Central-bank profiles and reaction functions | `macro.central_banks` (8, with policy rate and meeting cycle only); policy rates 2008 to now for all 8; scheduled FOMC dates; `macro.policy_decisions` table exists but is **empty** | **Partial**: data foundations only; no mandate/target/projection records, no dated profile versions, no statement texts, no communication comparison |
| 5.3 Surprise measurement | `macro.economic_releases` (6 rows, no forecasts), `surprise_statistics` (empty), forward-only consensus from the calendar | **Blocked**: no historical consensus. Surprise cannot be measured historically, and the code correctly refuses to invent one |
| 6 Buy the rumour, sell the fact | Event-study engine (`trade_stats`, release continuation/fade, FOMC runners), FOMC dates, BLS calendar 2021 on, 15-minute EURUSD/USDJPY/XAUUSD from 2020 | **Partial**: price-side event windows are testable now; the expectations side (futures, OIS, options, consensus history) is not available |
| 7 SMC with fundamentals | `src/smc.js` and SQL `smc_fib_backtest`: confirmed swings (3 bars, look-ahead safe), break-of-structure bias, current leg, Fibonacci OTE | **Partial**: no CHoCH/MSS, FVG, order blocks, liquidity sweeps or multi-timeframe; the two SMC hypotheses tested were rejected |
| 7.3 Gold model | Gold daily from 1988, 15m from 2020; US real yield, breakevens, broad dollar, GVZ, VIX now stored | **Data partial**: no ETF flows or official-sector purchases; gold untradable at the 120 USD account size |
| 8 Expectations engine | US 2Y as a policy-path proxy, breakevens, curve; no futures/OIS | **Partial; blocked by paid data** |
| 9 Integrated decision flow | `generate_decision_records` returns `no_trade` with `no_validated_strategy` for every instrument (correct: none is validated) | Placeholder by design |
| 10 to 11 Validation and research memory | Pre-registration ledger, stored runs, single-run guard, forward tests | **Exists and in use** (31 hypotheses) |
| 13 Untrusted-content isolation | News is stored as data only; nothing reads it into instructions or decisions | Holds today; must be preserved when an LLM is added |

## 3. Defects versus intentional states

| Observation | Classification |
|---|---|
| 10 news rows dated in the future (Bank of Canada / Banca d'Italia scheduled-event pages, stored 2026-10-12 12:06 before the guard) | Known defect, contained: `get_news` excludes them; deleting them needs the owner's approval |
| `sentiment_score`, `relevance_score`, `embedding` all empty | Intentional (no validated scorer) |
| `macro.policy_decisions` empty | Missing: no ingestion was ever built |
| `currency_scores` empty, `pair_scores` 11 rows from 2026-10-08 with no ML probability | Intentional placeholders; no validated model |
| `economic_releases` 6 rows without forecasts | Intentional: no consensus history |
| ALFRED vintages not point-in-time eligible | Intentional: publication second not independently verified |
| Daily Alpha Vantage FX stale since 2026-10-09 | Defect: the function needs a user session and has no schedule |
| `trading.broker_symbol_specs` empty | Awaiting the MT5 host |

## 4. Hard dependencies (owner decisions)

1. **A language model for comprehension (sections 3.2 to 3.4, 4.3 to 4.4, 5.1).** Nothing in the stack can interpret text today. Options: an Anthropic API key stored as an Edge Function secret (ongoing cost per document; the platform's 2-hourly central-bank feed is about 10 to 40 items a day), or a deterministic-only scope (structured extraction from official pages, no semantic interpretation). The model output would be stored as labelled interpretation with source excerpts, never as fact, and could not reach decisions or orders.
2. **Historical consensus and policy expectations (sections 5.3, 6.2, 8).** Without paid data (consensus history, fed funds futures / OIS, FX options), "surprise" and "what was priced in" can only be proxied (US 2Y yield changes, breakevens). Proxies must be labelled as such.
3. **News licensing.** Only official publisher feeds are used. Commercial news needs a licensed API; none is configured.

## 5. Implementation plan (proposed, smallest defensible steps)

Phase 1 (design, no production changes):
- Data contracts: news item (publisher, canonical URL, content fingerprint, published / event / first-seen / last-seen times, version lineage, reliability class), extracted claim (type: fact / attributed claim / official forecast / interpretation, supporting excerpt, confidence), central-bank profile version (valid_from, sources), communication diff.
- Reuse: `market.news_events` (add columns, keep URL key), `macro.policy_decisions` (fill from official decision pages), `macro.central_banks` (mandate and target as dated versions in a new profile-version table).

Phase 2 candidates, in order of evidence value:
1. **Deterministic central-bank decision history** into `macro.policy_decisions` from the stored policy-rate series (rate changes and holds per meeting) for all 8 banks: no model needed, point-in-time by construction.
2. **News provenance hardening**: fingerprint, publisher field, update lineage, first-seen time; backfill nothing that was not observed.
3. **FOMC statement texts** from federalreserve.gov (reachable through pg_net) with dated versions, enabling statement-to-statement diffs; deterministic diffs first, model interpretation only after dependency 1 is decided.

Phase 3 candidate research (registered before any outcome is computed): price-side anticipation and reversal around FOMC and BLS events using the 15-minute bars already stored (pre-event drift vs post-event reversal), with the yield change on the day as the only available expectations proxy, labelled as a proxy.

## 6. Acceptance status

None of the prompt's 17 acceptance criteria is claimed as met by this phase. Criteria 1, 2, 13 and 15 are partially met by existing components (official-feed ingestion with timestamps, recorded failed research, security boundaries); the rest depend on Phases 1 to 6 and on the decisions in section 4.
