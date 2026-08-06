-- Allani schema upgrade 8 -> 9: (column, r_isodate) indexes for counting
-- distinct values over a window
--
-- Counting the distinct values of a dimension is the one dashboard question
-- that reads every row in the window to produce a single small number. Over 30
-- days of an 8 million row syslog store, counting the distinct hosts -- there
-- are nine -- took 3.6 seconds.
--
-- The standard answer is an index skip scan: walk the column's distinct values
-- through an index and ask whether each has a row in the window, so the cost
-- follows the number of values rather than the number of rows. The existing
-- (column, id) indexes cannot serve the second half of that. They order a
-- value's rows by insertion, so asking whether a host appears in the last 24
-- hours walks every older entry for that host first. Measured on a store shaped
-- like production, the skip scan over a 24 hour window took 472ms against 47ms
-- for the plain count it was meant to replace -- ten times worse, and worst at
-- the window people actually use.
--
-- Ordering each value's entries by time instead makes that check a single index
-- descent. The same measurement with one of these in place: 0.6ms, against
-- 47ms for the plain count.
--
-- These are additions, not replacements. Both `allani search` and Lilith's
-- reader order by id, so the (column, id) indexes stay exactly as they are --
-- verified by plan, the newest-N lookups still choose them.
--
-- The columns are the ones the Lilith log dashboards count distinct values of.
-- r_isodate rather than s_isodate because that is the column those dashboards
-- window on: the aggregator's receive time is authoritative, a sending host's
-- clock may not be.
--
-- IF NOT EXISTS so an operator can build these with CREATE INDEX CONCURRENTLY
-- ahead of the upgrade and have the migration pass over them. Worth doing on a
-- large store: a plain CREATE INDEX takes a lock that blocks writes for as long
-- as the build runs, and a migration cannot use CONCURRENTLY because that
-- cannot run inside a transaction block.

CREATE INDEX IF NOT EXISTS syslog_host_r_isodate    ON syslog (host, r_isodate);
CREATE INDEX IF NOT EXISTS syslog_program_r_isodate ON syslog (program, r_isodate);

CREATE INDEX IF NOT EXISTS http_access_vhost_r_isodate     ON http_access (vhost, r_isodate);
CREATE INDEX IF NOT EXISTS http_access_client_ip_r_isodate ON http_access (client_ip, r_isodate);

CREATE INDEX IF NOT EXISTS http_error_client_ip_r_isodate ON http_error (client_ip, r_isodate);
CREATE INDEX IF NOT EXISTS http_error_server_r_isodate    ON http_error (server, r_isodate);
