# Install

## Dependencies

Declared in `Makefile.PL`. The ingest path itself is plain DBI and
JSON::XS; POE and the rest are what the `allani start` manager and its
`ishara` workers need.

| CPAN module                     | FreeBSD pkg                | Debian pkg                     |
|---------------------------------|----------------------------|--------------------------------|
| App::Cmd                        | p5-App-Cmd                 | libapp-cmd-perl                |
| DBI                             | p5-DBI                     | libdbi-perl                    |
| DBD::Pg                         | p5-DBD-Pg                  | libdbd-pg-perl                 |
| DBIx::Class                     | p5-DBIx-Class              | libdbix-class-perl             |
| DBIx::Class::Migration          | p5-DBIx-Class-Migration    | libdbix-class-migration-perl   |
| Ereshkigal                      | *(CPAN)*                   | *(CPAN)*                       |
| File::ShareDir                  | p5-File-ShareDir           | libfile-sharedir-perl          |
| File::ShareDir::Install         | p5-File-ShareDir-Install   | libfile-sharedir-install-perl  |
| File::Slurp                     | p5-File-Slurp              | libfile-slurp-perl             |
| Hash::Merge                     | p5-Hash-Merge              | libhash-merge-perl             |
| JSON::MaybeXS                   | p5-JSON-MaybeXS            | libjson-maybexs-perl           |
| JSON::XS                        | p5-JSON-XS                 | libjson-xs-perl                |
| Log::Munger                     | *(CPAN)*                   | *(CPAN)*                       |
| Net::Server                     | p5-Net-Server              | libnet-server-perl             |
| POE                             | p5-POE                     | libpoe-perl                    |
| POE::Component::Server::JSONUnix | *(CPAN)*                  | *(CPAN)*                       |
| YAML::XS                        | p5-YAML-LibYAML            | libyaml-libyaml-perl           |

A few of these earn a word:

- Log::Munger :: Powers log enrichment, and the HTTP ingest paths will
  not run without it.
- Ereshkigal :: Provides the client the `status` and `stop` commands use
  to reach the running manager.
- Net::Server :: Wanted for `Net::Server::Daemonize`, which daemonizes
  the manager and the workers.
- IP::Geolocation::MMDB :: Optional, and needed only when `munger_geoip`
  is set.

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
    p5-DBIx-Class p5-DBIx-Class-Migration p5-File-Slurp \
    p5-File-ShareDir p5-File-ShareDir-Install p5-Hash-Merge \
    p5-JSON-XS p5-JSON-MaybeXS p5-Net-Server p5-POE p5-YAML-LibYAML
cpanm Log::Munger Ereshkigal POE::Component::Server::JSONUnix
```

...then install Allani itself from source as above.

## Debian

```shell
apt-get install cpanminus libapp-cmd-perl libdbi-perl libdbd-pg-perl \
    libdbix-class-perl libdbix-class-migration-perl libfile-slurp-perl \
    libfile-sharedir-perl libfile-sharedir-install-perl \
    libhash-merge-perl libjson-xs-perl libjson-maybexs-perl \
    libnet-server-perl libpoe-perl libyaml-libyaml-perl
cpanm Log::Munger Ereshkigal POE::Component::Server::JSONUnix
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
