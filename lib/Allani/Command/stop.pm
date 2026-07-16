package Allani::Command::stop;

use strict;
use warnings;
use Allani -command;
use Allani::Manager   ();
use Ereshkigal::Client ();
use JSON::MaybeXS      ();

sub opt_spec { return () }

sub abstract { 'stop the running manager and its workers' }

sub description {
	return "Tells the running manager (via its control socket under run_dir) to stop its\n"
		. "ishara workers and exit.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );
	my $socket = Allani::Manager::socket_path_for( $self->{'app'}->config );

	my $client = Ereshkigal::Client->new( 'socket' => $socket );
	my $result;
	eval { $result = $client->call_ok('stop'); };
	if ($@) {
		die( 'Failed to reach the manager at "' . $socket . '"... ' . $@ );
	}

	print JSON::MaybeXS->new( 'pretty' => 1, 'canonical' => 1 )->encode($result);

	return 1;
} ## end sub execute

1;
