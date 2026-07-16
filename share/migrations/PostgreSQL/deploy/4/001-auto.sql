-- Allani schema version 4
--
-- Full schema at version 4: syslog (v1) + http_access (v2) + http_error (v3),
-- plus GIN indexes on each raw column (v4) so a jsonb `--field` search that
-- matches nothing returns at once instead of scanning the whole table.
-- `raw` is the primary datum ({ MESSAGE, enriched }); the other columns are
-- denormalized copies of parsed fields kept for query convenience.

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

CREATE INDEX syslog_raw_gin      ON syslog      USING gin (raw jsonb_path_ops);
CREATE INDEX http_access_raw_gin ON http_access USING gin (raw jsonb_path_ops);
CREATE INDEX http_error_raw_gin  ON http_error  USING gin (raw jsonb_path_ops);

CREATE TABLE dbix_class_deploymenthandler_versions (
    id bigserial NOT NULL,
    version varchar(50) NOT NULL UNIQUE,
    ddl text NULL,
    upgrade_sql text NULL,
    PRIMARY KEY (id)
);
