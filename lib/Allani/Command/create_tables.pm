package Allani::Command::create_tables;

use strict;
use warnings;
use Allani -command;

sub opt_spec {
	return (
		);
}

sub abstract { "Creates the tables." }

sub description { "Creates the tables." }

sub validate { return 1};

sub execute {
	my ($self, $opt, $args) = @_;

	$self->{'app'}->read_in_config('config'=>$self->{'app'}{'global_options'}{'config'});

	my $dbh=$self->{'app'}->connect_dbi;

	my $sth
		= $dbh->prepare( 'create table syslog ('
			. 'id bigserial NOT NULL, '
			. 'c_isodate TIMESTAMP WITH TIME ZONE NOT NULL, '
			. 'r_isodate  TIMESTAMP WITH TIME ZONE NOT NULL, '
			. 's_isodate  TIMESTAMP WITH TIME ZONE NOT NULL, '
			. 'facility varchar(255) NOT NULL, '
			. 'host varchar(255) NOT NULL, '
			. 'host_from varchar(255) NOT NULL, '
			. 'pid bigint NOT NULL, '
			. 'priority varchar(64) NOT NULL, '
			. 'program varchar(255) NOT NULL, '
			. 'sourceip inet NOT NULL, '
			. 'raw jsonb NOT NULL, '
			. 'PRIMARY KEY(id) );' );
	$sth->execute();
}

1;
