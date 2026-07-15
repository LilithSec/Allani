package Allani::Ingest::HttpAccess;

use 5.006;
use strict;
use warnings;
use JSON::XS ();

=head1 NAME

Allani::Ingest::HttpAccess - Ingest HTTP access log lines for Allani.

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 SYNOPSIS

    use Allani::Ingest::HttpAccess;

    my $ingester = Allani::Ingest::HttpAccess->new(
        'dbh'        => $dbh,
        'munger'     => $munger,
        'host'       => 'web01',
        'vhost'      => 'www.example.com',
        'vhost_port' => 443,
    );
    $ingester->ingest_line($access_log_line);

=head1 METHODS

=head2 new

    - dbh :: Database handle from DBI. Required.

    - munger :: A Log::Munger object (with the http_access_logs rules loaded)
        used to parse the line into fields. Required in practice -- without it
        every parsed column is null.

    - host / vhost / vhost_port :: Tags applied to every row, since a bare
        access log line carries none of them.

=cut

# Apache month abbreviations -> two digit number
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
		= 'INSERT INTO http_access '
		. '(req_isodate, host, vhost, vhost_port, client_ip, ident, auth, method, request, http_version, status, bytes, referrer, user_agent, raw) '
		. 'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);';
	eval { $self->{'sth'} = $self->{'dbh'}->prepare($statement) || die( $self->{'dbh'}->errstr ); };
	if ($@) {
		die( 'Statement prepare failed for "' . $statement . '"... ' . $@ );
	}

	return $self;
} ## end sub new

=head2 ingest_line

Parses one access log line through the munger and inserts a row. The whole
line plus the extracted fields are stored in C<raw> as C<< { MESSAGE,
enriched } >>; the well known fields are also copied into their own columns.
Enrichment can never cost a line: a parse failure just yields a row with null
columns and no C<enriched> block.

Returns 1 on insert, 0 for an empty/blank line. Dies only on a database error,
so the caller can warn and carry on.

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
			# process_item never dies, but guard anyway
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

		# a malformed request line lands in http_rawrequest instead
		my $request = defined( $fields->{'http_request'} ) ? $fields->{'http_request'} : $fields->{'http_rawrequest'};

		$self->{'sth'}->execute(
			_apache_time( $fields->{'http_timestamp'} ),
			$self->{'host'}, $self->{'vhost'}, $self->{'vhost_port'},
			$fields->{'http_clientip'},
			$fields->{'http_ident'},   $fields->{'http_auth'},
			$fields->{'http_verb'},    $request, $fields->{'http_httpversion'},
			_num( $fields->{'http_response'} ), _num( $fields->{'http_bytes'} ),
			$fields->{'http_referrer'}, $fields->{'http_agent'},
			$raw,
		);
	};
	if ($@) {
		die($@);
	}

	return 1;
} ## end sub ingest_line

# a status/bytes value: '-' or non-numeric becomes undef (NULL), else the number
sub _num {
	my ($value) = @_;
	return undef if ( !defined($value) || $value eq '' || $value eq '-' );
	return undef if ( $value !~ /\A\d+\z/ );
	return $value + 0;
}

# turn an Apache timestamp (10/Oct/2000:13:55:36 -0700) into an ISO 8601 string
# PostgreSQL parses natively as timestamptz. Returns undef on anything unexpected.
sub _apache_time {
	my ($str) = @_;

	return undef if ( !defined($str) );
	if ( $str =~ m{\A(\d{2})/([A-Za-z]{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2})\s*([+-]\d{2})(\d{2})\z} ) {
		my $mon = $MON{ ucfirst( lc($2) ) };
		return undef if ( !defined($mon) );
		return $3 . '-' . $mon . '-' . $1 . 'T' . $4 . ':' . $5 . ':' . $6 . $7 . ':' . $8;
	}

	return undef;
} ## end sub _apache_time

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

1;
