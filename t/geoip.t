#!perl
use 5.006;
use strict;
use warnings;
use Test::More;
use JSON::XS;
use Cwd qw(abs_path);
use File::Temp qw(tempfile);

my $mmdb = 't/mmdb/GeoLite2-Country-Test.mmdb';

plan skip_all => 'IP::Geolocation::MMDB is not installed'
	unless eval { require IP::Geolocation::MMDB; 1; };
plan skip_all => "test database $mmdb not found"
	unless -f $mmdb;
plan skip_all => 'Log::Munger / http rules unavailable'
	unless eval { require Log::Munger; Log::Munger->new( 'rules' => [ 'base', 'http_access_logs' ] ); 1; };

use_ok('Allani')                     || print "Bail out!\n";
use_ok('Allani::Ingest::HttpAccess') || print "Bail out!\n";

# a known test IP (81.2.69.142 => GB in the MaxMind test database) and a private
# one that the database does not resolve
my $GB_LINE   = '81.2.69.142 - - [15/Jul/2026:12:00:00 +0000] "GET / HTTP/1.1" 200 12 "-" "curl/8"';
my $PRIV_LINE = '10.0.0.1 - - [15/Jul/2026:12:00:00 +0000] "GET / HTTP/1.1" 200 12 "-" "curl/8"';

sub app_with {
	my (%config) = @_;
	my $app = bless {}, 'Allani';
	$app->{'allani'}{'config'} = {%config};
	return $app;
}

# a fake sth/dbh that records the last bound row (file scope so the named
# execute() closes over @ROW cleanly)
my @ROW;
{

	package FakeSth;
	sub execute { my ( $s, @a ) = @_; @ROW = @a; return 1; }
}
{

	package FakeDbh;
	sub prepare { return bless {}, 'FakeSth'; }
}
my @HTTP_COLS = qw(req_isodate host vhost vhost_port client_ip ident auth
	method request http_version status bytes referrer user_agent raw);

# ---- build_munger honours munger_geoip ---------------------------------------

subtest 'build_munger wires geoip from config' => sub {
	my $munger = app_with(
		'munger_rules' => [ 'base', 'http_access_logs' ],
		'munger_geoip' => $mmdb,
	)->build_munger;
	isa_ok( $munger, 'Log::Munger' );

	my $r = $munger->process_item( 'item' => $GB_LINE );
	ok( exists( $r->{'geoip'} ), 'geoip block present' );
	is( $r->{'geoip'}{'http_clientip'}{'country'}{'iso_code'},
		'GB', 'client ip resolves to GB under .geoip.http_clientip' );

	my $priv = $munger->process_item( 'item' => $PRIV_LINE );
	ok( defined($priv), 'private-ip line still matched' );
	ok( !exists( $priv->{'geoip'} ), 'private/absent ip => no geoip entry' );
};

subtest 'no munger_geoip => no geoip enrichment' => sub {
	my $munger = app_with( 'munger_rules' => [ 'base', 'http_access_logs' ] )->build_munger;
	my $r = $munger->process_item( 'item' => $GB_LINE );
	ok( defined($r) && !exists( $r->{'geoip'} ), 'no geoip key without a database' );
};

# ---- geoip flows into stored raw.enriched via the http ingest path -----------

subtest 'http ingest stores geoip inside raw.enriched' => sub {
	@ROW = ();

	my $munger = app_with(
		'munger_rules' => [ 'base', 'http_access_logs' ],
		'munger_geoip' => $mmdb,
	)->build_munger;

	my $ing = Allani::Ingest::HttpAccess->new(
		'dbh'        => bless( {}, 'FakeDbh' ),
		'munger'     => $munger,
		'host'       => 'web01',
		'vhost'      => 'www.example.com',
		'vhost_port' => 443,
	);
	$ing->ingest_line($GB_LINE);

	my %h;
	@h{@HTTP_COLS} = @ROW;
	is( $h{'client_ip'}, '81.2.69.142', 'client_ip column set' );

	my $raw = decode_json( $h{'raw'} );
	ok( exists( $raw->{'enriched'}{'geoip'} ), 'raw.enriched carries a geoip block' );
	is( $raw->{'enriched'}{'geoip'}{'http_clientip'}{'country'}{'iso_code'},
		'GB', 'stored geoip resolves the country' );
};

# ---- the munge command emits geoip -------------------------------------------

subtest 'munge command output includes geoip' => sub {
	my ( $cfh, $cfg ) = tempfile( 'allani-geoip-XXXXXX', SUFFIX => '.yaml', TMPDIR => 1, UNLINK => 1 );
	print {$cfh} "munger_rules:\n  - base\n  - http_access_logs\n";
	print {$cfh} 'munger_geoip: ' . abs_path($mmdb) . "\n";
	close($cfh);

	my ( $lfh, $lpath ) = tempfile( 'allani-line-XXXXXX', TMPDIR => 1, UNLINK => 1 );
	print {$lfh} $GB_LINE . "\n";
	close($lfh);

	# feed the line on stdin to avoid shell-quoting the request's embedded quotes
	my $out = `$^X -Ilib src_bin/allani --config $cfg munge < $lpath`;
	ok( length($out), 'munge produced output' );

	my $decoded = eval { decode_json($out) };
	ok( $decoded, 'munge output is valid JSON' ) or diag($out);
	is( $decoded->{'geoip'}{'http_clientip'}{'country'}{'iso_code'},
		'GB', 'munge enriches the client ip with geoip' );
};

done_testing();
