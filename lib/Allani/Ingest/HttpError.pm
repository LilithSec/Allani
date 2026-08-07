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

# Makes a parsed value safe to bind to an integer column -- here the pid an
# error line reports. A truncated or unusual line can leave the munger with
# something that is not a number, which the integer bind would reject, taking
# the whole INSERT down; such a value becomes NULL instead.
#
#   - $value :: The field as the munger extracted it, so a string of digits,
#       '-', '', or undef when the pattern did not capture it. Not a method
#       argument -- this is a plain function.
#
# Returns the value as a number when it is a string of digits, and undef
# otherwise, which DBI binds as SQL NULL.
#
#     _num('62131');   # 62131
#     _num(undef);     # undef
sub _num {
	my ($value) = @_;
	return undef if ( !defined($value) || $value eq '' || $value eq '-' );
	return undef if ( $value !~ /\A\d+\z/ );
	return $value + 0;
}

# Turns an error log timestamp into an ISO 8601 string PostgreSQL parses as a
# timestamp. Unlike the access log, the two servers disagree on the format, so
# both are handled: nginx writes YYYY/MM/DD HH:MM:SS, and Apache 2.2/2.4 write a
# ctime-ish string with the year at the end and, on 2.4, microseconds.
#
# Neither carries a timezone, so the stored value is interpreted in the
# database server's timezone. That makes err_isodate approximate whenever the
# web server and the database disagree about local time; r_isodate is the
# reliable receipt time.
#
#   - $str :: An error log timestamp as the munger captured it, in either
#       '2000/10/11 14:32:52' (nginx) or 'Wed Oct 11 14:32:52 2000' /
#       'Wed Oct 11 14:32:52.123456 2000' (Apache) form. Undef when the line did
#       not parse. Not a method argument -- this is a plain function.
#
# Returns the same moment as an ISO 8601 string, YYYY-MM-DDTHH:MM:SS, with
# fractional seconds kept when Apache logged them and no timezone suffix. Returns
# undef for undef input, an unrecognised layout, or an unknown month
# abbreviation; undef binds as SQL NULL, leaving err_isodate empty for that row.
#
#     _err_time('2000/10/11 14:32:52');              # '2000-10-11T14:32:52'
#     _err_time('Wed Oct 11 14:32:52 2000');         # '2000-10-11T14:32:52'
#     _err_time('Wed Oct 11 14:32:52.123456 2000');  # '2000-10-11T14:32:52.123456'
#     _err_time('nonsense');                         # undef
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

1;
