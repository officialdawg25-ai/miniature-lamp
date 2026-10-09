# Institutional AI ingestion hardening

## Current change set

- Mirrors the deployed `market-data-ingestion`, `economic-ingestion`, and `bls-economic-ingestion` sources into the repository so production function code is no longer missing from version control.
- Adds a dedicated `xauusd-ingestion` Supabase Edge Function using Twelve Data's `XAU/USD` daily time series. Its validation helper rejects malformed dates, non-positive/non-finite prices and inconsistent OHLC ranges; tests cover valid rows, invalid values, calendar dates and volume edge cases. The function writes in batches and uses the market bar natural key for idempotent upserts.
- Adds `macro.observations_as_of(timestamptz)` as an additive SQL migration. It excludes observations whose release, revision-release, first-seen or retrieval timestamps are later than the decision time.
- Changes the generic `economic-ingestion` endpoint to authenticate institutional users and return an explicit `501 PROVIDER_ADAPTER_NOT_CONFIGURED` until an auditable provider adapter exists, rather than reporting a false success.
- The XAUUSD function is deliberately **not deployed** by this change. It fails closed until the XAUUSD instrument, active Twelve Data provider registry entry, and `TWELVE_DATA_API_KEY` secret are configured.

## XAUUSD deployment prerequisites

1. Confirm Twelve Data entitlement and rate limits for the requested historical depth.
2. Register `XAUUSD` in `core.instruments` with the correct instrument type and contract metadata.
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

## Current limitations

- GitHub Actions run #61 passed: Deno type-checks, the XAUUSD validation tests, dependency installation and the Vite production build.
- The SQL migration has not been applied to Supabase and no Edge Function has been deployed. The XAUUSD provider has not yet been configured or tested against live provider data.
- This PR does not modify production data and does not deploy any Edge Function.
- The macro ingestion pipeline is not complete. BLS ingestion currently stores provider observations with `point_in_time_ready=false`; authoritative release timestamps and revision history must be populated from validated release evidence before those observations become model-eligible.
- The current repository build workflow does not validate Deno Edge Functions, and npm dependencies are not yet reproducibly locked. Add Deno checks and a committed npm lockfile before treating CI as a complete release gate.
- Daily precious-metal bars use the provider's date as a UTC-midnight session label. They must not be represented as an exact market-close timestamp without provider-specific evidence.
