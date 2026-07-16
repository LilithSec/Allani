package Allani::Command::prune;

use strict;
use warnings;
use Allani -command;
use Allani::Sources ();

sub opt_spec {
	return (
		[ 'source|s=s',   'which table: syslog, http_access, or http_error (default syslog)' ],
		[ 'older-than=s', 'delete rows older than this (e.g. 90d, 24h) -- required' ],
		[ 'column=s',     'timestamp column to compare (default r_isodate)' ],
		[ 'dry-run|n',    'report how many rows would be deleted without deleting' ],
	);
}

sub abstract { 'delete rows older than a given age (retention)' }

sub description {
	return
		"Deletes rows whose timestamp is older than the given age, for retention. The age\n"
		. "is a short duration like 90d, 24h, or 30m. --source picks the table (syslog,\n"
		. "http_access, http_error); --column picks the timestamp column (received time,\n"
		. "r_isodate, by default). Use --dry-run to see the count first.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	if ( !defined( $opt->older_than ) ) {
		die("--older-than is required (e.g. --older-than 90d)\n");
	}

	my $source = defined( $opt->source ) ? $opt->source : 'syslog';
	my $meta   = Allani::Sources::source($source);
	if ( !defined($meta) ) {
		die( '--source must be one of ' . join( ', ', Allani::Sources::names() ) . "\n" );
	}

	# retention compares the received time by default, not the message time
	my $column = defined( $opt->column ) ? $opt->column : 'r_isodate';
	if ( !$meta->{'ts'}{$column} ) {
		die( '--column for ' . $source . ' must be one of ' . join( ', ', sort keys %{ $meta->{'ts'} } ) . "\n" );
	}
	my $interval = Allani::duration_to_interval( $opt->older_than );

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );
	my $dbh = $self->{'app'}->connect_dbi;

	if ( $opt->dry_run ) {
		my $sth = $dbh->prepare(
			'SELECT count(*) FROM ' . $meta->{'table'} . ' WHERE ' . $column . ' < now() - ?::interval' );
		$sth->execute($interval);
		my ($count) = $sth->fetchrow_array;
		print 'would delete ' . $count . ' row(s) from ' . $meta->{'table'} . ' where ' . $column . ' < now() - '
			. $interval . "\n";
	} else {
		my $sth
			= $dbh->prepare( 'DELETE FROM ' . $meta->{'table'} . ' WHERE ' . $column . ' < now() - ?::interval' );
		my $deleted = $sth->execute($interval);
		$deleted = 0 if ( !defined($deleted) || $deleted eq '0E0' );
		print 'deleted ' . $deleted . ' row(s) from ' . $meta->{'table'} . ' where ' . $column . ' < now() - '
			. $interval . "\n";
	}

	return 1;
} ## end sub execute

1;
