-- Allani schema version 1
--
-- The syslog table. `raw` is the primary datum: the full JSON record as
-- received from syslog-ng, plus, when enrichment is enabled, the Log::Munger
-- extracted fields merged in under the `enriched` key. Every other column is a
-- denormalized copy of a syslog-ng field kept only for query convenience.

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

CREATE TABLE dbix_class_deploymenthandler_versions (
    id bigserial NOT NULL,
    version varchar(50) NOT NULL UNIQUE,
    ddl text NULL,
    upgrade_sql text NULL,
    PRIMARY KEY (id)
);
