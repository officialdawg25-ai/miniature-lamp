# Institutional AI — Macro Intelligence Terminal

Private, research-only terminal for USDJPY and XAUUSD macro research.

## Frontend configuration

The Vite build requires these **public client-side** variables:

- `VITE_SUPABASE_URL`: the Institutional AI Supabase project URL.
- `VITE_SUPABASE_ANON_KEY`: the project's publishable/anon key.

Set them in the environment that builds the frontend (Cloudflare Workers Builds → Build configuration → Environment variables, for both Preview and Production as appropriate). If you build through another pipeline, set the same variables in that pipeline. Then trigger a fresh build/deployment.

These are public frontend configuration values; **never place a Supabase service-role key in a `VITE_*` variable or ship it to the browser.** The frontend signs in with Supabase Auth and sends its session token to the authenticated `data-health` Edge Function.

## Live data health

The terminal calls `/functions/v1/data-health` after sign-in and refreshes the snapshot every 60 seconds. The Edge Function verifies the user session, then reads market bars, raw macro observations, economic releases, ingestion jobs/runs, and existing intelligence outputs using server-side credentials. Its response is marked `partial` if one or more source queries fail.

Raw provider observations are explicitly reported as **not point-in-time eligible** until authoritative release timestamps and revision lineage are validated. Counts and last-close values are telemetry, not trading recommendations.

## Security and deployment notes

- Supabase Auth sign-in is required; access tokens are not hard-coded.
- The `data-health` Edge Function requires a valid JWT and uses server-side credentials only.
- The platform remains research/paper-trading only. Live execution is not enabled.
- A successful Edge Function deployment does not itself deploy the Cloudflare frontend. Confirm the latest GitHub commit has built and the Cloudflare Worker has received the new assets.
- Automated ingestion scheduling is not enabled by this frontend change. Before configuring recurring jobs, install/verify the required scheduler extensions and add the required project URL/service-role credential to Supabase Vault; do not put those credentials in source control.
