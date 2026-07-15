package Allani::Command::stats;

use strict;
use warnings;
use Allani -command;

my %SOURCES = (
	'syslog' => {
		'table'       => 'syslog',
		'dims'        => { map { $_ => 1 } qw(program host host_from facility priority) },
		'default_dim' => 'program',
		'ts'          => { 'c_isodate' => 1, 'r_isodate' => 1, 's_isodate' => 1 },
		'default_ts'  => 's_isodate',
	},
	'http_access' => {
		'table'       => 'http_access',
		'dims'        => { map { $_ => 1 } qw(vhost host method status client_ip) },
		'default_dim' => 'vhost',
		'ts'          => { 'r_isodate' => 1, 'req_isodate' => 1 },
		'default_ts'  => 'r_isodate',
	},
	'http_error' => {
		'table'       => 'http_error',
		'dims'        => { map { $_ => 1 } qw(server host loglevel code client_ip) },
		'default_dim' => 'server',
		'ts'          => { 'r_isodate' => 1, 'err_isodate' => 1 },
		'default_ts'  => 'r_isodate',
	},
);

sub opt_spec {
	return (
		[ 'source|s=s', 'which table: syslog or http_access (default syslog)' ],
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
		. "table (syslog or http_access) and its available dimensions. Restrict to a recent\n"
		. "window with --since.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	my $source = defined( $opt->source ) ? $opt->source : 'syslog';
	my $meta   = $SOURCES{$source};
	if ( !defined($meta) ) {
		die( '--source must be one of ' . join( ', ', sort keys %SOURCES ) . "\n" );
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
