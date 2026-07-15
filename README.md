# Allani

Allani is the Lady of the Dark Earth, the Hurrian queen of the world
below. Hers is the bolt on the underworld's gate — nothing that dies
above descends without passing her door — and hers is the palace at the
gate, where she keeps a table so fine that even the storm god has come
down to dine at it. The Mesopotamians knew her as Allatum, kin to
Ereshkigal; she rules an underworld of her own, but she is family.

In the world above, Allani is a syslog store: a replacement for the
Logstash + Elasticsearch pattern for keeping logs. Everything that
happens above eventually dies and becomes a log line, and every log
line descends to Allani. [syslog-ng](https://www.syslog-ng.com/)
delivers the dead to her gate as JSON; she draws the bolt and lays them
to rest in PostgreSQL — the interesting fields as columns, the full
record as jsonb beside them, in the same earth where
[Lilith](https://github.com/LilithSec/Lilith)'s annals already lie.

She keeps company with the rest of the LilithSec household:
[Baphomet](https://github.com/LilithSec/Baphomet) accuses,
[Ereshkigal](https://github.com/LilithSec/Ereshkigal) punishes,
[Lamashtu](https://github.com/LilithSec/Lamashtu) remembers,
[Virani](https://github.com/LilithSec/Virani) reads, Allani receives —
and Lilith knows. Lilith keeps only the noteworthy dead, those whose
deaths looked suspicious; Lamashtu keeps what crossed the wire; Allani
keeps what the daemons said — all of it.

Laying the dead to rest looks like this...

```shell
# prepare the ground (the syslog table, in the configured PostgreSQL)
dbic-migration --schema_class Allani::Schema -U allani --dsn dbi:Pg:dbname=allani install

# draw the bolt; syslog-ng writes JSON to stdin, Allani inserts each
# line into PostgreSQL
allani ingest_json_syslog
```

...fed by a syslog-ng `program()` destination like this...

```
destination d_allani {
    program(
        "/usr/local/bin/allani ingest_json_syslog"
        template("$(format-json C_ISODATE=${C_ISODATE} R_ISODATE=${R_ISODATE} S_ISODATE=${S_ISODATE} FACILITY=${FACILITY} HOST=${HOST} HOST_FROM=${HOST_FROM} PID=${PID} PRIORITY=${PRIORITY} PROGRAM=${PROGRAM} SOURCEIP=${SOURCEIP} MESSAGE=${MESSAGE})\n")
    );
};

log { source(s_local); destination(d_allani); };
```

The whole JSON object is kept in the `raw` jsonb column, so anything
extra you put in the template rides along and stays queryable.

## Status

Allani is young — early development. What exists today is the gate: the
versioned schema (via `dbic-migration`) and the syslog-ng JSON ingest,
with optional Log::Munger enrichment. Planned, in keeping with her song:

- searching the dead — a CLI and frontend over the `syslog` table (in
  Hittite syncretism she is the Sun-goddess of the Earth, the light
  that shines in the world below; that will be its name's myth)
- `release` — retention pruning, after the *Song of Release* that is
  her great song: even Allani does not hold the dead forever

## Documentation

- [docs/index.md](docs/index.md) :: where to start
- [docs/architecture.md](docs/architecture.md) :: the ingest path, the
  `syslog` table, and where Allani sits in the household
- [docs/install.md](docs/install.md) :: dependencies, per-OS install,
  and preparing PostgreSQL
- [docs/configuration.md](docs/configuration.md) :: the `allani.yaml`
  reference
- [docs/usage.md](docs/usage.md) :: the `allani` CLI
- [docs/syslog-ng.md](docs/syslog-ng.md) :: hooking syslog-ng up to the
  gate

Also...

- `perldoc Allani`
- `perldoc Allani::Ingest`
