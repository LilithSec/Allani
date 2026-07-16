-- Allani schema downgrade 5 -> 4: drop the default search indexes

DROP INDEX IF EXISTS syslog_program_id;
DROP INDEX IF EXISTS syslog_host_id;
DROP INDEX IF EXISTS syslog_s_isodate;
DROP INDEX IF EXISTS syslog_r_isodate;

DROP INDEX IF EXISTS http_access_vhost_id;
DROP INDEX IF EXISTS http_access_host_id;
DROP INDEX IF EXISTS http_access_client_ip_id;
DROP INDEX IF EXISTS http_access_status_id;
DROP INDEX IF EXISTS http_access_r_isodate;

DROP INDEX IF EXISTS http_error_vhost_id;
DROP INDEX IF EXISTS http_error_host_id;
DROP INDEX IF EXISTS http_error_client_ip_id;
DROP INDEX IF EXISTS http_error_loglevel_id;
DROP INDEX IF EXISTS http_error_code_id;
DROP INDEX IF EXISTS http_error_server_id;
DROP INDEX IF EXISTS http_error_r_isodate;
