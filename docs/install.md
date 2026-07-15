# Install

## Dependencies

Declared in `Makefile.PL`. The chain is small — the ingest path is
plain DBI and JSON::XS.

| CPAN module            | FreeBSD pkg              | Debian pkg               |
|------------------------|-------------------------|--------------------------|
| App::Cmd               | p5-App-Cmd              | libapp-cmd-perl          |
| DBI                    | p5-DBI                  | libdbi-perl              |
| DBD::Pg                | p5-DBD-Pg               | libdbd-pg-perl           |
| DBIx::Class            | p5-DBIx-Class           | libdbix-class-perl       |
| DBIx::Class::Migration | p5-DBIx-Class-Migration | libdbix-class-migration-perl |
| File::Slurp            | p5-File-Slurp           | libfile-slurp-perl       |
| Hash::Merge            | p5-Hash-Merge           | libhash-merge-perl       |
| JSON::XS               | p5-JSON-XS              | libjson-xs-perl          |
| Log::Munger            | *(CPAN)*                | *(CPAN)*                 |
| YAML::XS               | p5-YAML-LibYAML         | libyaml-libyaml-perl     |

`Log::Munger` powers log enrichment; `IP::Geolocation::MMDB` is an
additional optional dependency, needed only when `munger_geoip` is set.

Package names are current as of writing. Anything missing from your
release installs cleanly from CPAN via
[cpanminus](https://metacpan.org/pod/App::cpanminus).

## From source

Dependencies are declared in `Makefile.PL`, so from a checkout or an
unpacked release tarball...

```shell
cpanm --installdeps .
perl Makefile.PL
make
make test
make install
```

## FreeBSD

```shell
pkg install p5-App-cpanminus p5-App-Cmd p5-DBI p5-DBD-Pg \
    p5-DBIx-Class p5-DBIx-Class-Migration p5-File-Slurp p5-Hash-Merge \
    p5-JSON-XS p5-YAML-LibYAML
cpanm Log::Munger
```

...then install Allani itself from source as above.

## Debian

```shell
apt-get install cpanminus libapp-cmd-perl libdbi-perl libdbd-pg-perl \
    libdbix-class-perl libdbix-class-migration-perl libfile-slurp-perl \
    libhash-merge-perl libjson-xs-perl libyaml-libyaml-perl
cpanm Log::Munger
```

...then install Allani itself from source as above.

## The database

Allani needs PostgreSQL — the raw records live in a jsonb column. She
owns and creates her own schema (unlike
[Lilu](https://github.com/LilithSec/App-Lilu), who writes into
Lilith's).

Create a role and a database...

```shell
psql -U postgres -c "CREATE ROLE allani WITH LOGIN PASSWORD 'changeme';"
psql -U postgres -c "CREATE DATABASE allani OWNER allani;"
```

...write `/usr/local/etc/allani.yaml` (see
[configuration](configuration.md); with the defaults — database
`allani`, user `allani`, local socket — no config file is needed at
all)...

```yaml
dsn: dbi:Pg:dbname=allani
user: allani
pass: changeme
```

...and prepare the ground. The schema is versioned with
[DBIx::Class::Migration](https://metacpan.org/pod/DBIx::Class::Migration);
deploy it with `dbic-migration` (installed with that module):

```shell
dbic-migration --schema_class Allani::Schema -P changeme -U allani \
    --dsn 'dbi:Pg:dbname=allani;host=192.168.1.2' install
```

### Upgrading

After pulling a release that bumps the schema version:

```shell
dbic-migration --schema_class Allani::Schema -P changeme -U allani \
    --dsn 'dbi:Pg:dbname=allani;host=192.168.1.2' upgrade
```

`dbic-migration` needs `Allani::Schema` on `@INC` — run it from an
installed Allani, or from a checkout with `perl -Ilib $(command -v
dbic-migration) ...`.

Then hook syslog-ng up to the gate — see [syslog-ng](syslog-ng.md).
