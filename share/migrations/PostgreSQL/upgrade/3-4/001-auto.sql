-- Allani schema upgrade 3 -> 4: GIN indexes on raw for fast jsonb search
--
-- Without these, an `allani search --field key=value` that matches nothing has
-- to sequentially scan the whole table before returning empty. jsonb_path_ops
-- indexes the containment (@>) operator the search now uses, so a zero-hit
-- field search returns at once. These add write cost on ingest; drop them if a
-- deployment never searches by enriched field.

CREATE INDEX syslog_raw_gin      ON syslog      USING gin (raw jsonb_path_ops);
CREATE INDEX http_access_raw_gin ON http_access USING gin (raw jsonb_path_ops);
CREATE INDEX http_error_raw_gin  ON http_error  USING gin (raw jsonb_path_ops);
