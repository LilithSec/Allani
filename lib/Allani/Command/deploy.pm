package Allani::Command::deploy;

use strict;
use warnings;
use Allani -command;
use Allani::Schema ();
use DBIx::Class::Migration ();

sub opt_spec { return () }

sub abstract { 'deploy the schema into a fresh database' }

sub description {
	return
		"Installs the current schema version into an empty database using\n"
		. "DBIx::Class::Migration. Run this once, after the database and role exist. For an\n"
		. "existing database that needs to move to a newer schema, use migrate instead.";
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

	eval { $migration->install; };
	if ($@) {
		die( 'Failed to deploy the schema... ' . $@ );
	}

	print 'deployed schema version ' . $Allani::Schema::VERSION . "\n";

	return 1;
} ## end sub execute

1;
