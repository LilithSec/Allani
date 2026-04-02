package Allani::Command::ingest_json_syslog;

use strict;
use warnings;
use Allani -command;
use Allani::Ingest;

sub opt_spec {
	return ();
}

sub abstract { "Ingests JSON data via stdin from syslog-ng." }

sub description { "Ingests JSON data via stdin from syslog-ng." }

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );

	my $dbh      = $self->{'app'}->connect_dbi;
	my $ingester = Allani::Ingest->new( 'dbh' => $dbh );

	while ( readline(STDIN) ) {
		eval { $ingester->ingest_json_syslog( $_ ); };
		if ($@) {
			warn($@);
		}
	}
} ## end sub execute

1;
