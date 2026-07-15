#!perl
use 5.006;
use strict;
use warnings;
use Test::More;
use JSON::XS;

BEGIN { use_ok('Allani::Ingest::HttpError'); }

my $have_munger = eval {
	require Log::Munger;
	Log::Munger->new( 'rules' => [ 'base', 'http_error_logs' ] );
	1;
};
my $mmdb = 't/mmdb/GeoLite2-Country-Test.mmdb';
my $have_geoip = ( eval { require IP::Geolocation::MMDB; 1; } && -f $mmdb );

my @ROW;
{

	package FakeSth;
	sub execute { my ( $s, @a ) = @_; @ROW = @a; return 1; }
}
{

	package FakeDbh;
	sub prepare { return bless {}, 'FakeSth'; }
}

my @COLS = qw(err_isodate host vhost vhost_port client_ip loglevel pid code
	server request message raw);

sub row_hash {
	my %h;
	@h{@COLS} = @ROW;
	return \%h;
}

sub ingester {
	my (%extra) = @_;
	my %args = ( 'rules' => [ 'base', 'http_error_logs' ] );
	$args{'geoip'} = $mmdb if ( $extra{'geoip'} && $have_geoip );
	my $munger = $have_munger ? Log::Munger->new(%args) : undef;
	return Allani::Ingest::HttpError->new(
		'dbh'        => bless( {}, 'FakeDbh' ),
		'munger'     => $munger,
		'host'       => 'web01',
		'vhost'      => 'www.example.com',
		'vhost_port' => 443,
	);
}

subtest 'apache 2.4 error line' => sub {
	plan skip_all => 'Log::Munger / http rules unavailable' unless $have_munger;

	@ROW = ();
	ingester()->ingest_line(
		'[Wed Oct 11 14:32:52.123456 2000] [core:error] [pid 12345:tid 140234] [client 192.168.1.1:1234] AH00128: File does not exist: /var/www/html/favicon.ico'
	);
	my $h = row_hash();
	is( $h->{'host'},        'web01',   'host tag' );
	is( $h->{'loglevel'},    'error',   'loglevel' );
	is( $h->{'pid'},         12345,     'pid' );
	is( $h->{'code'},        'AH00128', 'code' );
	is( $h->{'client_ip'},   '192.168.1.1', 'client_ip' );
	is( $h->{'err_isodate'}, '2000-10-11T14:32:52.123456', 'apache 2.4 timestamp -> ISO 8601 with fraction' );
	like( $h->{'message'}, qr/File does not exist/, 'message' );

	my $raw = decode_json( $h->{'raw'} );
	ok( exists( $raw->{'enriched'} ), 'raw carries enriched' );
};

subtest 'apache 2.2 error line (no pid/code)' => sub {
	plan skip_all => 'Log::Munger / http rules unavailable' unless $have_munger;

	@ROW = ();
	ingester()->ingest_line(
		'[Wed Oct 11 14:32:52 2000] [error] [client 192.168.1.1] File does not exist: /var/www/favicon.ico' );
	my $h = row_hash();
	is( $h->{'loglevel'},    'error', 'loglevel' );
	is( $h->{'pid'},         undef,   'no pid in 2.2' );
	is( $h->{'code'},        undef,   'no code in 2.2' );
	is( $h->{'err_isodate'}, '2000-10-11T14:32:52', 'apache 2.2 timestamp -> ISO 8601' );
};

subtest 'nginx error line (server/request/pid)' => sub {
	plan skip_all => 'Log::Munger / http rules unavailable' unless $have_munger;

	@ROW = ();
	ingester()->ingest_line(
		'2000/10/11 14:32:52 [error] 12345#0: *67 open() "/x" failed (2: No such file or directory), client: 192.168.1.1, server: example.com, request: "GET /favicon.ico HTTP/1.1", host: "example.com"'
	);
	my $h = row_hash();
	is( $h->{'loglevel'},    'error',            'loglevel' );
	is( $h->{'pid'},         12345,              'pid' );
	is( $h->{'server'},      'example.com',      'nginx server' );
	is( $h->{'request'},     'GET /favicon.ico HTTP/1.1', 'nginx request' );
	is( $h->{'err_isodate'}, '2000-10-11T14:32:52', 'nginx timestamp -> ISO 8601' );
};

subtest 'geoip enriches the error client ip' => sub {
	plan skip_all => 'geoip unavailable' unless ( $have_munger && $have_geoip );

	@ROW = ();
	ingester( 'geoip' => 1 )->ingest_line(
		'2000/10/11 14:32:52 [error] 1#0: *1 boom, client: 81.2.69.142, server: x, request: "GET / HTTP/1.1", host: "x"'
	);
	my $raw = decode_json( row_hash()->{'raw'} );
	is( $raw->{'enriched'}{'geoip'}{'http_error_client_ip'}{'country'}{'iso_code'},
		'GB', 'error client ip resolves to GB under raw.enriched.geoip' );
};

subtest 'blank/undef lines and non-error lines' => sub {
	my $ing = ingester();
	is( $ing->ingest_line(undef), 0, 'undef skipped' );
	is( $ing->ingest_line("\n"),  0, 'blank skipped' );

	SKIP: {
		skip( 'Log::Munger unavailable', 1 ) unless $have_munger;
		@ROW = ();
		$ing->ingest_line('this is not an error log line');
		my $raw = decode_json( row_hash()->{'raw'} );
		ok( !exists( $raw->{'enriched'} ), 'non-error line stored without enriched' );
	}
};

done_testing();
