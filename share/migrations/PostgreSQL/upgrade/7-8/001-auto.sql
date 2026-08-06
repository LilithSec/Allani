-- Allani schema upgrade 7 -> 8: keep vacuum on the log tables to a flat
-- cadence, as version 7 did for analyze
--
-- Version 7 fixed the analyze trigger and left the vacuum trigger on the
-- server's proportional default, which has the same flaw one step over: a
-- scale factor of 0.2 means nothing is vacuumed until dead tuples reach a fifth
-- of the table, and that bar rises as the store grows.
--
-- Two things make dead tuples here. `allani prune` deletes by age, which on a
-- retention run removes millions of rows at once; and `allani enrich` updates
-- raw in place, which leaves a dead tuple behind per row touched. Left long
-- enough both bloat the heap and every index on it, and the space is not
-- returned to the operating system by the eventual vacuum -- only made
-- available for reuse.
--
-- The insert trigger matters for a different reason. These tables are mostly
-- appended to, so dead tuples alone may never reach any threshold, and without
-- a vacuum the visibility map goes stale. A stale visibility map is what stops
-- Postgres answering from an index alone, and it also leaves freezing to pile
-- up until an anti-wraparound vacuum has to do all of it at once.
--
-- A zero scale factor with a flat threshold gives a constant cadence for both,
-- whatever the table size.

ALTER TABLE syslog SET (
    autovacuum_vacuum_scale_factor        = 0,
    autovacuum_vacuum_threshold           = 50000,
    autovacuum_vacuum_insert_scale_factor = 0,
    autovacuum_vacuum_insert_threshold    = 50000
);

ALTER TABLE http_access SET (
    autovacuum_vacuum_scale_factor        = 0,
    autovacuum_vacuum_threshold           = 50000,
    autovacuum_vacuum_insert_scale_factor = 0,
    autovacuum_vacuum_insert_threshold    = 50000
);

ALTER TABLE http_error SET (
    autovacuum_vacuum_scale_factor        = 0,
    autovacuum_vacuum_threshold           = 50000,
    autovacuum_vacuum_insert_scale_factor = 0,
    autovacuum_vacuum_insert_threshold    = 50000
);

-- No VACUUM here, unlike the ANALYZE version 7 ran. VACUUM cannot run inside a
-- transaction block and a migration is one, so it would abort the upgrade. A
-- store that has already accumulated bloat wants a manual VACUUM (or VACUUM
-- FULL, which does return the space but takes an exclusive lock) run outside
-- the migration.
