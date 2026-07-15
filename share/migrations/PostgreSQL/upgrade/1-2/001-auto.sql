-- Allani schema upgrade 1 -> 2: the http_access table
--
-- Holds HTTP access log lines (Apache/nginx combined or common format). `raw`
-- is the primary datum, { MESSAGE, enriched }; the columns are the parsed
-- fields kept for query convenience. vhost/vhost_port/host are supplied by the
-- ingest command (a bare access line carries none of them).

CREATE TABLE http_access (
    id bigserial NOT NULL,
    r_isodate TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    req_isodate TIMESTAMP WITH TIME ZONE,
    host varchar(255),
    vhost varchar(255),
    vhost_port integer,
    client_ip inet,
    ident varchar(255),
    auth varchar(255),
    method varchar(16),
    request text,
    http_version varchar(16),
    status integer,
    bytes bigint,
    referrer text,
    user_agent text,
    raw jsonb NOT NULL,
    PRIMARY KEY(id)
);
