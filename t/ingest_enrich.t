#!perl
use 5.006;
use strict;
use warnings;
use Test::More;
use JSON::XS;

BEGIN { use_ok('Allani::Ingest'); }

# Log::Munger (and its shipped 'base'/'sshd' rule files) is a hard prereq, but
# guard anyway so a box missing the rule share dir skips rather than fails.
my $munger;
my $have_munger = eval {
	require Log::Munger;
	$munger = Log::Munger->new( 'rules' => [ 'base', 'sshd' ] );
	1;
};

# A fake statement handle/db handle pair: execute() just records the last bound
# row so we can assert on what would have been stored, no PostgreSQL needed.
my @last_row;
{

	package FakeSth;
	sub execute { my ( $s, @a ) = @_; @last_row = @a; return 1; }
}
{

	package FakeDbh;
	sub prepare { return bless {}, 'FakeSth'; }
}

# the bind order in Allani::Ingest, so tests can name the columns
my @COLS = qw(C_ISODATE R_ISODATE S_ISODATE FACILITY HOST HOST_FROM PID PRIORITY PROGRAM SOURCEIP raw);

sub row_as_hash {
	my %h;
	@h{@COLS} = @last_row;
	return \%h;
}

sub base_record {
	return {
		'C_ISODATE' => '2026-07-15T00:00:00Z',
		'R_ISODATE' => '2026-07-15T00:00:00Z',
		'S_ISODATE' => '2026-07-15T00:00:00Z',
		'FACILITY'  => 'auth',
		'HOST'      => 'gate',
		'HOST_FROM' => 'gate',
		'PRIORITY'  => 'info',
		'PROGRAM'   => 'sshd',
		'SOURCEIP'  => '10.0.0.1',
		@_,
	};
}

# a message a shipped sshd rule matches
my $SSH_FAIL = 'Failed password for invalid user admin from 203.0.113.7 port 44444 ssh2';

subtest 'enrichment merges captures under the enriched key' => sub {
	plan skip_all => 'Log::Munger / rule files unavailable' unless $have_munger;

	@last_row = ();
	my $ing = Allani::Ingest->new( 'dbh' => bless( {}, 'FakeDbh' ), 'munger' => $munger );
	my $rc  = $ing->ingest_json_syslog( encode_json( base_record( 'MESSAGE' => $SSH_FAIL ) ) );
	is( $rc, 1, 'ingest returned 1' );

	my $row = row_as_hash();
	is( $row->{'PROGRAM'}, 'sshd', 'PROGRAM column bound correctly' );

	my $raw = eval { decode_json( $row->{'raw'} ) };
	ok( $raw, 'raw column is valid JSON' );
	ok( exists( $raw->{'enriched'} ), 'raw carries an enriched key' );
	is( $raw->{'MESSAGE'}, $SSH_FAIL, 'original MESSAGE preserved in raw' );

	my $e = $raw->{'enriched'};
	is( $e->{'ssh_user'},   'admin',       'enriched ssh_user' );
	is( $e->{'ssh_src_ip'}, '203.0.113.7', 'enriched ssh_src_ip' );

	# convert: fields serialize as JSON numbers, not strings
	is( $e->{'ssh_src_port'}, 44444, 'enriched ssh_src_port value' );
	like( encode_json($e), qr/"ssh_src_port":44444/, 'ssh_src_port serialized as a JSON number' );
};

subtest 'a non-matching program is stored verbatim (no enriched key)' => sub {
	plan skip_all => 'Log::Munger / rule files unavailable' unless $have_munger;

	@last_row = ();
	my $ing = Allani::Ingest->new( 'dbh' => bless( {}, 'FakeDbh' ), 'munger' => $munger );
	# gated on PROGRAM=sshd*, so 'cron' can never match an sshd rule
	$ing->ingest_json_syslog( encode_json( base_record( 'PROGRAM' => 'cron', 'MESSAGE' => $SSH_FAIL ) ) );

	my $raw = decode_json( row_as_hash()->{'raw'} );
	ok( !exists( $raw->{'enriched'} ), 'no enriched key on a non-match' );
};

subtest 'no munger => rows stored verbatim' => sub {
	@last_row = ();
	my $ing = Allani::Ingest->new( 'dbh' => bless( {}, 'FakeDbh' ) );
	my $raw_json = encode_json( base_record( 'MESSAGE' => $SSH_FAIL ) );
	$ing->ingest_json_syslog($raw_json);

	my $row = row_as_hash();
	is( $row->{'raw'}, $raw_json, 'raw is the original bytes when enrichment is off' );
	my $raw = decode_json( $row->{'raw'} );
	ok( !exists( $raw->{'enriched'} ), 'no enriched key when there is no munger' );
};

subtest 'PID stays optional under enrichment' => sub {
	plan skip_all => 'Log::Munger / rule files unavailable' unless $have_munger;

	@last_row = ();
	my $ing = Allani::Ingest->new( 'dbh' => bless( {}, 'FakeDbh' ), 'munger' => $munger );
	# base_record has no PID
	my $rc = $ing->ingest_json_syslog( encode_json( base_record( 'MESSAGE' => $SSH_FAIL ) ) );
	is( $rc,                     1,     'ingest with no PID returned 1' );
	is( row_as_hash()->{'PID'}, undef, 'PID bound as undef' );
};

subtest 'a non-integer PID is coerced to NULL' => sub {
	# FreeBSD kernel lines carry a boot timestamp in the bracket syslog-ng parses
	# as PID, e.g. "kernel[6558585.501484]: ...", so PID arrives as a
	# seconds.microseconds string that a bigint column will reject. It must land
	# as undef/NULL rather than fail the insert; the original still lives in raw.
	my $ing = Allani::Ingest->new( 'dbh' => bless( {}, 'FakeDbh' ) );

	@last_row = ();
	$ing->ingest_json_syslog( encode_json( base_record( 'PROGRAM' => 'kernel', 'PID' => '6558585.501484' ) ) );
	is( row_as_hash()->{'PID'}, undef, 'a seconds.microseconds PID binds as undef' );
	is( decode_json( row_as_hash()->{'raw'} )->{'PID'}, '6558585.501484', 'original PID still preserved in raw' );

	@last_row = ();
	$ing->ingest_json_syslog( encode_json( base_record( 'PID' => '25446' ) ) );
	is( row_as_hash()->{'PID'}, '25446', 'a normal integer PID is bound unchanged' );

	@last_row = ();
	$ing->ingest_json_syslog( encode_json( base_record( 'PID' => 'notanumber' ) ) );
	is( row_as_hash()->{'PID'}, undef, 'a non-numeric PID binds as undef' );
};

subtest 'a missing required field still dies, munger or not' => sub {
	plan skip_all => 'Log::Munger / rule files unavailable' unless $have_munger;

	my $ing = Allani::Ingest->new( 'dbh' => bless( {}, 'FakeDbh' ), 'munger' => $munger );
	my $rec = base_record( 'MESSAGE' => $SSH_FAIL );
	delete $rec->{'PROGRAM'};
	eval { $ing->ingest_json_syslog( encode_json($rec) ); };
	like( $@, qr/PROGRAM/, 'missing PROGRAM dies with a useful message' );
};

done_testing();
