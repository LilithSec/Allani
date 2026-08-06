-- Allani schema upgrade 9 -> 10: covering indexes so windowed group-by reads
-- the index instead of the table
--
-- The busiest-values panels group a dimension over a window: every row in the
-- window is visited, one per group is not enough. There is no avoiding the
-- visit, but there is avoiding what gets visited. A syslog row averages about
-- 950 bytes, of which roughly 830 is the raw jsonb these panels never look at,
-- so reading rows to count hosts moves about forty times more data than the
-- question needs.
--
-- An index carrying the timestamp and the dimensions answers from itself. On a
-- 2 million row store with production sized payloads, grouping over 30 days
-- went from a sequential scan reading 231543 pages to an index only scan
-- reading none, and from ~490ms to ~205ms -- the same for every dimension, for
-- one index rather than one each.
--
-- The dimensions are INCLUDE payload rather than key columns. Both shapes
-- measured identically, in time and to the megabyte; INCLUDE is used because it
-- states the intent, that these are carried to be read and not to be ordered or
-- searched by. The (column, id) and (column, r_isodate) indexes remain what
-- serve ordering and lookup.
--
-- The columns are each source's aggregatable dimensions plus the address the
-- countries panel geolocates. Ordered by r_isodate because that is what the
-- window is on.
--
-- This pays nothing until the visibility map is populated. An index only scan
-- has to know a page holds no rows needing a visibility check, and that comes
-- from vacuum. A store that has never been vacuumed -- which is every store
-- before version 8 set an insert driven threshold -- reports zero all-visible
-- pages and will keep reading the table however many indexes it has. Run a
-- VACUUM after this upgrade; version 8 keeps it that way afterwards.
--
-- IF NOT EXISTS so these can be pre-built with CREATE INDEX CONCURRENTLY on a
-- large store, since a migration runs in a transaction and cannot use it.

CREATE INDEX IF NOT EXISTS syslog_ts_dims ON syslog (r_isodate)
    INCLUDE (program, facility, host, host_from, priority, sourceip);

CREATE INDEX IF NOT EXISTS http_access_ts_dims ON http_access (r_isodate)
    INCLUDE (vhost, client_ip, host, method, status);

CREATE INDEX IF NOT EXISTS http_error_ts_dims ON http_error (r_isodate)
    INCLUDE (server, client_ip, code, host, loglevel);
