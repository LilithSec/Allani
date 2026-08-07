package Allani;

use 5.006;
use strict;
use warnings;
use App::Cmd::Setup -app;
use YAML::XS qw( Load );
use File::Slurp qw( read_file );
use Hash::Merge;
use DBI;
use Log::Munger ();

=head1 NAME

Allani - A syslog store; syslog-ng JSON laid to rest in PostgreSQL.

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 SYNOPSIS

Allani is an L<App::Cmd> application. C<src_bin/allani> is little more than
this:

    use Allani;
    Allani->run;

The class is also usable directly, which is what the commands and the
L<Allani::Ishara> workers do:

    my $allani = Allani->new;
    $allani->read_in_config( 'config' => '/usr/local/etc/allani.yaml' );

    my $dbh    = $allani->connect_dbi;
    my $munger = $allani->build_munger;

=head1 DESCRIPTION

Allani holds the pieces every command and worker needs: the config, the
database handle, and the L<Log::Munger> enricher built from that config. Each
subcommand lives in its own module under L<Allani::Command>, and the ingest
paths live in L<Allani::Ingest> and its subclasses.

=head1 METHODS

=head2 connect_dbi

Connects via L<DBI> and returns a database handle, using the C<dsn>, C<user>,
and C<pass> from the loaded config. The handle comes from
C<connect_cached>, so repeated calls in one process share a connection.

Takes no arguments. Dies when the config has not been loaded yet or when the
connection fails; the password is never included in the error, only whether
one was set.

Unless you plan to use the defaults, read_in_config should be called first.

    my $dbh = $allani->connect_dbi;


=cut

sub connect_dbi {
	my ( $self, %opts ) = @_;

	if ( !defined( $self->{'allani'} ) || !defined( $self->{'allani'}{'config'} ) ) {
		die('read_in_config has not been called or it failed.');
	}

	my $dbh;
	eval {
		$dbh = DBI->connect_cached(
			$self->{'allani'}{'config'}{'dsn'},
			$self->{'allani'}{'config'}{'user'},
			$self->{'allani'}{'config'}{'pass'}
		) or die;
	};
	if ($@) {
		my $pw = 'undef';
		if ( defined( $self->{'allani'}{'config'}{'pass'} ) ) {
			$pw = 'not_shown';
		}
		die(      'Failed to connect... dsn="'
				. $self->{'allani'}{'config'}{'dsn'}
				. '" user="'
				. $self->{'allani'}{'config'}{'user'}
				. '" pass='
				. $pw . ' ... '
				. $@ );
	} ## end if ($@)

	return $dbh;
} ## end sub connect_dbi

=head2 build_munger

Builds the L<Log::Munger> enricher from the loaded config and returns it, or
returns undef when enrichment is disabled.

read_in_config must have been called first.

Enrichment is controlled by two config keys:

    - munger_rules :: An array of Log::Munger rule file names to load (e.g.
        [ 'base', 'postfix' ]). Undef or an empty list disables enrichment
        and this returns undef.

    - munger_geoip :: Optional path to a MaxMind .mmdb database. When set,
        rules that flag captured fields for geoip lookup have those looked
        up. Requires IP::Geolocation::MMDB.

An optional C<geoip> argument overrides the config's C<munger_geoip> for this
build (pass C<< geoip => undef >> to force geoip off) -- used by the web-log
follower, which resolves geoip per web_logs set.

    my $munger = $allani->build_munger;
    my $munger = $allani->build_munger( 'geoip' => $set_geoip );

=cut

sub build_munger {
	my ( $self, %opts ) = @_;

	if ( !defined( $self->{'allani'} ) || !defined( $self->{'allani'}{'config'} ) ) {
		die('read_in_config has not been called or it failed.');
	}

	my $config = $self->{'allani'}{'config'};
	my $rules  = $config->{'munger_rules'};

	# no rule files => enrichment disabled
	if ( !defined($rules) ) {
		return undef;
	}
	if ( ref($rules) ne 'ARRAY' ) {
		die('munger_rules is set but is not an array');
	}
	if ( !defined( $rules->[0] ) ) {
		return undef;
	}

	# an explicit geoip argument (even undef) overrides the config default
	my $geoip = exists( $opts{'geoip'} ) ? $opts{'geoip'} : $config->{'munger_geoip'};

	my %args = ( 'rules' => $rules );
	if ( defined($geoip) ) {
		$args{'geoip'} = $geoip;
	}

	my $munger;
	eval { $munger = Log::Munger->new(%args); };
	if ($@) {
		die( 'Failed to build the Log::Munger enricher... ' . $@ );
	}

	return $munger;
} ## end sub build_munger

=head2 config

Returns the loaded config hash ref. read_in_config must have been called first.

    my $dsn = $allani->config->{'dsn'};

=cut

sub config {
	my ($self) = @_;

	if ( !defined( $self->{'allani'} ) || !defined( $self->{'allani'}{'config'} ) ) {
		die('read_in_config has not been called or it failed.');
	}

	return $self->{'allani'}{'config'};
} ## end sub config

=head2 installed_schema_version

Returns the highest schema version recorded in the
C<dbix_class_deploymenthandler_versions> table, or undef when the table does
not exist (the schema has not been deployed).

    my $v = $allani->installed_schema_version($dbh);

=cut

sub installed_schema_version {
	my ( $self, $dbh ) = @_;

	if ( !defined($dbh) ) {
		die('dbh is undef');
	}

	my $version;
	eval {
		my $sth = $dbh->prepare('SELECT version FROM dbix_class_deploymenthandler_versions');
		$sth->execute;
		while ( my $row = $sth->fetchrow_arrayref ) {
			my $v = $row->[0];
			next if ( !defined($v) || $v !~ /\A\d+\z/ );
			$version = $v if ( !defined($version) || $v > $version );
		}
	};
	# the table not existing is not an error here -- it just means "not deployed"

	return $version;
} ## end sub installed_schema_version

=head2 duration_to_interval

Turns a short duration string into a PostgreSQL interval literal. Accepts a
bare integer (days) or an integer with a C<s>/C<m>/C<h>/C<d>/C<w> suffix
(seconds/minutes/hours/days/weeks). Dies on anything else. Not a method.

    my $interval = Allani::duration_to_interval('90d');    # "90 days"

=cut

sub duration_to_interval {
	my ($str) = @_;

	if ( !defined($str) ) {
		die('duration is undef');
	}
	if ( $str =~ /\A(\d+)\z/ ) {
		return "$1 days";
	}
	if ( $str =~ /\A(\d+)\s*([smhdw])\z/i ) {
		my %unit = (
			's' => 'seconds',
			'm' => 'minutes',
			'h' => 'hours',
			'd' => 'days',
			'w' => 'weeks',
		);
		return $1 . ' ' . $unit{ lc($2) };
	}

	die( '"' . $str . '" is not a valid duration (e.g. 90d, 24h, 30m, 60s, 2w, or a plain number of days)' );
} ## end sub duration_to_interval

=head2 read_in_config

Reads the config file, merges it over the built-in defaults, and stores the
result for L</config> and the rest of the class to use. Returns 1.

    - config :: Path to the YAML config to read.
        default :: /usr/local/etc/allani.yaml

A missing config file is only an error when it is not the default one -- the
defaults alone (database C<allani>, user C<allani>, local socket) are a
usable configuration.

    $allani->read_in_config;
    $allani->read_in_config( 'config' => '/usr/local/etc/allani.yaml' );

=cut

sub read_in_config {
	my ( $self, %opts ) = @_;

	if ( !defined( $opts{'config'} ) ) {
		$opts{'config'} = '/usr/local/etc/allani.yaml';
	}

	my $base_config = {
		'user' => 'allani',
		'pass' => undef,
		'dsn'  => 'dbi:Pg:dbname=allani',
	};

	# munger_rules / munger_geoip are intentionally left out of the defaults:
	# seeding munger_rules => undef makes Hash::Merge splice a leading undef into
	# a config-supplied list. Absent => undef => enrichment off (see build_munger).

	if (   ( !defined( $self->{'allani'} ) )
		|| ( ref( $self->{'allani'} ) ne 'HASH' ) )
	{
		$self->{'allani'} = {};
	}

	if (
		   ( !-f $opts{'config'} )
		&& ( $opts{'config'} eq '/usr/local/etc/allani.yaml' )

		)
	{
		$self->{'allani'}{'config'} = $base_config;
		return 1;
	} elsif ( !-f $opts{'config'} ) {
		die( 'Config file, "' . $opts{'config'} . '", does not exist' );
	}

	my $raw_config;
	eval { $raw_config = read_file( $opts{'config'} ); };
	if ($@) {
		die( 'Failed to read in "' . $opts{'config'} . '"... ' . $@ );
	}

	my $config;
	eval {
		$config = Load($raw_config);
	};
	if ($@) {
		die( 'Failed to parse "' . $opts{'config'} . '"... ' . $@ );
	}

	my $merger     = Hash::Merge->new('RIGHT_PRECEDENT');
	my $new_config = $merger->merge( $base_config, $config );

	$self->{'allani'}{'config'} = $new_config;
	return 1;
} ## end sub read_in_config

# The App::Cmd hook naming the options accepted before the subcommand name,
# i.e. the ones that apply to every command rather than to one of them. App::Cmd
# calls it while preparing a command and files the parsed values under
# $app->{'global_options'}, which is where each command's execute reads --config
# from.
#
# Takes no arguments beyond the invocant App::Cmd passes.
#
# Returns a list of Getopt::Long::Descriptive option specs -- one array ref per
# option, holding the spec string, the help text, and optionally a hash ref of
# attributes. The options are:
#
#   - help|h :: Print the usage screen.
#
#   - version|v :: Print the version.
#
#   - config=s :: Path to the config file, defaulting to
#       /usr/local/etc/allani.yaml. The default is applied here rather than in
#       read_in_config so --help shows it.
#
# Not called directly; App::Cmd invokes it. The values it produces are read like
# this, as every command's execute does:
#
#     $self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );
sub global_opt_spec {
	return (
		[ 'help|h'    => "This usage screen." ],
		[ 'version|v' => "This usage screen." ],
		[
			'config=s',
			'Config file to use. Default: "/usr/local/etc/allani.yaml"',
			{ 'default' => '/usr/local/etc/allani.yaml' }
		],
	);
} ## end sub global_opt_spec

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-allani at rt.cpan.org>, or through
the web interface at L<https://rt.cpan.org/NoAuth/ReportBug.html?Queue=Allani>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Allani


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=Allani>

=item * CPAN Ratings

L<https://cpanratings.perl.org/d/Allani>

=item * Search CPAN

L<https://metacpan.org/release/Allani>

=back

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991


=cut

1;    # End of Allani
