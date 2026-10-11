-- The yield ingestion function runs server-side as service_role and upserts into market.yield_observations.
-- service_role had no write privileges on it. No browser-facing role is granted write access.
grant select, insert, update on table market.yield_observations to service_role;
