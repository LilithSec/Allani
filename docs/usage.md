# Usage

Global options come before the command; `allani commands` lists them all
and `allani help <command>` explains one.

```shell
allani [--config <file>] <command> [command options]
allani commands
allani help <command>
```

## Global options

| switch            | description                                                |
|-------------------|------------------------------------------------------------|
| `--config <file>` | Config file to use. Default `/usr/local/etc/allani.yaml`.  |
| `--help`, `-h`    | Usage information.                                         |
| `--version`, `-v` | Version.                                                   |

## The commands

| command           | what it does                                                        |
|-------------------|---------------------------------------------------------------------|
| `ingest_json_syslog` | the gate — read syslog-ng JSON from stdin and store it            |
| `ingest_file`     | ingest syslog-ng JSON from files instead of stdin (replay/testing)  |
| `ingest_http_access` | read HTTP access log lines from stdin into the `http_access` table |
| `ingest_http_error` | read HTTP error log lines from stdin into the `http_error` table |
| `deploy`          | install the schema into a fresh database                            |
| `migrate`         | upgrade an existing database to this release's schema               |
| `schema_version`  | show the deployed schema version vs. this release                   |
| `check`           | pre-flight: config, database, schema version, and rules             |
| `munge`           | preview enrichment for a line without storing it                    |
| `enrich`          | re-run enrichment over rows already stored                          |
| `search`          | query stored rows with simple filters                               |
| `stats`           | count rows grouped by a field                                       |
| `prune`           | delete rows older than a given age (retention)                      |

`deploy`/`migrate` wrap `dbic-migration` with the schema class and the
connection from the config, so you do not retype it — see
[install](install.md#the-database).

## ingest_json_syslog

Reads syslog-ng-flavored JSON from stdin, one message per line, and
inserts each into the `syslog` table. It reads until stdin closes;
normally it is not run by hand but as a syslog-ng `program()`
destination, which starts it, feeds it, and keeps it running — see
[syslog-ng](syslog-ng.md).

```shell
allani ingest_json_syslog
```

Each line must be a JSON object bearing the syslog-ng macros
`C_ISODATE`, `R_ISODATE`, `S_ISODATE`, `FACILITY`, `HOST`, `HOST_FROM`,
`PRIORITY`, `PROGRAM`, and `SOURCEIP`; `PID` is optional. Those become
the columns; the entire line, extra fields and all, is kept in the `raw`
jsonb column — verbatim, plus the extracted fields under `enriched` when
enrichment is on (see [configuration](configuration.md)).

A line that fails to parse or is missing a required field is warned
about on stderr and skipped; ingestion continues with the next line.

Testing the gate by hand looks like...

```shell
echo '{"C_ISODATE":"2026-07-14T12:00:00-05:00","R_ISODATE":"2026-07-14T12:00:00-05:00","S_ISODATE":"2026-07-14T12:00:00-05:00","FACILITY":"daemon","HOST":"foo","HOST_FROM":"foo","PID":"42","PRIORITY":"info","PROGRAM":"test","SOURCEIP":"127.0.0.1","MESSAGE":"hello below"}' \
    | allani ingest_json_syslog
```

...followed by asking her table what arrived:

```shell
psql -U allani -c "SELECT id, s_isodate, host, program, raw->>'MESSAGE' AS message FROM syslog ORDER BY id DESC LIMIT 5;"
```

## ingest_file

Same as `ingest_json_syslog` but reads named files (one JSON record per
line) instead of stdin — for replaying a spool or loading test data.

```shell
allani ingest_file /var/spool/allani/backlog.json
```

## ingest_http_access

Reads HTTP access log lines (Apache/nginx *combined* or *common* format)
from stdin, one request per line, parses each through the configured rules
(`munger_rules` must include `http_access_logs`), and stores it in the
`http_access` table. `raw` holds `{ MESSAGE, enriched }`; the parsed fields
(client IP, method, request, status, bytes, referrer, user agent, and the
request time) are also copied into their own columns.

A bare access line carries no server identity, so those are supplied as
options and tag every row: `-H`/`--host` the server (defaults to the system
hostname), `--vhost` the virtual host name, `-P`/`--port` its port. The
natural fit is an Apache `CustomLog` pipe:

```apache
CustomLog "|/usr/local/bin/allani ingest_http_access -H web01 --vhost www.example.com -P 443" combined
```

By hand, or replaying a file:

```shell
allani ingest_http_access -H web01 --vhost www.example.com -P 443 < access.log
```

## ingest_http_error

The error-log counterpart to `ingest_http_access`. Reads HTTP error log lines
(Apache 2.2/2.4 or nginx) from stdin, parses each through the configured rules
(`munger_rules` must include `http_error_logs`), and stores it in the
`http_error` table. Same tagging options — `-H`/`--host`, `--vhost`,
`-P`/`--port` — since an error line carries none of them (nginx does log its
own `server`, kept in its own column). The natural fit is an Apache `ErrorLog`
pipe:

```apache
ErrorLog "|/usr/local/bin/allani ingest_http_error -H web01 --vhost www.example.com -P 443"
```

## deploy / migrate / schema_version

`deploy` installs the schema into a fresh database; `migrate` upgrades an
existing one after a release that bumps the schema; `schema_version`
reports where things stand. All read the connection from the config — see
[install](install.md#the-database).

```shell
allani deploy
allani migrate
allani schema_version
```

## check

A pre-flight check: parses the config, connects, compares the deployed
schema version against this release, and loads the configured munger
rules. Prints a line per check and exits non-zero on any problem — good
in a deploy script.

```shell
allani check
```

## munge

Previews what enrichment would extract from a line, without storing
anything — the tool for tuning `munger_rules`. Input is an argument or
stdin; a full JSON record, or a bare `MESSAGE` with `--program` to gate.
`--explain` shows which rule fired.

```shell
allani munge '{"PROGRAM":"sshd","MESSAGE":"Failed password for root from 203.0.113.7 port 2222 ssh2"}'
allani munge --explain -p sshd 'Failed password for root from 203.0.113.7 port 2222 ssh2'
```

## enrich

Re-runs the configured rules over rows already stored and rewrites the
`enriched` block inside `raw` — use it after adding or fixing rules. Only
rows whose enrichment changes are written. A filter (`--since`/`--program`)
or `--all` is required; `--dry-run` reports the count first.

```shell
allani enrich --since 7d --program postfix/smtpd --dry-run
allani enrich --all
```

## search

Queries stored rows with simple filters and prints a plain, tab-separated
table (no color). `--source syslog|http_access|http_error` (default `syslog`)
picks the table; only the filters valid for that source may be used
(`--program`/`--facility`/`--priority` for syslog;
`--vhost`/`--client-ip`/`--method`/`--status` for http_access;
`--vhost`/`--client-ip`/`--loglevel`/`--code`/`--server` for http_error;
`--host` for all). `--field key=value` matches an enriched field and may
repeat; `--json` prints each row's whole `raw`.

```shell
allani search --program sshd --since 24h --limit 50
allani search --field ssh_src_ip=203.0.113.7
allani search --source http_access --status 404 --vhost www.example.com
allani search --source http_error --loglevel error --since 1h
```

## stats

Counts rows grouped by a field, highest first. `--source` picks the table
and its dimensions (syslog: program/host/host_from/facility/priority;
http_access: vhost/host/method/status/client_ip; http_error:
server/host/loglevel/code/client_ip).

```shell
allani stats --by host --since 1d
allani stats --source http_access --by status --since 1h
allani stats --source http_error --by code --since 1d
```

## prune

Retention: deletes rows older than a given age (`90d`, `24h`, `30m`, ...).
`--source` picks the table (`syslog`, `http_access`, or `http_error`);
`r_isodate` is compared by default; `--dry-run` shows the count first.

```shell
allani prune --older-than 90d --dry-run
allani prune --source http_access --older-than 30d
allani prune --source http_error --older-than 30d
```

# ishara — the web-log follower

`ishara` is a separate daemon (not an `allani` subcommand) that tails the
Apache/nginx logs named by the `web_logs` config sets and feeds each line to
the `http_access` / `http_error` tables — the standing counterpart to piping
a `CustomLog`/`ErrorLog` into `ingest_http_access`/`ingest_http_error`. It
persists file offsets under `state_dir` (default `/var/db/allani`), so a
restart resumes exactly where it left off and never re-ingests.

```shell
ishara [--name <set>] [--config <file>] [-f|--foreground]
```

- `--name <set>` follows just that `web_logs` set; the default `all` follows
  every set in one process.
- `-f`/`--foreground` runs without daemonizing (writing its own PID file) —
  for systemd or running by hand. Without it, `ishara` daemonizes via
  `Net::Server::Daemonize`.

See [configuration](configuration.md#web_logs-the-ishara-follower) for the
`web_logs` block. A minimal run:

```shell
ishara --config /usr/local/etc/allani.yaml --foreground
```
