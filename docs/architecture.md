# Architecture

## The ingest path

The path from a daemon's dying words to the Dark Earth is short, and
that is the point — there is no broker, no pipeline DSL, no cluster.

```
daemons → syslog-ng → $(format-json ...) → program("allani ingest_json_syslog") → PostgreSQL
```

1. syslog-ng collects log messages as usual (local sources, network
   sources, whatever it is configured for).
2. A `program()` destination formats each message as a single line of
   JSON via `$(format-json ...)` and writes it to the stdin of a
   long-running `allani ingest_json_syslog` process. syslog-ng owns
   that process: it starts it, keeps it running, and restarts it if it
   exits.
3. `ingest_json_syslog` reads stdin line by line. Each line is decoded
   (`JSON::XS`), the required fields checked, and one row inserted into
   the `syslog` table via a prepared statement. A line that fails to
   parse or is missing a required field is warned about on stderr and
   skipped — one malformed message does not stop the procession behind
   it.

There is no daemon of Allani's own and no state outside PostgreSQL.
Scaling out is running the same destination on more syslog-ng boxes,
all pointed at the same database.

## The syslog table

`dbic-migration ... install` prepares the ground (see
[install](install.md#the-database)):

| column       | type                       | from (syslog-ng macro)                                  |
|--------------|----------------------------|---------------------------------------------------------|
| `id`         | `bigserial`, primary key   | —                                                       |
| `c_isodate`  | `timestamp with time zone` | `C_ISODATE` — wall clock when the message was processed |
| `r_isodate`  | `timestamp with time zone` | `R_ISODATE` — when syslog-ng received the message       |
| `s_isodate`  | `timestamp with time zone` | `S_ISODATE` — the timestamp carried in the message      |
| `facility`   | `varchar(255)`             | `FACILITY`                                              |
| `host`       | `varchar(255)`             | `HOST`                                                  |
| `host_from`  | `varchar(255)`             | `HOST_FROM`                                             |
| `pid`        | `bigint`, nullable         | `PID` — not every program has one                       |
| `priority`   | `varchar(64)`              | `PRIORITY`                                              |
| `program`    | `varchar(255)`             | `PROGRAM`                                               |
| `sourceip`   | `inet`                     | `SOURCEIP`                                              |
| `raw`        | `jsonb`                    | the entire JSON line, verbatim                          |

The columns are the fields worth indexing and filtering on; `raw` is
the whole record as syslog-ng rendered it, so nothing in the template
is ever lost. Extra fields added to the `format-json` template (the
message itself, structured data, anything) are not columns but live on
in `raw` and are reachable with PostgreSQL's jsonb operators:

```sql
-- what did sshd say from that host?
SELECT s_isodate, raw->>'MESSAGE'
    FROM syslog
    WHERE program = 'sshd' AND host = 'foo.example'
    ORDER BY s_isodate DESC;
```

This is the household's established burial rite — the same
columns-plus-jsonb shape Lilith uses for her alerts, in the same
PostgreSQL earth.

`Allani::Schema` / `Allani::Schema::Result::Syslog` are
DBIx::Class::Schema::Loader-generated classes for the same table, there
for the coming search side of things; the ingest path itself is plain
DBI and does not use them.

## The http_access table

HTTP access logs are not syslog and do not fit the syslog table's
required columns, so they get their own table (schema version 2) — the
same per-source shape Lilith uses for her several alert kinds. A bare
Apache/nginx access line is parsed by the `http_access_logs` Log::Munger
rules; `raw` holds `{ MESSAGE, enriched }` and the parsed fields become
columns:

| column         | type                       | from                                              |
|----------------|----------------------------|---------------------------------------------------|
| `id`           | `bigserial`, primary key   | —                                                 |
| `r_isodate`    | `timestamptz`, `now()`     | when Allani received the line                     |
| `req_isodate`  | `timestamptz`, nullable    | the request time, parsed from the log timestamp   |
| `host`         | `varchar(255)`             | the server, from `-H` (default: system hostname)  |
| `vhost`        | `varchar(255)`             | the virtual host, from `--vhost`                  |
| `vhost_port`   | `integer`                  | the virtual host port, from `-P`                  |
| `client_ip`    | `inet`                     | `http_clientip` (geoip rides in `raw.enriched`)   |
| `ident`        | `varchar(255)`             | `http_ident`                                      |
| `auth`         | `varchar(255)`             | `http_auth`                                       |
| `method`       | `varchar(16)`              | `http_verb`                                       |
| `request`      | `text`                     | `http_request`                                    |
| `http_version` | `varchar(16)`              | `http_httpversion`                                |
| `status`       | `integer`                  | `http_response`                                   |
| `bytes`        | `bigint`, nullable         | `http_bytes` (`-` → NULL)                         |
| `referrer`     | `text`                     | `http_referrer`                                   |
| `user_agent`   | `text`                     | `http_agent`                                      |
| `raw`          | `jsonb`                    | `{ MESSAGE, enriched }`                            |

The `vhost`/`vhost_port`/`host` values are supplied to
`ingest_http_access` as options because the log line itself carries
none of them. `search`, `stats`, and `prune` reach this table with
`--source http_access`.

## The http_error table

The error-log sibling (schema version 3), fed by `ingest_http_error`
through the `http_error_logs` rules. `raw` is `{ MESSAGE, enriched }`;
the columns hold the parsed fields common across Apache 2.2/2.4 and
nginx:

| column        | type                       | from                                             |
|---------------|----------------------------|--------------------------------------------------|
| `id`          | `bigserial`, primary key   | —                                                |
| `r_isodate`   | `timestamptz`, `now()`     | when Allani received the line                    |
| `err_isodate` | `timestamptz`, nullable    | the log timestamp, parsed (no tz in the log)     |
| `host`        | `varchar(255)`             | the server, from `-H` (default: system hostname) |
| `vhost`       | `varchar(255)`             | the virtual host, from `--vhost`                 |
| `vhost_port`  | `integer`                  | the virtual host port, from `-P`                 |
| `client_ip`   | `inet`                     | `http_error_client_ip` (geoip in `raw.enriched`) |
| `loglevel`    | `varchar(32)`              | `http_error_loglevel`                            |
| `pid`         | `bigint`, nullable         | `http_error_pid`                                 |
| `code`        | `varchar(64)`              | `http_error_code` (Apache `AH…`)                 |
| `server`      | `varchar(255)`             | `http_error_server` (nginx logs its own vhost)   |
| `request`     | `text`                     | `http_error_request` (nginx)                     |
| `message`     | `text`                     | `http_error_message`                             |
| `raw`         | `jsonb`                    | `{ MESSAGE, enriched }`                           |

Reach it with `--source http_error`. Fields specific to one server
(Apache module/tid/client_port, nginx connection id/host) are not
columns but live on in `raw.enriched`.

## Where she sits in the household

Everything that happens above eventually dies and becomes a log line,
and every log line descends to Allani. The others each keep a narrower
court:

- [Lilith](https://github.com/LilithSec/Lilith) keeps the *noteworthy*
  dead — alerts from Suricata, Sagan, and CAPEv2, the deaths that
  looked suspicious.
- [Lamashtu](https://github.com/LilithSec/Lamashtu) keeps what crossed
  the wire — raw packets — and
  [Virani](https://github.com/LilithSec/Virani) divines answers back
  out of her hoard.
- [Baphomet](https://github.com/LilithSec/Baphomet) reads logs to
  accuse, and [Ereshkigal](https://github.com/LilithSec/Ereshkigal)
  punishes the accused at the firewall.

Allani receives everything the daemons said, remarkable or not. When an
alert in Lilith's annals needs context — what else was happening on
that host around that time — the ordinary dead who surrounded it are in
Allani's halls, one SQL query away in the same database engine.

None of the others depend on her and she depends on none of them; she
shares the household's bones (PostgreSQL, columns-plus-jsonb, a small
config file in `/usr/local/etc/`) and keeps its dead.
