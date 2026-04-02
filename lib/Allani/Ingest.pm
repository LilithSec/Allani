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



    my $ingester = Allani::Ingest->new('dbh' => $dbh);

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

sub ingest_json_syslog {
	my ( $self, $raw_json ) = @_;

	if ( !defined($raw_json) ) {
		return 0;
	}

	eval {
		my $json = JSON::XS->new->utf8->decode($raw_json);

		if (   ( !defined( $json->{'c_isodate'} ) )
			|| ( !defined( $json->{'r_isodate'} ) )
			|| ( !defined( $json->{'s_isodate'} ) )
			|| ( !defined( $json->{'facility'} ) )
			|| ( !defined( $json->{'host'} ) )
			|| ( !defined( $json->{'host_from'} ) )
			|| ( !defined( $json->{'pid'} ) )
			|| ( !defined( $json->{'priority'} ) )
			|| ( !defined( $json->{'program'} ) )
			|| ( !defined( $json->{'sourceip'} ) )
			|| ( !defined( $json->{'raw'} ) ) )
		{
			return 0;
		} ## end if ( ( !defined( $json->{'c_isodate'} ) ) ...)

		$self->{'sth'}->execute(
			$json->{'c_isodate'}, $json->{'r_isodate'}, $json->{'s_isodate'}, $json->{'facility'},
			$json->{'host'},      $json->{'host_from'}, $json->{'pid'},       $json->{'priority'},
			$json->{'program'},   $json->{'sourceip'},  $json->{'raw'},
		);
	};
	if ($@) {
		return 0;
	}

	return 1;
} ## end sub ingest_json_syslog

1;    # End of Allani
