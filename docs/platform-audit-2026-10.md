# Platform audit: trading lifecycle state (12 October 2026)

Evidence-based map of what exists, what works and what is missing, taken from the live Supabase project (`ieocpcapgwusbojzrrxr`) and this
repository. "Verified" means checked against the live database or by running code. Everything else is labelled as inferred.

## Status by lifecycle stage

| Stage | State | Evidence |
|---|---|---|
| Data: FX prices | Operational | 10 pairs, daily, USDJPY complete 2008 to 2026 (260-262 bars per year, no gaps over 4 days) |
| Data: gold | Partially reliable | 5,419 closes; series changes construction on 2013-03-27 (see backtest caveat) |
| Data: US and Japan yields | Operational | 23,159 rows, 2008 to 2026-10-08, availability times stored |
| Data: policy rates | Operational (Fed, BoJ only) | 11,097 rows; BoJ is a market call rate, not the target; 6 other banks missing |
| Data: macro releases | Partial | 279 provider observations, 7,113 ALFRED vintages (6,902 promoted to scheduled-time availability), 109 factor points |
| Data: positioning (COT), sentiment, intervention, news | Missing | `market.news_events` has 0 rows; no COT or intervention source exists |
| Fundamental interpretation | Partial | factor engine v2 stores 109 US inflation and labour points; `intelligence.currency_scores` has 0 rows |
| Regime detection | Not operational | `intelligence.regime_states` has 0 rows |
| Opportunity discovery | Missing | nothing writes `trading.trade_setups` (0 rows, no producer function) |
| Strategy lifecycle | Missing | no strategy or hypothesis registry; three nulls were run but nothing was stored |
| Backtesting | Operational, research-grade | `backtest-runner` v6, walk-forward, holdout, bootstrap, timing test, deflated Sharpe |
| ML | Scaffolding only | `ml.feature_definitions` has 9 rows; `feature_values`, `model_versions`, `predictions` have 0 |
| Portfolio construction | Missing | no exposure or correlation logic |
| Risk authorization | Partial | SQL gate exists, with gaps listed below |
| Execution | Paper simulation in SQL; MT5 missing | simulate/approve functions exist; dispatcher Edge Function cannot run (grants); no MT5 bridge |
| Monitoring | Missing | no scheduler (pg_cron is not installed), no heartbeats, no reconciliation |
| Attribution and learning | Missing | `trading.paper_account_summary` only; no performance engine |
| Frontend | Research views operational; trading UI absent | "Paper trading" nav entry renders no panel (code inspection) |

## Findings (verified unless marked)

1. **The paper-execution dispatcher cannot work.** `service_role` has no USAGE on schema `trading` and no table privileges on it, but the
   `paper-execution-dispatcher` Edge Function reads and updates `trading.*` tables with the service key. Its first query fails. All
   `trading` tables are empty, so it has never run.
2. **The pre-trade risk gate checks the setup, not the request.** `trading.evaluate_pretrade_risk(account, setup)` compares the setup's own
   `maximum_loss` to the account limit. `trading.request_execution` accepts the quantity, stop and side from the caller and never compares
   them with the approved setup, and does not require a stop loss. A request with a larger quantity than the setup's `position_size`
   would pass.
3. **The gate is incomplete for the target design.** No aggregate open risk, correlated exposure, margin or leverage, drawdown, stale-data,
   spread or event-risk checks. Monetary risk cannot be computed anyway: `core.instruments.contract_size` is null and there are no
   broker specifications.
4. **Nothing produces setups, and no scheduler exists.** The lifecycle stops before the first trading table.
5. **Open read policies (fixed).** Nine policies used a bare `true`. They were not reachable (authenticated users have no schema USAGE on
   `ml` or `research`), but `core.*` were readable by any signed-in user. Fixed in migration `20261012071430` and tested with the
   approved user (full access) and a stranger (none).
6. **Duplicate backtest storage.** `research.backtest_runs` and `research.backtest_trades` (empty, unreachable by API roles) overlap with
   `intelligence.backtest_runs` (empty, written by `backtest-runner`). Needs a decision before either is used.
7. **Repository does not track most of the backend.** 125 migrations are applied in the database; 11 are in the repository. 6 of 24
   deployed Edge Functions are in the repository.
8. **Security posture that is sound:** browser role has SELECT only on `trading.*`, scoped by account membership; all writes go through
   SECURITY DEFINER functions; `trading.execution_audit_events` is append-only by trigger; execution status transitions are guarded by a
   trigger; paper approval requires an owner or risk manager and cannot override a blocked decision.

## Prioritised plan

- **P0 safety:** make the risk gate validate the actual request against the approved setup and require a stop; move the dispatcher onto
  SECURITY DEFINER RPCs so no table privileges are granted to `service_role`; prove with tests that a rejected request cannot reach
  execution.
- **P1 research governance:** a hypothesis and experiment ledger (store every run, including nulls); consolidate backtest storage.
- **P2 decision record:** a decision engine that writes an auditable outcome (approved, wait, no trade, rejected, insufficient data) with
  reason codes. Today the correct output is "no trade" for every instrument, because no strategy has passed validation.
- **P3 data for new hypotheses:** policy rates for the other six central banks (for cross-sectional carry), CFTC positioning with its
  publication lag, event calendar.
- **P4 operations:** scheduler with a stored secret, heartbeats, stale-data detection.
- **P5 execution (needs owner decisions):** MT5 bridge on a demo account. See the boundary below.
- **P6 frontend:** an operations view bound to real state (decisions, risk, paper positions, service health).

## Decisions that need the owner

- Where the MT5 terminal will run (the Python MT5 package needs Windows) and which broker/demo account. Credentials must never be sent in
  chat or stored in the browser; they stay on the execution host.
- Whether to use a pull model (execution host polls Supabase over outbound HTTPS with a narrowly scoped credential). Recommended, since it
  needs no inbound ports.
- Whether a scheduler secret may be stored for the cron job.
- Whether to retire the `research.backtest_*` tables.

## P0 outcome (12 October 2026)

Verified with `supabase/tests/trading_risk_gate.sql` against the live database (31 checks, 0 failures; the block rolls back and leaves every
`trading` table empty).

Additional defects found and fixed while testing, none visible in the first audit:

- **A block could be downgraded.** `evaluate_pretrade_risk` assigned `blocked`, then later checks could overwrite it with `manual_review`
  (reproduced: an unapproved setup with missing data, and a per-trade risk breach on an automated account, both came back `manual_review`).
  A human can approve `manual_review` but never `blocked`, so a block could be approved and dispatched. Severity now only escalates.
- **The gate checked the setup, not the request.** The new `trading.evaluate_execution_risk` validates the actual side, quantity, order
  type, reference price, stop and take profit against the approved setup, requires a stop, rejects expired setups, enforces one live request
  per setup, and treats a missing account limit as "no policy" (blocked), not "unlimited".
- **Human approval could never succeed.** `trading.approve_paper_execution` failed with "column reference status is ambiguous" on every call.
- **The dispatcher could not work** (service role has no access to the trading schema; the schema is not exposed to the API). Dispatch is now
  one database transaction, `trading.dispatch_paper_execution`, reached through a single wrapper `public.dispatch_paper_execution`, which
  re-runs the risk gate immediately before the fill. The Edge Function is a thin wrapper using only the caller's token. No privileges were
  granted to `service_role`.
- My own first version of the new gate failed on any rejected request (`blocked || 'text'` is read as an array literal). The tests caught it
  before anything used it; fixed in migration `20261012083000`.

Still open after P0: monetary risk is estimated from the setup's declared maximum loss, because `core.instruments` has no contract size and
there are no broker specifications; there is no drawdown, correlation or margin check; there is no setup producer; there is no scheduler.
The `request_execution` and `approve_paper_execution` functions have no API entry point yet (they need the same thin public wrappers when the
operations view is built).

## Demo execution bridge (added)
`supabase/migrations/20261012160000_add_demo_execution_host_bridge.sql` and `execution-host/` add a pull-model, demo-only bridge to MT5: host registry (token hash only), claim with re-gating, step reports with dry-run protection, spec sync. Tested by `supabase/tests/execution_host_bridge.sql` (13 checks) and `execution-host/test_host_logic.py`. Position reconciliation back into the platform is not built yet.

## Intraday data (status)
`intraday-ingestion` builds 5-minute bars from Dukascopy tick files (decoder and bar builder unit-tested). In production the first call returned HTTP 429 and the next timed out, so the source is throttling the shared Edge egress. No intraday bars are stored yet. Options: slow background crawl, a free-tier API key from another vendor, or exporting from MT5 once an execution host exists.

## Intraday data and the SMC + Fibonacci test
15-minute bars for USDJPY (from 2023-08) and XAUUSD (from 2023-09) were backfilled from Twelve Data with one request per call (about 17 calls per symbol, temporary job removed). Vendor data includes weekend bars (excluded) and, for gold, a few suspect bars. `intelligence.smc_fib_backtest` implements the owner's rules mechanically. Result, run once per symbol with rules frozen first: USDJPY 304 trades, mean -0.49R, profit factor 0.28; XAUUSD 36 trades, mean -0.83R. Recorded as retired in the ledger.

## SMC + Fibonacci, target at the leg extreme
Pre-registered variant (third trial in the family) run once on USDJPY via `intelligence.smc_fib_backtest_v2`: 301 trades, win rate 15.6% vs 20% break-even, mean -0.23R (t = -2.09), profit factor 0.74, -25.81 USD at 0.01 lot. Retired.

## Broker-state reconciliation
`20261012210000`/`20261012220000`/`20261012230000`: broker snapshots and deals tables, reconciliation flags, risk gate uses broker state for accounts with a host (stale snapshot blocks, broker positions and in-flight requests count toward the open-trade limit, realized broker losses count toward daily and weekly limits), and the Operations page shows host status, broker state, flags and deals. Tests: `supabase/tests/execution_host_bridge.sql` (22 checks) and `trading_risk_gate.sql` (31 checks) pass.

## Interface redesign
The terminal was restyled as a light, minimal theme: one calm palette (ink, a muted gold accent, hairline borders), a single card level instead of nested shells, key figures with hairline dividers instead of boxes, a quiet status row, and a responsive layout (drawer navigation under 900px, two-column key figures under 1100px, single column under 600px). Removed non-functional chrome (workspace picker, search and bell buttons, date, "Analyst workspace" block). The overview dashboard now shows only on Market overview; before, it rendered underneath every page. No behaviour or data logic changed.

## Control layer and live chart (2026-10-13)

Readiness assessment against the master specification: the platform could observe and record but not be operated. Row counts confirmed no economic calendar feed with forecasts (`economic_releases` 6, `surprise_statistics` 0), no news (`news_events` 0), no central-bank decisions (`policy_decisions` 0), no regime states, no ML models or predictions, and no trade setups or trades. Limits lived only in SQL.

Added in this step:
- `trading.accounts.operating_mode` (research, paper, demo, restricted_live), `kill_switch`, with owner-checked, validated, audited functions `update_risk_policy`, `set_account_mode`, `set_kill_switch` and read function `get_account_controls`. The risk gate blocks on kill switch, research mode and live mode; the execution host hands out nothing under a kill switch or outside demo mode. Live and automated execution cannot be selected from the interface. 12 checks in `supabase/tests/account_controls.sql`; the existing 31 gate and 22 bridge checks still pass.
- Controls page (`ControlsPanel`).
- Edge function `live-candles` (read only, vendor key server side, 10 s cache) and a Live chart page drawing candles with the owner's SMC and Fibonacci levels (`src/smc.js`, 6 tests). The overlay is an annotation, not an approved signal. Candles are vendor mid quotes polled every 20 s; this is near-real-time, not tick streaming.

Not yet built: drawdown stop, correlated-exposure limit, economic calendar with consensus, news, sentiment page, regime detection, lifecycle timeline per decision, paper-trading engine, ML layer.

### Macro pages (2026-10-13)
`public.get_macro_intelligence()` returns one read-only snapshot (policy rates for 8 banks, US and Japan yields and the 10Y spread, CFTC leveraged-fund positioning with a 5-year percentile using only reports already available, the release calendar and the latest US indicator prints). Five pages now read it: Central bank policy, Yield differentials, COT positioning, Inflation & growth and a new Economic calendar. Verified against production data (8 banks, 5 yield series, 7 currencies, 13 upcoming releases, 11 indicators). Still missing and stated on the pages: consensus and forecasts, non-US data, meeting dates and statements, market-implied rate paths, year-over-year transforms, news and sentiment beyond positioning.

### Economic calendar source (2026-10-13)
Financial Modeling Prep's economic-calendar endpoint is refused on the free key (HTTP 402), so it is registered but inactive. The calendar now loads from the free Forex Factory weekly feed (unofficial; forecast, previous and impact only, no actuals) through `calendar-ingestion`, hourly on weekdays (cron `hourly-calendar-refresh`). 109 events stored, 52 with forecasts. Each value carries first-seen timestamps. No surprise is computed from this source. `macro_upsert_calendar_events(jsonb)` (first version) remains unused in the database; dropping it is an owner task.

### Regime, paper ticket and lifecycle (2026-10-13)
- `intelligence.compute_macro_regime()` (rules_v1, daily 07:40 UTC) classifies US growth and inflation from stored values, with the Fed phase as context. No probability or confidence is stored. Rows are flagged not point-in-time safe and must not feed backtests. First row: growth_disinflation (CPI y/y 3.40% vs 4.25% three months earlier, real GDP 2.2%, unemployment flat).
- `submit_paper_idea`, `approve_and_fill_paper`, `close_paper_position`, `mark_paper_position_price` and `get_lifecycle` give the operator a paper path through the existing gate and paper accounting: sized from the risk policy (rejected, never rounded up, when 0.01 lot exceeds the budget), approval by an owner, instant paper fill at the entered price, USD profit and R computed from contract-scaled units. Contract specs for 8 instruments are standard assumptions and are flagged as assumed on every setup. Paper mode only; the demo host path is untouched.
- Trade lifecycle page shows each idea as thesis, risk gate, request, order and outcome. The Live chart can prefill a ticket from the SMC and Fibonacci levels.
- `supabase/tests/paper_ticket.sql`: 11 checks. In the run, 10 passed; the eleventh (P7) failed only because the expected value in the test was wrong (0.316 instead of 0.633); the function returned the correct 0.6329 and the test was corrected.

Not built: news feed, market sentiment beyond positioning, drawdown stop and correlated-exposure limits, order management after fill (trailing and partial exits), volatility-adjusted stops, ML models (no validated baseline exists to compare against), BLS-actual surprises.

### News (2026-10-13)
Alpha Vantage's NEWS_SENTIMENT endpoint is refused as premium on the saved key, and GDELT answers HTTP 429 from the shared Edge Function address. News therefore comes from the eight central banks' official RSS and Atom feeds (all eight verified, 74 articles in two weeks), refreshed every two hours (cron `news-central-banks-refresh`). No sentiment is stored because no validated scoring exists. Defect found and handled: the Bank of Canada feed lists scheduled events (holidays, conferences) with future dates; the database function now rejects anything dated more than an hour ahead, and reads exclude the rows stored before the guard. `news_upsert_articles` (first version) remains unused in the database.

### G8 FX portfolio research, batch 2 (2026-10-13)
Engine: `fx-research` Edge Function (`fx.ts`, 7 unit tests) on `public.research_fx_panel()` (4,997 aligned daily bars from 2007-08-09; Fed rate from 2008-12-16). Rules, costs (2 bp per unit traded, 0.5% a year financing haircut on gross exposure) and the acceptance thresholds were registered in the ledger before the first run: net Sharpe >= 0.50, timing-permutation p <= 0.05/6, both halves positive, Sharpe >= 0.30 at double costs, deflated Sharpe >= 0.95, max drawdown no worse than -30%. Multiplicity family size 6.

| Hypothesis | Net Sharpe | Perm. p | Halves | Deflated Sharpe | Checks passed |
|---|---|---|---|---|---|
| fx-g8-time-series-trend-volscaled | -0.04 | 0.375 | -0.10 / +0.02 | 0.07 | 2 of 7 |
| fx-g8-carry-trend-filter | 0.01 | 0.673 | +0.10 / -0.11 | 0.11 | 1 of 7 |
| fx-g8-carry-vol-managed | 0.08 | 0.906 | -0.07 / +0.24 | 0.17 | 2 of 7 |

All three retired; runs stored in `intelligence.backtest_runs`. Reference run (not a new trial): plain carry on the same engine gives net Sharpe 0.19 with the financing haircut and 0.29 without; the earlier ad hoc test reported 0.42 (p 0.038) and could not be reproduced exactly, so that earlier figure should be treated as an upper bound. Known limitation of the registered permutation test for carry-like strategies: shifting weights in time keeps most carry income (rate ranks are persistent), so its p-value is conservative for them. It was kept as registered; changing an acceptance rule after seeing results is not allowed, a new rule needs a new pre-registration.

Even a validated portfolio of this kind could not be traded on a 15 USD account under stop-based per-trade risk limits: six simultaneous legs at the 0.01 lot minimum exceed the 0.75 USD per-trade budget.

### Intraday event studies, batch 3 (2026-10-13)
Engine `event-study-v1` (SQL: `trades_usdjpy_tokyo_window`, `trades_release_continuation`, `trade_stats`, `run_event_study`, `run_release_fade_oos`). Statistics were checked against hand-computed values before any real trade was produced; that check found and fixed a precedence bug in `norm_cdf` (unary minus binds tighter than `^` in Postgres). Data checks: 15-minute USDJPY and XAUUSD bars have no duplicates, off-grid times or invalid OHLC; the bar timestamp is the bar open (the release spike sits in the bar stamped with the release time). All rules, costs and criteria were frozen in the ledger before each run.

| Hypothesis | Sample | Trades | Mean net | t | Checks |
|---|---|---|---|---|---|
| usdjpy-gotobi-tokyo-fix-drift | 2023-08 to 2026-10 | 223 | -2.52 pips | -3.18 | 1 of 9 (gotobi -0.72 pips gross vs -0.66 on other days, Welch p 0.53) |
| us-release-continuation-usdjpy | 2023-09 to 2026-10 | 73 | -13.14 pips | -2.57 | 1 of 8 |
| us-release-continuation-xauusd | 2023-09 to 2026-10 | 71 | -0.97 USD/oz | -0.43 | 3 of 8 |
| us-release-fade-usdjpy-oos | 2021-01 to 2023-08 (independent) | 61 | -6.98 pips | -1.09 | 1 of 7 |

The fade hypothesis was suggested by the continuation result, so it was registered with its origin disclosed and judged only on releases before 2023-08-22, data the platform loaded after freezing the rule (USDJPY 15m backfilled to 2020-10-29: 70,000 bars, clean, continuous join). It failed: the 2023-2026 reversal was sample-specific. All four retired.

Programme total: 15 hypotheses in the ledger (14 rejected and retired; plain G8 carry left at "tested" with a weak, non-reproduced result), none research-validated. Seven have stored runs with every check; the earliest eight were run before runs were stored. Untestable with current data: signed macro-surprise strategies (no historical consensus), intervention-risk models (no timestamped official intervention record), gold financing-specific tests (no historical swap data).

### Automatic risk engine (2026-10-13)
Owner choice "option 2" on a 60 USD demo balance. Policy in percent of equity: 5% per trade, 10% daily, 20% weekly, 5% total open risk, kill switch at 30% drawdown from the equity peak, no new entry below a 300% margin level. `trading.refresh_risk_limits` recomputes the dollar limits (rounded down to the cent) on every broker snapshot, every paper ledger entry, every risk-gate evaluation and every 15 minutes (cron `risk-engine-refresh`), and audits every change. Equity comes from the MT5 host when its snapshot is under 15 minutes old (the first broker snapshot replaces the starting balance, audited) and otherwise from the paper ledger. Blocks: daily and weekly equity loss (including open losses), margin level, non-positive equity; the drawdown stop engages the kill switch, which only an owner can release. The host claim refuses an order when broker leverage is unknown or when its margin would take the margin level under the minimum. The host now reports leverage and the margin-call and stop-out levels from MT5 (`account_terms`, 14 host tests). Manual dollar edits are refused while the engine is on. Current limits: 3.00 / 6.00 / 12.00 / 3.00 USD from paper equity 60. Tests: `supabase/tests/auto_risk_engine.sql` 15 checks; all suites 91 of 91 pass (gate 31, bridge 22, controls 12, paper ticket 11, engine 15). Not covered: correlated exposure across instruments, Exness news-time and weekend margin increases (only visible through the margin MT5 reports), and gold margin rules beyond leverage.

### Batch 4 and the gold forward test (2026-10-13)
Rules, costs and criteria frozen in the ledger before each run (engine `event-study-v2`).

| Hypothesis | Sample | Trades | Mean net | t | Checks |
|---|---|---|---|---|---|
| usdjpy-london-breakout-tokyo-range | 2020-10 to 2026-10 | 650 | +1.10 pips | 0.73 | 3 of 8 (PF 1.08, -5.19 pips without the best 5%) |
| xauusd-asia-london-session-drift | 2020-01 to 2026-10 | 1,558 | +1.15 USD/oz | 1.66 | 5 of 9 (p 0.049 vs 0.025; first half -0.37, holdout +3.74; double costs +0.75; -2.42 without the best 5%; PF 1.16; Asia+London +1.55 vs US -0.68 gross, Welch p 0.009) |

Both retired. Gold session drift is the strongest result in the programme, but it fails significance, the first half and the trimmed mean. An exact replication on 2016-2020 (`xauusd-asia-london-session-drift-replication`) was retired as unrunnable: Twelve Data's 15-minute gold history starts 2020-01-24, leaving 162 unseen days against the registered minimum of 500. Those days were not examined.

Forward test `xauusd-asia-london-session-drift-forward`: the unchanged rule (0.40 USD/oz cost) on trading days from 2026-10-14. `intraday-twelvedata` has a forward mode (from the newest stored bar, closed bars only), run hourly on weekdays for XAUUSD and USDJPY (crons `intraday-forward-xauusd`, `intraday-forward-usdjpy`); first call stored 34 closed bars each. `intelligence.run_gold_session_forward` stores a monthly interim run (cron `gold-session-forward-monthly`, monitoring only) and the decision is taken once at 250 days with the same checks plus the Welch session benchmark. The rule has no stop; a tradable version would need its own registered risk design under the account policy.

Programme total: 19 hypotheses (18 retired, plain G8 carry at "tested", the forward test collecting data). None research-validated.

### Batch 5: USDJPY local-hours depreciation (2026-10-13)
Direction from Breedon and Ranaldo (2013): currencies tend to weaken during their home market's hours. The session theme was prompted by the gold result (disclosed in the specification); no USDJPY session returns were looked at before registration. Runner `intelligence.run_batch5` on `intelligence.usdjpy_session_windows()`, costs 1.8 pips (stress 3.6), alpha 0.05/2.

| Hypothesis | Days | Mean net | t | Checks |
|---|---|---|---|---|
| usdjpy-tokyo-hours-jpy-depreciation (long 00:00-07:00 UTC) | 1,539 | -1.02 pips | -0.94 | 2 of 9 (halves +1.32 / -3.36, holdout -3.14, PF 0.93; Tokyo +0.78 vs New York +2.34 gross, Welch p 0.82) |
| usdjpy-new-york-hours-usd-depreciation (short 13:00-21:00 UTC) | 1,482 | -4.14 pips | -3.19 | 1 of 9 (USDJPY rose more in New York, +2.34, than in London, +1.46) |

Both retired. Over 2020-2026 the dollar's rise against the yen happened mostly in New York hours, the opposite of the published pattern, and no session window covers a 1.8-pip cost on its own.

Programme total: 21 hypotheses (20 retired, plain G8 carry at "tested", the gold forward test collecting data). None research-validated.

### Batch 6: daily gold momentum and FX large-move reversal (2026-10-13)
New data: Twelve Data daily XAU/USD from 1988-12-23 (9,999 bars; `intraday-twelvedata` now takes `timeframe: "daily"` and refuses to write daily bars where another source already holds them). Fixed before any result: weekend quotes (163, from 2024 on, not tradable at the broker) and the one bar retrieved before its day ended are excluded. The parser now accepts date-only rows, which also repairs the live chart's 1d view (it had been rejecting every daily row; `live-candles` v3). A further fix (drop forming bars in backfill mode too, and page on the vendor count) is in the repository but not yet deployed: the deploy service returned internal errors; the research query excludes unfinished bars in the meantime.

| Hypothesis | Sample | Obs. | Mean net | t | Checks |
|---|---|---|---|---|---|
| xauusd-daily-time-series-momentum (sign of 12-month return) | 1989-12 to 2026-10 | 9,582 days | +0.27 USD/oz/day | 1.49 | 5 of 9 (earns less than holding gold, +0.39; short-signal days -0.15) |
| fx-usd-pairs-daily-large-move-reversal (fade moves > 2 sd) | 2007-09 to 2026-10 | 2,290 trades | -3.04 bp | -1.97 | 1 of 9 (1 of 7 pairs positive) |

Both retired.

### Batch 7: the dollar on scheduled FOMC days (2026-10-13)
Data: `macro.fomc_meetings`, 157 scheduled statement dates 2007-2026 parsed from federalreserve.gov (calendar page and per-year historical pages, fetched through `pg_net`); unscheduled meetings, conference calls, notation votes and the cancelled March 2020 meeting excluded. Cross-check: all 30 Fed target changes in the rate series fall on these dates except the two March 2020 emergency cuts. The Alpha Vantage daily close was verified to be the 22:00 UTC price (against Twelve Data 15-minute USDJPY), so each day's bar contains the 18:00-19:00 UTC statement.

`fx-usd-weakens-on-fomc-days` (Mueller, Tahbaz-Salehi and Vedolin 2017): short the dollar equally against the seven currencies from the previous close to the close of the statement day, costs per pair as in batch 6.

| Events | Mean net | t | p | Halves | 2017 on | Double cost | Without best 5% | PF | FOMC vs other days |
|---|---|---|---|---|---|---|---|---|---|
| 152 | +11.26 bp | 1.99 | 0.024 | +12.17 / +10.35 | +9.97 (77) | +9.17 | +1.09 | 1.54 | +13.36 vs -0.75 bp, Welch p 0.007 |

All 9 pre-registered checks pass: the first hypothesis in the programme to do so. Status `backtest_completed`, research-validated on this sample only. Caveats: the programme-wide Bonferroni level (0.0021 over 24 hypotheses) is not met; the 2017-on subsample alone is t 1.54 and the sample without 2008-2009 is t 1.15; the largest gains are dovish surprises (2008-12-16, 2009-03-18, 2015-03-18), the largest losses hawkish ones; observed after the run and not a registered check, USDJPY alone is flat while the other six pairs are +11.7 to +14.7 bp. Not tradable as specified on the 60 USD account (seven pairs exceed the open-risk limit; the daily swing on one EURUSD 0.01 lot is about 8 USD at one standard deviation, above the 3 USD per-trade limit without a stop). A one-pair version with a stop needs its own registration and intraday data.

Programme total: 24 hypotheses (21 retired, 1 validated on the historical sample, plain G8 carry at "tested", the gold forward test collecting data).

### Batch 8: tradable form of the FOMC result (2026-10-13)
`eurusd-fomc-day-long-stop30`: long EURUSD from the previous close to the FOMC-day close with a 30-pip stop (the largest that keeps a 0.01 lot near the 3 USD per-trade limit), stop treated as hit 3 pips early for vendor differences and filled 2 pips worse. 152 events: mean net +6.53 pips (t 1.34, p 0.091), 94 trades stopped (62%), PF 1.31, -2.44 pips without the best 5%. 7 of 9 checks: retired. FOMC-day EURUSD ranges are wide enough that the stop cuts off most of the effect. The basket result stands; the binding constraint is account size, not the signal.

Programme total: 25 hypotheses (22 retired, 1 validated on the historical sample, plain G8 carry at "tested", the gold forward test collecting data).

### Balance 120 USD and batch 9 (2026-10-13)
Owner raised the demo balance to 120 USD (migration `set_demo_account_balance_120`, audited; option 2 percentages unchanged; the engine's peak, day-start and week-start equity moved to 120 because a deposit is not profit). Limits: 6 USD per trade, 12 daily, 24 weekly, 6 open, kill switch at 36 USD drawdown.

`eurusd-fomc-day-long-stop56`: the FOMC-day EURUSD rule with the stop the new balance allows (56 pips + 2 slippage + 1.6 costs = 5.96 USD at 0.01 lot); alpha 0.025 because it is the second stop size tried. The parametric runner reproduces the 30-pip run exactly (0 mismatched days). 152 events: mean net +13.19 pips (t 2.03, p 0.021), 58 stopped, halves +16.96 / +9.43, 2017 on +8.54, double costs +11.59, without the best 5% +2.03, PF 1.53, Welch p 0.004 against other days. **All 9 checks pass.**

In dollars at 0.01 lot it made +200.55 over 19 years (+1.32 per trade), but found after the run: the maximum drawdown is 51.69 USD, beyond the 36 USD kill switch, and the rule is in that drawdown now (peak 2024-11-07; since then 15 meetings, 11 stopped, 3 winners, -49.81 USD). The seven-pair basket shows the same break (15 meetings from 2024-12: -41.3 bp mean, 3 winners; 2017 to 2024-11: +22.4 bp). Verdict: research-validated on the 2007-2026 sample, not recommended for execution. 2025 and 2026 alone would have triggered the kill switch.

Forward test `eurusd-fomc-day-long-stop56-forward`: the same rule on meetings from 2026-10-28, on 15-minute EURUSD bars (entry 22:30 UTC after rollover, stop path observed bar by bar). Decision once at 24 events: mean > 0, p <= 0.10, PF >= 1.2 and cumulative loss never 360 pips; retired at once if the cumulative loss reaches 360 pips. Paper only. EURUSD was added to `intraday-twelvedata` (v6, which also drops forming bars in backfill mode); crons `intraday-forward-eurusd` and `eurusd-fomc-forward-run`. Daily Alpha Vantage FX (`market-data-ingestion`) requires a signed-in user and has no schedule, so daily FX stops updating unless the owner refreshes it from the app.

Programme total: 27 hypotheses (22 retired; FOMC basket and its 56-pip EURUSD form validated on the historical sample only; plain G8 carry at "tested"; two forward tests collecting data).
Checks on the forward code: Twelve Data EURUSD 15-minute bars include weekend quotes (unlike USDJPY); they do not enter the rule, which runs Tuesday 22:30 to Wednesday 22:00 UTC. On the three 2026 meetings already loaded, the 15-minute method and the daily method agree on every stop outcome (2026-06-17 and 2026-09-16 stopped, 2026-07-29 +72.7 vs +78.4 pips, the gap being the later entry). The 15-minute EURUSD backfill to 2020 runs through a temporary job that unschedules itself when done.

### Batch 10: month-end equity hedge rebalancing (2026-10-13)
New data: Twelve Data daily SPY and EZU, total-return (dividend-adjusted) closes from 2006-11, stored as inactive research-only instruments (`intraday-twelvedata` v7 requests `adjust=all` for these two only). `eurusd-month-end-hedge-rebalancing` (Melvin and Prins 2015): on the last London business day of each month (UK late-May and August bank-holiday Mondays skipped), sell EURUSD if EZU outperformed SPY month to date, buy if not; 56-pip stop. 230 events: mean net -7.61 pips (t -2.11), PF 0.71, maximum drawdown 230 USD at 0.01 lot; the placebo day ten trading days earlier also loses (-11.05). 1 of 10 checks: retired.

Structural limit at 120 USD: the 0.01-lot minimum fixes risk at 0.10 USD per EURUSD pip regardless of edge, and the 36 USD kill switch allows at most a 360-pip drawdown. Historical drawdowns of real but modest edges exceed that (FOMC rule: 517 pips; a daily intraday rule with a 1-2 pip edge would be several hundred pips). Strategies that pass must be both significant and unusually smooth, or the account must allow smaller positions (for example a cent account).

Programme total: 28 hypotheses (23 retired; FOMC basket and its 56-pip EURUSD form validated on the historical sample only; plain G8 carry at "tested"; two forward tests collecting data).

### Batch 11: equity announcement-day premium (2026-10-13)
Owner chose to stay on the Standard account and test only well-founded event ideas. Equity-index CFDs avoid the 0.01-lot problem (US500 position size can match the 6 USD limit; contract terms to be confirmed from MT5), so the announcement-day equity premium was tested on SPY total-return closes, sized at 200 USD notional with a 3% stop, drawdown limit 36 USD, alpha 0.025.

| Hypothesis | Events | Mean net | t | Checks |
|---|---|---|---|---|
| spy-fomc-day-announcement-premium (Savor and Wilson 2013; Lucca and Moench 2015) | 157 (2007-2026) | +23.5 bp | 2.28 | 8 of 10: first half +48.1, second half -0.7, since 2016 -0.1 bp (85 events) |
| spy-cpi-ppi-payrolls-day-premium (Savor and Wilson 2013) | 198 (2021-2026) | +8.2 bp | 1.03 | 6 of 9: not above other days (Welch p 0.26), -4.0 without the best 5% |

Both retired. The FOMC equity premium was large before 2016 and has been absent since, matching later literature.

Programme total: 30 hypotheses (25 retired; FOMC dollar basket and its 56-pip EURUSD form validated on the historical sample only and currently in drawdown; plain G8 carry at "tested"; two forward tests collecting data).
