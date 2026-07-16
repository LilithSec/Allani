#!perl
use 5.006;
use strict;
use warnings;
use Test::More;
use JSON::XS;

BEGIN { use_ok('Allani::Ingest'); }

# a fake dbh/sth recording each execute; prepare_cached is what flush uses
our @EXEC;
our $EXPLODE = 0;
{

	package FakeSth;
	sub execute {
		my ( $s, @binds ) = @_;
		die "boom\n" if $main::EXPLODE;
		push( @main::EXEC, { 'sql' => $s->{'sql'}, 'binds' => \@binds } );
		return 1;
	}
}
{

	package FakeDbh;
	sub prepare        { return bless { 'sql' => $_[1] }, 'FakeSth'; }
	sub prepare_cached { return bless { 'sql' => $_[1] }, 'FakeSth'; }
}

sub record {
	my (%extra) = @_;
	return encode_json(
		{
			'C_ISODATE' => 't', 'R_ISODATE' => 't', 'S_ISODATE' => 't',
			'FACILITY'  => 'f', 'HOST'      => 'h', 'HOST_FROM' => 'h',
			'PRIORITY'  => 'p', 'PROGRAM'   => 'prog', 'SOURCEIP' => '1.2.3.4',
			%extra,
		}
	);
} ## end sub record

sub ingester { return Allani::Ingest->new( 'dbh' => bless( {}, 'FakeDbh' ), @_ ); }

subtest 'queue buffers and flush writes one multi-row insert' => sub {
	@EXEC = ();
	my $ing = ingester();
	$ing->queue( record( 'MESSAGE' => "line $_" ) ) for ( 1 .. 3 );
	is( $ing->pending, 3, 'three rows buffered' );

	my $n = $ing->flush;
	is( $n,            3, 'flush wrote three' );
	is( $ing->pending, 0, 'buffer drained' );

	is( scalar(@EXEC), 1, 'one insert statement' );
	is( scalar( @{ $EXEC[0]{'binds'} } ), 33, '33 binds (3 rows x 11 columns)' );
	like( $EXEC[0]{'sql'}, qr/VALUES \(\?.*\),\(\?.*\),\(\?/, 'a three-tuple multi-row VALUES' );

	is( $ing->flush, 0, 'flushing an empty buffer writes nothing' );
};

subtest 'a bad line dies in queue, before it is buffered' => sub {
	my $ing = ingester();
	eval { $ing->queue('{ not valid json') };
	isnt( $@, '', 'malformed line dies' );
	eval { $ing->queue( encode_json( { 'HOST' => 'h' } ) ) };    # missing required fields
	like( $@, qr/is undef/, 'missing required field dies' );
	is( $ing->pending, 0, 'nothing buffered from the bad lines' );
};

subtest 'enrichment works in the batched path' => sub {
	my $have = eval { require Log::Munger; 1 };
	plan skip_all => 'Log::Munger unavailable' unless $have;

	@EXEC = ();
	my $ing = ingester( 'munger' => Log::Munger->new( 'rules' => [ 'base', 'sshd' ] ) );
	$ing->queue(
		record(
			'PROGRAM' => 'sshd-session',
			'MESSAGE' => 'Failed password for invalid user admin from 203.0.113.7 port 44444 ssh2'
		)
	);
	$ing->flush;
	my $raw = $EXEC[0]{'binds'}[-1];    # raw is the last column of the single row
	my $decoded = decode_json($raw);
	ok( exists( $decoded->{'enriched'} ), 'batched row carries enriched' );
	is( $decoded->{'enriched'}{'ssh_user'}, 'admin', 'enriched field present' );
};

subtest 'a batch larger than the chunk limit is split' => sub {
	@EXEC = ();
	my $ing = ingester();
	$ing->queue( record( 'MESSAGE' => 'x' ) ) for ( 1 .. 5001 );    # > 5000 chunk cap
	my $n = $ing->flush;
	is( $n,            5001, 'all rows written' );
	is( scalar(@EXEC), 2,    'split into two inserts (5000 + 1)' );
	is( scalar( @{ $EXEC[0]{'binds'} } ), 5000 * 11, 'first chunk is 5000 rows' );
	is( scalar( @{ $EXEC[1]{'binds'} } ), 1 * 11,    'second chunk is the remainder' );
};

subtest 'a failing chunk is dropped, not wedged' => sub {
	@EXEC = ();
	local $EXPLODE = 1;
	my $ing = ingester();
	$ing->queue( record( 'MESSAGE' => 'x' ) ) for ( 1 .. 3 );
	my $n;
	my @warns;
	local $SIG{'__WARN__'} = sub { push( @warns, $_[0] ) };
	$n = $ing->flush;
	is( $n,            0, 'nothing counted as written' );
	is( $ing->pending, 0, 'buffer still drained (not wedged)' );
	like( join( '', @warns ), qr/batch insert of 3 syslog row/, 'the failure was warned' );
};

done_testing();
