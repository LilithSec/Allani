package Allani::Ingest::HttpError;

use 5.006;
use strict;
use warnings;
use JSON::XS ();

=head1 NAME

Allani::Ingest::HttpError - Ingest HTTP error log lines for Allani.

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 SYNOPSIS

    use Allani::Ingest::HttpError;

    my $ingester = Allani::Ingest::HttpError->new(
        'dbh'        => $dbh,
        'munger'     => $munger,
        'host'       => 'web01',
        'vhost'      => 'www.example.com',
        'vhost_port' => 443,
    );
    $ingester->ingest_line($error_log_line);

=head1 METHODS

=head2 new

    - dbh :: Database handle from DBI. Required.

    - munger :: A Log::Munger object (with the http_error_logs rules loaded)
        used to parse the line. Required in practice.

    - host / vhost / vhost_port :: Tags applied to every row, since an error
        line does not carry them (nginx does log its own C<server>, which is
        stored separately).

=cut

# month abbreviation -> two digit number (Apache error timestamps)
my %MON = (
	'Jan' => '01', 'Feb' => '02', 'Mar' => '03', 'Apr' => '04',
	'May' => '05', 'Jun' => '06', 'Jul' => '07', 'Aug' => '08',
	'Sep' => '09', 'Oct' => '10', 'Nov' => '11', 'Dec' => '12',
);

sub new {
	my ( $blank, %opts ) = @_;

	if ( !defined( $opts{'dbh'} ) ) {
		die('dbh is undef');
	}

	my $self = {
		'dbh'        => $opts{'dbh'},
		'munger'     => $opts{'munger'},
		'host'       => $opts{'host'},
		'vhost'      => $opts{'vhost'},
		'vhost_port' => $opts{'vhost_port'},
	};
	bless $self;

	# r_isodate defaults to now() in the schema, so it is not bound here
	my $statement
		= 'INSERT INTO http_error '
		. '(err_isodate, host, vhost, vhost_port, client_ip, loglevel, pid, code, server, request, message, raw) '
		. 'VALUES (?,?,?,?,?,?,?,?,?,?,?,?);';
	eval { $self->{'sth'} = $self->{'dbh'}->prepare($statement) || die( $self->{'dbh'}->errstr ); };
	if ($@) {
		die( 'Statement prepare failed for "' . $statement . '"... ' . $@ );
	}

	return $self;
} ## end sub new

=head2 ingest_line

Parses one error log line through the munger and inserts a row. The whole line
plus the extracted fields are stored in C<raw> as C<< { MESSAGE, enriched }
>>; the well known fields also become columns. A parse failure just yields a
row with null columns and no C<enriched> block, so a line is never lost.

Returns 1 on insert, 0 for an empty/blank line. Dies only on a database error.

=cut

sub ingest_line {
	my ( $self, $line ) = @_;

	if ( !defined($line) ) {
		return 0;
	}
	chomp($line);
	if ( $line =~ /\A\s*\z/ ) {
		return 0;
	}

	eval {
		my $fields = {};
		if ( defined( $self->{'munger'} ) ) {
			my $f = eval { $self->{'munger'}->process_item( 'item' => $line ); };
			if ( !$@ && defined($f) && ref($f) eq 'HASH' ) {
				$fields = $f;
			}
		}

		my $record = { 'MESSAGE' => $line };
		if ( keys( %{$fields} ) ) {
			$record->{'enriched'} = $fields;
		}
		my $raw = JSON::XS->new->utf8->canonical->encode($record);

		$self->{'sth'}->execute(
			_err_time( $fields->{'http_error_timestamp'} ),
			$self->{'host'}, $self->{'vhost'}, $self->{'vhost_port'},
			$fields->{'http_error_client_ip'},
			$fields->{'http_error_loglevel'},
			_num( $fields->{'http_error_pid'} ),
			$fields->{'http_error_code'},
			$fields->{'http_error_server'},
			$fields->{'http_error_request'},
			$fields->{'http_error_message'},
			$raw,
		);
	};
	if ($@) {
		die($@);
	}

	return 1;
} ## end sub ingest_line

# an integer value: undef/non-numeric becomes undef (NULL), else the number
sub _num {
	my ($value) = @_;
	return undef if ( !defined($value) || $value eq '' || $value eq '-' );
	return undef if ( $value !~ /\A\d+\z/ );
	return $value + 0;
}

# turn an error-log timestamp into an ISO 8601 string PostgreSQL parses as a
# timestamp. Handles nginx (2000/10/11 14:32:52) and Apache 2.2/2.4
# (Wed Oct 11 14:32:52[.ffffff] 2000). These carry no timezone, so the value is
# interpreted in the server's timezone; r_isodate is the reliable receipt time.
# Returns undef on anything unexpected.
sub _err_time {
	my ($str) = @_;

	return undef if ( !defined($str) );

	# nginx: YYYY/MM/DD HH:MM:SS
	if ( $str =~ m{\A(\d{4})/(\d{2})/(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\z} ) {
		return $1 . '-' . $2 . '-' . $3 . 'T' . $4 . ':' . $5 . ':' . $6;
	}

	# Apache: Ddd Mon D HH:MM:SS[.ffffff] YYYY
	if ( $str =~ m{\A[A-Za-z]{3}\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?\s+(\d{4})\z} ) {
		my $mon = $MON{ ucfirst( lc($1) ) };
		return undef if ( !defined($mon) );
		my $day  = sprintf( '%02d', $2 );
		my $frac = defined($6) ? '.' . $6 : '';
		return $7 . '-' . $mon . '-' . $day . 'T' . $3 . ':' . $4 . ':' . $5 . $frac;
	}

	return undef;
} ## end sub _err_time

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

1;
