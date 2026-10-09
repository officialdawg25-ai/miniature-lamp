# Institutional AI ingestion hardening

## Current change set

- Mirrors the deployed `market-data-ingestion`, `economic-ingestion`, and `bls-economic-ingestion` sources into the repository so production function code is no longer missing from version control.
- Adds a dedicated `xauusd-ingestion` Supabase Edge Function using Twelve Data's `XAU/USD` daily time series. Its validation helper rejects malformed dates, non-positive/non-finite prices and inconsistent OHLC ranges; tests cover valid rows, invalid values, calendar dates and volume edge cases. The function writes in batches and uses the market bar natural key for idempotent upserts.
- Adds `macro.observations_as_of(timestamptz)` as an additive SQL migration. It excludes observations whose release, revision-release, first-seen or retrieval timestamps are later than the decision time.
- Changes the generic `economic-ingestion` endpoint to authenticate institutional users and return an explicit `501 PROVIDER_ADAPTER_NOT_CONFIGURED` until an auditable provider adapter exists, rather than reporting a false success.
- Adds an authenticated `intelligence-engine` endpoint that computes a transparent, bounded price-only technical score from actual daily bars and persists it to `intelligence.pair_scores`. It intentionally does not fabricate composite scores, currency scores, macro regimes or ML predictions when their validated inputs are missing.
- Adds Deno checks and tests for the intelligence engine to GitHub Actions.
- The intelligence-engine function has now been deployed to Supabase with JWT verification enabled. It has **not yet been invoked with an authorized institutional user token**, so successful persistence and runtime behavior remain unverified. The XAUUSD function is not deployed; it fails closed until its provider registry and secret prerequisites are configured.

## Price-only intelligence baseline

The baseline requires at least 21 valid daily closes for an instrument. It computes a log-return over the available window, daily return volatility, annualized volatility as a decimal ratio, and a bounded technical trend-strength score in [-100, 100]. The score is not a probability, target price, or calibrated forecast.

Only `technical_score`, `expected_volatility`, and an explicit methodology/input explanation are populated. Fundamental, policy, yield, intermarket, sentiment, regime, ML and composite fields remain NULL. Instruments without enough valid bars are reported as skipped. The live database audit found 5,000 daily bars for USDJPY and zero for XAUUSD and the other audited instruments; therefore USDJPY is currently the only instrument expected to produce a score.

Invoke the deployed function using an authenticated POST request to `https://ieocpcapgwusbojzrrxr.supabase.co/functions/v1/intelligence-engine`, with a valid signed-in user's bearer token. The endpoint independently checks active institutional access. It upserts by `(instrument_id, as_of)`, making repeat calls for the same latest bar idempotent. Do not treat deployment as proof of successful execution: verify the returned JSON and confirm the persisted row and repeat-run behavior.

## XAUUSD deployment prerequisites

1. Confirm Twelve Data entitlement and rate limits for the requested historical depth.
2. Confirm `XAUUSD` exists in `core.instruments` with the correct instrument type and contract metadata.
3. Register `Twelve Data` in `core.data_sources` as an active market-data provider.
4. Set `TWELVE_DATA_API_KEY` as a Supabase Edge Function secret. Never place provider credentials in the frontend or repository.
5. Validate provider payload shape, OHLC invariants, duplicate/idempotent reruns, missing dates, latest/earliest timestamps, and the actual count of persisted XAUUSD bars in a staging environment.
6. Only after staging validation, deploy with JWT verification enabled and confirm the function rejects unauthenticated and non-institutional users.

## Point-in-time macro pipeline: required acceptance gates

A provider observation must not become model-eligible merely because a value exists or `point_in_time_ready` is true. Eligibility must require a validated provider-series mapping, matching active indicator/source mapping, matching provider + series + period + revision + value, a corresponding complete release, an authoritative release timestamp, a revision row for that exact revision, and no future release/revision timestamp relative to the model's as-of time.

For each stored observation/revision preserve at least:
- provider and provider series code;
- indicator and observation period;
- value, unit, status, revision number and raw provider payload;
- first-seen/retrieved timestamp;
- authoritative release timestamp and revision release timestamp;
- ingestion run ID and validation outcome.

### Required tests before production promotion

- Release timestamp after the simulated decision time: observation is excluded.
- Revision timestamp after the simulated decision time: revised value is excluded.
- Value/revision mismatch across provider observation, release and revision ledger: excluded.
- Unvalidated or inactive series/source/indicator mapping: excluded.
- Correctly matched release/revision with all timestamps at or before as-of time: eligible.
- Duplicate ingestion is idempotent and does not erase earlier revisions.
- Provider failure, rate limit, malformed payload and partial write are auditable and fail closed.

## Current validation and limitations

- Commit `050d40061a21758adaf8f26a5ed398a5b4d9154a` passed GitHub Actions and Cloudflare Workers **preview build** checks. The latest branch commit `60e6130a7144e4d18d4add8667507b9a855872c9` also passed GitHub Actions and Cloudflare preview checks.
- Supabase function `intelligence-engine` was deployed as version 1 with `verify_jwt=true`. No authenticated invocation has been performed yet, and current logs show no invocation entries. No database migration has been applied by this step.
- XAUUSD provider configuration is incomplete and the XAUUSD function has not been deployed or tested against live provider data.
- This change has not modified existing production market bars. The first authorized engine invocation is expected to create/update price-only baseline score rows in `intelligence.pair_scores`; verify the output before relying on it.
- The macro ingestion pipeline is not complete. Authoritative release timestamps and revision history must be populated from validated release evidence before observations become model-eligible.
- The GitHub workflow validates the frontend and selected Deno functions; it is not a complete production release gate. npm dependencies are not yet reproducibly locked.
- Daily precious-metal bars use the provider's date as a UTC-midnight session label. They must not be represented as an exact market-close timestamp without provider-specific evidence.
- Cloudflare is currently invoking `npx wrangler preview`. If the desired outcome is production publishing, the Cloudflare build command must be changed to `npx wrangler deploy` in the Cloudflare dashboard; preview success does not publish the production Worker.
