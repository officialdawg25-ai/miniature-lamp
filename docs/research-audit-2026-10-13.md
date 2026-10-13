# Research programme audit, data discovery and feasibility (2026-10-13)

Scope: the master implementation prompt of 2026-10-13. Every figure below was read from the production database (Supabase `ieocpcapgwusbojzrrxr`) or produced by a stored, pre-registered run on that day. Nothing is estimated unless marked as such.

## A. Platform findings (Phase 1)

### Data inventory (verified counts)

| Dataset | Table | Coverage | Status |
|---|---|---|---|
| FX daily, 7 USD pairs + 3 crosses | `market.price_bars` (Alpha Vantage) | 2007-08 to 2026-10-08 (crosses from 2023) | **Stale since 2026-10-09**: `market-data-ingestion` needs a signed-in user and has no schedule |
| EURUSD 15m | `market.price_bars` (Twelve Data) | 2020-01-30 to now, 174k bars | Live (hourly forward job); includes vendor weekend quotes |
| USDJPY 15m | same | 2020-10-29 to now, 155k bars | Live |
| XAUUSD 15m | same | 2020-01-24 to now, 170k bars | Live; vendor has no earlier history |
| XAUUSD daily | same | 1988-12 to now, 10k bars | On demand; weekend quotes from 2024 excluded in research |
| SPY, EZU daily (total return) | same, inactive research-only instruments | SPY 1993-01-29, EZU 2006-11 | On demand |
| Policy rates, 8 central banks | `macro.policy_rate_observations` | 2008 to now | Live |
| US 2Y/10Y, 10Y real; JGB 2/5/10Y | `market.yield_observations` | 2008 to now | Live |
| CFTC TFF positioning, 7 currencies | `macro.cot_observations` | 2008 to now, 979 weeks each, availability = report date + 6 days | Live (weekly) |
| ALFRED first-release vintages: CPI, core CPI, unemployment | `macro.alfred_vintage_observations` | 2021 to now | Stored but **not point-in-time eligible**: publication second not independently verified (by design) |
| BLS release calendar | `macro.provider_release_calendars` | 2021 to 2026 | Usable |
| Scheduled FOMC dates | `macro.fomc_meetings` | 157 meetings 2007 to 2026, from federalreserve.gov | Verified against all 30 target changes |
| Economic calendar (forecasts) | `macro.calendar_events` | Forward only (one week), no actuals | **No historical consensus exists**: true surprise studies are impossible |
| Central-bank news | `market.news_events` | 74 items, 8 RSS feeds | Live, no sentiment |
| **New today:** FRED reference series | `market.reference_series`, `market.reference_observations` | See section B | Live (daily refresh) |
| Broker contract specifications | `trading.broker_symbol_specs` | **Empty**: no MT5 host has connected | Blocks every tradability verification |

### Engineering and integrity findings
- **Duplicate confirmation run (fixed going forward).** A client timeout let `eurusd-month-end-hedge-rebalancing` be stored twice (runs `713b8d48` and `4b50cc26`, identical result hash). A trigger now refuses a second confirmation run for any historical hypothesis; forward tests (with an `interim_policy`) still store interim runs. Tested: second historical run refused, forward run accepted, unlinked run accepted. The duplicate row itself is unchanged: the tool refused the update to stored evidence, which needs the owner's approval.
- **Temporary EURUSD backfill job did not stop itself.** Its stop condition assumed history to 2020-01-03, but the vendor starts at 2020-01-30. It was found in this audit and unscheduled after 2 wasted vendor calls.
- **Daily jobs showing no runs** are a history-retention artefact (cron history starts 2026-10-12 09:48), not failures; their data has current retrieval dates.

### Research ledger (verified)
31 hypotheses: 26 retired, 3 `backtest_completed`, 2 registered forward tests. 8 of the earliest have no stored run (they predate run storage; their verdicts are in the status history).

### Forward tests (Phase 10, unchanged)
| Test | Registered | Starts | Decision | Observations now | Integrity |
|---|---|---|---|---|---|
| `xauusd-asia-london-session-drift-forward` | 2026-10-12 18:41 UTC | trading days from 2026-10-14 | at 250 days (about 2027-10) | 0 | 1 status entry, no runs, rules unchanged; XAUUSD 15m arriving hourly |
| `eurusd-fomc-day-long-stop56-forward` | 2026-10-13 03:58 UTC | FOMC 2026-10-28 | at 24 meetings (about 2029-09); early stop at -360 pips | 0 | 1 status entry, no runs, rules unchanged; EURUSD 15m arriving hourly; 15m method agrees with the daily method on the three 2026 meetings already loaded |

## B. Data-source findings (Phases 3 to 5)

### Feasibility matrix

| Source / dataset | Access | Cost | History | Update | Timestamp / revisions | Licensing | Status | Research value | Priority |
|---|---|---|---|---|---|---|---|---|---|
| FRED VIXCLS (VIX) | FRED API (existing key) | Free | 1990 | Daily, posted next day | Market close, not revised | CBOE copyright, research use | **Ingested, verified** | Equity implied vol, risk regime, VRP | High |
| FRED GVZCLS (gold implied vol) | same | Free | 2008-06 | Daily | same | CBOE | **Ingested** | Gold implied vs realised vol | Medium (gold not tradable at 120 USD) |
| FRED EVZCLS (EUR/USD implied vol) | same | Free | 2007-11 to **2025-03-11** | **Discontinued by CBOE** | same | CBOE | Ingested, history only | Historical EURUSD VRP only; no live rule possible | Low |
| FRED BAA10Y (credit spread) | same | Free | 1986 | Daily | Computed from closes | Moody's copyright | **Ingested** | Risk appetite | Medium |
| FRED T10YIE (10Y breakeven) | same | Free | 2003 | Daily | same | Fed / Treasury | **Ingested** | Inflation expectations | Medium |
| FRED T10Y2Y (curve) | same | Free | 1976 | Daily | same | Treasury | **Ingested** | Curve regime | Medium |
| FRED DTWEXBGS (broad dollar) | same | Free | 2006 | **Weekly H.10 release**: availability set to date + 8 days | not revised | Federal Reserve | **Ingested** | Broad dollar factor | Medium |
| FRED DFF (fed funds) | same | Free | 1986 | Daily | not revised | Federal Reserve | **Ingested** | Financing cost modelling | High (cost realism) |
| FRED NFCI / STLFSI4 | same | Free | 1971 / 1993 | Weekly | **Revised every week**: needs ALFRED vintages | Fed | Not ingested (excluded by design) | Financial conditions | Medium |
| Historical consensus forecasts | Paid terminals (Bloomberg, Refinitiv) or paid calendar APIs | Paid, cost not verified | Varies | Event | Contemporaneous survey | Commercial | **Not available**; the free calendar is forward-only | Enables true surprise studies | High value, blocked by cost |
| OIS / fed funds futures (policy expectations) | CME DataMine, Bloomberg | Paid, not verified | Decades | Daily / tick | Exchange time | Commercial | Not available; free proxy: US 2Y (stored) | Policy-surprise and expectations research | High value, blocked by cost |
| FX options surfaces / risk reversals | CME DataMine, Bloomberg, OTC dealers | Paid, not verified | Varies | Daily | | Commercial | Not available; free substitute EVZ is discontinued | VRP, skew, event vol | High value, blocked by cost |
| CFTC disaggregated (gold) and TFF | CFTC public reporting API | Free | 2006 / 2008 | Weekly (Friday for Tuesday) | report + release dates | Public | TFF ingested; gold disaggregated not ingested | Positioning (an FX contrarian test already failed) | Low |
| Broker tick history and spreads | Exness MT5 terminal (`copy_ticks`) through the execution host | Free with an account | Broker-dependent | Tick | Broker server time | Broker terms | **Needs a running MT5 host** | Real spreads, event spread widening, stop slippage | High for tradability |
| Broker contract specifications | MT5 `symbol_info` through the host; Exness web pages are JavaScript-rendered or bot-protected | Free | Current only | On connect | | | **Unverifiable until a host connects** | Minimum lot, tick value, margin, swap | Critical for tradability |
| Japan MoF intervention records | mof.go.jp (published with a lag) | Free | 1991 | Quarterly / monthly | Disclosure lags | Public | Not ingested; not verified this session | Intervention studies (small sample) | Low |
| Twelve Data | API (existing key) | Free tier, 800 requests/day | FX 15m from 2020; XAU daily from 1988; SPY from 1993 | Hourly jobs | Bar open, UTC | Free-tier terms | Ingested | Price series | Existing |

Reachability evidence: the FRED API answered from the database host; `fredgraph.csv` failed (HTTP/2 stream errors); the sandbox proxy blocks FRED, federalreserve.gov and Exness entirely.

### Integration delivered
- `supabase/functions/reference-series-ingestion` (v2, cron-secret auth, allow-listed series only, `probe` mode stores nothing). Per-series availability lag (daily closes +1 day 14:00 UTC; weekly H.10 +8 days); missing FRED values (".") skipped and counted, never stored as zero; discontinued EVZ flagged and not refreshed; licensing noted per series.
- Tables with row-level security on and no access for `anon`/`authenticated`; `service_role` has the same grants as the other market tables.
- Verified records: VIXCLS 9,292 (1990-01-02 to 2026-10-09, range 9.14 to 82.69); GVZCLS 4,620; EVZCLS 4,360 (to 2025-03-11); BAA10Y 10,193; T10YIE 5,948; T10Y2Y 10,200; DTWEXBGS 5,203; DFF 14,891. Availability lags verified per row (38 h; 206 h for DTWEXBGS). No weekend rows except DFF, which is a calendar-day series.
- Cron `reference-series-daily-refresh` (Tue to Sat 15:35 UTC, last 30 days, 7 requests a day).
- Tests: `tests/reference-series.test.mjs` (5 tests).

## C. Research: failure classification (Phase 2) and the new test (Phase 6)

| Hypothesis family | Principal reason |
|---|---|
| G8 cross-sectional momentum; time-series trend vol-scaled; carry with trend filter; vol-managed carry | No significant edge after costs |
| Plain G8 carry | Inconclusive (t 1.79, not reproduced at 0.42 Sharpe; 0.19 to 0.29 on the current engine) |
| USDJPY yield / policy differential rules; gold real-yield rules | No out-of-sample evidence |
| COT leveraged-fund contrarian | No significant edge; unstable across halves |
| SMC + Fibonacci OTE (2 variants) | Negative after costs |
| US release continuation (USDJPY, gold); release fade (USDJPY, independent out of sample) | Fade: in-sample effect disappeared out of sample; continuation: no edge |
| Gotobi Tokyo fix | No edge (gotobi days no different from other days) |
| London breakout of the Tokyo range | No significant edge; tail-dependent |
| Gold Asia+London session drift | Inconclusive (strongest intraday result; replication impossible: vendor history; now forward-testing) |
| USDJPY Tokyo / New York local-hours depreciation | Effect absent (opposite sign) |
| FX daily large-move reversal | No edge (moves continued) |
| Gold daily 12-month momentum | No timing value over holding gold |
| FOMC-day dollar weakness (basket; EURUSD 56-pip stop) | Historically validated, but **structurally weakened**: 11 of the last 15 meetings lost; drawdown above the 36 USD kill switch; forward-testing |
| EURUSD FOMC 30-pip stop | Untradable sizing: stop too tight for event volatility |
| EURUSD month-end hedge rebalancing | No edge (placebo also loses) |
| SPY FOMC-day premium | Structurally decayed after 2016 |
| SPY CPI/PPI/payrolls premium | Inconclusive, tail-dependent |
| **SPY variance risk premium, monthly (new today)** | **Inconclusive: direction as predicted, too weak** |

New hypothesis `spy-variance-risk-premium-monthly-timing` (Bollerslev, Tauchen and Zhou 2009): registered before VIX was stored; the first use of options-implied data on the platform. Rule: long US500 for the next month when VIX²/12 minus the month's realised variance is above its 60-month median; returns net of financing at fed funds + 2.5% and 2 bp per round trip. Result (run `10833359`, 344 months 1998 to 2026, 153 in market): mean net +0.65% per in-market month (t 1.61, p 0.053 against 0.025); in-market +0.65% vs out-of-market +0.25% (Welch p 0.22); timed Sharpe 0.30 vs buy and hold 0.31; halves +0.10 / +1.19; from 2010 +1.11; stress +0.34; without the best 5% +0.10; drawdown 35.1 USD at 60 USD notional. 7 of 10 checks: **rejected**. The signal points the right way, but monthly timing adds nothing measurable over simply holding the index.

## D. Account feasibility (Phase 9)

Account: Exness demo Standard, USD, 120 USD equity, option 2 limits (6 USD per trade, 12 daily, 24 weekly, 6 open, kill switch at 36 USD drawdown). **No contract specification is broker-verified**: `trading.broker_symbol_specs` is empty until an MT5 host connects. The values below are standard market conventions, marked as such.

| Instrument | Minimum size (convention) | Value per unit move at minimum | Stop that fits 6 USD | Representative cost | Can satisfy 36 USD drawdown budget? |
|---|---|---|---|---|---|
| EURUSD | 0.01 lot = 1,000 EUR | 0.10 USD per pip | about 58 pips including costs | 1.0 pip spread + slippage (assumed) | Only for strategies with historical drawdown below 360 pips: none so far |
| USDJPY | 0.01 lot = 1,000 USD | about 0.067 USD per pip at 150 | about 88 pips | 1.2 pips (assumed) | Same issue, slightly more room (about 540 pips) |
| XAUUSD | 0.01 lot = 1 oz | 1 USD per 1 USD move | 6 USD (about 0.15% of price) | 0.40 USD/oz (assumed) | No: gold's daily range is far larger |
| US500 CFD | **unverified** (likely contract size 1, minimum 0.01 to 0.1) | **unverified** | **unverified** | 2 bp assumed; financing unverified (swap-free status of indices unknown) | Only research-feasible until confirmed |

## E. Implementation evidence
- Migrations: `20261013300000_one_confirmation_run_per_hypothesis`, `20261013310000_add_reference_series` (with service-role grant), `20261013320000_schedule_reference_series_refresh`, `20261013330000_add_spy_vrp_test`; earlier today `20261013240000` to `20261013290000` (balance, FOMC forward, ETFs, month-end, announcement tests).
- Edge Functions: `reference-series-ingestion` v2 (new), `intraday-twelvedata` v7.
- UI: the research ledger page now shows evidence labels (REGISTERED, TESTING, REJECTED, INCONCLUSIVE, HISTORICALLY VALIDATED, FORWARD TESTING) derived only from stored stages and run results; TRADABLE is 0 by rule until broker terms are verified.
- Tests: `npm test` 114 passed, build and lint clean; guard trigger checks passed (in a rolled-back block).
- Known defects: duplicate run `713b8d48` remains (needs the owner's approval to annotate); daily Alpha Vantage FX is stale unless refreshed from the app; no broker specifications.

## F. Research conclusion

**6. No candidate is currently validated and tradable.** The remaining blockers, in order of importance:
1. **No verified broker terms.** Tradability cannot be established for any instrument until an MT5 host connects and fills `broker_symbol_specs` (minimum lot, tick value, margin, swap) and real spreads.
2. **The data that would most plausibly carry new information is paid**: historical consensus (true macro surprises), policy-rate expectations (OIS / futures) and FX options surfaces. The free substitutes are now ingested; EVZ, the only free FX implied-volatility series, is discontinued.
3. **Statistical power at this account size.** The 0.01-lot minimum on FX and the 36 USD kill switch rule out modest edges whose historical drawdowns exceed 360 pips.

Recommended next action: connect an MT5 host (even on the demo account) so the platform records real contract specifications and tick spreads. That is the only step that converts the "assumed" columns above into evidence, and it is a prerequisite for any TRADABLE label. Research can continue in parallel only on hypotheses whose data is already stored and which differ materially from the 31 above; the two forward tests continue untouched.
