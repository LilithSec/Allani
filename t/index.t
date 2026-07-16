#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

BEGIN { use_ok('Allani::Command::index'); }

my $C = 'Allani::Command::index';

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
{

	package FakeDbh;
	sub new { my ( $c, %h ) = @_; return bless { 'row' => $h{'row'}, 'done' => [] }, $c; }
	sub selectrow_arrayref { return $_[0]->{'row'}; }              # canned SELECT result
	sub do { my ( $s, $sql ) = @_; push( @{ $s->{'done'} }, $sql ); return 1; }
}

sub captured {
	my ($code) = @_;
	my $out = '';
	open( my $fh, '>', \$out ) or die $!;
	my $old = select($fh);
	eval { $code->() };
	my $err = $@;
	select($old);
	close($fh);
	die $err if $err;
	return $out;
}

# ---- name / DDL --------------------------------------------------------------

is( $C->can('_index_name')->( 'syslog', 'dovecot_event', 0 ),
	'allani_ix_syslog_dovecot_event', 'btree index name' );
is( $C->can('_index_name')->( 'syslog', 'url', 1 ), 'allani_ix_syslog_url_trgm', 'trigram name gets _trgm' );

is( $C->can('_ddl')->( 'syslog', 'dovecot_event', 0, 'allani_ix_syslog_dovecot_event' ),
	"CREATE INDEX allani_ix_syslog_dovecot_event ON syslog ((raw->'enriched'->>'dovecot_event'))",
	'btree DDL' );
is( $C->can('_ddl')->( 'syslog', 'url', 1, 'allani_ix_syslog_url_trgm' ),
	"CREATE INDEX allani_ix_syslog_url_trgm ON syslog USING gin ((raw->'enriched'->>'url') gin_trgm_ops)",
	'trigram DDL' );

# ---- _plan (import from legacy config) + validation --------------------------

subtest '_plan' => sub {
	my @p = $C->can('_plan')->( { 'syslog' => [ 'dovecot_event', { 'field' => 'url', 'trigram' => 1 } ] } );
	is( scalar(@p),        2,                                'two planned' );
	is( $p[0]{'name'},     'allani_ix_syslog_dovecot_event', 'btree name' );
	is( $p[1]{'trigram'},  1,                                'second is trigram' );

	eval { $C->can('_plan')->( { 'bogus' => ['x'] } ) };
	like( $@, qr/table must be one of/, 'unknown table dies' );
	eval { $C->can('_plan')->( { 'syslog' => ["evil'); DROP TABLE syslog; --"] } ) };
	like( $@, qr/field must be word characters/, 'injection attempt dies' );
};

# ---- drop guards (the protection) --------------------------------------------

subtest 'drop refuses schema-required / non-allani indexes' => sub {
	my $dbh = FakeDbh->new;    # selectrow returns undef; should never be reached
	eval { $C->can('_drop')->( undef, $dbh, FakeOpt->new( 'name' => 'syslog_raw_gin' ), [] ) };
	like( $@, qr/schema-required indexes are protected/, 'a non-allani_ix_ name is refused' );
	is( scalar( @{ $dbh->{'done'} } ), 0, 'nothing was executed' );

	eval { $C->can('_drop')->( undef, $dbh, FakeOpt->new( 'name' => 'syslog_pkey' ), [] ) };
	like( $@, qr/protected/, 'a primary key name is refused' );
};

subtest 'drop refuses an allani name not tracked in managed_indexes' => sub {
	my $dbh = FakeDbh->new( 'row' => undef );    # not present in managed_indexes
	eval { $C->can('_drop')->( undef, $dbh, FakeOpt->new( 'name' => 'allani_ix_syslog_ghost' ), [] ) };
	like( $@, qr/not tracked in managed_indexes/, 'untracked allani index is refused' );
	is( scalar( @{ $dbh->{'done'} } ), 0, 'nothing was executed' );
};

subtest 'drop a tracked index' => sub {
	# dry-run: tracked, but nothing executed
	my $dbh = FakeDbh->new( 'row' => [1] );
	my $out = captured(
		sub { $C->can('_drop')->( undef, $dbh, FakeOpt->new( 'dry_run' => 1 ), [ 'syslog', 'dovecot_event' ] ) } );
	like( $out, qr/would drop index allani_ix_syslog_dovecot_event/, 'dry-run reports the drop' );
	is( scalar( @{ $dbh->{'done'} } ), 0, 'dry-run executes nothing' );

	# real: DROP INDEX then DELETE the row
	my $dbh2 = FakeDbh->new( 'row' => [1] );
	$out = captured(
		sub { $C->can('_drop')->( undef, $dbh2, FakeOpt->new, [ 'syslog', 'dovecot_event' ] ) } );
	like( $out, qr/dropped: allani_ix_syslog_dovecot_event/, 'reports dropped' );
	like( $dbh2->{'done'}[0], qr/^DROP INDEX .*allani_ix_syslog_dovecot_event/, 'ran DROP INDEX' );
	like( $dbh2->{'done'}[1], qr/^DELETE FROM managed_indexes/,                 'deleted the tracking row' );
};

done_testing();
