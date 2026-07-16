-- Allani schema version 6
--
-- Full schema at version 6: syslog + http_access + http_error, the raw GIN
-- indexes (v4), and the default search indexes (v5): composite (column, id)
-- btrees for "newest N matching a filter" and timestamp btrees for --since / prune (v5), plus the managed_indexes meta-table (v6). `raw` is the primary datum ({ MESSAGE, enriched }); the other columns
-- are denormalized copies of parsed fields kept for query convenience.

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

CREATE TABLE managed_indexes (
    id bigserial NOT NULL,
    tbl varchar(64) NOT NULL,
    field varchar(255) NOT NULL,
    trigram boolean NOT NULL DEFAULT false,
    index_name varchar(63) NOT NULL,
    created TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    PRIMARY KEY(id),
    UNIQUE (index_name),
    UNIQUE (tbl, field, trigram)
);

CREATE TABLE dbix_class_deploymenthandler_versions (
    id bigserial NOT NULL,
    version varchar(50) NOT NULL UNIQUE,
    ddl text NULL,
    upgrade_sql text NULL,
    PRIMARY KEY (id)
);
