package Allani::Command::tail;

use strict;
use warnings;
use Allani -command;
use Allani::Sources ();

sub opt_spec {
	return (
		[ 'source|s=s', 'which table: syslog, http_access, or http_error (default syslog)' ],
		Allani::Sources::filter_opt_spec(),
		[ 'lines|n=i',  'initial rows to show (default 10)' ],
		[ 'follow|f',   'keep polling for new rows (until interrupted)' ],
		[ 'interval=i', 'seconds between polls when following (default 2)' ],
		[ 'since=s',    'only seed from rows within this window (e.g. 24h)' ],
		[ 'column=s',   'timestamp column for --since / display (default depends on --source)' ],
		[ 'json',       'print each row as its raw JSON, one per line' ],
	);
}

sub abstract { 'show the most recent rows, optionally following new ones' }

sub description {
	return
		"Prints the last few rows of a table, oldest first, then with --follow keeps polling\n"
		. "for newer rows and printing them as they arrive -- the database analog of tail -f.\n"
		. "New rows are found by id (the monotonic primary key), so nothing is missed or\n"
		. "repeated. --source and the filters work exactly as in search. Ctrl-C stops a\n"
		. "follow.";
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

	# validate options before connecting
	my ( $where, $binds ) = Allani::Sources::build_where( $meta, $opt );
	if ( defined( $opt->since ) ) {
		push( @{$where}, $column . ' >= now() - ?::interval' );
		push( @{$binds}, Allani::duration_to_interval( $opt->since ) );
	}
	my $where_sql = @{$where} ? ( ' AND ' . join( ' AND ', @{$where} ) ) : '';

	my $lines = ( defined( $opt->lines ) && $opt->lines > 0 ) ? $opt->lines : 10;
	# tail keeps id as the first column -- it is the follow cursor (row->[0])
	my ( $select, $headers ) = Allani::Sources::select_and_headers( $meta, $column, $opt->json, 1 );

	my $dbh = $self->{'app'}->connect_dbi;

	# 1) the last N matching rows, then shown oldest-first (newest at the bottom)
	my $seed_sql = 'SELECT ' . $select . ' FROM ' . $meta->{'table'};
	$seed_sql .= ' WHERE ' . join( ' AND ', @{$where} ) if ( @{$where} );
	$seed_sql .= ' ORDER BY id DESC LIMIT ?';

	my $seed = $dbh->prepare($seed_sql);
	$seed->execute( @{$binds}, $lines );
	my @rows = reverse @{ $seed->fetchall_arrayref };

	my $last = 0;
	Allani::Sources::print_header($headers);
	foreach my $row ( @rows ) {
		$last = $row->[0] if ( $row->[0] > $last );
		Allani::Sources::emit_row( $row, $opt->json );
	}

	return 1 if ( !$opt->follow );

	# 2) follow: poll for id > last and print anything new
	local $SIG{'INT'} = sub { print "\n"; exit(0); };
	my $interval = ( defined( $opt->interval ) && $opt->interval > 0 ) ? $opt->interval : 2;

	my $poll = $dbh->prepare(
		'SELECT ' . $select . ' FROM ' . $meta->{'table'} . ' WHERE id > ?' . $where_sql . ' ORDER BY id ASC' );

	while (1) {
		sleep($interval);
		$poll->execute( $last, @{$binds} );
		while ( my $row = $poll->fetchrow_arrayref ) {
			$last = $row->[0] if ( $row->[0] > $last );
			Allani::Sources::emit_row( [ @{$row} ], $opt->json );
		}
	}

	return 1;
} ## end sub execute

1;
