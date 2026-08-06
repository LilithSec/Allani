-- Allani schema downgrade 10 -> 9: drop the covering indexes
--
-- The group-by panels go back to reading rows, which is slower but correct.
-- Nothing else depended on these: the plain r_isodate indexes still serve the
-- window, and the (column, r_isodate) pair from version 9 still serves counting
-- distinct values.

DROP INDEX IF EXISTS syslog_ts_dims;
DROP INDEX IF EXISTS http_access_ts_dims;
DROP INDEX IF EXISTS http_error_ts_dims;
