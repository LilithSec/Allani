package Allani::Command::search;

use strict;
use warnings;
use Allani -command;

# accessor name (dashes -> underscores) => column name
my %FILTER_COL = (
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

my %SOURCES = (
	'syslog' => {
		'table'      => 'syslog',
		'ts'         => { 'c_isodate' => 1, 'r_isodate' => 1, 's_isodate' => 1 },
		'default_ts' => 's_isodate',
		'eq'         => { map { $_ => 1 } qw(host program facility priority) },
		# extra display columns after id and time: [ header, sql expression ]
		'display'    => [ [ 'host', 'host' ], [ 'program', 'program' ], [ 'message', "raw->>'MESSAGE'" ] ],
	},
	'http_access' => {
		'table'      => 'http_access',
		'ts'         => { 'r_isodate' => 1, 'req_isodate' => 1 },
		'default_ts' => 'r_isodate',
		'eq'         => { map { $_ => 1 } qw(host vhost client_ip method status) },
		'display'    => [
			[ 'vhost',   'vhost' ],
			[ 'client',  'client_ip' ],
			[ 'status',  'status' ],
			[ 'method',  'method' ],
			[ 'request', 'request' ],
		],
	},
	'http_error' => {
		'table'      => 'http_error',
		'ts'         => { 'r_isodate' => 1, 'err_isodate' => 1 },
		'default_ts' => 'r_isodate',
		'eq'         => { map { $_ => 1 } qw(host vhost client_ip loglevel code server) },
		'display'    => [
			[ 'level',   'loglevel' ],
			[ 'client',  'client_ip' ],
			[ 'code',    'code' ],
			[ 'message', 'message' ],
		],
	},
);

sub opt_spec {
	return (
		[ 'source|s=s', 'which table: syslog or http_access (default syslog)' ],
		[ 'host=s',      'match host' ],
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
		[ 'field=s@',    'match an enriched field, key=value (repeatable)' ],
		[ 'message=s',   'substring (ILIKE) match against the MESSAGE field' ],
		[ 'since=s',     'only rows within this window (e.g. 24h)' ],
		[ 'column=s',    'timestamp column --since and ordering use (default depends on --source)' ],
		[ 'limit=i',     'maximum rows to return (default 20)' ],
		[ 'asc',         'oldest first (default newest first)' ],
		[ 'json',        'print the full raw JSON of each row, one per line' ],
	);
}

sub abstract { 'query stored log rows' }

sub description {
	return
		"Queries a table with simple filters and prints a plain, tab-separated table (no\n"
		. "color). --source picks syslog or http_access. Column filters are exact and only\n"
		. "the ones valid for the source may be used; --message is a substring match on\n"
		. "MESSAGE; --field matches an enriched field (key=value) and may repeat. --json\n"
		. "prints each row's whole raw JSON instead.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	my $source = defined( $opt->source ) ? $opt->source : 'syslog';
	my $meta   = $SOURCES{$source};
	if ( !defined($meta) ) {
		die( '--source must be one of ' . join( ', ', sort keys %SOURCES ) . "\n" );
	}

	my $column = defined( $opt->column ) ? $opt->column : $meta->{'default_ts'};
	if ( !$meta->{'ts'}{$column} ) {
		die( '--column for ' . $source . ' must be one of ' . join( ', ', sort keys %{ $meta->{'ts'} } ) . "\n" );
	}

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );

	# build the query (and validate options) before connecting, so an option
	# mistake is reported without waiting on the database
	my @where;
	my @binds;
	foreach my $accessor ( sort keys %FILTER_COL ) {
		my $val = $opt->$accessor;
		next if ( !defined($val) );
		my $col = $FILTER_COL{$accessor};
		if ( !$meta->{'eq'}{$col} ) {
			die( '--' . $accessor =~ tr/_/-/r . ' is not valid for source ' . $source . "\n" );
		}
		push( @where, $col . ' = ?' );
		push( @binds, $val );
	}
	if ( defined( $opt->message ) ) {
		push( @where, "raw->>'MESSAGE' ILIKE ?" );
		push( @binds, '%' . $opt->message . '%' );
	}
	if ( defined( $opt->since ) ) {
		push( @where, $column . ' >= now() - ?::interval' );
		push( @binds, Allani::duration_to_interval( $opt->since ) );
	}
	if ( defined( $opt->field ) ) {
		foreach my $f ( @{ $opt->field } ) {
			my ( $k, $v ) = split( /=/, $f, 2 );
			if ( !defined($v) ) {
				die( '--field must be key=value, got "' . $f . "\"\n" );
			}
			push( @where, "raw->'enriched'->>? = ?" );
			push( @binds, $k, $v );
		}
	}

	my $limit = ( defined( $opt->limit ) && $opt->limit > 0 ) ? $opt->limit : 20;
	my $order = $opt->asc ? 'ASC' : 'DESC';

	my @exprs   = ( 'id', $column );
	my @headers = ( 'id', 'time' );
	if ( !$opt->json ) {
		foreach my $d ( @{ $meta->{'display'} } ) {
			push( @headers, $d->[0] );
			push( @exprs,   $d->[1] );
		}
	} else {
		push( @exprs, 'raw' );
	}

	my $sql = 'SELECT ' . join( ', ', @exprs ) . ' FROM ' . $meta->{'table'};
	if (@where) {
		$sql .= ' WHERE ' . join( ' AND ', @where );
	}
	$sql .= ' ORDER BY id ' . $order . ' LIMIT ?';
	push( @binds, $limit );

	my $dbh = $self->{'app'}->connect_dbi;
	my $sth = $dbh->prepare($sql);
	$sth->execute(@binds);

	if ( $opt->json ) {
		while ( my $row = $sth->fetchrow_arrayref ) {
			print $row->[-1], "\n";    # raw is the last selected column
		}
		return 1;
	}

	print join( "\t", @headers ), "\n";
	while ( my $row = $sth->fetchrow_arrayref ) {
		my @out = map {
			my $v = $_;
			$v = '' if ( !defined($v) );
			$v =~ s/[\r\n\t]+/ /g;
			$v;
		} @{$row};
		print join( "\t", @out ), "\n";
	}

	return 1;
} ## end sub execute

1;
