package Allani::Command::stats;

use strict;
use warnings;
use Allani -command;
use Allani::Sources ();

sub opt_spec {
	return (
		[ 'source|s=s', 'which table: syslog, http_access, or http_error (default syslog)' ],
		[ 'by=s',       'dimension to group by (default depends on --source)' ],
		[ 'since=s',    'only rows within this window (e.g. 24h)' ],
		[ 'column=s',   'timestamp column --since compares against (default depends on --source)' ],
		[ 'limit=i',    'maximum groups to show (default 20)' ],
	);
}

sub abstract { 'count rows grouped by a field' }

sub description {
	return
		"Counts rows grouped by a field and prints them highest first. --source picks the\n"
		. "table (syslog, http_access, http_error) and its available dimensions. Restrict to\n"
		. "a recent window with --since.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	my $source = defined( $opt->source ) ? $opt->source : 'syslog';
	my $meta   = Allani::Sources::source($source);
	if ( !defined($meta) ) {
		die( '--source must be one of ' . join( ', ', Allani::Sources::names() ) . "\n" );
	}

	my $by = defined( $opt->by ) ? $opt->by : $meta->{'default_dim'};
	if ( !$meta->{'dims'}{$by} ) {
		die( '--by for ' . $source . ' must be one of ' . join( ', ', sort keys %{ $meta->{'dims'} } ) . "\n" );
	}
	my $column = defined( $opt->column ) ? $opt->column : $meta->{'default_ts'};
	if ( !$meta->{'ts'}{$column} ) {
		die( '--column for ' . $source . ' must be one of ' . join( ', ', sort keys %{ $meta->{'ts'} } ) . "\n" );
	}

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );
	my $dbh = $self->{'app'}->connect_dbi;

	my @binds;
	my $sql = 'SELECT ' . $by . ' AS k, count(*) AS c FROM ' . $meta->{'table'};
	if ( defined( $opt->since ) ) {
		$sql .= ' WHERE ' . $column . ' >= now() - ?::interval';
		push( @binds, Allani::duration_to_interval( $opt->since ) );
	}
	$sql .= ' GROUP BY ' . $by . ' ORDER BY c DESC, k ASC LIMIT ?';
	my $limit = ( defined( $opt->limit ) && $opt->limit > 0 ) ? $opt->limit : 20;
	push( @binds, $limit );

	my $sth = $dbh->prepare($sql);
	$sth->execute(@binds);
	my $rows = $sth->fetchall_arrayref;

	printf( "%12s  %s\n", 'count', $by );
	foreach my $row ( @{$rows} ) {
		my ( $k, $c ) = @{$row};
		printf( "%12s  %s\n", $c, ( defined($k) ? $k : '(null)' ) );
	}

	return 1;
} ## end sub execute

1;
