-- Allani schema downgrade 7 -> 6: return the log tables to the server's
-- default analyze cadence
--
-- RESET drops the per-table override so the server-wide
-- autovacuum_analyze_scale_factor applies again. The statistics the upgrade
-- gathered are left alone: they are not part of the schema, and discarding
-- them would only make the planner worse.

ALTER TABLE syslog      RESET (autovacuum_analyze_scale_factor, autovacuum_analyze_threshold);
ALTER TABLE http_access RESET (autovacuum_analyze_scale_factor, autovacuum_analyze_threshold);
ALTER TABLE http_error  RESET (autovacuum_analyze_scale_factor, autovacuum_analyze_threshold);
