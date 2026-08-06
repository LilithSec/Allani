-- Allani schema upgrade 6 -> 7: keep the planner's statistics current on the
-- log tables
--
-- The log tables grow without bound and are almost always read over a recent
-- window. The default analyze trigger is proportional -- 10% of the table --
-- so the larger a store grows the longer it waits between runs, and the
-- statistics for the newest rows, which are the ones being queried, are the
-- first to go stale.
--
-- That matters more than it sounds. Without a histogram of the timestamp
-- column the planner cannot tell how much of a table a time window covers, so
-- it falls back to a fixed guess for a range condition and assumes roughly a
-- third of the rows match. At that fraction a sequential scan really is
-- cheaper than an index lookup, so it reads the whole table and never touches
-- the timestamp index that exists for exactly this query. Measured on an 8
-- million row syslog store, a 24 hour window was estimated at 2.7 million rows
-- when it held 170 thousand, and the aggregates the Lilith log dashboard
-- issues each took around 1.4 seconds instead of 150 milliseconds.
--
-- A zero scale factor with a flat threshold analyzes every 50k new rows
-- whatever the table size, so the cadence stays constant as a store grows
-- rather than degrading. Each run samples rows rather than reading the table,
-- so it stays cheap however large the table gets.

ALTER TABLE syslog      SET (autovacuum_analyze_scale_factor = 0, autovacuum_analyze_threshold = 50000);
ALTER TABLE http_access SET (autovacuum_analyze_scale_factor = 0, autovacuum_analyze_threshold = 50000);
ALTER TABLE http_error  SET (autovacuum_analyze_scale_factor = 0, autovacuum_analyze_threshold = 50000);

-- The settings above only take effect once a table next gains 50k rows, and an
-- existing store may have no statistics at all -- an autoanalyze that has
-- never completed leaves the table with no entry in pg_stats whatsoever. Seed
-- them here so the upgrade itself fixes the plans rather than the next 50k
-- rows doing it. ANALYZE is allowed inside a transaction block, unlike VACUUM,
-- so it is safe to run from a migration.

ANALYZE syslog;
ANALYZE http_access;
ANALYZE http_error;
