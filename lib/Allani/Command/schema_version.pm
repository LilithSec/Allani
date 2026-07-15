package Allani::Command::schema_version;

use strict;
use warnings;
use Allani -command;
use Allani::Schema ();

sub opt_spec { return () }

sub abstract { 'show the deployed schema version and this release' }

sub description {
	return
		"Prints the schema version recorded in the database alongside the version this\n"
		. "release of Allani expects, and whether an upgrade is pending.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );
	my $dbh = $self->{'app'}->connect_dbi;

	my $installed = $self->{'app'}->installed_schema_version($dbh);
	my $code      = $Allani::Schema::VERSION;

	print 'this release: ' . $code . "\n";
	if ( !defined($installed) ) {
		print "deployed:     none (run: allani deploy)\n";
	} else {
		print 'deployed:     ' . $installed . "\n";
		if ( $installed < $code ) {
			print "status:       upgrade pending (run: allani migrate)\n";
		} elsif ( $installed == $code ) {
			print "status:       current\n";
		} else {
			print "status:       database is newer than this release\n";
		}
	}

	return 1;
} ## end sub execute

1;
