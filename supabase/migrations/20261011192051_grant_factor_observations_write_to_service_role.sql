-- The macro factor engines run server-side as service_role and upsert into macro.factor_observations.
-- service_role previously had SELECT only, so every engine write failed. No browser-facing role is granted write access.
grant insert, update on table macro.factor_observations to service_role;
