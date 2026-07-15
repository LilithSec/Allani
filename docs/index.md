# Allani documentation

Allani is the Lady of the Dark Earth, the Hurrian queen of the world
below, kin to Ereshkigal. Hers is the bolt on the underworld's gate:
nothing that dies above descends without passing her door.

In the world above, Allani is a syslog store — a replacement for the
Logstash + Elasticsearch pattern. [syslog-ng](https://www.syslog-ng.com/)
formats each log message as JSON and hands it to `allani
ingest_json_syslog` on stdin; Allani inserts each line into a
PostgreSQL `syslog` table, the interesting fields as columns and the
full JSON record as jsonb beside them. Where
[Lilith](https://github.com/LilithSec/Lilith) keeps only the alerts,
Allani keeps every log line.

- [architecture](architecture.md) :: the ingest path, the `syslog`
  table and its columns, and where Allani sits in the household

- [install](install.md) :: dependencies in detail, per-OS install, and
  preparing the PostgreSQL database

- [configuration](configuration.md) :: the `allani.yaml` reference —
  it is small: `dsn`, `user`, `pass`

- [usage](usage.md) :: the `allani` CLI — `ingest_json_syslog`

- [syslog-ng](syslog-ng.md) :: the `program()` destination and JSON
  template that feed the gate, and the fields Allani requires

Also...

- `perldoc Allani`
- `perldoc Allani::Ingest`
