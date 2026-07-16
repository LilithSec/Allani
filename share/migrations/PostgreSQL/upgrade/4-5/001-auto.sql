-- Allani schema upgrade 4 -> 5: default search indexes
--
-- Composite (column, id) btrees so "the newest N rows matching a filter" (and
-- the zero-hit case) is served straight from an index -- no sort, early stop,
-- and instant when the value has no rows. Plus btrees on the timestamp columns
-- that --since and prune use. These add write cost on ingest; drop any a given
-- deployment does not search or prune by.

CREATE INDEX syslog_program_id ON syslog (program, id);
CREATE INDEX syslog_host_id     ON syslog (host, id);
CREATE INDEX syslog_s_isodate   ON syslog (s_isodate);
CREATE INDEX syslog_r_isodate   ON syslog (r_isodate);

CREATE INDEX http_access_vhost_id     ON http_access (vhost, id);
CREATE INDEX http_access_host_id      ON http_access (host, id);
CREATE INDEX http_access_client_ip_id ON http_access (client_ip, id);
CREATE INDEX http_access_status_id    ON http_access (status, id);
CREATE INDEX http_access_r_isodate    ON http_access (r_isodate);

CREATE INDEX http_error_vhost_id     ON http_error (vhost, id);
CREATE INDEX http_error_host_id      ON http_error (host, id);
CREATE INDEX http_error_client_ip_id ON http_error (client_ip, id);
CREATE INDEX http_error_loglevel_id  ON http_error (loglevel, id);
CREATE INDEX http_error_code_id      ON http_error (code, id);
CREATE INDEX http_error_server_id    ON http_error (server, id);
CREATE INDEX http_error_r_isodate    ON http_error (r_isodate);
