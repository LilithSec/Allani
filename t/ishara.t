#!perl
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);

BEGIN {
	use_ok('Allani');
	use_ok('Allani::Ishara');
}

# build an Ishara over a given web_logs config, without connecting to anything
sub ishara {
	my ( $web_logs, $name ) = @_;
	my $app = bless { 'allani' => { 'config' => { 'web_logs' => $web_logs } } }, 'Allani';
	return Allani::Ishara->new( 'app' => $app, 'name' => ( defined($name) ? $name : 'all' ) );
}

# ---- _glob_capture -----------------------------------------------------------

{
	my $c = \&Allani::Ishara::_glob_capture;
	is( $c->( '/var/log/apache2/*-access.log', '/var/log/apache2/www.example.com:443-access.log' ),
		'www.example.com:443', 'single * captures the wildcard text (with :port)' );
	is( $c->( '/var/log/nginx/*.access.log', '/var/log/nginx/blog.example.org.access.log' ),
		'blog.example.org', 'single * captures the vhost' );
	is( $c->( '/var/log/*/*.log', '/var/log/foo/bar.log' ), 'foobar', 'multiple wildcards concatenate' );
	is( $c->( '/var/log/fixed.log', '/var/log/other.log' ), undef, 'a non-match returns undef' );
}

# ---- _resolve_vhost ----------------------------------------------------------

subtest 'vhost resolution' => sub {
	my $ish = ishara( {} );

	my $derived = { 'name' => 'foo', 'access' => '/var/log/apache2/*-access.log', 'vhost' => undef };
	my ( $v, $p ) = $ish->_resolve_vhost( $derived, 'access', '/var/log/apache2/www.example.com:443-access.log' );
	is( $v, 'www.example.com', 'derived vhost from glob' );
	is( $p, '443',             'derived port from the : in the name' );

	( $v, $p ) = $ish->_resolve_vhost( $derived, 'access', '/var/log/apache2/plain.example-access.log' );
	is( $v, 'plain.example', 'derived vhost, no port' );
	is( $p, undef,           'no port when there is no colon' );

	my $explicit = { 'name' => 'foo', 'access' => '/var/log/apache2/*-access.log',
		'vhost' => 'set.example', 'vhost_port' => 8080 };
	( $v, $p ) = $ish->_resolve_vhost( $explicit, 'access', '/var/log/apache2/whatever-access.log' );
	is( $v, 'set.example', 'explicit vhost wins over the glob' );
	is( $p, 8080,          'explicit port' );

	# a fixed (wildcardless) glob falls back to the set name
	my $fixed = { 'name' => 'thename', 'access' => '/var/log/only.log', 'vhost' => undef };
	( $v, $p ) = $ish->_resolve_vhost( $fixed, 'access', '/var/log/only.log' );
	is( $v, 'thename', 'no wildcard => set name is the vhost' );
};

# ---- _load_sets: reserved keys, geoip inheritance, --name filter -------------

subtest 'set loading' => sub {
	my $web_logs = {
		'geoip'     => '/global.mmdb',
		'state_dir' => '/tmp/whatever',
		'foo'       => { 'access' => '/a/*.log', 'error' => '/ae/*.log', 'geoip' => '/foo.mmdb' },
		'bar'       => { 'access' => '/b/*.log', 'error' => '/be/*.log' },
	};

	my $all = ishara( $web_logs, 'all' );
	is( scalar( @{ $all->{'sets'} } ), 2, 'two sets (geoip/state_dir are reserved, not sets)' );
	my %by = map { $_->{'name'} => $_ } @{ $all->{'sets'} };
	is( $by{'foo'}{'geoip'}, '/foo.mmdb',   'per-set geoip overrides the global' );
	is( $by{'bar'}{'geoip'}, '/global.mmdb', 'a set with no geoip inherits the global' );

	my $one = ishara( $web_logs, 'foo' );
	is( scalar( @{ $one->{'sets'} } ), 1, '--name foo loads only that set' );
	is( $one->{'sets'}[0]{'name'}, 'foo', 'the right set' );
};

# ---- tablet round-trip + _seek_for -------------------------------------------

subtest 'position tablet persist / load / seek' => sub {
	my $dir = tempdir( CLEANUP => 1 );
	my $web_logs = { 'state_dir' => $dir };

	# a real file to seek against
	my ( $fh, $file ) = tempfile( DIR => $dir );
	print {$fh} "line one\nline two\n";
	close($fh);
	my ( $inode, $size ) = ( stat($file) )[ 1, 7 ];

	my $writer = ishara($web_logs);
	$writer->{'positions'}{$file} = { 'inode' => $inode, 'offset' => 5 };
	$writer->{'positions'}{'/var/log/has,comma and "quote".log'} = { 'inode' => 99, 'offset' => 42 };
	$writer->_write_positions;
	ok( -f $writer->_tablet_path, 'tablet written' );

	# a fresh instance loads it back
	my $reader = ishara($web_logs);
	$reader->_load_positions;
	is( $reader->{'positions'}{$file}{'offset'}, 5, 'offset round-trips' );
	is( $reader->{'positions'}{$file}{'inode'}, $inode, 'inode round-trips' );
	is( $reader->{'positions'}{'/var/log/has,comma and "quote".log'}{'offset'},
		42, 'a path with commas and quotes round-trips (csv escaping)' );

	# _seek_for: same inode, not shrunk => the saved offset
	is( $reader->_seek_for($file), 5, 'resume at the saved offset' );

	# shrunk file (offset past EOF) => start over at 0
	$reader->{'positions'}{$file}{'offset'} = $size + 1000;
	is( $reader->_seek_for($file), 0, 'a shrunk/truncated file restarts at 0' );

	# different inode => rotation => 0
	$reader->{'positions'}{$file} = { 'inode' => $inode + 1, 'offset' => 3 };
	is( $reader->_seek_for($file), 0, 'a rotated file (inode changed) restarts at 0' );

	# unknown file => undef (FollowTail tails from EOF)
	is( $reader->_seek_for('/no/such/file'), undef, 'an unknown file => undef' );
};

done_testing();
