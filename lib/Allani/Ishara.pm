package Allani::Ishara;

use 5.006;
use strict;
use warnings;
use POE qw( Wheel::FollowTail Wheel::SocketFactory Wheel::ReadWrite Filter::Line );
use Socket qw( PF_UNIX );
use Sys::Hostname qw(hostname);
use File::Path qw(make_path);
use Allani::Ingest             ();
use Allani::Ingest::HttpAccess ();
use Allani::Ingest::HttpError  ();
use Allani::LogDrek            qw( log_drek );

=head1 NAME

Allani::Ishara - The web-log follower that carries access/error lines to Allani's gate.

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 SYNOPSIS

    use Allani::Ishara;

    my $ishara = Allani::Ishara->new( 'app' => $allani, 'name' => 'all' );
    $ishara->start;    # runs the POE kernel until signalled

Ishara tails the files named by the C<web_logs> config sets (see
L</CONFIG>), parses each line through Log::Munger, and inserts it into the
C<http_access> / C<http_error> tables via L<Allani::Ingest::HttpAccess> and
L<Allani::Ingest::HttpError>. File offsets are persisted (Baphomet's tablet
pattern) so a restart resumes exactly where it left off.

=head1 CONFIG

    web_logs:
      geoip: /usr/local/share/GeoIP/GeoLite2-City.mmdb   # global default (reserved key)
      state_dir: /var/db/allani                          # reserved key
      foo:
        access: /var/log/apache2/foo/*access.log
        error:  /var/log/apache2/foo/*error.log
        vhost:  www.example.com     # optional; else derived from the glob wildcard
        vhost_port: 443             # optional
        geoip:  /path/to/other.mmdb # optional per-set override

C<geoip>, C<state_dir>, and C<pid_dir> are reserved keys under C<web_logs>;
every other key is a set. When a set has no explicit C<vhost>, the wildcard
portion of each matched filename becomes the vhost, and a C<:> in it splits
off the port (e.g. a C<*> matching C<www.example.com:443> => vhost
C<www.example.com>, port 443).

=head1 METHODS

=head2 new

    - app :: A configured Allani (read_in_config already called). Required.

    - name :: The web_logs set to follow, or 'all' (the default) for every set.

    - syslog :: When true, run in syslog mode: listen on a unix socket for
        JSONL syslog records (as syslog-ng's unix-stream destination sends) and
        ingest them, instead of tailing web logs. The name becomes 'syslog'.

=cut

sub new {
	my ( $blank, %opts ) = @_;

	if ( !defined( $opts{'app'} ) ) {
		die('app is undef');
	}

	my $syslog = $opts{'syslog'} ? 1 : 0;

	my $self = {
		'app'       => $opts{'app'},
		'mode'      => ( $syslog ? 'syslog' : 'web' ),
		'name'      => $syslog ? 'syslog'
		: ( ( defined( $opts{'name'} ) && $opts{'name'} ne '' ) ? $opts{'name'} : 'all' ),
		'hostname'  => hostname(),
		'sets'      => [],       # parsed web_logs sets (web mode)
		'mungers'   => {},       # geoip path (or '') => Log::Munger
		'ingesters' => {},       # "set/kind/vhost/port" => Ingest object
		'wheels'    => {},       # wheel id => { wheel, file, ingester }
		'by_file'   => {},       # file => wheel id (already tailing?)
		'positions' => {},       # file => { inode, offset }
		'clients'   => {},       # syslog mode: read/write wheel id => wheel
		'dbh'       => undef,
	};
	bless $self;

	$self->_load_sets if ( $self->{'mode'} eq 'web' );

	return $self;
} ## end sub new

# Turns the web_logs block of the config into the list of sets this instance
# will follow. Called once from new, in web mode only.
#
# The keys geoip, state_dir, and pid_dir under web_logs are settings rather than
# sets and are skipped; every other key naming a hash is a set. When the
# instance was given a name other than 'all', only that set is kept, which is
# how the manager runs one worker per set.
#
# Takes no arguments.
#
# Returns nothing. It fills $self->{'sets'} with hash refs, in sorted name
# order, of:
#
#   - name :: The set name as it appears in the config, e.g. 'foo'.
#
#   - access :: The glob pattern matching that set's access logs, or undef when
#       the set has none.
#
#   - error :: The glob pattern matching that set's error logs, or undef.
#
#   - vhost :: The vhost to tag rows with, or undef to derive one per file from
#       the wildcard portion of the matched path -- see _resolve_vhost.
#
#   - vhost_port :: The port to tag rows with, or undef.
#
#   - geoip :: Path to the MaxMind database to use for this set, taken from the
#       set when it names one and from the global web_logs geoip otherwise. May
#       be undef, meaning no geoip lookups.
#
# A missing or malformed web_logs block simply leaves the list empty, and the
# worker then tails nothing.
sub _load_sets {
	my ($self) = @_;

	my $wl = $self->{'app'}->config->{'web_logs'};
	if ( ref($wl) ne 'HASH' ) {
		return;
	}

	my %reserved = ( 'geoip' => 1, 'state_dir' => 1, 'pid_dir' => 1 );
	my $global_geoip = $wl->{'geoip'};

	foreach my $name ( sort keys( %{$wl} ) ) {
		next if ( $reserved{$name} );
		next if ( $self->{'name'} ne 'all' && $name ne $self->{'name'} );
		my $set = $wl->{$name};
		next if ( ref($set) ne 'HASH' );

		push(
			@{ $self->{'sets'} },
			{
				'name'       => $name,
				'access'     => $set->{'access'},
				'error'      => $set->{'error'},
				'vhost'      => $set->{'vhost'},         # may be undef => derive per file
				'vhost_port' => $set->{'vhost_port'},
				'geoip'      => ( exists( $set->{'geoip'} ) ? $set->{'geoip'} : $global_geoip ),
			}
		);
	} ## end foreach my $name ( sort keys...)

	return;
} ## end sub _load_sets

=head2 start

Connects to the database, loads the saved positions, and runs the POE kernel:
one FollowTail wheel per matched file, a periodic re-glob for rotated/new
files, and a periodic checkpoint. Returns when signalled (TERM/INT), after a
final checkpoint.

=cut

sub start {
	my ($self) = @_;

	return $self->start_syslog if ( $self->{'mode'} eq 'syslog' );

	$self->{'dbh'} = $self->{'app'}->connect_dbi;
	$self->_load_positions;

	POE::Session->create(
		'object_states' => [
			$self => {
				'_start'     => '_poe_start',
				'rescan'     => '_rescan',
				'got_line'   => '_got_line',
				'checkpt'    => '_checkpt',
				'tail_error' => '_tail_error',
				'tail_reset' => '_tail_reset',
				'shutdown'   => '_shutdown',
			},
		],
	);

	POE::Kernel->run;

	return 1;
} ## end sub start

=head2 start_syslog

Runs the syslog-mode POE kernel: a unix stream socket that reads JSONL syslog
records (one C<format-json> object per line, as syslog-ng's unix-stream
destination sends) and ingests each via L<Allani::Ingest>. Returns on TERM/INT.

=cut

sub start_syslog {
	my ($self) = @_;

	$self->{'batch_size'}     = $self->_batch_size;
	$self->{'flush_interval'} = $self->_flush_interval;

	$self->{'dbh'}      = $self->{'app'}->connect_dbi;
	$self->{'ingester'} = Allani::Ingest->new(
		'dbh'    => $self->{'dbh'},
		'munger' => $self->{'app'}->build_munger,
	);

	POE::Session->create(
		'object_states' => [
			$self => {
				'_start'       => '_syslog_poe_start',
				'accepted'     => '_syslog_accepted',
				'got_line'     => '_syslog_got_line',
				'flush'        => '_syslog_flush_tick',
				'sock_error'   => '_syslog_sock_error',
				'client_error' => '_syslog_client_error',
				'shutdown'     => '_shutdown',
			},
		],
	);

	POE::Kernel->run;

	return 1;
} ## end sub start_syslog

# The POE _start handler for syslog mode, run once when the session is created.
# It puts the unix socket in place for syslog-ng to connect to, arms the signal
# handlers and the flush timer, and announces itself to syslog.
#
# The run directory is created when missing, and a socket left behind by a
# previous run is unlinked first -- bind would fail against the stale file, and
# nothing else owns that path.
#
#   - $kernel :: The POE kernel, from the KERNEL argument slot.
#
# Returns nothing. It stores the listening SocketFactory as
# $self->{'listener'}, points TERM and INT at the shutdown handler, and starts
# the max-wait flush timer so a partly-filled batch never lingers.
#
# Not called directly; POE dispatches it when start_syslog creates the session.
sub _syslog_poe_start {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	my $dir = $self->_run_dir;
	if ( !-d $dir ) {
		eval { make_path( $dir, { 'mode' => 0755 } ); };
	}

	my $sock = $self->_ingest_socket;
	unlink($sock) if ( -S $sock );    # clear a stale socket from a prior run

	$self->{'listener'} = POE::Wheel::SocketFactory->new(
		'SocketDomain' => PF_UNIX,
		'BindAddress'  => $sock,
		'SuccessEvent' => 'accepted',
		'FailureEvent' => 'sock_error',
	);

	$kernel->sig( 'TERM' => 'shutdown' );
	$kernel->sig( 'INT'  => 'shutdown' );

	# the max-wait timer: flush whatever is buffered every flush_interval
	# seconds so a partly-filled batch never lingers
	$kernel->delay( 'flush' => $self->{'flush_interval'} );

	log_drek(
		'info',
		'syslog ingest listening on '
			. $sock
			. ' (batch '
			. $self->{'batch_size'}
			. ', flush '
			. $self->{'flush_interval'} . 's)',
		undef, 'ishara-syslog'
	);

	return;
} ## end sub _syslog_poe_start

# Writes whatever is buffered when the max-wait timer fires, then re-arms it.
#
# Batching syslog rows is what keeps the insert rate up, but on a quiet host a
# batch might take a long time to fill, and rows should not sit in memory
# waiting. This is the other half of the pair: _syslog_got_line flushes a full
# batch, and this flushes a partial one that has waited long enough. Between
# them, a row is never buffered for longer than flush_interval seconds.
#
#   - $kernel :: The POE kernel, from the KERNEL argument slot.
#
# Returns nothing.
#
# Not called directly; POE dispatches it every flush_interval seconds -- one by
# default, or whatever syslog_flush_interval sets.
sub _syslog_flush_tick {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	$self->{'ingester'}->flush if ( $self->{'ingester'}->pending );
	$kernel->delay( 'flush' => $self->{'flush_interval'} );

	return;
} ## end sub _syslog_flush_tick

# Takes over a connection syslog-ng has just made to the ingest socket and reads
# it line by line. syslog-ng's unix-stream destination sends one format-json
# object per line, so a line filter is all the framing needed.
#
#   - $handle :: The accepted socket handle, from ARG0, handed over by the
#       listening SocketFactory.
#
# Returns nothing. It wraps the handle in a ReadWrite wheel that delivers each
# line to _syslog_got_line, and keeps the wheel in $self->{'clients'} keyed by
# its ID -- both so it stays alive, since a dropped wheel closes the connection,
# and so _syslog_client_error can forget it again on disconnect.
#
# Not called directly; POE dispatches it on each new connection. Several
# connections may be open at once and are handled independently.
sub _syslog_accepted {
	my ( $self, $handle ) = @_[ OBJECT, ARG0 ];

	my $rw = POE::Wheel::ReadWrite->new(
		'Handle'     => $handle,
		'Filter'     => POE::Filter::Line->new,
		'InputEvent' => 'got_line',
		'ErrorEvent' => 'client_error',
	);
	$self->{'clients'}{ $rw->ID } = $rw;

	return;
} ## end sub _syslog_accepted

# Handles one JSON record read from a syslog-ng connection: buffers it, and
# writes the batch out once it is full.
#
# A malformed record is logged and dropped rather than being allowed to
# propagate. queue validates before it buffers, so a bad line dies without ever
# entering the batch and the good lines around it are unaffected -- one broken
# record can never cost the stream.
#
#   - $line :: One line read from the connection, from ARG0, expected to be a
#       single JSON object as syslog-ng's format-json template emits it. Empty
#       and whitespace-only lines are ignored.
#
# Returns nothing. The row joins the batch, and when the batch has reached
# batch_size rows it is written immediately; a batch that never fills is written
# by _syslog_flush_tick instead.
#
# Not called directly; POE dispatches it per line.
sub _syslog_got_line {
	my ( $self, $line ) = @_[ OBJECT, ARG0 ];

	return if ( !defined($line) || $line =~ /\A\s*\z/ );

	# queue dies on a bad line (before buffering it) but never loses a good one;
	# log and carry on so one malformed record can't drop the stream
	eval { $self->{'ingester'}->queue($line); };
	if ($@) {
		log_drek( 'err', 'syslog ingest... ' . $@, undef, 'ishara-syslog' );
		return;
	}

	# flush as soon as the batch is full; the max-wait timer handles the rest
	if ( $self->{'ingester'}->pending >= $self->{'batch_size'} ) {
		$self->{'ingester'}->flush;
	}

	return;
} ## end sub _syslog_got_line

# Forgets a syslog-ng connection that has ended.
#
# The common case here is not an error at all: POE reports an ordinary
# disconnect as an error with errnum 0, and syslog-ng reconnecting is routine.
# Either way the response is the same, so the distinction is not worth drawing
# and nothing is logged. Dropping the wheel closes the handle and releases it.
#
#   - $wheel_id :: The ID of the wheel whose connection ended, from ARG3. The
#       preceding slots hold the failed operation (ARG0), the error number
#       (ARG1), which is 0 for a clean EOF, and the error string (ARG2); none of
#       them are needed.
#
# Returns nothing.
#
# Not called directly; POE dispatches it when a connection closes or fails.
sub _syslog_client_error {
	my ( $self, $wheel_id ) = @_[ OBJECT, ARG3 ];

	# ARG0 op, ARG1 errnum (0 = EOF/disconnect), ARG2 errstr, ARG3 wheel id
	delete $self->{'clients'}{$wheel_id};

	return;
} ## end sub _syslog_client_error

# Logs a failure on the listening socket itself, as opposed to on one
# connection. This is the serious kind: a bind or accept that fails usually
# means the run directory is not writable or the socket path is unusable, and no
# records will arrive until it is fixed.
#
#   - $op :: The operation that failed, from ARG0, e.g. 'bind' or 'accept'.
#
#   - $errnum :: The error number, from ARG1.
#
#   - $errstr :: The human-readable error string, from ARG2.
#
# Returns nothing. The failure is logged to syslog at the err level under the
# ishara-syslog ident. The listener is left in place rather than torn down, so a
# transient failure does not end the worker.
#
# Not called directly; POE dispatches it.
sub _syslog_sock_error {
	my ( $self, $op, $errnum, $errstr ) = @_[ OBJECT, ARG0 .. ARG2 ];

	log_drek( 'err', 'syslog ingest socket ' . $op . ' error... ' . $errstr . ' (' . $errnum . ')',
		undef, 'ishara-syslog' );

	return;
} ## end sub _syslog_sock_error

# The POE _start handler for web mode, run once when the session is created. It
# arms the signal handlers and sets the two recurring jobs going: finding files
# to tail, and checkpointing where each tail has got to.
#
# The first rescan is yielded rather than called so that _start returns promptly
# and the kernel is running before any wheels are opened.
#
#   - $kernel :: The POE kernel, from the KERNEL argument slot.
#
# Returns nothing. TERM and INT are pointed at the shutdown handler, the first
# rescan is queued immediately, and the first checkpoint is scheduled for thirty
# seconds out.
#
# Not called directly; POE dispatches it when start creates the session.
sub _poe_start {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	$kernel->sig( 'TERM' => 'shutdown' );
	$kernel->sig( 'INT'  => 'shutdown' );
	$kernel->yield('rescan');
	$kernel->delay( 'checkpt' => 30 );

	return;
} ## end sub _poe_start

# Finds the files that should be tailed and opens a wheel for any that is not
# already being followed.
#
# This runs on start and then once a minute, which is what lets a worker cope
# with logs that come and go: a newly configured vhost, a log created after the
# worker started, or a rotation that produces a fresh dated filename all get
# picked up on the next pass without a restart. Files already being tailed are
# skipped, so re-running it is harmless.
#
# A new wheel starts from the saved offset when there is one, so a restart
# resumes exactly where the previous run stopped rather than replaying the file
# or skipping to its end. Each file's wheel is paired with the ingester matching
# its set, kind, and vhost.
#
#   - $kernel :: The POE kernel, from the KERNEL argument slot.
#
# Returns nothing. For every file matched by a set's access or error glob it
# records an entry in $self->{'wheels'}, keyed by wheel ID, holding:
#
#   - wheel :: The POE::Wheel::FollowTail reading the file.
#
#   - file :: The path being tailed, used when reporting errors and when
#       checkpointing.
#
#   - ingester :: The Allani::Ingest::HttpAccess or Allani::Ingest::HttpError
#       object each line from this file is handed to.
#
# It also notes the file in $self->{'by_file'} so later passes skip it, and
# schedules itself to run again in sixty seconds.
#
# Not called directly; POE dispatches it.
sub _rescan {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	foreach my $set ( @{ $self->{'sets'} } ) {
		foreach my $kind (qw(access error)) {
			my $pattern = $set->{$kind};
			next if ( !defined($pattern) );

			foreach my $file ( glob($pattern) ) {
				next if ( $self->{'by_file'}{$file} );
				next if ( !-f $file );

				my ( $vhost, $port ) = $self->_resolve_vhost( $set, $kind, $file );

				my $seek = $self->_seek_for($file);
				my $wheel = POE::Wheel::FollowTail->new(
					'Filename'   => $file,
					'InputEvent' => 'got_line',
					'ErrorEvent' => 'tail_error',
					'ResetEvent' => 'tail_reset',
					( defined($seek) ? ( 'Seek' => $seek ) : () ),
				);

				$self->{'wheels'}{ $wheel->ID } = {
					'wheel'    => $wheel,
					'file'     => $file,
					'ingester' => $self->_ingester( $set, $kind, $vhost, $port ),
				};
				$self->{'by_file'}{$file} = $wheel->ID;
			} ## end foreach my $file ( glob($pattern...))
		} ## end foreach my $kind (qw(access error))
	} ## end foreach my $set ( @{ $self->{'sets'} } )

	$kernel->delay( 'rescan' => 60 );

	return;
} ## end sub _rescan

# Handles one line read from a tailed web log: hands it to the ingester paired
# with that file, which parses and inserts it.
#
# A failure here is always a database problem, never a parsing one -- a line the
# munger cannot make sense of becomes a row with null columns rather than an
# error -- so it is warned about and stepped over. The warning goes to stderr,
# which the manager captures into syslog. A database that is genuinely down will
# produce one of these per line until it returns, which is noisy but preferable
# to the worker exiting and losing its place.
#
#   - $line :: One line read from the file, from ARG0, already stripped of its
#       newline by the wheel.
#
#   - $wheel_id :: The ID of the wheel that read it, from ARG1, used to find the
#       file and its ingester in $self->{'wheels'}. A line from a wheel that has
#       already been forgotten is dropped.
#
# Returns nothing.
#
# Not called directly; POE dispatches it per line.
sub _got_line {
	my ( $self, $line, $wheel_id ) = @_[ OBJECT, ARG0, ARG1 ];

	my $w = $self->{'wheels'}{$wheel_id};
	return if ( !defined($w) );

	# ingest_line only dies on a database error; a parse miss is a null-column
	# row, so one bad line never takes Ishara down
	eval { $w->{'ingester'}->ingest_line($line); };
	if ($@) {
		warn( 'ishara: ' . $w->{'file'} . ': ' . $@ );
	}

	return;
} ## end sub _got_line

# Reports a read failure on a tailed file. Typically a permissions change or a
# filesystem that has gone away underneath the worker.
#
# The wheel is left in place rather than closed, since the condition is often
# temporary and the wheel recovers on its own once the file is readable again.
#
#   - $operation :: The operation that failed, from ARG0, e.g. 'read'.
#
#   - $errnum :: The error number, from ARG1.
#
#   - $errstr :: The human-readable error string, from ARG2.
#
#   - $wheel_id :: The ID of the wheel that failed, from ARG3, used to name the
#       file; a wheel that has already been forgotten reports as '?'.
#
# Returns nothing. The failure is warned to stderr, which the manager captures
# into syslog.
#
# Not called directly; POE dispatches it.
sub _tail_error {
	my ( $self, $operation, $errnum, $errstr, $wheel_id ) = @_[ OBJECT, ARG0 .. ARG3 ];

	my $w    = $self->{'wheels'}{$wheel_id};
	my $file = defined($w) ? $w->{'file'} : '?';
	warn( 'ishara: tail ' . $operation . ' error on "' . $file . '": ' . $errnum . ' ' . $errstr );

	return;
} ## end sub _tail_error

# Acknowledges that a tailed file has been rotated or truncated. It exists only
# because POE requires a handler for the event; there is genuinely nothing to
# do. FollowTail notices the file it holds is no longer the file at that path,
# reopens it, and carries on from the top of the new one by itself.
#
# The saved offset is not cleared here, and does not need to be: the next
# checkpoint overwrites it with the new file's offset and inode, and _seek_for
# compares inodes anyway, so a stale entry could not cause a wheel to seek into
# the wrong file.
#
# Takes no arguments, and ignores the ones POE passes.
#
# Returns nothing.
#
# Not called directly; POE dispatches it when a rotation is detected.
sub _tail_reset {

	# FollowTail reopened a rotated/truncated file; nothing to do, it resumes
	# from the top of the new file on its own
	return;
}

# Checkpoints on the timer, then re-arms it, so that offsets reach disk
# regularly rather than only at shutdown. Without this, a worker killed outright
# -- rather than asked to stop -- would resume from wherever it last managed to
# write, so the interval bounds how much a hard kill can cost.
#
#   - $kernel :: The POE kernel, from the KERNEL argument slot.
#
# Returns nothing.
#
# Not called directly; POE dispatches it every thirty seconds.
sub _checkpt {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	$self->checkpoint;
	$kernel->delay( 'checkpt' => 30 );

	return;
} ## end sub _checkpt

# Shuts the worker down cleanly on TERM or INT, saving whatever would otherwise
# be lost. This is why the manager TERMs its workers rather than killing them.
#
# What needs saving depends on the mode. A web worker's value is in its tail
# offsets, so it checkpoints, and a restart then resumes at the exact byte
# rather than replaying the file or skipping what arrived while it was down. A
# syslog worker's value is in its buffered rows, so it flushes them, and it
# unlinks the ingest socket on the way out so the path is clear for the next
# run.
#
# Shared by both modes' sessions.
#
#   - $kernel :: The POE kernel, from the KERNEL argument slot.
#
# Returns nothing. After the mode-specific save, the wheels, client
# connections, and listener are dropped -- which closes their handles -- and the
# kernel is stopped, which returns control to start or start_syslog and from
# there to the caller.
#
# Not called directly; POE dispatches it on TERM or INT.
sub _shutdown {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	if ( $self->{'mode'} eq 'web' ) {
		$self->checkpoint;    # persist tail offsets so a restart resumes exactly
	} elsif ( $self->{'mode'} eq 'syslog' ) {
		$self->{'ingester'}->flush if ( defined( $self->{'ingester'} ) );    # write anything still buffered
		unlink( $self->_ingest_socket ) if ( -S $self->_ingest_socket );
	}

	delete $self->{'wheels'};
	delete $self->{'clients'};
	delete $self->{'listener'};
	$kernel->stop;

	return;
} ## end sub _shutdown

# Returns the enricher to use for a given geoip database, building it the first
# time and reusing it after.
#
# Compiling the rule set and opening the MaxMind database is not free, and a
# worker following several sets would otherwise pay for it once per set. Since
# the geoip path is the only thing that varies between them, one munger per
# distinct path is enough, and sets sharing a database share an enricher.
#
#   - $geoip :: Path to a MaxMind .mmdb file, or undef for no geoip lookups.
#       Undef is cached under the empty string, so the no-geoip enricher is
#       built once as well.
#
# Returns a Log::Munger object, or undef when enrichment is disabled altogether
# -- that is, when no munger_rules are configured. Undef is cached like any
# other value, so a disabled enricher is not rebuilt on every call.
#
#     my $munger = $self->_munger_for('/usr/local/share/GeoIP/GeoLite2-City.mmdb');
#     my $plain  = $self->_munger_for(undef);
sub _munger_for {
	my ( $self, $geoip ) = @_;

	my $key = defined($geoip) ? $geoip : '';
	if ( !exists( $self->{'mungers'}{$key} ) ) {
		$self->{'mungers'}{$key} = $self->{'app'}->build_munger( 'geoip' => $geoip );
	}

	return $self->{'mungers'}{$key};
} ## end sub _munger_for

# Returns the ingester for one combination of set, log kind, vhost, and port,
# building it the first time and reusing it after.
#
# An ingester carries the tags applied to every row it writes along with a
# prepared statement, so it can only serve rows sharing those tags -- hence one
# per combination rather than one per worker. Several files often map to the
# same combination, though: a set whose glob matches both the current log and
# yesterday's rotated one has two wheels feeding one ingester, which is the
# point of caching them.
#
#   - $set :: The set hash ref from $self->{'sets'}, used for its name and its
#       geoip path.
#
#   - $kind :: Which log this is, 'access' or 'error'. It decides the class:
#       Allani::Ingest::HttpAccess for access, Allani::Ingest::HttpError
#       otherwise.
#
#   - $vhost :: The vhost to tag rows with, from _resolve_vhost. May be undef.
#
#   - $port :: The port to tag rows with, from _resolve_vhost. May be undef.
#
# Returns the ingester object, which is cached under a key joining the four
# arguments so undef vhosts and ports stay distinct from empty ones.
#
#     my $ingester = $self->_ingester( $set, 'access', 'www.example.com', 443 );
sub _ingester {
	my ( $self, $set, $kind, $vhost, $port ) = @_;

	my $key = join( '/', $set->{'name'}, $kind, ( defined($vhost) ? $vhost : '' ), ( defined($port) ? $port : '' ) );
	if ( !exists( $self->{'ingesters'}{$key} ) ) {
		my $class = ( $kind eq 'access' ) ? 'Allani::Ingest::HttpAccess' : 'Allani::Ingest::HttpError';
		$self->{'ingesters'}{$key} = $class->new(
			'dbh'        => $self->{'dbh'},
			'munger'     => $self->_munger_for( $set->{'geoip'} ),
			'host'       => $self->{'hostname'},
			'vhost'      => $vhost,
			'vhost_port' => $port,
		);
	} ## end if ( !exists( $self->{'ingesters'...}))

	return $self->{'ingesters'}{$key};
} ## end sub _ingester

# Works out which vhost and port to tag the rows from one file with.
#
# A bare access or error line carries no vhost, so it has to come from
# somewhere else. A set may simply name one, which is right when the set covers
# a single site. The more common arrangement is one directory or filename per
# vhost, matched by a glob, and there the wildcard has already captured the
# vhost -- so a pattern like /var/log/apache2/*/access.log applied to
# /var/log/apache2/www.example.com/access.log yields www.example.com without
# anything needing to be configured per site.
#
# Apache commonly writes such directories as host:port, so a trailing colon and
# digits are split off as the port.
#
#   - $set :: The set hash ref from $self->{'sets'}.
#
#   - $kind :: Which log this is, 'access' or 'error', naming the glob pattern
#       in the set to compare the path against.
#
#   - $file :: The path matched by that pattern.
#
# Returns the two-element list ( $vhost, $port ). An explicit vhost on the set
# wins outright and is returned with the set's vhost_port. Otherwise the vhost
# is what the wildcards matched, falling back to the set's own name when the
# pattern has no wildcard or does not match; the port is taken from the captured
# text when it ends in a colon and digits, and from the set's vhost_port
# otherwise. Either may be undef, which stores as SQL NULL.
#
#     # set { name => 'foo', access => '/var/log/apache2/*/access.log' }
#     $self->_resolve_vhost( $set, 'access', '/var/log/apache2/www.example.com/access.log' );
#     # ( 'www.example.com', undef )
#
#     $self->_resolve_vhost( $set, 'access', '/var/log/apache2/www.example.com:443/access.log' );
#     # ( 'www.example.com', 443 )
sub _resolve_vhost {
	my ( $self, $set, $kind, $file ) = @_;

	if ( defined( $set->{'vhost'} ) ) {
		return ( $set->{'vhost'}, $set->{'vhost_port'} );
	}

	my $name = _glob_capture( $set->{$kind}, $file );
	if ( !defined($name) || $name eq '' ) {
		$name = $set->{'name'};
	}
	if ( $name =~ /\A(.*):(\d+)\z/ ) {
		return ( $1, $2 );
	}

	return ( $name, $set->{'vhost_port'} );
} ## end sub _resolve_vhost

# Recovers the text a glob's wildcards matched in a path, which glob itself does
# not report. This is how _resolve_vhost derives a vhost from a filename: the
# pattern is translated into an equivalent regular expression with the wildcards
# turned into capture groups, and the path is matched against it.
#
# One '*' is the intended case. Several are allowed and their captures are
# concatenated, which is rarely what anyone wants but is better than failing.
#
#   - $pattern :: The glob pattern, e.g. '/var/log/apache2/*/access.log'. Only
#       '*' and '?' are treated as wildcards; everything else, character classes
#       included, is matched literally.
#
#   - $file :: A path the pattern matched.
#
# Not method arguments -- this is a plain function.
#
# Returns the text the wildcards matched, or undef when either argument is
# undef, when the pattern has no wildcard at all, or when the path does not
# actually match. A pattern with no wildcard returns undef deliberately rather
# than the empty string: there is nothing to capture, and a match without
# capture groups would otherwise yield a 1, which is not a name.
#
#     _glob_capture( '/var/log/apache2/*/access.log',
#                    '/var/log/apache2/www.example.com/access.log' );
#     # 'www.example.com'
#
#     _glob_capture( '/var/log/messages', '/var/log/messages' );   # undef
sub _glob_capture {
	my ( $pattern, $file ) = @_;

	return undef if ( !defined($pattern) || !defined($file) );

	my $re       = '';
	my $has_wild = 0;
	foreach my $ch ( split( //, $pattern ) ) {
		if    ( $ch eq '*' ) { $re .= '(.*)'; $has_wild = 1; }
		elsif ( $ch eq '?' ) { $re .= '(.)';  $has_wild = 1; }
		else                 { $re .= quotemeta($ch); }
	}

	# no wildcard => nothing to capture (and a captureless match would return
	# (1) in list context, which is not a name)
	return undef if ( !$has_wild );

	my @caps = ( $file =~ /\A$re\z/ );
	return undef if ( !@caps );

	return join( '', @caps );
} ## end sub _glob_capture

=head2 pid_path

The PID file path for this instance: C<< <run_dir>/ishara.<name>.pid >>.

=cut

sub pid_path {
	my ($self) = @_;

	return $self->_run_dir . '/ishara.' . $self->{'name'} . '.pid';
}

# The directory holding the runtime files -- PID files and sockets -- that exist
# only while something is running. Set with the top-level run_dir config key,
# which the manager reads too, so both agree on where to look.
#
# Takes no arguments.
#
# Returns the configured path, or '/var/run/allani' when run_dir is not set. No
# trailing slash, and the directory is not created here; whoever writes into it
# does that.
#
#     my $dir = $self->_run_dir;    # '/var/run/allani'
sub _run_dir {
	my ($self) = @_;

	my $config = $self->{'app'}->config;
	return ( defined( $config->{'run_dir'} ) ) ? $config->{'run_dir'} : '/var/run/allani';
}

# The unix socket syslog-ng connects to in syslog mode. Set with the top-level
# syslog_socket config key, whose presence is also what tells the manager to run
# a syslog worker at all.
#
# Takes no arguments.
#
# Returns the configured path, or 'syslog.ingest.sock' inside the run directory
# when syslog_socket is not set. The path must match the unix-stream destination
# in the syslog-ng config, since that is the other end of it.
#
#     my $sock = $self->_ingest_socket;    # '/var/run/allani/syslog.ingest.sock'
sub _ingest_socket {
	my ($self) = @_;

	my $config = $self->{'app'}->config;
	return ( defined( $config->{'syslog_socket'} ) )
		? $config->{'syslog_socket'}
		: ( $self->_run_dir . '/syslog.ingest.sock' );
} ## end sub _ingest_socket

# How many rows to buffer before writing them in one multi-row INSERT. Set with
# the top-level syslog_batch_size config key.
#
# Larger batches mean fewer round trips and a higher sustained insert rate, at
# the cost of more rows in memory and more lost if the worker is killed outright
# rather than asked to stop. The default suits a busy host; there is little
# reason to change it unless memory is tight.
#
# Takes no arguments.
#
# Returns the configured number, or 1000 when the key is unset or not a positive
# number.
#
#     my $size = $self->_batch_size;    # 1000
sub _batch_size {
	my ($self) = @_;

	my $v = $self->{'app'}->config->{'syslog_batch_size'};
	return ( defined($v) && $v > 0 ) ? $v : 1000;
}

# How long, in seconds, a partly-filled batch may wait before being written
# anyway. Set with the top-level syslog_flush_interval config key.
#
# This bounds how stale the table can be on a quiet host, where a batch might
# otherwise take a long time to fill. The default keeps rows visible almost
# immediately; raising it trades freshness for fewer writes.
#
# Takes no arguments.
#
# Returns the configured number of seconds, or 1 when the key is unset or not a
# positive number.
#
#     my $interval = $self->_flush_interval;    # 1
sub _flush_interval {
	my ($self) = @_;

	my $v = $self->{'app'}->config->{'syslog_flush_interval'};
	return ( defined($v) && $v > 0 ) ? $v : 1;
}

# The directory holding the position tablets. Set with the state_dir key inside
# the web_logs block, which is why it is read from there rather than from the
# top level.
#
# Unlike the run directory this holds state that must outlive the process: lose
# it and every worker restarts by tailing from the end of its files, silently
# skipping whatever arrived while it was down.
#
# Takes no arguments.
#
# Returns the configured path, or '/var/db/allani' when web_logs has no
# state_dir. The directory is created, mode 0700, by _write_positions when it
# first needs it.
#
#     my $dir = $self->_state_dir;    # '/var/db/allani'
sub _state_dir {
	my ($self) = @_;

	my $wl = $self->{'app'}->config->{'web_logs'};
	return ( ref($wl) eq 'HASH' && defined( $wl->{'state_dir'} ) ) ? $wl->{'state_dir'} : '/var/db/allani';
}

# Where this instance's position tablet lives. The name carries the instance
# name, so the workers the manager runs -- one per web_logs set -- each keep
# their own tablet and never overwrite one another's.
#
# Takes no arguments.
#
# Returns the full path, 'ishara.<name>.positions.csv' inside the state
# directory.
#
#     my $path = $self->_tablet_path;
#     # '/var/db/allani/ishara.foo.positions.csv'
sub _tablet_path {
	my ($self) = @_;

	return $self->_state_dir . '/ishara.' . $self->{'name'} . '.positions.csv';
}

=head2 checkpoint

Snapshots every wheel's current offset and writes the position tablet
atomically (temp file + rename). Called on a timer and on shutdown. A failed
checkpoint is logged, never fatal.

=cut

sub checkpoint {
	my ($self) = @_;

	$self->_snapshot_positions;
	$self->_write_positions;

	return;
} ## end sub checkpoint

# Records where each live wheel has read to, into the in-memory position map
# that _write_positions then puts on disk.
#
# The inode is stored alongside the offset because an offset alone is not enough
# to resume safely: after a rotation the same path is a different file, and
# seeking to the old offset would skip past real log lines. _seek_for compares
# the inode to catch exactly that.
#
# Entries are only ever added or updated, never removed, so a file that has
# stopped being tailed keeps its last known position and can still be resumed if
# it comes back.
#
# Takes no arguments.
#
# Returns nothing. For each wheel whose offset and inode can both be read it
# sets $self->{'positions'}{$file} to a hash ref of:
#
#   - inode :: The file's inode number at the time of the snapshot.
#
#   - offset :: The byte offset the wheel has read to.
#
# A file that has been unlinked, or a wheel that cannot report an offset, is
# skipped rather than being recorded with a missing half.
sub _snapshot_positions {
	my ($self) = @_;

	foreach my $id ( keys( %{ $self->{'wheels'} } ) ) {
		my $w = $self->{'wheels'}{$id};
		my $offset;
		eval { $offset = $w->{'wheel'}->tell; };
		my $inode = ( stat( $w->{'file'} ) )[1];
		if ( defined($offset) && defined($inode) ) {
			$self->{'positions'}{ $w->{'file'} } = { 'inode' => $inode, 'offset' => $offset };
		}
	} ## end foreach my $id ( keys( %{ $self...}))

	return;
} ## end sub _snapshot_positions

# Writes the in-memory position map to disk as this instance's tablet.
#
# The write goes to a temporary file which is then renamed over the real one, so
# the tablet is only ever replaced whole. A worker killed mid-write therefore
# leaves the previous tablet intact rather than a half-written one, and a
# half-written tablet is precisely what would make the next start resume from a
# nonsensical offset.
#
# A failed write is warned about but never fatal. Losing a checkpoint costs at
# most some replayed or skipped lines at the next restart, which is not worth
# taking the worker down for -- and the next checkpoint, thirty seconds later,
# may well succeed.
#
# Takes no arguments.
#
# Returns nothing. The state directory is created, mode 0700, when missing. The
# file written is CSV with a 'file,inode,offset' header and one row per known
# file, sorted by path; only the path is escaped, since it is the one field that
# can hold a comma, a quote, or a newline.
#
#     file,inode,offset
#     /var/log/apache2/www.example.com/access.log,1234567,90210
sub _write_positions {
	my ($self) = @_;

	my $dir = $self->_state_dir;
	if ( !-d $dir ) {
		eval { make_path( $dir, { 'mode' => 0700 } ); };
	}

	my $path = $self->_tablet_path;
	eval {
		my $tmp = $path . '.tmp';
		open( my $fh, '>', $tmp ) || die( 'open failed... ' . $! );
		print $fh "file,inode,offset\n";
		foreach my $file ( sort keys( %{ $self->{'positions'} } ) ) {
			my $p = $self->{'positions'}{$file};
			print $fh join( ',', _csv_escape($file), $p->{'inode'}, $p->{'offset'} ) . "\n";
		}
		close($fh);
		rename( $tmp, $path ) || die( 'rename failed... ' . $! );
	};
	if ($@) {
		warn( 'ishara: writing the position tablet "' . $path . '" failed... ' . $@ );
	}

	return;
} ## end sub _write_positions

# Reads this instance's position tablet back into memory, so that the wheels
# _rescan opens can seek to where the previous run left off. Called once from
# start, before the kernel runs.
#
# A missing tablet is not an error, just a fresh start -- the worker then tails
# from the end of each file, as it does the first time it ever runs. A tablet
# that cannot be read is warned about and treated the same way, since refusing
# to start over a lost checkpoint would help nobody.
#
# Takes no arguments.
#
# Returns nothing. Each parseable row becomes an entry in
# $self->{'positions'}, keyed by the unescaped path, holding the inode and
# offset that _seek_for then judges. The header row and blank lines are skipped,
# as is any row that does not parse, so a partly damaged tablet still yields the
# positions it can.
sub _load_positions {
	my ($self) = @_;

	my $path = $self->_tablet_path;
	return if ( !-f $path );

	eval {
		open( my $fh, '<', $path ) || die( 'open failed... ' . $! );
		while ( my $line = <$fh> ) {
			chomp($line);
			next if ( $line eq '' || $line =~ /^file,inode,offset$/ );
			my ( $file, $inode, $offset ) = _csv_split($line);
			next if ( !defined($file) || !defined($offset) );
			$self->{'positions'}{ _csv_unescape($file) } = { 'inode' => $inode, 'offset' => $offset };
		}
		close($fh);
	};
	if ($@) {
		warn( 'ishara: reading the position tablet "' . $path . '" failed... ' . $@ );
	}

	return;
} ## end sub _load_positions

# Decides where a new wheel should start reading a file, which is the whole
# point of keeping the position tablet. The same rule as Baphomet's galla.
#
# Three cases, and the distinction between them matters. A file that is
# recognisably the same one -- same inode, and no shorter than the saved offset
# -- is resumed at that offset, so nothing is replayed or missed across a
# restart. A file that has been rotated or truncated is a different file wearing
# a familiar name, so it starts at the beginning. A file with no saved position
# is new to this worker and starts at the end, since its existing contents are
# history rather than something to ingest.
#
#   - $file :: The path a wheel is about to be opened on.
#
# Returns the byte offset to seek to: the saved offset to resume, or 0 to read
# from the beginning. Returns undef when there is no saved position or the file
# cannot be stat'ed, which _rescan passes on by omitting the Seek argument
# entirely, leaving FollowTail to start at the end of the file.
#
#     $self->_seek_for('/var/log/apache2/access.log');   # 90210, resuming
sub _seek_for {
	my ( $self, $file ) = @_;

	my $pos = $self->{'positions'}{$file};
	if ( !defined($pos) || !-f $file ) {
		return undef;
	}

	my ( $inode, $size ) = ( stat($file) )[ 1, 7 ];
	if ( !defined($inode) ) {
		return undef;
	}

	if ( $inode == $pos->{'inode'} && $size >= $pos->{'offset'} ) {
		return $pos->{'offset'};
	}

	return 0;
} ## end sub _seek_for

# Escapes a file path for the position tablet. Only the path needs this; the
# inode and offset beside it are always plain integers, which is why the tablet
# uses these three small helpers rather than a CSV module.
#
#   - $value :: The file path to write. Not a method argument -- this is a plain
#       function.
#
# Returns the path unchanged when it holds nothing that would confuse the
# format, and otherwise the path wrapped in double quotes with any embedded
# quote doubled, per the usual CSV convention. _csv_unescape reverses it.
#
#     _csv_escape('/var/log/messages');          # '/var/log/messages'
#     _csv_escape('/var/log/odd,name.log');      # '"/var/log/odd,name.log"'
#     _csv_escape('/var/log/say "hi".log');      # '"/var/log/say ""hi"".log"'
sub _csv_escape {
	my ($value) = @_;
	if ( $value =~ /[",\r\n]/ ) {
		$value =~ s/"/""/g;
		return '"' . $value . '"';
	}
	return $value;
}

# Reverses _csv_escape, turning a path field read back from the tablet into the
# path it stands for.
#
#   - $value :: The path field as it appeared in the file, quoted or not. Not a
#       method argument -- this is a plain function.
#
# Returns the path with its surrounding quotes removed and any doubled quote
# collapsed back to one. A value that is not quoted is returned unchanged, so
# running this over an unescaped path is harmless.
#
#     _csv_unescape('/var/log/messages');             # '/var/log/messages'
#     _csv_unescape('"/var/log/odd,name.log"');       # '/var/log/odd,name.log'
#     _csv_unescape('"/var/log/say ""hi"".log"');     # '/var/log/say "hi".log'
sub _csv_unescape {
	my ($value) = @_;
	if ( $value =~ /\A"(.*)"\z/s ) {
		$value = $1;
		$value =~ s/""/"/g;
	}
	return $value;
}

# Splits one row of the position tablet into its three fields.
#
# The path is matched first and may be a quoted value holding commas or quotes,
# while the inode and offset are anchored to the end of the line as plain
# integers. Anchoring them that way is what keeps a comma inside an unquoted
# path from being mistaken for a field separator.
#
#   - $line :: One row from the tablet, already chomped, in the form
#       'file,inode,offset'. Not a method argument -- this is a plain function.
#
# Returns the three-element list ( $file, $inode, $offset ), where the path is
# still escaped and the caller passes it through _csv_unescape. Returns the
# empty list when the row does not parse, which _load_positions treats as a row
# to skip.
#
#     _csv_split('/var/log/messages,1234567,90210');
#     # ( '/var/log/messages', '1234567', '90210' )
sub _csv_split {
	my ($line) = @_;

	if ( $line =~ /\A(".*?(?:""|[^"])*"|[^,]*),(\d+),(\d+)\z/ ) {
		return ( $1, $2, $3 );
	}

	return ();
} ## end sub _csv_split

1;
