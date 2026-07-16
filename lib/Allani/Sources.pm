package Allani::Sources;

use 5.006;
use strict;
use warnings;
use JSON::XS ();

=head1 NAME

Allani::Sources - Shared per-table metadata and query/format helpers for the read commands.

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 DESCRIPTION

The C<search>, C<tail>, C<stats>, and C<prune> commands all address the same
handful of tables (C<syslog>, C<http_access>, C<http_error>) via a C<--source>
option. This module holds, in one place, what each source offers: its table,
the timestamp columns, the exact-match filter columns, the group-by
dimensions, and the display columns. It also carries the shared WHERE builder
and row formatter so C<search> and C<tail> render identically.

Column and dimension names are whitelisted here; all user I<values> are passed
as bind parameters by the commands.

=cut

# accessor name (dashes in the option become underscores) => column name
our %FILTER_COL = (
	'host'      => 'host',
	'program'   => 'program',
	'facility'  => 'facility',
	'priority'  => 'priority',
	'vhost'     => 'vhost',
	'client_ip' => 'client_ip',
	'method'    => 'method',
	'status'    => 'status',
	'loglevel'  => 'loglevel',
	'code'      => 'code',
	'server'    => 'server',
);

# columns whose filter switches to LIKE when the value carries a % wildcard
our %LIKEABLE = ( 'program' => 1, 'host' => 1 );

our %SOURCES = (
	'syslog' => {
		'table'       => 'syslog',
		'ts'          => { 'c_isodate' => 1, 'r_isodate' => 1, 's_isodate' => 1 },
		'default_ts'  => 's_isodate',
		'eq'          => { map { $_ => 1 } qw(host program facility priority) },
		'dims'        => { map { $_ => 1 } qw(program host host_from facility priority) },
		'default_dim' => 'program',
		'display'     => [ [ 'host', 'host' ], [ 'program', 'program' ], [ 'message', "raw->>'MESSAGE'" ] ],
	},
	'http_access' => {
		'table'       => 'http_access',
		'ts'          => { 'r_isodate' => 1, 'req_isodate' => 1 },
		'default_ts'  => 'r_isodate',
		'eq'          => { map { $_ => 1 } qw(host vhost client_ip method status) },
		'dims'        => { map { $_ => 1 } qw(vhost host method status client_ip) },
		'default_dim' => 'vhost',
		'display'     => [
			[ 'vhost',   'vhost' ],
			[ 'client',  'client_ip' ],
			[ 'status',  'status' ],
			[ 'method',  'method' ],
			[ 'request', 'request' ],
		],
	},
	'http_error' => {
		'table'       => 'http_error',
		'ts'          => { 'r_isodate' => 1, 'err_isodate' => 1 },
		'default_ts'  => 'r_isodate',
		'eq'          => { map { $_ => 1 } qw(host vhost client_ip loglevel code server) },
		'dims'        => { map { $_ => 1 } qw(server host loglevel code client_ip) },
		'default_dim' => 'server',
		'display'     => [
			[ 'level',   'loglevel' ],
			[ 'client',  'client_ip' ],
			[ 'code',    'code' ],
			[ 'message', 'message' ],
		],
	},
);

=head1 FUNCTIONS

=head2 source

Returns the metadata hash ref for a source name, or undef.

=cut

sub source { return $SOURCES{ $_[0] }; }

=head2 names

Returns the source names, sorted.

=cut

sub names { return sort keys(%SOURCES); }

=head2 filter_opt_spec

Returns the App::Cmd opt_spec entries for the shared filters, so C<search> and
C<tail> declare an identical set (which L</build_where> then reads).

=cut

sub filter_opt_spec {
	return (
		[ 'host=s',      'match host (all sources)' ],
		[ 'program=s',   'match program (syslog)' ],
		[ 'facility=s',  'match facility (syslog)' ],
		[ 'priority=s',  'match priority (syslog)' ],
		[ 'vhost=s',     'match vhost (http_access, http_error)' ],
		[ 'client-ip=s', 'match client_ip (http_access, http_error)' ],
		[ 'method=s',    'match method (http_access)' ],
		[ 'status=s',    'match status (http_access)' ],
		[ 'loglevel=s',  'match loglevel (http_error)' ],
		[ 'code=s',      'match code (http_error)' ],
		[ 'server=s',    'match server (http_error)' ],
		[ 'field=s@',    'match an enriched field: key<op>value, op = != <> > < >= <= ~ !~ =~ (repeatable)' ],
		[ 'message=s',   'substring (ILIKE) match against the MESSAGE field' ],
	);
} ## end sub filter_opt_spec

=head2 build_where

Builds the exact-match / message / enriched-field WHERE fragments and bind
values from the shared filter options for a given source. Dies if a filter is
used that is not valid for the source, or on a malformed C<--field>.

    my ( $where, $binds ) = Allani::Sources::build_where( $meta, $opt );

The C<since> window (which needs the caller's chosen timestamp column) is left
to the command.

=cut

sub build_where {
	my ( $meta, $opt ) = @_;

	my @where;
	my @binds;

	foreach my $accessor ( sort keys(%FILTER_COL) ) {
		my $val = $opt->$accessor;
		next if ( !defined($val) );
		my $col = $FILTER_COL{$accessor};
		if ( !$meta->{'eq'}{$col} ) {
			( my $flag = $accessor ) =~ tr/_/-/;
			die( '--' . $flag . ' is not valid for source ' . $meta->{'table'} . "\n" );
		}
		# program and host use LIKE when the value carries a % wildcard
		if ( $LIKEABLE{$col} && index( $val, '%' ) >= 0 ) {
			push( @where, $col . ' LIKE ?' );
		} else {
			push( @where, $col . ' = ?' );
		}
		push( @binds, $val );
	} ## end foreach my $accessor ( sort...)

	if ( defined( $opt->message ) ) {
		push( @where, "raw->>'MESSAGE' ILIKE ?" );
		push( @binds, '%' . $opt->message . '%' );
	}

	if ( defined( $opt->field ) ) {
		foreach my $f ( @{ $opt->field } ) {
			my ( $k, $op, $v ) = _parse_field($f);
			my ( $frag, @fb ) = _field_predicate( $k, $op, $v );
			push( @where, $frag );
			push( @binds, @fb );
		}
	}

	return ( \@where, \@binds );
} ## end sub build_where

# does a string look like a plain number (no leading zeros on multi-digit ints)?
sub _looks_numeric {
	my ($v) = @_;
	return ( defined($v) && $v =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/ ) ? 1 : 0;
}

# --field key<op>value -> (key, op, value). Keys are word-ish and never hold an
# operator char, so the first operator after the key wins.
sub _parse_field {
	my ($f) = @_;

	if ( $f =~ /\A([\w.]+)\s*(!=|>=|<=|<>|=~|!~|~|>|<|=)\s*(.*)\z/s ) {
		return ( $1, $2, $3 );
	}

	die( '--field must be key<op>value (op one of = != <> > < >= <= ~ !~ =~), got "' . $f . "\"\n" );
} ## end sub _parse_field

# build the WHERE fragment + binds for one --field predicate.
#
# '=' uses jsonb containment (@>) so the GIN index on raw serves it -- fast even
# when nothing matches. Every other operator extracts raw->'enriched'->>key and
# compares, which the GIN index cannot serve: pair it with a column/time filter,
# or add a per-key index with `allani index`.
sub _field_predicate {
	my ( $k, $op, $v ) = @_;

	if ( $op eq '=' ) {
		my $jc    = JSON::XS->new->canonical;
		my @preds = ('raw @> ?::jsonb');
		my @binds = ( $jc->encode( { 'enriched' => { $k => $v } } ) );
		if ( _looks_numeric($v) ) {
			push( @preds, 'raw @> ?::jsonb' );
			push( @binds, $jc->encode( { 'enriched' => { $k => ( $v + 0 ) } } ) );
		}
		return ( '(' . join( ' OR ', @preds ) . ')', @binds );
	} ## end if ( $op eq '=' )

	my $extract = "raw->'enriched'->>?";

	if ( $op eq '!=' || $op eq '<>' ) {
		# IS DISTINCT FROM so a row missing the field counts as != value
		return ( $extract . ' IS DISTINCT FROM ?', $k, $v );
	}
	if ( $op eq '~' )  { return ( $extract . ' ~ ?',     $k, $v ); }
	if ( $op eq '!~' ) { return ( $extract . ' !~ ?',    $k, $v ); }
	if ( $op eq '=~' ) { return ( $extract . ' ILIKE ?', $k, '%' . $v . '%' ); }

	# >, <, >=, <= : numeric compare when the value is a number (guarded with
	# jsonb_typeof so a row storing a non-number is skipped, not a query error),
	# otherwise a plain text compare. $op is whitelisted by _parse_field.
	if ( $op eq '>' || $op eq '<' || $op eq '>=' || $op eq '<=' ) {
		if ( _looks_numeric($v) ) {
			return (
				"(jsonb_typeof(raw->'enriched'->?) = 'number' AND (raw->'enriched'->>?)::numeric " . $op . ' ?)',
				$k, $k, ( $v + 0 )
			);
		}
		return ( $extract . ' ' . $op . ' ?', $k, $v );
	} ## end if ( $op eq '>' || $op eq...)

	die( 'unknown field operator "' . $op . "\"\n" );    # unreachable; parser guards
} ## end sub _field_predicate

=head2 select_and_headers

Given a source's metadata, the chosen timestamp column, whether JSON output is
wanted, and whether to include the C<id> column, returns
C<< ( $select_sql, $headers ) >>. When C<$with_id> is true, C<id> is the first
selected column (so a caller such as C<tail> can use it as a cursor); C<search>
passes it false so the id is neither selected nor shown. For JSON, C<raw> is the
last column and C<$headers> is undef.

=cut

sub select_and_headers {
	my ( $meta, $tscol, $json, $with_id ) = @_;

	if ($json) {
		return ( $with_id ? 'id, raw' : 'raw', undef );
	}

	my @exprs   = $with_id ? ('id') : ();
	my @headers = $with_id ? ('id') : ();
	push( @exprs,   $tscol );
	push( @headers, 'time' );
	foreach my $d ( @{ $meta->{'display'} } ) {
		push( @headers, $d->[0] );
		push( @exprs,   $d->[1] );
	}

	return ( join( ', ', @exprs ), \@headers );
} ## end sub select_and_headers

=head2 print_header

Prints the tab-separated header row (a no-op with no headers, i.e. JSON mode).

=cut

sub print_header {
	my ($headers) = @_;
	return if ( !defined($headers) );
	print join( "\t", @{$headers} ) . "\n";
	return;
}

=head2 emit_row

Prints one fetched row: its raw JSON (JSON mode, the last column) or a
tab-separated line with tabs/newlines squashed to spaces.

=cut

sub emit_row {
	my ( $row, $json ) = @_;

	if ($json) {
		print $row->[-1] . "\n";
		return;
	}

	print join( "\t", map { my $v = defined($_) ? $_ : ''; $v =~ s/[\r\n\t]+/ /g; $v } @{$row} ) . "\n";
	return;
} ## end sub emit_row

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

1;
