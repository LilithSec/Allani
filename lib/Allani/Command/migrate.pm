package Allani::Command::migrate;

use strict;
use warnings;
use Allani -command;
use Allani::Schema ();
use DBIx::Class::Migration ();

sub opt_spec { return () }

sub abstract { 'upgrade an existing database to the current schema' }

sub description {
	return
		"Upgrades an already-deployed database to the schema version this release expects,\n"
		. "using DBIx::Class::Migration. It is a no-op when the database is already current.\n"
		. "For a fresh, empty database use deploy instead.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );
	my $config = $self->{'app'}->config;

	my $migration = DBIx::Class::Migration->new(
		'schema_class' => 'Allani::Schema',
		'schema_args'  => [ $config->{'dsn'}, $config->{'user'}, $config->{'pass'} ],
	);

	eval { $migration->upgrade; };
	if ($@) {
		die( 'Failed to upgrade the schema... ' . $@ );
	}

	print 'schema is now at version ' . $Allani::Schema::VERSION . "\n";

	return 1;
} ## end sub execute

1;
