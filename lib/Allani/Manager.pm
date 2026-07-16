package Allani::Manager;

use 5.006;
use strict;
use warnings;
use POE qw( Wheel::Run );
use POE::Component::Server::JSONUnix ();
use File::Path                       qw( make_path );
use Allani                           ();
use Allani::LogDrek                  qw( log_drek );

=head1 NAME

Allani::Manager - Supervises the ishara workers (one per web set, one for syslog).

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 SYNOPSIS

    use Allani::Manager;

    my $manager = Allani::Manager->new( 'config' => '/usr/local/etc/allani.yaml' );
    $manager->start_server;    # runs the POE kernel until stopped

=head1 DESCRIPTION

Like Baphomet's manager: it does no ingestion itself, it spawns and supervises
one L<Allani::Ishara> worker per C<web_logs> set plus one syslog worker (when a
C<syslog_socket> is configured), each run as C<ishara --foreground> under a
L<POE::Wheel::Run>. It restarts a worker that dies (exponential backoff),
captures each worker's stdout/stderr into syslog via L<Allani::LogDrek>, and
answers C<status>/C<stop> on a unix control socket
(C<< <run_dir>/manager.sock >>).

=head1 METHODS

=head2 new

    - config :: Path to the config file. Required.

=cut

sub new {
	my ( $blank, %opts ) = @_;

	if ( !defined( $opts{'config'} ) ) {
		die('config is undef');
	}

	my $app = Allani->new;
	$app->read_in_config( 'config' => $opts{'config'} );
	log_drek( 'info', 'loaded config from ' . $opts{'config'} );

	my $config = $app->config;

	my $self = {
		'app'             => $app,
		'config_path'     => $opts{'config'},
		'run_dir'         => ( defined( $config->{'run_dir'} )    ? $config->{'run_dir'}    : '/var/run/allani' ),
		'ishara_bin'      => ( defined( $config->{'ishara_bin'} ) ? $config->{'ishara_bin'} : 'ishara' ),
		'workers'         => {},
		'wheel_to_worker' => {},
		'pid_to_worker'   => {},
		'started'         => undef,
		'shutting_down'   => 0,
	};
	bless $self;

	$self->_plan_workers;

	return $self;
} ## end sub new

# work out the worker list: one per web_logs set (keyed web-<set>), plus one
# syslog worker when a syslog_socket is configured
sub _plan_workers {
	my ($self) = @_;

	my $config = $self->{'app'}->config;

	my $wl = $config->{'web_logs'};
	if ( ref($wl) eq 'HASH' ) {
		my %reserved = ( 'geoip' => 1, 'state_dir' => 1, 'pid_dir' => 1, 'run_dir' => 1 );
		foreach my $name ( sort keys( %{$wl} ) ) {
			next if ( $reserved{$name} );
			next if ( ref( $wl->{$name} ) ne 'HASH' );
			$self->{'workers'}{ 'web-' . $name } = { 'args' => [ '--name', $name ], 'restarts' => 0, 'delay' => 0 };
		}
	}

	if ( defined( $config->{'syslog_socket'} ) ) {
		$self->{'workers'}{'syslog'} = { 'args' => ['--syslog'], 'restarts' => 0, 'delay' => 0 };
	}

	return;
} ## end sub _plan_workers

=head2 pid_path

The manager's PID file: C<< <run_dir>/allani.pid >>.

=cut

sub pid_path { return $_[0]->{'run_dir'} . '/allani.pid'; }

=head2 manager_socket

The manager's control socket: C<< <run_dir>/manager.sock >>.

=cut

sub manager_socket { return $_[0]->{'run_dir'} . '/manager.sock'; }

=head2 socket_path_for

Given a loaded config hash ref, returns the manager socket path -- for the
stop/status commands, which have no Manager instance. Not a method.

    my $sock = Allani::Manager::socket_path_for( $allani->config );

=cut

sub socket_path_for {
	my ($config) = @_;
	my $run_dir = ( ref($config) eq 'HASH' && defined( $config->{'run_dir'} ) ) ? $config->{'run_dir'} : '/var/run/allani';
	return $run_dir . '/manager.sock';
}

=head2 start_server

Spawns the workers and runs the POE kernel until a stop request or signal.

=cut

sub start_server {
	my ($self) = @_;

	if ( !-d $self->{'run_dir'} ) {
		eval { make_path( $self->{'run_dir'}, { 'mode' => 0755 } ); };
		if ($@) { die( 'Failed to create run_dir "' . $self->{'run_dir'} . '"... ' . $@ ); }
	}

	$self->{'started'} = time;
	log_drek( 'info', 'allani manager starting; workers: ' . join( ', ', sort keys( %{ $self->{'workers'} } ) ) );

	POE::Component::Server::JSONUnix->spawn(
		'socket_path' => $self->manager_socket,
		'alias'       => 'allani_server',
		'on_error'    => sub {
			my ( $operation, $errnum, $errstr ) = @_;
			log_drek( 'err', 'manager socket ' . $operation . ' error... ' . $errstr . ' (' . $errnum . ')' );
		},
		'commands' => {
			'status' => sub {
				return $self->_cmd_status;
			},
			'stop' => sub {
				log_drek( 'info', 'stop requested' );
				$poe_kernel->post( 'allani_manager', 'stop_all' );
				$poe_kernel->delay( 'shutdown', 1 );
				return { 'stopping' => 1, 'pid' => $$ };
			},
		},
	);

	POE::Session->create(
		'object_states' => [
			$self => {
				'_start'        => '_poe_start',
				'spawn_worker'  => '_poe_spawn',
				'worker_stdout' => '_poe_stdout',
				'worker_stderr' => '_poe_stderr',
				'worker_reaped' => '_poe_reaped',
				'stop_all'      => '_poe_stop_all',
			},
		],
	);

	POE::Kernel->run;

	unlink( $self->manager_socket ) if ( -S $self->manager_socket );

	return 1;
} ## end sub start_server

sub _poe_start {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	$kernel->alias_set('allani_manager');
	foreach my $name ( sort keys( %{ $self->{'workers'} } ) ) {
		$kernel->yield( 'spawn_worker', $name );
	}

	return;
} ## end sub _poe_start

# spawn one ishara worker in the foreground under a Wheel::Run
sub _poe_spawn {
	my ( $self, $kernel, $name ) = @_[ OBJECT, KERNEL, ARG0 ];

	my $entry = $self->{'workers'}{$name};
	return if ( !defined($entry) );

	my @cmd = ( $self->{'ishara_bin'}, @{ $entry->{'args'} }, '--config', $self->{'config_path'}, '--foreground' );

	my $wheel = POE::Wheel::Run->new(
		'Program'     => \@cmd,
		'StdoutEvent' => 'worker_stdout',
		'StderrEvent' => 'worker_stderr',
	);

	$entry->{'wheel'} = $wheel;
	$entry->{'pid'}   = $wheel->PID;
	$self->{'wheel_to_worker'}{ $wheel->ID } = $name;
	$self->{'pid_to_worker'}{ $wheel->PID }  = $name;
	$kernel->sig_child( $wheel->PID, 'worker_reaped' );

	log_drek( 'info', 'spawned ishara "' . $name . '" as PID ' . $wheel->PID . '... ' . join( ' ', @cmd ) );

	return;
} ## end sub _poe_spawn

# a worker's stdout/stderr are captured here and logged by the manager
sub _poe_stdout {
	my ( $self, $line, $wheel_id ) = @_[ OBJECT, ARG0, ARG1 ];
	my $name = defined( $self->{'wheel_to_worker'}{$wheel_id} ) ? $self->{'wheel_to_worker'}{$wheel_id} : '?';
	log_drek( 'info', 'ishara "' . $name . '" stdout... ' . $line );
	return;
}

sub _poe_stderr {
	my ( $self, $line, $wheel_id ) = @_[ OBJECT, ARG0, ARG1 ];
	my $name = defined( $self->{'wheel_to_worker'}{$wheel_id} ) ? $self->{'wheel_to_worker'}{$wheel_id} : '?';
	log_drek( 'err', 'ishara "' . $name . '" stderr... ' . $line );
	return;
}

# reap a dead worker; restart it (exponential backoff) unless we are stopping
sub _poe_reaped {
	my ( $self, $kernel, $pid, $status ) = @_[ OBJECT, KERNEL, ARG1, ARG2 ];

	my $name = delete $self->{'pid_to_worker'}{$pid};
	return if ( !defined($name) );

	my $entry = $self->{'workers'}{$name};
	log_drek( 'info', 'ishara "' . $name . '" PID ' . $pid . ' exited with ' . ( $status >> 8 ) );

	delete $self->{'wheel_to_worker'}{ $entry->{'wheel'}->ID } if ( defined( $entry->{'wheel'} ) );
	delete $entry->{'wheel'};
	delete $entry->{'pid'};

	return if ( $self->{'shutting_down'} );

	$entry->{'delay'}    = $entry->{'delay'} ? ( $entry->{'delay'} * 2 > 60 ? 60 : $entry->{'delay'} * 2 ) : 1;
	$entry->{'restarts'} = ( $entry->{'restarts'} || 0 ) + 1;
	log_drek( 'err', 'ishara "' . $name . '" died, restarting in ' . $entry->{'delay'} . ' seconds' );
	$kernel->delay_set( 'spawn_worker', $entry->{'delay'}, $name );

	return;
} ## end sub _poe_reaped

# TERM every worker (ishara traps it and shuts down cleanly), then release the
# manager so the kernel can wind down
sub _poe_stop_all {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	$self->{'shutting_down'} = 1;

	foreach my $name ( sort keys( %{ $self->{'workers'} } ) ) {
		my $entry = $self->{'workers'}{$name};
		next if ( !defined( $entry->{'wheel'} ) );
		log_drek( 'info', 'stopping ishara "' . $name . '"' );
		$entry->{'wheel'}->kill('TERM');
	}

	$kernel->alarm_remove_all;
	$kernel->alias_remove('allani_manager');

	return;
} ## end sub _poe_stop_all

# the control-socket status response
sub _cmd_status {
	my ($self) = @_;

	my %workers;
	foreach my $name ( sort keys( %{ $self->{'workers'} } ) ) {
		my $entry = $self->{'workers'}{$name};
		$workers{$name} = {
			'up'       => ( defined( $entry->{'pid'} ) ? 1 : 0 ),
			'pid'      => $entry->{'pid'},
			'restarts' => ( $entry->{'restarts'} || 0 ),
		};
	}

	return {
		'uptime'  => ( defined( $self->{'started'} ) ? ( time - $self->{'started'} ) : undef ),
		'workers' => \%workers,
	};
} ## end sub _cmd_status

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

1;
