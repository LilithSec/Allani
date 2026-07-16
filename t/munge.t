#!perl
use 5.006;
use strict;
use warnings;
use Test::More;
use JSON::XS;

BEGIN { use_ok('Allani::Command::munge'); }

my $have_munger = eval {
	require Log::Munger;
	Log::Munger->new( 'rules' => [ 'base', 'sshd' ] );
	1;
};
plan skip_all => 'Log::Munger / sshd rules unavailable' unless $have_munger;

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

	package FakeApp;
	sub new            { return bless {}, $_[0]; }
	sub read_in_config { return 1; }
	sub build_munger   { return Log::Munger->new( 'rules' => [ 'base', 'sshd' ] ); }
}

sub run_munge {
	my ( $opt, @args ) = @_;
	my $cmd = bless { 'app' => FakeApp->new }, 'Allani::Command::munge';
	my $out = '';
	open( my $fh, '>', \$out ) or die $!;
	my $old = select($fh);
	$cmd->execute( $opt, [@args] );
	select($old);
	close($fh);
	return decode_json($out);
}

my $LINE = '{"PROGRAM":"sshd-session","MESSAGE":"Failed password for invalid user admin from 203.0.113.7 port 44444 ssh2"}';

subtest 'default: just the extracted fields' => sub {
	my $d = run_munge( FakeOpt->new, $LINE );
	is( $d->{'ssh_user'}, 'admin', 'extracted field present' );
	ok( !exists( $d->{'MESSAGE'} ),  'the record itself is not included' );
	ok( !exists( $d->{'enriched'} ), 'not wrapped under enriched' );
};

subtest '--full: the whole record with enrichment merged in' => sub {
	my $d = run_munge( FakeOpt->new( 'full' => 1 ), $LINE );
	is( $d->{'PROGRAM'}, 'sshd-session', 'record PROGRAM kept' );
	like( $d->{'MESSAGE'}, qr/Failed password/, 'record MESSAGE kept' );
	is( $d->{'enriched'}{'ssh_user'},   'admin',       'extracted fields under enriched' );
	is( $d->{'enriched'}{'ssh_src_ip'}, '203.0.113.7', 'and the client ip' );
};

subtest '--full with no match: record kept, no enriched key' => sub {
	my $d = run_munge( FakeOpt->new( 'full' => 1, 'program' => 'sshd-session' ), 'this does not match any rule' );
	is( $d->{'MESSAGE'}, 'this does not match any rule', 'bare line kept as MESSAGE' );
	is( $d->{'PROGRAM'}, 'sshd-session', 'program tag kept' );
	ok( !exists( $d->{'enriched'} ), 'no enriched key when nothing matched' );
};

subtest '--explain: which rule fired' => sub {
	my $d = run_munge( FakeOpt->new( 'explain' => 1 ), $LINE );
	is( $d->{'matched'}, 1,      'matched' );
	is( $d->{'rule'},    'sshd', 'the sshd rule' );
	is( $d->{'fields'}{'ssh_user'}, 'admin', 'fields under .fields' );
};

done_testing();
