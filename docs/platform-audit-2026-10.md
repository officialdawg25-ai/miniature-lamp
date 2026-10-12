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
