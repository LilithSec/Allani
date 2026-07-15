package Allani::Command::check;

use strict;
use warnings;
use Allani -command;
use Allani::Schema ();

sub opt_spec { return () }

sub abstract { 'check the config, database, schema version, and rules' }

sub description {
	return
		"A pre-flight check: parses the config, connects to the database, compares the\n"
		. "deployed schema version against this release, and loads the configured munger\n"
		. "rules. Prints a line per check and exits non-zero if anything is wrong.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	my $problems = 0;

	my $config_path = $self->{'app'}{'global_options'}{'config'};
	eval { $self->{'app'}->read_in_config( 'config' => $config_path ); };
	if ($@) {
		print 'config:   FAIL (' . $config_path . ') -- ' . $@;
		# without a usable config nothing else can be checked
		exit(1);
	}
	print 'config:   ok (' . $config_path . ")\n";

	my $dbh = eval { $self->{'app'}->connect_dbi; };
	if ( $@ || !defined($dbh) ) {
		print "database: FAIL -- could not connect\n";
		$problems++;
	} else {
		print "database: connected\n";

		my $installed = $self->{'app'}->installed_schema_version($dbh);
		my $code      = $Allani::Schema::VERSION;
		if ( !defined($installed) ) {
			print "schema:   NOT DEPLOYED (run: allani deploy)\n";
			$problems++;
		} elsif ( $installed == $code ) {
			print 'schema:   version ' . $installed . " (current)\n";
		} elsif ( $installed < $code ) {
			print 'schema:   version '
				. $installed
				. ', this release is '
				. $code
				. " -- upgrade pending (run: allani migrate)\n";
			$problems++;
		} else {
			print 'schema:   version '
				. $installed
				. ' is newer than this release ('
				. $code
				. ") -- upgrade Allani\n";
			$problems++;
		}
	} ## end else [ if ( $@ || !defined($dbh...))]

	my $rules = $self->{'app'}->config->{'munger_rules'};
	if ( !defined($rules) || ref($rules) ne 'ARRAY' || !defined( $rules->[0] ) ) {
		print "rules:    enrichment disabled (no munger_rules)\n";
	} else {
		my $munger = eval { $self->{'app'}->build_munger; };
		if ( $@ || !defined($munger) ) {
			print 'rules:    FAIL -- ' . ( $@ ? $@ : "build returned nothing\n" );
			$problems++;
		} else {
			print 'rules:    ok (' . join( ', ', @{$rules} ) . ")\n";
		}
	}

	if ($problems) {
		print "\n" . $problems . " problem(s) found.\n";
		exit(1);
	}
	print "\nall good.\n";

	return 1;
} ## end sub execute

1;
