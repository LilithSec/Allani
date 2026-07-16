package Allani::Command::start;

use strict;
use warnings;
use Allani -command;
use Allani::Manager ();
use Net::Server::Daemonize qw( daemonize );

sub opt_spec {
	return ( [ 'foreground|f', 'do not daemonize (run in the foreground)' ], );
}

sub abstract { 'start the manager and its ishara workers' }

sub description {
	return
		"Starts the Allani manager, which spawns and supervises one ishara worker per\n"
		. "web_logs set plus one syslog worker (when a syslog_socket is configured). PID\n"
		. "files and the control socket live under run_dir (default /var/run/allani). Use\n"
		. "stop and status to control it.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	my $manager = Allani::Manager->new( 'config' => $self->{'app'}{'global_options'}{'config'} );

	if ( $opt->foreground ) {
		open( my $pid_fh, '>', $manager->pid_path )
			|| die( 'Failed to open the PID file "' . $manager->pid_path . '"... ' . $! );
		print $pid_fh $$;
		close($pid_fh);
	} else {
		daemonize( $>, ( split( /\s+/, $) ) )[0], $manager->pid_path );
	}

	$manager->start_server;

	unlink( $manager->pid_path ) if ( -e $manager->pid_path );

	return 1;
} ## end sub execute

1;
