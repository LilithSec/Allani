#!perl
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);

BEGIN { use_ok('Allani'); }

# ---- duration_to_interval ----------------------------------------------------

is( Allani::duration_to_interval('90'),  '90 days',    'bare integer => days' );
is( Allani::duration_to_interval('24h'), '24 hours',   'h => hours' );
is( Allani::duration_to_interval('30m'), '30 minutes', 'm => minutes' );
is( Allani::duration_to_interval('60s'), '60 seconds', 's => seconds' );
is( Allani::duration_to_interval('2w'),  '2 weeks',    'w => weeks' );
eval { Allani::duration_to_interval('9x') };
like( $@, qr/not a valid duration/, 'garbage duration dies' );
eval { Allani::duration_to_interval(undef) };
like( $@, qr/undef/, 'undef duration dies' );

# ---- config merge does not splice a leading undef into munger_rules ----------
# (regression: seeding munger_rules => undef in the defaults made Hash::Merge
#  produce [undef, 'base', ...], which build_munger read as "disabled")

sub config_from {
	my ($yaml) = @_;
	my ( $fh, $path ) = tempfile( 'allani-XXXXXX', SUFFIX => '.yaml', TMPDIR => 1, UNLINK => 1 );
	print {$fh} $yaml;
	close($fh);
	my $app = bless {}, 'Allani';
	$app->read_in_config( 'config' => $path );
	return $app;
}

my $app = config_from("munger_rules:\n  - base\n  - sshd\n");
is_deeply(
	$app->config->{'munger_rules'},
	[ 'base', 'sshd' ],
	'munger_rules merges cleanly with no leading undef'
);
ok( defined( $app->config->{'munger_rules'}[0] ), 'first rule is defined, not undef' );

my $bare = config_from("dsn: dbi:Pg:dbname=allani\n");
ok( !defined( $bare->config->{'munger_rules'} ), 'munger_rules absent when not configured' );
is( $bare->build_munger, undef, 'build_munger returns undef when disabled' );

# with rules configured, build_munger yields a Log::Munger (skip if unavailable)
SKIP: {
	my $ok = eval { require Log::Munger; 1; };
	skip( 'Log::Munger / rule files unavailable', 1 ) unless $ok;
	my $munger = eval { $app->build_munger };
	isa_ok( $munger, 'Log::Munger', 'build_munger with rules' );
}

# ---- installed_schema_version: missing table => undef, not a die -------------

{

	package DeadSth;
	sub execute { die "relation does not exist\n"; }
}
{

	package DeadDbh;
	sub prepare { return bless {}, 'DeadSth'; }
}

my $app2 = bless {}, 'Allani';
my $v = $app2->installed_schema_version( bless( {}, 'DeadDbh' ) );
is( $v, undef, 'installed_schema_version returns undef when the version table is absent' );

done_testing();
