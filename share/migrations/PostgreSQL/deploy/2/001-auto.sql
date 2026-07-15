-- Allani schema version 2
--
-- Full schema at version 2: the syslog table (unchanged from v1) plus the
-- http_access table for HTTP access log lines. As with syslog, `raw` is the
-- primary datum -- the whole record as { MESSAGE, enriched } -- and every other
-- column is a denormalized copy of a parsed field kept for query convenience.

CREATE TABLE syslog (
    id bigserial NOT NULL,
    c_isodate TIMESTAMP WITH TIME ZONE NOT NULL,
    r_isodate TIMESTAMP WITH TIME ZONE NOT NULL,
    s_isodate TIMESTAMP WITH TIME ZONE NOT NULL,
    facility varchar(255) NOT NULL,
    host varchar(255) NOT NULL,
    host_from varchar(255) NOT NULL,
    pid bigint,
    priority varchar(64) NOT NULL,
    program varchar(255) NOT NULL,
    sourceip inet NOT NULL,
    raw jsonb NOT NULL,
    PRIMARY KEY(id)
);

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

CREATE TABLE dbix_class_deploymenthandler_versions (
    id bigserial NOT NULL,
    version varchar(50) NOT NULL UNIQUE,
    ddl text NULL,
    upgrade_sql text NULL,
    PRIMARY KEY (id)
);
