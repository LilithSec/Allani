-- Allani schema downgrade 8 -> 7: return the log tables to the server's
-- default vacuum cadence
--
-- Only the vacuum parameters are reset. The analyze ones version 7 set are
-- left in place, which is what makes this a downgrade to 7 rather than to 6.

ALTER TABLE syslog RESET (
    autovacuum_vacuum_scale_factor,
    autovacuum_vacuum_threshold,
    autovacuum_vacuum_insert_scale_factor,
    autovacuum_vacuum_insert_threshold
);

ALTER TABLE http_access RESET (
    autovacuum_vacuum_scale_factor,
    autovacuum_vacuum_threshold,
    autovacuum_vacuum_insert_scale_factor,
    autovacuum_vacuum_insert_threshold
);

ALTER TABLE http_error RESET (
    autovacuum_vacuum_scale_factor,
    autovacuum_vacuum_threshold,
    autovacuum_vacuum_insert_scale_factor,
    autovacuum_vacuum_insert_threshold
);
