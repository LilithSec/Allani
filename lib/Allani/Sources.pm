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

# Decides whether a --field value should be compared as a number rather than as
# text. Enriched values are stored as JSON, so a field may hold either, and the
# same filter has to work both ways: 'bytes>1000' wants a numeric comparison,
# 'version>2.4.1' a textual one.
#
# The test is deliberately stricter than Perl's own idea of a number. A leading
# zero is not accepted on a multi-digit integer, so values that only look
# numeric -- a zero-padded port, an octal file mode, an account number -- keep
# being compared as the strings they are.
#
#   - $v :: The value half of a --field filter, or undef. Not a method argument
#       -- this is a plain function.
#
# Returns 1 when the value is an optionally negative integer or decimal with no
# leading zeros, and 0 otherwise, including for undef.
#
#     _looks_numeric('1000');     # 1
#     _looks_numeric('-2.5');     # 1
#     _looks_numeric('007');      # 0 -- a padded number stays text
#     _looks_numeric('2.4.1');    # 0
sub _looks_numeric {
	my ($v) = @_;
	return ( defined($v) && $v =~ /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/ ) ? 1 : 0;
}

# Splits one --field filter into its three parts. Enriched field names are
# word-ish -- letters, digits, underscores, and dots -- and so never contain an
# operator character, which means the first operator after the name is
# unambiguously the operator, and everything after it is the value however odd
# it looks.
#
#   - $f :: One --field argument as it came off the command line, in the form
#       key<op>value, e.g. 'dovecot_event=login'. Whitespace either side of the
#       operator is allowed and discarded. Not a method argument -- this is a
#       plain function.
#
# Returns the three-element list ( $key, $op, $value ): the field name, one of
# the operators = != <> > < >= <= ~ !~ =~, and the value, which may be empty and
# may contain anything, newlines included.
#
# Dies with a newline-terminated message -- so App::Cmd prints it without a
# source line -- when the argument does not parse.
#
#     _parse_field('dovecot_event=login');   # ( 'dovecot_event', '=', 'login' )
#     _parse_field('bytes >= 1000');         # ( 'bytes', '>=', '1000' )
#     _parse_field('url =~ /admin');         # ( 'url', '=~', '/admin' )
sub _parse_field {
	my ($f) = @_;

	if ( $f =~ /\A([\w.]+)\s*(!=|>=|<=|<>|=~|!~|~|>|<|=)\s*(.*)\z/s ) {
		return ( $1, $2, $3 );
	}

	die( '--field must be key<op>value (op one of = != <> > < >= <= ~ !~ =~), got "' . $f . "\"\n" );
} ## end sub _parse_field

# Builds the WHERE fragment and bind values for one --field predicate.
#
# The two halves of this behave very differently at query time. '=' uses jsonb
# containment (@>), which the GIN index on raw serves, so it stays fast even
# when nothing matches; because the stored value may be a JSON string or a JSON
# number, a numeric-looking value is matched both ways. Every other operator has
# to extract raw->'enriched'->>key and compare it, which the GIN index cannot
# serve. Those want either a column or time filter alongside them, or a per-key
# index added with `allani index`.
#
# The field name and value are always bound, never interpolated, so a filter can
# name any key without becoming an injection route. The operator is the one
# thing that reaches the SQL as text, and it can only be one of the operators
# _parse_field recognises.
#
#   - $k :: The enriched field name, from _parse_field.
#
#   - $op :: The operator, one of = != <> > < >= <= ~ !~ =~, from _parse_field.
#
#   - $v :: The value to compare against, as a string.
#
# Not method arguments -- this is a plain function.
#
# Returns the list ( $fragment, @binds ): a WHERE fragment holding one
# placeholder per bind, followed by the values for them in order. The caller
# joins the fragments with AND and passes the binds to execute in the same
# order. The operators map as follows:
#
#   - = :: jsonb containment, matching the value as a JSON string and, when it
#       looks numeric, as a JSON number too. One fragment, one or two binds.
#
#   - != and <> :: IS DISTINCT FROM, so a row missing the field counts as not
#       equal rather than dropping out of the result the way NULL <> value would.
#
#   - ~ and !~ :: PostgreSQL POSIX regular expression match and non-match.
#
#   - =~ :: a case-insensitive substring match, i.e. ILIKE with the value
#       wrapped in % signs.
#
#   - >, <, >=, <= :: a numeric comparison when the value looks numeric, guarded
#       with jsonb_typeof so a row storing a non-number is skipped rather than
#       failing the whole query, and a plain text comparison otherwise.
#
# Dies on an unrecognised operator, which _parse_field should have already made
# impossible.
#
#     _field_predicate( 'dovecot_event', '=', 'login' );
#     # ( '(raw @> ?::jsonb)', '{"enriched":{"dovecot_event":"login"}}' )
#
#     _field_predicate( 'url', '=~', '/admin' );
#     # ( "raw->'enriched'->>? ILIKE ?", 'url', '%/admin%' )
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

1;
