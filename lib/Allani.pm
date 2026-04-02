package Allani;

use 5.006;
use strict;
use warnings;
use App::Cmd::Setup -app;
use YAML::XS qw( Load );
use File::Slurp qw( read_file );
use Hash::Merge;
use DBI;

=head1 NAME

Allani - The great new Allani!

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Allani;

    my $foo = Allani->new();
    ...

=head1 EXPORT

A list of functions that can be exported.  You can delete this section
if you don't export anything, such as for a purely object-oriented module.

=head1 METHODS

=head2 connect_dbi

Connects via the L<DBI> and returns a DBH.

Unless your a plan to use the defaults, read_in_config should
be called first.

    my $dbh=$allani->connect_dbi;


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

=head2 create_tables

Creates the required tables.

=cut

sub create_tables {
	my ( $self, %opts ) = @_;

	if ( !defined( $self->{'allani'} ) || !defined( $self->{'allani'}{'config'} ) ) {
		die('read_in_config has not been called or it failed.');
	}

	my $dbh = $self->connect_dbi;

	my $sth
		= $dbh->prepare( 'create table syslog ('
			. 'id bigserial NOT NULL, '
			. 'c_isodate TIMESTAMP WITH TIME ZONE, '
			. 'r_isodate  TIMESTAMP WITH TIME ZONE, '
			. 's_isodate  TIMESTAMP WITH TIME ZONE, '
			. 'facility varchar(255), '
			. 'host varchar(255), '
			. 'host_from varchar(255), '
			. 'pid bigint, '
			. 'priority varchar(64), '
			. 'program varchar(255), '
			. 'sourceip inet, '
			. 'raw jsonb, '
			. 'PRIMARY KEY(id) );' );
	$sth->execute();

} ## end sub create_tables

=head1 read_in_config

Reads in the specified config.

If none is specified, then the default, /usr/local/etc/allani.yaml, is
used. If that does not exist, the default settings are used.

    $allani->read_in_config;

=cut

sub read_in_config {
	my ( $self, %opts ) = @_;

	my $base_config = {
		'user' => 'allani',
		'pass' => undef,
		'dsn'  => 'dbi:Pg:dbname=allani',
	};

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


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991


=cut

1;    # End of Allani
