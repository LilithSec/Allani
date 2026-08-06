-- Allani schema downgrade 9 -> 8: drop the (column, r_isodate) indexes
--
-- The (column, id) indexes are untouched: they serve the newest-N lookups and
-- were never what version 9 changed. A reader that was using a skip scan falls
-- back to counting the rows once these are gone, which is slower but correct.

DROP INDEX IF EXISTS syslog_host_r_isodate;
DROP INDEX IF EXISTS syslog_program_r_isodate;

DROP INDEX IF EXISTS http_access_vhost_r_isodate;
DROP INDEX IF EXISTS http_access_client_ip_r_isodate;

DROP INDEX IF EXISTS http_error_client_ip_r_isodate;
DROP INDEX IF EXISTS http_error_server_r_isodate;
