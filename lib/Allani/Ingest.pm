package Allani::Ingest;

use 5.006;
use strict;
use warnings;
use JSON::XS ();

=head1 NAME

Allani::Ingest - Ingest data for Allani.

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

# the syslog columns, in bind order, and one value tuple for a row
my $COLUMNS = '(c_isodate, r_isodate, s_isodate, facility, host, host_from, pid, priority, program, sourceip, raw)';
my $TUPLE   = '(?,?,?,?,?,?,?,?,?,?,?)';

# rows per multi-row INSERT: 11 binds/row keeps this well under PostgreSQL's
# 65535 bound-parameter limit, so a large batch is chunked
my $MAX_ROWS_PER_INSERT = 5000;

=head1 SYNOPSIS

    use Allani::Ingest;

    my $ingester = Allani::Ingest->new('dbh' => $dbh);
    $ingester->syslog_json_ingest($raw_json_from_syslog_ng);

=head1 METHODS

=head2 new

Creates a new object.

    my $ingester = Allani::Ingest->new('dbh' => $dbh);
    my $ingester = Allani::Ingest->new('dbh' => $dbh, 'munger' => $munger);

    - dbh :: Database handle from DBI to use.
        default :: undef

    - munger :: An optional L<Log::Munger> object used to enrich each log
        record before it is stored. When set, the extracted fields are
        merged into the stored JSON under the C<enriched> key (see
        L</ingest_json_syslog>). When undef, enrichment is disabled and rows
        are stored verbatim.
        default :: undef

=cut

sub new {
	my ( $blank, %opts ) = @_;

	if ( !defined( $opts{'dbh'} ) ) {
		die('dbh is undef');
	}

	my $self = {
		'dbh'    => $opts{'dbh'},
		'munger' => $opts{'munger'},
		'batch'  => [],            # queued rows awaiting a flush (see queue/flush)
	};
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
    PRIORITY
    PROGRAM
    SOURCEIP

The following are optional.

    PID

The stored C<raw> column is the primary datum; the other columns are
denormalized copies kept only for search convenience. When the object was
built with a C<munger>, the decoded record is run through it and, on a
match, the extracted fields are merged into the record under the C<enriched>
key before it is re-encoded and stored as C<raw>. C<MESSAGE> should be
present for enrichment to have anything to work with, since the shipped rule
sets gate on C<PROGRAM> and match against C<MESSAGE>.

Enrichment can never cost a log line: any failure (or no match) simply
stores the record without an C<enriched> key.

=cut

sub ingest_json_syslog {
	my ( $self, $raw_json ) = @_;

	if ( !defined($raw_json) ) {
		return 0;
	}

	my $row = $self->_build_row($raw_json);    # dies on a bad line; caller catches
	$self->{'sth'}->execute( @{$row} );

	return 1;
} ## end sub ingest_json_syslog

# Decode + validate + enrich one raw JSON line into the ordered bind values for
# a syslog row. Dies on a malformed line or missing required field. Shared by
# the immediate insert (ingest_json_syslog) and the batched path (queue).
sub _build_row {
	my ( $self, $raw_json ) = @_;

	my $json = JSON::XS->new->utf8->decode($raw_json);

	if ( !defined($json) ) {
		die('JSON parsing returned undef');
	}
	if ( ref($json) ne 'HASH' ) {
		die( '$json hash ref is "' . ref($json) . '" and not "HASH"' );
	}
	foreach my $field (qw(C_ISODATE R_ISODATE S_ISODATE FACILITY HOST HOST_FROM PRIORITY PROGRAM SOURCEIP)) {
		if ( !defined( $json->{$field} ) ) {
			die( '$json->{' . $field . '} is undef' );
		}
	}

	# raw is the primary column and is what gets enriched. Default to the
	# verbatim line so a disabled munger, a non-match, or an enrichment failure
	# all fall through to storing the record unchanged.
	my $raw_to_store = $raw_json;
	if ( defined( $self->{'munger'} ) ) {
		my $fields;
		# process_item is documented never to die, but guard anyway so a
		# pathological rule can never cost this log line
		eval { $fields = $self->{'munger'}->process_item( 'item' => $json ); };
		if ( !$@ && defined($fields) && ref($fields) eq 'HASH' && keys( %{$fields} ) ) {
			$json->{'enriched'} = $fields;
			my $encoded;
			eval { $encoded = JSON::XS->new->utf8->canonical->encode($json); };
			if ( !$@ && defined($encoded) ) {
				$raw_to_store = $encoded;
			}
		}
	} ## end if ( defined( $self->{'munger'} ) )

	return [
		$json->{'C_ISODATE'}, $json->{'R_ISODATE'}, $json->{'S_ISODATE'},  $json->{'FACILITY'},
		$json->{'HOST'},      $json->{'HOST_FROM'}, _clean_pid( $json->{'PID'} ), $json->{'PRIORITY'},
		$json->{'PROGRAM'},   $json->{'SOURCEIP'},  $raw_to_store,
	];
} ## end sub _build_row

# The pid column is a bigint, but the bracketed value syslog-ng parses as PID is
# not always a process id. FreeBSD kernel lines look like
# "kernel[6558585.501484]: ..." where the brackets hold the boot timestamp
# (seconds.microseconds), so PID arrives as "6558585.501484" and the bigint
# bind is rejected, taking the whole INSERT (or, in batch mode, the whole chunk)
# down with it. Coerce anything that is not a plain non-negative integer within
# bigint range to undef/NULL; the untouched original still lives in the raw JSON.
sub _clean_pid {
	my ($pid) = @_;

	return undef if ( !defined($pid) );
	return undef if ( $pid !~ /\A[0-9]+\z/ );
	return undef if ( $pid > 9223372036854775807 );

	return $pid;
} ## end sub _clean_pid

=head2 queue

Decodes/validates/enriches a raw JSON line and appends its row to the batch
buffer instead of inserting it immediately. Call L</flush> (on a size threshold
and/or a max-wait timer) to write the buffer. Dies on a malformed line, like
L</ingest_json_syslog>, before anything is buffered.

    $ingester->queue($raw_json);
    $ingester->flush if ( $ingester->pending >= 1000 );

=cut

sub queue {
	my ( $self, $raw_json ) = @_;

	if ( !defined($raw_json) ) {
		return 0;
	}

	push( @{ $self->{'batch'} }, $self->_build_row($raw_json) );

	return 1;
} ## end sub queue

=head2 pending

Returns the number of rows currently buffered by L</queue>.

=cut

sub pending { return scalar( @{ $_[0]->{'batch'} } ); }

=head2 flush

Writes every buffered row in one (or, for a very large buffer, a few)
multi-row INSERT and empties the buffer. Returns the number of rows written.
A chunk whose insert fails is logged (via warn) and dropped so the buffer
always drains -- a bad batch never wedges the stream. Safe to call with an
empty buffer.

=cut

sub flush {
	my ($self) = @_;

	my $batch = $self->{'batch'};
	return 0 if ( !@{$batch} );

	my $written = 0;
	while ( @{$batch} ) {
		my @chunk = splice( @{$batch}, 0, $MAX_ROWS_PER_INSERT );
		my $sql   = 'INSERT INTO syslog ' . $COLUMNS . ' VALUES ' . join( ',', ($TUPLE) x scalar(@chunk) );
		my @binds = map { @{$_} } @chunk;

		eval {
			my $sth = $self->{'dbh'}->prepare_cached($sql);
			$sth->execute(@binds);
		};
		if ($@) {
			warn( 'batch insert of ' . scalar(@chunk) . ' syslog row(s) failed... ' . $@ );
		} else {
			$written += scalar(@chunk);
		}
	} ## end while ( @{$batch} )

	return $written;
} ## end sub flush

1;    # End of Allani
