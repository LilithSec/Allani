#!perl
use 5.006;
use strict;
use warnings;
use Test::More;
use JSON::XS;

BEGIN { use_ok('Allani::Ingest::HttpAccess'); }

my $have_munger = eval {
	require Log::Munger;
	1;
};

# fake sth/dbh that records the last bound row
my @row;
{

	package FakeSth;
	sub execute { my ( $s, @a ) = @_; @row = @a; return 1; }
}
{

	package FakeDbh;
	sub prepare { return bless {}, 'FakeSth'; }
}

# column order in the INSERT (r_isodate defaults in the DB, so not bound)
my @COLS = qw(req_isodate host vhost vhost_port client_ip ident auth
	method request http_version status bytes referrer user_agent raw);

sub row_hash {
	my %h;
	@h{@COLS} = @row;
	return \%h;
}

sub ingester {
	my $munger = $have_munger ? Log::Munger->new( 'rules' => [ 'base', 'http_access_logs' ] ) : undef;
	return Allani::Ingest::HttpAccess->new(
		'dbh'        => bless( {}, 'FakeDbh' ),
		'munger'     => $munger,
		'host'       => 'web01',
		'vhost'      => 'www.example.com',
		'vhost_port' => 443,
	);
}

subtest 'a combined log line maps to columns and raw' => sub {
	plan skip_all => 'Log::Munger / http rules unavailable' unless $have_munger;

	@row = ();
	my $line =
		'203.0.113.5 - frank [15/Jul/2026:10:00:00 +0000] "POST /login HTTP/1.1" 302 512 "https://example.org/" "curl/7.68.0"';
	my $rc = ingester()->ingest_line($line);
	is( $rc, 1, 'ingest_line returned 1' );

	my $h = row_hash();
	is( $h->{'host'},         'web01',           'host tag' );
	is( $h->{'vhost'},        'www.example.com', 'vhost tag' );
	is( $h->{'vhost_port'},   443,               'vhost_port tag' );
	is( $h->{'client_ip'},    '203.0.113.5',     'client_ip' );
	is( $h->{'auth'},         'frank',           'auth' );
	is( $h->{'method'},       'POST',            'method' );
	is( $h->{'request'},      '/login',          'request' );
	is( $h->{'http_version'}, '1.1',             'http_version' );
	is( $h->{'status'},       302,               'status' );
	is( $h->{'bytes'},        512,               'bytes' );
	is( $h->{'referrer'},     'https://example.org/', 'referrer' );
	is( $h->{'user_agent'},   'curl/7.68.0',     'user_agent' );

	# Apache time -> ISO 8601 (PostgreSQL parses this as timestamptz)
	is( $h->{'req_isodate'}, '2026-07-15T10:00:00+00:00', 'req_isodate reformatted' );

	my $raw = decode_json( $h->{'raw'} );
	is( $raw->{'MESSAGE'}, $line, 'raw keeps the whole line' );
	ok( exists( $raw->{'enriched'} ), 'raw carries enriched' );
	is( $raw->{'enriched'}{'http_clientip'}, '203.0.113.5', 'enriched clientip' );
};

subtest 'common log format: - bytes becomes NULL, no referrer/agent' => sub {
	plan skip_all => 'Log::Munger / http rules unavailable' unless $have_munger;

	@row = ();
	ingester()->ingest_line('192.168.1.1 - - [12/Jul/2026:08:15:50 +0000] "GET / HTTP/1.1" 304 -');
	my $h = row_hash();
	is( $h->{'status'},     304,   'status parsed' );
	is( $h->{'bytes'},      undef, '"-" bytes -> undef (NULL)' );
	is( $h->{'referrer'},   undef, 'no referrer' );
	is( $h->{'user_agent'}, undef, 'no user agent' );
};

subtest 'blank and undef lines are skipped' => sub {
	my $ing = ingester();
	is( $ing->ingest_line(undef), 0, 'undef line skipped' );
	is( $ing->ingest_line("\n"),  0, 'blank line skipped' );
};

subtest 'a non-access line stores raw without enriched' => sub {
	plan skip_all => 'Log::Munger / http rules unavailable' unless $have_munger;

	@row = ();
	ingester()->ingest_line('this is not an access log line');
	my $h   = row_hash();
	my $raw = decode_json( $h->{'raw'} );
	ok( !exists( $raw->{'enriched'} ), 'no enriched block on a non-match' );
	is( $h->{'client_ip'}, undef, 'client_ip NULL on a non-match' );
};

done_testing();
