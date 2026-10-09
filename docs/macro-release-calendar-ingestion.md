# BLS official release-calendar ingestion

## Purpose

The `bls-release-calendar-ingestion` Supabase Edge Function reads the official BLS iCalendar feed at `https://www.bls.gov/schedule/news_release/bls.ics` and upserts supported release events into `macro.provider_release_calendars`.

Supported event families are Employment Situation, Consumer Price Index, Producer Price Index, U.S. Import and Export Price Indexes, and Job Openings and Labor Turnover Survey. Unrelated calendar events are intentionally ignored.

## Safety contract

- Supabase Edge Function JWT verification must remain enabled.
- A POST with an empty body defaults to `dry_run: true`; it must not write rows.
- Persist only with an authenticated POST body containing `{"dry_run":false}`.
- The function writes scheduled calendar events only. It must never set `provider_observations.point_in_time_ready` or `economic_releases.point_in_time_complete`.
- A scheduled publication time is not evidence that a release was actually published at that exact instant, nor does it prove a historical observation's vintage. PIT readiness remains false until actual release/vintage evidence and revision lineage are validated.
- Calendar rows include the official source URL, feed UID/summary, timezone and original source datetime in `raw_payload`.
- Existing provider observations and release revisions are not modified.

## Deployment checklist

1. Deploy as a new Edge Function named `bls-release-calendar-ingestion` with JWT verification enabled.
2. Keep the BLS provider feed URL fixed to the official BLS domain; do not accept arbitrary URLs from request payloads.
3. Run a dry-run with a signed-in test user. Confirm `status=completed`, `dry_run=true`, a nonzero `records_seen`, and no database writes.
4. Inspect preview entries: release names, reference periods, timezone conversion, and scheduled timestamps must match the official BLS calendar.
5. Persist once with `{"dry_run":false}`. Repeat the persist and confirm the unique key prevents duplicate rows.
6. Confirm only the supported calendar table changed, and that all PIT-ready / PIT-complete flags remain unchanged.
7. Keep the existing BLS and BEA observation ingestion functions unchanged until the new function passes the above checks.

## Current limitation

This function is committed to the feature branch only. It has not been deployed to Supabase or called against the live calendar from the platform. No database rows have been written by this source-code change.
