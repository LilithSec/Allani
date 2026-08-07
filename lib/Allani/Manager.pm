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

# Works out which workers this manager is responsible for, reading the loaded
# config. Called once from new, before anything is spawned, so that start_server
# has the full list up front and can report it.
#
# One worker is planned per web_logs set, plus a single syslog worker when a
# syslog_socket is configured. The reserved keys under web_logs -- geoip,
# state_dir, pid_dir, run_dir -- are settings rather than sets and are skipped,
# as is any key whose value is not a hash.
#
# Takes no arguments.
#
# Returns nothing. It populates $self->{'workers'}, a hash keyed by worker name
# -- 'web-<set>' for a web_logs set, 'syslog' for the syslog worker -- whose
# values are hash refs of:
#
#   - args :: An array ref of the ishara arguments identifying this worker, e.g.
#       [ '--name', 'foo' ] or [ '--syslog' ]. _poe_spawn appends --config and
#       --foreground to these.
#
#   - restarts :: How many times the worker has been restarted, starting at 0.
#
#   - delay :: Seconds to wait before the next restart, starting at 0 and backed
#       off by _poe_reaped.
#
# Given a config with web_logs sets 'foo' and 'bar' and a syslog_socket set,
# this plans the workers web-bar, web-foo, and syslog.
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

# The POE _start handler for the manager session, run once when the session is
# created. It names the session 'allani_manager' so the control socket handlers
# can post to it by alias rather than by ID, then queues a spawn for every
# planned worker.
#
# The workers are yielded rather than spawned inline so that _start returns
# promptly and the kernel is running by the time the first child appears.
#
#   - $kernel :: The POE kernel, from the KERNEL argument slot.
#
# Returns nothing.
#
# Not called directly; POE dispatches it when start_server creates the session.
sub _poe_start {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	$kernel->alias_set('allani_manager');
	foreach my $name ( sort keys( %{ $self->{'workers'} } ) ) {
		$kernel->yield( 'spawn_worker', $name );
	}

	return;
} ## end sub _poe_start

# Spawns one ishara worker under a POE::Wheel::Run and records what is needed to
# recognise it again later. The worker is always run with --foreground: the
# manager is its supervisor, so it must not daemonize away from the wheel
# watching it.
#
# Handles the 'spawn_worker' event, which is fired both by _poe_start at
# startup and by _poe_reaped after a backoff delay, so this is the single place
# a worker is ever started.
#
#   - $kernel :: The POE kernel, from the KERNEL argument slot.
#
#   - $name :: The worker name, from ARG0, matching a key in $self->{'workers'},
#       e.g. 'web-foo' or 'syslog'. An unknown name is ignored.
#
# Returns nothing. It stores the wheel and its PID on the worker's entry and
# records the reverse lookups -- wheel ID to name, PID to name -- that
# _poe_stdout, _poe_stderr, and _poe_reaped use to attribute output and exits.
# The child is registered for reaping via sig_child, and the spawn is logged to
# syslog with the full command line.
#
# Not called directly; POE dispatches it. The effect for a web set named foo is
# to run:
#
#     ishara --name foo --config /usr/local/etc/allani.yaml --foreground
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

# Logs one line a worker wrote to stdout. A supervised worker has nowhere useful
# to print to, so the manager captures its output and forwards it to syslog
# instead, tagged with the worker's name so lines stay attributable.
#
#   - $line :: One line of the worker's stdout, from ARG0, already stripped of
#       its newline by the wheel.
#
#   - $wheel_id :: The ID of the wheel that produced it, from ARG1, looked up in
#       $self->{'wheel_to_worker'} to name the worker. A wheel that has already
#       been forgotten logs as '?' rather than being dropped.
#
# Returns nothing. The line reaches syslog at the info level as, for example:
#
#     ishara "web-foo" stdout... tailing /var/log/apache2/foo/access.log
#
# Not called directly; POE dispatches it.
sub _poe_stdout {
	my ( $self, $line, $wheel_id ) = @_[ OBJECT, ARG0, ARG1 ];
	my $name = defined( $self->{'wheel_to_worker'}{$wheel_id} ) ? $self->{'wheel_to_worker'}{$wheel_id} : '?';
	log_drek( 'info', 'ishara "' . $name . '" stdout... ' . $line );
	return;
}

# Logs one line a worker wrote to stderr. The counterpart to _poe_stdout,
# differing only in that it logs at the err level, since this is where a
# worker's warnings and die messages surface.
#
#   - $line :: One line of the worker's stderr, from ARG0, already stripped of
#       its newline by the wheel.
#
#   - $wheel_id :: The ID of the wheel that produced it, from ARG1, looked up in
#       $self->{'wheel_to_worker'} to name the worker; an unknown wheel logs
#       as '?'.
#
# Returns nothing. The line reaches syslog at the err level as, for example:
#
#     ishara "web-foo" stderr... tail read error on "/var/log/httpd/access.log"
#
# Not called directly; POE dispatches it.
sub _poe_stderr {
	my ( $self, $line, $wheel_id ) = @_[ OBJECT, ARG0, ARG1 ];
	my $name = defined( $self->{'wheel_to_worker'}{$wheel_id} ) ? $self->{'wheel_to_worker'}{$wheel_id} : '?';
	log_drek( 'err', 'ishara "' . $name . '" stderr... ' . $line );
	return;
}

# Reaps a worker that has exited and, unless the manager is shutting down,
# arranges for it to be restarted. This is what makes the manager a supervisor:
# a worker that dies for any reason -- a crash, a lost database connection, an
# operator killing it -- comes back on its own.
#
# Restarts back off exponentially, doubling from one second and capping at
# sixty, so a worker that cannot start at all (a bad config, a database that is
# down) settles into retrying once a minute rather than spinning. The delay is
# never reset, so it reflects the whole life of the manager rather than the last
# failure alone.
#
# Handles the sig_child event registered by _poe_spawn.
#
#   - $kernel :: The POE kernel, from the KERNEL argument slot.
#
#   - $pid :: The PID that exited, from ARG1, looked up in
#       $self->{'pid_to_worker'}. A PID the manager does not know is ignored.
#
#   - $status :: The raw wait status, from ARG2. Shifted right eight places for
#       the exit code when logging.
#
# Returns nothing. It forgets the dead worker's wheel and PID, logs the exit,
# and then either stops -- when $self->{'shutting_down'} is set, because
# _poe_stop_all asked the worker to exit -- or bumps the worker's restart count
# and delay and schedules a fresh 'spawn_worker' for it.
#
# Not called directly; POE dispatches it when a child is reaped.
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

# Begins an orderly shutdown: asks every running worker to stop, then releases
# the manager's own hold on the kernel so it can wind down once the workers are
# gone.
#
# Workers are sent TERM rather than killed, because ishara traps it and uses it
# to checkpoint -- flushing buffered rows and writing its position tablet -- so
# that a restart resumes exactly where it left off. The shutting_down flag is
# set first so that _poe_reaped lets the workers stay dead instead of restarting
# them as it normally would.
#
# Handles the 'stop_all' event, which the control socket's stop command posts.
#
#   - $kernel :: The POE kernel, from the KERNEL argument slot.
#
# Returns nothing. Every worker with a live wheel is TERMed and the stop logged
# per worker; the pending restart timers are cleared and the 'allani_manager'
# alias dropped, which is what lets the kernel finish. The socket's stop handler
# separately schedules the final shutdown a second later, giving this a moment
# to run first.
#
# Not called directly; POE dispatches it.
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

# Builds the reply to a status request on the control socket -- what
# `allani status` prints.
#
# Takes no arguments.
#
# Returns a hash ref, which the socket server encodes as JSON:
#
#   - uptime :: Seconds since start_server began, or undef when the manager has
#       somehow not started yet.
#
#   - workers :: A hash ref keyed by worker name, e.g. 'web-foo' or 'syslog',
#       each value a hash ref of:
#
#       - up :: 1 when the worker currently has a PID, 0 when it is between
#           restarts or has not been spawned.
#
#       - pid :: The worker's PID, or undef when it is not running.
#
#       - restarts :: How many times it has been restarted since the manager
#           started. A number climbing here is the sign of a worker that cannot
#           stay up.
#
# So a healthy manager with one web worker and one syslog worker answers:
#
#     { 'uptime' => 3600,
#       'workers' => {
#           'web-foo' => { 'up' => 1, 'pid' => 4242, 'restarts' => 0 },
#           'syslog'  => { 'up' => 1, 'pid' => 4243, 'restarts' => 0 },
#       } }
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

1;
