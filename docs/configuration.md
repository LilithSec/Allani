# Configuration

The config file is YAML, default `/usr/local/etc/allani.yaml`. Any
command takes another via `allani --config <file> <command>`.

It is small — the database connection plus optional enrichment. Settings
given in the file are merged over the defaults, so only what differs needs
to be present.

| key            | default                | description                                                                                                    |
|----------------|------------------------|----------------------------------------------------------------------------------------------------------------|
| `dsn`          | `dbi:Pg:dbname=allani` | The [DBI](https://metacpan.org/pod/DBI) DSN. PostgreSQL only ([DBD::Pg](https://metacpan.org/pod/DBD::Pg)).   |
| `user`         | `allani`               | User for the connection.                                                                                        |
| `pass`         | *(none)*               | Password for the connection.                                                                                    |
| `munger_rules` | *(none)*               | List of [Log::Munger](https://metacpan.org/pod/Log::Munger) rule files to enrich each record with. Empty/absent disables enrichment. |
| `munger_geoip` | *(none)*               | Path to a MaxMind `.mmdb` database. When set, rules that flag captured fields for geoip lookup get enriched. Needs `IP::Geolocation::MMDB`. |

A complete example, pointing at a remote database and enriching postfix and
sshd logs with geoip...

```yaml
dsn: dbi:Pg:dbname=allani;host=192.168.1.2
user: allani
pass: changeme
munger_rules:
  - base
  - postfix
  - sshd
munger_geoip: /usr/local/share/GeoIP/GeoLite2-City.mmdb
```

Notes:

- Enrichment is off unless `munger_rules` lists at least one rule file.
  `base` is the primitive library the daemon rule files build on; list it
  alongside the daemon files you want (`postfix`, `sshd`, `named`, ...).
  Include `http_access_logs` / `http_error_logs` if you use
  `ingest_http_access` / `ingest_http_error` — those commands parse each line
  through these same rules. The
  extracted fields are stored inside `raw` under the `enriched` key; the row
  is stored un-enriched if nothing matches or a rule misbehaves — a bad
  pattern never costs a log line. Enrichment needs `MESSAGE` in the record
  (see [syslog-ng.md](syslog-ng.md)), since the rules gate on `PROGRAM` and
  match against `MESSAGE`.

- If the default config path does not exist, the defaults above are
  used as-is — a local PostgreSQL over the socket, database `allani`,
  user `allani`, no password (e.g. peer/ident or `trust` auth). A
  path given explicitly via `--config` must exist; a missing one is a
  fatal error.
- The password sits in the file in cleartext, so keep it readable only
  by root and whatever user runs the ingest:
  `chmod 640 /usr/local/etc/allani.yaml`. On connection failure the
  DSN and user are printed, but the password is never echoed.

## indexes (per-field search indexes)

The schema migrations already ship the default indexes — the GIN index on
`raw` (for `--field key=value`), composite `(column, id)` btrees for the
convenience columns, and timestamp btrees for `--since`/`prune`. Those cover
the everyday searches.

Non-equality `--field` operators (`>`, `<`, `~`, `=~`, ...) extract a single
enriched field and can't use the `raw` GIN index, so searching a large table by
one of those is slow unless that specific field is indexed. These per-field
indexes are managed in the database (the `managed_indexes` table) via
[`allani index`](usage.md#index), not the config:

```shell
allani index add syslog dovecot_event
allani index add syslog url --trigram
```

The `indexes:` **config key is legacy** — a one-time `allani index import` reads
it into `managed_indexes`, after which you should delete it from the config:

```yaml
indexes:            # legacy: run `allani index import`, then remove this
  syslog:
    - dovecot_event
    - { field: ssh_user, trigram: true }
  http_error:
    - code
```

Every index costs write time on ingest, so index only the fields you actually
search by operator.

## web_logs (the `ishara` follower)

`ishara` — Allani's web-log follower — tails Apache/nginx logs and feeds
them to the `http_access` / `http_error` tables. It is configured under a
`web_logs` key: a map of named *sets*, plus a few reserved keys.

```yaml
munger_rules:
  - base
  - http_access_logs
  - http_error_logs

web_logs:
  geoip: /usr/local/share/GeoIP/GeoLite2-City.mmdb   # global default (reserved)
  state_dir: /var/db/allani                          # position tablets (reserved)
  pid_dir: /var/run                                  # PID files (reserved)

  # a set named "apache"
  apache:
    access: /var/log/apache2/*-access.log
    error:  /var/log/apache2/*-error.log
    # vhost/port are derived from the "*" of each filename (a ":" splits the
    # port), e.g. www.example.com:443-access.log -> vhost www.example.com, 443

  # a set with explicit tags and its own geoip
  nginx:
    access: /var/log/nginx/blog.access.log
    error:  /var/log/nginx/blog.error.log
    vhost:  blog.example.org
    vhost_port: 443
    geoip:  /path/to/other.mmdb
```

Notes:

- `geoip`, `state_dir`, and `pid_dir` are **reserved keys** — a set cannot
  use those names. `geoip` here is the global default; a set may override it
  with its own `geoip`, and geoip applies to the parsed client IP.
- `access` / `error` are globs. A set with no explicit `vhost` derives the
  vhost from the wildcard portion of each matched filename (with a `:`
  splitting off `vhost_port`); set `vhost`/`vhost_port` explicitly to tag all
  of a set's files the same.
- `munger_rules` must include `http_access_logs` and/or `http_error_logs`.
- Positions are checkpointed to `state_dir` (default `/var/db/allani`), so a
  restart resumes exactly where it left off — see [usage](usage.md#ishara).
