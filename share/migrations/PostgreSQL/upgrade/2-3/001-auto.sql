-- Allani schema upgrade 2 -> 3: the http_error table
--
-- Holds HTTP error log lines (Apache 2.2/2.4 or nginx). `raw` is the primary
-- datum, { MESSAGE, enriched }; the columns are the parsed fields kept for
-- query convenience. vhost/vhost_port/host are supplied by the ingest command
-- (an error line carries none of them; nginx does log its own `server`).

CREATE TABLE http_error (
    id bigserial NOT NULL,
    r_isodate TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    err_isodate TIMESTAMP WITH TIME ZONE,
    host varchar(255),
    vhost varchar(255),
    vhost_port integer,
    client_ip inet,
    loglevel varchar(32),
    pid bigint,
    code varchar(64),
    server varchar(255),
    request text,
    message text,
    raw jsonb NOT NULL,
    PRIMARY KEY(id)
);
