# Allani documentation

Allani is the Lady of the Dark Earth, the Hurrian queen of the world
below, kin to Ereshkigal. Hers is the bolt on the underworld's gate:
nothing that dies above descends without passing her door.

In the world above, Allani is a log store — a replacement for the
Logstash + Elasticsearch pattern. [syslog-ng](https://www.syslog-ng.com/)
formats each log message as JSON and hands it over, on stdin or through
a unix socket; Apache and nginx logs are tailed from their files.
Everything lands in PostgreSQL, the interesting fields as columns and
the full record as jsonb beside them. Where
[Lilith](https://github.com/LilithSec/Lilith) keeps only the alerts,
Allani keeps every log line.

- [architecture](architecture.md) :: the three ingest routes, the
  `syslog` / `http_access` / `http_error` tables and their columns, what
  the migrations index, and where Allani sits in the household

- [install](install.md) :: dependencies in detail, per-OS install, and
  preparing the PostgreSQL database

- [configuration](configuration.md) :: the `allani.yaml` reference — the
  database connection, enrichment, the manager, and the web logs to
  follow

- [usage](usage.md) :: the `allani` CLI — ingesting, searching,
  retention, and running the manager — plus the `ishara` worker

- [syslog-ng](syslog-ng.md) :: the `program()` and `unix-stream()`
  destinations and the JSON template that feed the gate, and the fields
  Allani requires

Also...

- `perldoc Allani`
- `perldoc Allani::Ingest`
- `perldoc Allani::Ishara`
- `perldoc Allani::Manager`
