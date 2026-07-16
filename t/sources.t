#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

BEGIN { use_ok('Allani::Sources'); }

# a stand-in for a Getopt::Long::Descriptive::Opts object
{

	package FakeOpt;
	our $AUTOLOAD;
	sub new { my ( $c, %h ) = @_; return bless {%h}, $c; }

	sub AUTOLOAD {
		my $self = shift;
		my $name = $AUTOLOAD;
		$name =~ s/.*:://;
		return if ( $name eq 'DESTROY' );
		return $self->{$name};
	}
}

# capture what a coderef prints to STDOUT
sub captured {
	my ($code) = @_;
	my $out = '';
	open( my $fh, '>', \$out ) or die $!;
	my $old = select($fh);
	$code->();
	select($old);
	close($fh);
	return $out;
}

is_deeply( [ Allani::Sources::names() ], [qw(http_access http_error syslog)], 'names() sorted' );
ok( Allani::Sources::source('syslog'),      'source(syslog) exists' );
is( Allani::Sources::source('nope'), undef, 'unknown source => undef' );

# ---- build_where -------------------------------------------------------------

subtest 'build_where' => sub {
	my $ha = Allani::Sources::source('http_access');

	my ( $w, $b ) = Allani::Sources::build_where( $ha,
		FakeOpt->new( 'host' => 'h1', 'status' => '404' ) );
	is_deeply( $w, [ 'host = ?', 'status = ?' ], 'valid filters become WHERE fragments' );
	is_deeply( $b, [ 'h1', '404' ], 'and their bind values' );

	( $w, $b ) = Allani::Sources::build_where( $ha, FakeOpt->new( 'message' => 'boom' ) );
	is_deeply( $w, ["raw->>'MESSAGE' ILIKE ?"], 'message => ILIKE' );
	is_deeply( $b, ['%boom%'], 'wrapped in wildcards' );

	# a non-numeric field value => a single containment predicate (uses the GIN index)
	( $w, $b ) = Allani::Sources::build_where( $ha, FakeOpt->new( 'field' => ['ssh_src_ip=1.2.3.4'] ) );
	is_deeply( $w, ['(raw @> ?::jsonb)'], 'field => jsonb containment' );
	is_deeply( $b, ['{"enriched":{"ssh_src_ip":"1.2.3.4"}}'], 'containment json bound' );

	# a numeric value => string OR number containment, so a numeric enriched
	# field (e.g. a port) still matches
	( $w, $b ) = Allani::Sources::build_where( $ha, FakeOpt->new( 'field' => ['ssh_src_port=44444'] ) );
	is_deeply( $w, ['(raw @> ?::jsonb OR raw @> ?::jsonb)'], 'numeric field => string OR number containment' );
	is_deeply(
		$b,
		[ '{"enriched":{"ssh_src_port":"44444"}}', '{"enriched":{"ssh_src_port":44444}}' ],
		'both the string and number forms are bound'
	);

	eval { Allani::Sources::build_where( $ha, FakeOpt->new( 'program' => 'x' ) ); };
	like( $@, qr/--program is not valid for source http_access/, 'invalid-for-source filter dies' );

	eval { Allani::Sources::build_where( $ha, FakeOpt->new( 'field' => ['noequals'] ) ); };
	like( $@, qr/--field must be key/, 'a field with no operator dies' );
};

# ---- field operators other than = --------------------------------------------

subtest 'field operators' => sub {
	my $sl = Allani::Sources::source('syslog');

	my ( $w, $b ) = Allani::Sources::build_where( $sl, FakeOpt->new( 'field' => ['code!=AH00128'] ) );
	is_deeply( $w, ["raw->'enriched'->>? IS DISTINCT FROM ?"], '!= => IS DISTINCT FROM' );
	is_deeply( $b, [ 'code', 'AH00128' ], 'key + value bound' );

	( $w, $b ) = Allani::Sources::build_where( $sl, FakeOpt->new( 'field' => ['n>=400'] ) );
	is_deeply(
		$w,
		["(jsonb_typeof(raw->'enriched'->?) = 'number' AND (raw->'enriched'->>?)::numeric >= ?)"],
		'numeric >= is guarded + cast'
	);
	is_deeply( $b, [ 'n', 'n', 400 ], 'key twice then the number' );

	( $w, $b ) = Allani::Sources::build_where( $sl, FakeOpt->new( 'field' => ['name>zzz'] ) );
	is_deeply( $w, ["raw->'enriched'->>? > ?"], 'non-numeric > is a text compare' );
	is_deeply( $b, [ 'name', 'zzz' ], 'text compare binds' );

	( $w, $b ) = Allani::Sources::build_where( $sl, FakeOpt->new( 'field' => ['ssh_user~^adm'] ) );
	is_deeply( $w, ["raw->'enriched'->>? ~ ?"], '~ => regex' );
	is_deeply( $b, [ 'ssh_user', '^adm' ], 'regex binds' );

	( $w, $b ) = Allani::Sources::build_where( $sl, FakeOpt->new( 'field' => ['ssh_user=~admin'] ) );
	is_deeply( $w, ["raw->'enriched'->>? ILIKE ?"], '=~ => ILIKE' );
	is_deeply( $b, [ 'ssh_user', '%admin%' ], 'contains wrapped in wildcards' );
};

# ---- program / host LIKE when the value has a % -------------------------------

subtest 'program/host LIKE on %' => sub {
	my $sl = Allani::Sources::source('syslog');

	my ( $w, $b ) = Allani::Sources::build_where( $sl, FakeOpt->new( 'program' => 'postfix/%' ) );
	is_deeply( $w, ['program LIKE ?'], 'program with % => LIKE' );
	is_deeply( $b, ['postfix/%'], 'value kept verbatim' );

	( $w, $b ) = Allani::Sources::build_where( $sl, FakeOpt->new( 'program' => 'sshd' ) );
	is_deeply( $w, ['program = ?'], 'program without % => exact' );

	( $w, $b ) = Allani::Sources::build_where( $sl, FakeOpt->new( 'host' => 'web%' ) );
	is_deeply( $w, ['host LIKE ?'], 'host with % => LIKE' );

	( $w, $b ) = Allani::Sources::build_where( $sl, FakeOpt->new( 'facility' => 'ma%il' ) );
	is_deeply( $w, ['facility = ?'], 'facility with % stays exact (not likeable)' );
};

# ---- select_and_headers ------------------------------------------------------

subtest 'select_and_headers' => sub {
	my $syslog = Allani::Sources::source('syslog');

	# with_id (tail: id is the follow cursor)
	my ( $sel, $hdr ) = Allani::Sources::select_and_headers( $syslog, 's_isodate', 0, 1 );
	is( $sel, "id, s_isodate, host, program, raw->>'MESSAGE'", 'with_id: id first, then time, then display' );
	is_deeply( $hdr, [qw(id time host program message)], 'with_id headers' );

	# without id (search: id neither selected nor shown)
	my ( $sel2, $hdr2 ) = Allani::Sources::select_and_headers( $syslog, 's_isodate', 0, 0 );
	is( $sel2, "s_isodate, host, program, raw->>'MESSAGE'", 'no id in the select' );
	is_deeply( $hdr2, [qw(time host program message)], 'no id in the headers' );

	my ( $jsel, $jhdr ) = Allani::Sources::select_and_headers( $syslog, 's_isodate', 1, 1 );
	is( $jsel, 'id, raw', 'json with_id selects id (cursor) + raw' );
	my ($jsel2) = Allani::Sources::select_and_headers( $syslog, 's_isodate', 1, 0 );
	is( $jsel2, 'raw',  'json without id selects just raw' );
	is( $jhdr,  undef,  'no headers in json mode' );
};

# ---- emit_row ----------------------------------------------------------------

subtest 'emit_row' => sub {
	my $line = captured( sub { Allani::Sources::emit_row( [ 5, 't', 'h', 'p', "two\nlines\there" ], 0 ) } );
	is( $line, "5\tt\th\tp\ttwo lines here\n", 'tab-joined, newlines/tabs squashed to spaces' );

	my $json = captured( sub { Allani::Sources::emit_row( [ 5, '{"a":1}' ], 1 ) } );
	is( $json, "{\"a\":1}\n", 'json mode prints the last (raw) column' );
};

done_testing();
