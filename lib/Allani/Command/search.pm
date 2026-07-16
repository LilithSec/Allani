package Allani::Command::search;

use strict;
use warnings;
use Allani -command;
use Allani::Sources ();

sub opt_spec {
	return (
		[ 'source|s=s', 'which table: syslog, http_access, or http_error (default syslog)' ],
		Allani::Sources::filter_opt_spec(),
		[ 'since=s',  'only rows within this window (e.g. 24h)' ],
		[ 'column=s', 'timestamp column --since and ordering use (default depends on --source)' ],
		[ 'limit=i',  'maximum rows to return (default 20)' ],
		[ 'asc',      'oldest first (default newest first)' ],
		[ 'json',     'print the full raw JSON of each row, one per line' ],
	);
}

sub abstract { 'query stored log rows' }

sub description {
	return
		"Queries a table with simple filters and prints a plain, tab-separated table (no\n"
		. "color). --source picks syslog, http_access, or http_error. Column filters are\n"
		. "exact and only the ones valid for the source may be used; --message is a substring\n"
		. "match on MESSAGE; --field matches an enriched field (key=value) and may repeat.\n"
		. "--json prints each row's whole raw JSON instead.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	my $source = defined( $opt->source ) ? $opt->source : 'syslog';
	my $meta   = Allani::Sources::source($source);
	if ( !defined($meta) ) {
		die( '--source must be one of ' . join( ', ', Allani::Sources::names() ) . "\n" );
	}

	my $column = defined( $opt->column ) ? $opt->column : $meta->{'default_ts'};
	if ( !$meta->{'ts'}{$column} ) {
		die( '--column for ' . $source . ' must be one of ' . join( ', ', sort keys %{ $meta->{'ts'} } ) . "\n" );
	}

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );

	# build the query (and validate options) before connecting, so an option
	# mistake is reported without waiting on the database
	my ( $where, $binds ) = Allani::Sources::build_where( $meta, $opt );
	if ( defined( $opt->since ) ) {
		push( @{$where}, $column . ' >= now() - ?::interval' );
		push( @{$binds}, Allani::duration_to_interval( $opt->since ) );
	}

	my $limit = ( defined( $opt->limit ) && $opt->limit > 0 ) ? $opt->limit : 20;
	my $order = $opt->asc ? 'ASC' : 'DESC';

	# search never needs the id (no cursor), so it is not selected or shown
	my ( $select, $headers ) = Allani::Sources::select_and_headers( $meta, $column, $opt->json, 0 );

	my $sql = 'SELECT ' . $select . ' FROM ' . $meta->{'table'};
	if ( @{$where} ) {
		$sql .= ' WHERE ' . join( ' AND ', @{$where} );
	}
	$sql .= ' ORDER BY id ' . $order . ' LIMIT ?';
	push( @{$binds}, $limit );

	my $dbh = $self->{'app'}->connect_dbi;
	my $sth = $dbh->prepare($sql);
	$sth->execute( @{$binds} );

	Allani::Sources::print_header($headers);
	while ( my $row = $sth->fetchrow_arrayref ) {
		Allani::Sources::emit_row( $row, $opt->json );
	}

	return 1;
} ## end sub execute

1;
