package Allani::Ingest;

use 5.006;
use strict;
use warnings;
use JSON::XS;

=head1 NAME

Allani::Ingest - Ingest data for Allani.

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 SYNOPSIS

    use Allani::Ingest;

    my $ingester = Allani::Ingest->new('dbh' => $dbh);
    $ingester->syslog_json_ingest($raw_json_from_syslog_ng);

=head1 METHODS

=head2 new

Creates a new object.

    my $ingester = Allani::Ingest->new('dbh' => $dbh);

    - dbh :: Database handle from DBI to use.
        default :: undef

=cut

sub new {
	my ( $blank, %opts ) = @_;

	if ( !defined( $opts{'dbh'} ) ) {
		die('dbh is undef');
	}

	my $self = { 'dbh' => $opts{'dbh'}, };
	bless $self;

	my $statement
		= 'INSERT INTO syslog '
		. '(c_isodate, r_isodate, s_isodate, facility, host, host_from, pid, priority, program, sourceip, raw) '
		. 'VALUES (?,?,?,?,?,?,?,?,?,?,?);';
	eval { $self->{'sth'} = $self->{'dbh'}->prepare($statement) || die( $self->{'dbh'}->errstr ); };
	if ($@) {
		die( 'Statement prepare failed for "' . $statement . '"... ' . $@ );
	}

	return $self;
} ## end sub new

=head2 ingest_json_syslog

Ingests a log line.

The following syslog-ng fields are required to be present.

    C_ISODATE
    R_ISODATE
    S_ISODATE
    FACILITY
    HOST
    HOST_FROM
    PID
    PRIORITY
    PROGRAM
    SOURCEIP

=cut

sub ingest_json_syslog {
	my ( $self, $raw_json ) = @_;

	if ( !defined($raw_json) ) {
		return 0;
	}

	eval {
		my $json = JSON::XS->new->utf8->decode($raw_json);

		if (   ( !defined($json) )
			|| ( ref($json) ne 'HASH' )
			|| ( !defined( $json->{'C_ISODATE'} ) )
			|| ( !defined( $json->{'R_ISODATE'} ) )
			|| ( !defined( $json->{'S_ISODATE'} ) )
			|| ( !defined( $json->{'FACILITY'} ) )
			|| ( !defined( $json->{'HOST'} ) )
			|| ( !defined( $json->{'HOST_FROM'} ) )
			|| ( !defined( $json->{'PID'} ) )
			|| ( !defined( $json->{'PRIORITY'} ) )
			|| ( !defined( $json->{'PROGRAM'} ) )
			|| ( !defined( $json->{'SOURCEIP'} ) ) )
		{
			die('missing a required field in the JSON, undef, or not a hash ref');
			return 0;
		} ## end if ( ( !defined($json) ) || ( ref($json) ne...))

		$self->{'sth'}->execute(
			$json->{'C_ISODATE'}, $json->{'R_ISODATE'}, $json->{'S_ISODATE'}, $json->{'FACILITY'},
			$json->{'HOST'},      $json->{'HOST_FROM'}, $json->{'PID'},       $json->{'PRIORITY'},
			$json->{'PROGRAM'},   $json->{'SOURCEIP'},  $raw_json,
		);
	};
	if ($@) {
		die($@);
	}

	return 1;
} ## end sub ingest_json_syslog

1;    # End of Allani
