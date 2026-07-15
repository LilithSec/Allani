package Allani::Command::ingest_file;

use strict;
use warnings;
use Allani -command;
use Allani::Ingest;

sub opt_spec { return () }

sub abstract { 'ingest syslog-ng JSON from one or more files' }

sub description {
	return
		"Like ingest_json_syslog, but reads from the named files (one JSON record per line)\n"
		. "instead of stdin. Handy for replaying a spool or loading test data. Enrichment,\n"
		. "if configured, is applied just as with the live gate. A line that fails to parse\n"
		. "or is missing a required field is warned about and skipped.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	if ( !defined( $args->[0] ) ) {
		die("at least one file is required\n");
	}

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );
	my $dbh      = $self->{'app'}->connect_dbi;
	my $munger   = $self->{'app'}->build_munger;
	my $ingester = Allani::Ingest->new( 'dbh' => $dbh, 'munger' => $munger );

	my $total  = 0;
	my $failed = 0;
	foreach my $file ( @{$args} ) {
		my $fh;
		if ( !open( $fh, '<', $file ) ) {
			warn( 'could not open "' . $file . '"... ' . $! );
			next;
		}
		while ( my $line = readline($fh) ) {
			next if ( $line =~ /\A\s*\z/ );
			$total++;
			eval { $ingester->ingest_json_syslog($line); };
			if ($@) {
				$failed++;
				warn($@);
			}
		}
		close($fh);
	} ## end foreach my $file ( @{$args} )

	print 'ingested ' . ( $total - $failed ) . ' of ' . $total . " line(s)\n";

	return 1;
} ## end sub execute

1;
