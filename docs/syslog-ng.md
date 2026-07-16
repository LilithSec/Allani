# Hooking syslog-ng up to the gate

There are two ways in, both sending the same JSONL (one `format-json`
object per line):

1. **`program()`** — syslog-ng starts `allani ingest_json_syslog`, keeps
   it running, and writes to its stdin. Simplest; good for a standalone
   ingest.
2. **`unix-stream()`** — syslog-ng connects to a socket that the `ishara`
   syslog worker listens on (`allani start` with `syslog_socket` set).
   Preferred when running the managed daemon, since the manager keeps the
   ingester alive and syslog-ng just reconnects.

## The unix-stream destination (managed daemon)

Set `syslog_socket` in the config (see
[configuration](configuration.md#the-manager-run_dir-syslog_socket)) and
run `allani start`; then:

```
destination d_allani {
    unix-stream("/var/run/allani/syslog.ingest.sock"
        template("$(format-json C_ISODATE=${C_ISODATE} R_ISODATE=${R_ISODATE} S_ISODATE=${S_ISODATE} FACILITY=${FACILITY} HOST=${HOST} HOST_FROM=${HOST_FROM} PID=${PID} PRIORITY=${PRIORITY} PROGRAM=${PROGRAM} SOURCEIP=${SOURCEIP} MESSAGE=${MESSAGE})\n"));
};

log { source(s_local); destination(d_allani); };
```

## The program destination

```
destination d_allani {
    program(
        "/usr/local/bin/allani ingest_json_syslog"
        template("$(format-json C_ISODATE=${C_ISODATE} R_ISODATE=${R_ISODATE} S_ISODATE=${S_ISODATE} FACILITY=${FACILITY} HOST=${HOST} HOST_FROM=${HOST_FROM} PID=${PID} PRIORITY=${PRIORITY} PROGRAM=${PROGRAM} SOURCEIP=${SOURCEIP} MESSAGE=${MESSAGE})\n")
    );
};

log { source(s_local); destination(d_allani); };
```

Attach it to whatever sources should descend — the local box, the
network sources a central syslog-ng receives from other hosts, or both:

```
log {
    source(s_local);
    source(s_network);
    destination(d_allani);
};
```

## The fields

Allani requires these keys on every line; all are standard syslog-ng
macros:

| key         | meaning                                                    |
|-------------|------------------------------------------------------------|
| `C_ISODATE` | wall clock when syslog-ng processed the message            |
| `R_ISODATE` | when syslog-ng received the message                        |
| `S_ISODATE` | the timestamp carried in the message itself                |
| `FACILITY`  | syslog facility                                            |
| `HOST`      | host the message claims to be from                         |
| `HOST_FROM` | host syslog-ng actually got it from                        |
| `PRIORITY`  | syslog level (`info`, `err`, ...)                          |
| `PROGRAM`   | the program name                                           |
| `SOURCEIP`  | IP of the immediate sender                                 |

`PID` is optional — not everything that dies had one. A line missing a
required key is warned about on stderr (which syslog-ng logs) and
skipped.

Everything else in the template is stored too: the whole JSON line lands
in the `raw` jsonb column, so any additional macros or name-value pairs
added to `$(format-json ...)` — `MESSAGE` above, but also `MSGHDR`,
`${.SDATA.*}`, whatever — ride along and stay queryable via jsonb
operators. Adding a field is editing the template and reloading syslog-ng;
no schema change on Allani's side.

`MESSAGE` is optional for a bare store-everything deployment, but
**required for enrichment**: with `munger_rules` set (see
[configuration](configuration.md)) each record is run through
[Log::Munger](https://metacpan.org/pod/Log::Munger), whose rules gate on
`PROGRAM` and match against `MESSAGE`. Without `MESSAGE` in the record there
is nothing to extract from, and the extracted fields it does produce are
merged back into `raw` under the `enriched` key.

## Notes

- The `program()` destination runs as the user syslog-ng runs it as;
  that user needs to be able to read `/usr/local/etc/allani.yaml` (see
  [configuration](configuration.md)) and reach PostgreSQL.
- syslog-ng buffers to the program's stdin; if PostgreSQL is briefly
  unreachable the ingest process dies loudly, syslog-ng restarts it,
  and delivery resumes. For real spool-and-forward durability between
  boxes, use syslog-ng's own disk-buffer on the sending side.
- Test the template without the database by swapping the destination to
  `file("/tmp/allani-test.json" template(...))` and eyeballing the
  lines, or by feeding a captured line to `allani ingest_json_syslog`
  by hand — see [usage](usage.md#ingest_json_syslog).
