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
| `tail`            | show the most recent rows, optionally following new ones            |
| `stats`           | count rows grouped by a field                                       |
| `prune`           | delete rows older than a given age (retention)                      |
| `index`           | create the per-enriched-field indexes named in the config           |
| `start`           | start the manager and its ishara workers                            |
| `stop`            | stop the running manager and its workers                            |
| `status`          | show the manager and workers status                                 |

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
By default it prints just the extracted fields; `--full` prints the whole
record with them merged under `enriched`, exactly as it would be stored;
`--explain` shows which rule fired.

```shell
allani munge '{"PROGRAM":"sshd","MESSAGE":"Failed password for root from 203.0.113.7 port 2222 ssh2"}'
allani munge --full -p sshd 'Failed password for root from 203.0.113.7 port 2222 ssh2'
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

`--field key<op>value` supports operators beyond `=`:

| op | meaning | indexed? |
|----|---------|----------|
| `=`  | equals (jsonb containment) | yes — the GIN index on `raw` |
| `!=` / `<>` | not equal (a missing field counts as not-equal) | no |
| `>` `<` `>=` `<=` | numeric compare when the value is a number, else text | no |
| `~` / `!~` | POSIX regex match / not-match | no |
| `=~` | substring, case-insensitive (`ILIKE %value%`) | no |

Only `=` uses the `raw` GIN index (schema version 4). The other operators
extract and compare per row, so **pair them with a column or `--since` filter**,
or index the specific field with [`index`](#index) below — otherwise they scan
the table. Apply `allani migrate` if you are on an older schema.

`--program` and `--host` switch to `LIKE` automatically when their value
contains a `%` wildcard, e.g. `--program 'postfix/%'` or `--host 'web%'`.

## tail

Prints the last few rows (oldest first, newest at the bottom) and, with
`-f`/`--follow`, keeps polling for newer rows and printing them as they
arrive — the database analog of `tail -f`. New rows are found by `id` (the
monotonic primary key), so nothing is missed or repeated. It shares
`--source` and all the filters with `search`; `Ctrl-C` stops a follow.

```shell
allani tail -n 20                                  # last 20 syslog rows
allani tail -f --program sshd                      # follow sshd
allani tail --source http_error -f --loglevel error
```

`-n`/`--lines` sets the initial batch (default 10); `--interval` the poll
seconds when following (default 2).

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

## index

Manages btree / trigram indexes on individual enriched fields so non-equality
`--field` searches (`>`, `<`, `~`, `=~`, ...) on those fields are fast. The set
of managed indexes lives in the `managed_indexes` table (schema version 6), not
the config. It is verb-dispatched:

```shell
allani index                       # (list) the managed indexes and whether they exist
allani index list --all            # also show schema/other indexes on the tables
allani index add syslog dovecot_event
allani index add syslog url --trigram      # trigram GIN, for ~ / =~ / ILIKE
allani index drop syslog dovecot_event
allani index drop --name allani_ix_syslog_url_trgm
allani index sync                  # create any tracked index that is missing
allani index sync --prune          # also drop managed indexes no longer tracked
allani index import                # seed the table from a legacy 'indexes' config block
```

`--concurrently` builds/drops without locking ingest; `--dry-run` shows what
would happen. Trigram indexes need the `pg_trgm` extension, which `add`/`sync`
create if missing.

`drop` only ever touches `allani_ix_*` indexes tracked in `managed_indexes`, so
the **schema-required indexes** — primary keys, the raw GIN, the `(column, id)`
composites, the timestamp btrees — as well as any hand-made index, can never be
dropped. Those defaults are shipped by the schema migrations and applied by
`deploy`/`migrate`.

# The manager — start / stop / status

For a running deployment, `allani start` launches a **manager** that spawns and
supervises the `ishara` workers: one per `web_logs` set, plus one syslog worker
when a `syslog_socket` is configured. It restarts a worker that dies (with
backoff), logs each worker's stdout/stderr to syslog, and answers `stop` /
`status` on a unix control socket. PID files and sockets live under `run_dir`
(default `/var/run/allani`).

```shell
allani start                 # daemonize the manager
allani start --foreground    # run it in the foreground (systemd, or by hand)
allani status                # uptime + per-worker up/down, PID, restart count
allani stop                  # stop the workers and the manager
```

`allani` logs (via syslog, ident `allani`) when it starts up and loads its
config; workers log under `ishara-<name>`. See
[configuration](configuration.md#the-manager-run_dir-syslog_socket) for
`run_dir`, `syslog_socket`, and `ishara_bin`.

# ishara — the worker

`ishara` is the worker daemon the manager spawns; it can also be run directly.
In **web mode** it tails the Apache/nginx logs named by a `web_logs` set and
feeds each line to the `http_access` / `http_error` tables, persisting file
offsets under `state_dir` (default `/var/db/allani`) so a restart resumes
exactly. In **syslog mode** it listens on a unix socket for JSONL syslog and
ingests it into the `syslog` table.

```shell
ishara [--name <set>] [--config <file>] [-f|--foreground]   # web mode
ishara --syslog [--config <file>] [-f|--foreground]         # syslog socket mode
```

- `--name <set>` follows just that `web_logs` set; `all` (default) follows every
  set in one process.
- `-s`/`--syslog` runs the syslog JSONL socket ingester instead (see
  [syslog-ng](syslog-ng.md)).
- `-f`/`--foreground` runs without daemonizing; the manager always spawns
  workers this way.

Normally you run `allani start` and let the manager manage the workers rather
than launching `ishara` by hand.
