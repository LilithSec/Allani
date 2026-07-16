-- Allani schema downgrade 4 -> 3: drop the raw GIN indexes

DROP INDEX IF EXISTS syslog_raw_gin;
DROP INDEX IF EXISTS http_access_raw_gin;
DROP INDEX IF EXISTS http_error_raw_gin;
