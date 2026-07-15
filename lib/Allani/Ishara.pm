package Allani::Ishara;

use 5.006;
use strict;
use warnings;
use POE qw( Wheel::FollowTail );
use Sys::Hostname qw(hostname);
use File::Path qw(make_path);
use Allani::Ingest::HttpAccess ();
use Allani::Ingest::HttpError  ();

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

=cut

sub new {
	my ( $blank, %opts ) = @_;

	if ( !defined( $opts{'app'} ) ) {
		die('app is undef');
	}

	my $self = {
		'app'       => $opts{'app'},
		'name'      => ( defined( $opts{'name'} ) && $opts{'name'} ne '' ) ? $opts{'name'} : 'all',
		'hostname'  => hostname(),
		'sets'      => [],       # parsed web_logs sets
		'mungers'   => {},       # geoip path (or '') => Log::Munger
		'ingesters' => {},       # "set/kind/vhost/port" => Ingest object
		'wheels'    => {},       # wheel id => { wheel, file, ingester }
		'by_file'   => {},       # file => wheel id (already tailing?)
		'positions' => {},       # file => { inode, offset }
		'dbh'       => undef,
	};
	bless $self;

	$self->_load_sets;

	return $self;
} ## end sub new

# web_logs -> sets. 'geoip'/'state_dir'/'pid_dir' are reserved; every other
# key is a set. --name filters to one set unless it is 'all'.
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

sub _poe_start {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	$kernel->sig( 'TERM' => 'shutdown' );
	$kernel->sig( 'INT'  => 'shutdown' );
	$kernel->yield('rescan');
	$kernel->delay( 'checkpt' => 30 );

	return;
} ## end sub _poe_start

# glob each set's patterns and open a FollowTail wheel for any file not already
# tailed. Runs on start and on a timer, so rotated / newly created logs get
# picked up. A new wheel seeks to the saved offset (resume) when there is one.
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

sub _tail_error {
	my ( $self, $operation, $errnum, $errstr, $wheel_id ) = @_[ OBJECT, ARG0 .. ARG3 ];

	my $w    = $self->{'wheels'}{$wheel_id};
	my $file = defined($w) ? $w->{'file'} : '?';
	warn( 'ishara: tail ' . $operation . ' error on "' . $file . '": ' . $errnum . ' ' . $errstr );

	return;
} ## end sub _tail_error

sub _tail_reset {

	# FollowTail reopened a rotated/truncated file; nothing to do, it resumes
	# from the top of the new file on its own
	return;
}

sub _checkpt {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	$self->checkpoint;
	$kernel->delay( 'checkpt' => 30 );

	return;
} ## end sub _checkpt

sub _shutdown {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

	$self->checkpoint;
	delete $self->{'wheels'};
	$kernel->stop;

	return;
} ## end sub _shutdown

# one munger per distinct geoip value (compiling the rules is not free)
sub _munger_for {
	my ( $self, $geoip ) = @_;

	my $key = defined($geoip) ? $geoip : '';
	if ( !exists( $self->{'mungers'}{$key} ) ) {
		$self->{'mungers'}{$key} = $self->{'app'}->build_munger( 'geoip' => $geoip );
	}

	return $self->{'mungers'}{$key};
} ## end sub _munger_for

# one ingester per (set, kind, vhost, port): holds the tags + munger + sth
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

# resolve (vhost, port) for one matched file: an explicit set vhost wins;
# otherwise the wildcard portion of the filename is the vhost, with a ':'
# splitting off the port
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

# given a glob pattern and a path it matched, return the text the wildcards
# matched (a single '*' is the intended case; multiple wildcards concatenate)
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

The PID file path for this instance:
C<< <pid_dir>/ishara.<name>.pid >> (default pid_dir C</var/run>).

=cut

sub pid_path {
	my ($self) = @_;

	my $wl      = $self->{'app'}->config->{'web_logs'};
	my $pid_dir = ( ref($wl) eq 'HASH' && defined( $wl->{'pid_dir'} ) ) ? $wl->{'pid_dir'} : '/var/run';

	return $pid_dir . '/ishara.' . $self->{'name'} . '.pid';
} ## end sub pid_path

# the state directory holding the position tablets
sub _state_dir {
	my ($self) = @_;

	my $wl = $self->{'app'}->config->{'web_logs'};
	return ( ref($wl) eq 'HASH' && defined( $wl->{'state_dir'} ) ) ? $wl->{'state_dir'} : '/var/db/allani';
}

# the position tablet path for this instance
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

# record each live wheel's offset (via tell) and the file's inode
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

# atomically write the positions tablet: file,inode,offset (path csv-escaped)
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

=head2 load_positions

Reads the position tablet back into memory (used at start so new wheels can
seek). A missing tablet is a fresh start. Also callable directly for testing.

=cut

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

# same rule as Baphomet's galla: same inode and the file has not shrunk =>
# resume at the saved offset; a rotated/truncated file starts at 0; an unknown
# file returns undef so FollowTail tails from EOF
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

# minimal CSV escaping for the file path (only field that can hold a comma or
# newline); inode/offset are always plain integers
sub _csv_escape {
	my ($value) = @_;
	if ( $value =~ /[",\r\n]/ ) {
		$value =~ s/"/""/g;
		return '"' . $value . '"';
	}
	return $value;
}

sub _csv_unescape {
	my ($value) = @_;
	if ( $value =~ /\A"(.*)"\z/s ) {
		$value = $1;
		$value =~ s/""/"/g;
	}
	return $value;
}

# split a positions row into (file, inode, offset); the file field may be a
# quoted CSV value, inode/offset are the last two plain integer fields
sub _csv_split {
	my ($line) = @_;

	if ( $line =~ /\A(".*?(?:""|[^"])*"|[^,]*),(\d+),(\d+)\z/ ) {
		return ( $1, $2, $3 );
	}

	return ();
} ## end sub _csv_split

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

1;
