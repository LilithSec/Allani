#!perl
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);

BEGIN { use_ok('Allani::Manager'); }

sub manager_for {
	my ($yaml) = @_;
	my ( $fh, $path ) = tempfile( 'allani-mgr-XXXXXX', SUFFIX => '.yaml', TMPDIR => 1, UNLINK => 1 );
	print {$fh} $yaml;
	close($fh);
	return Allani::Manager->new( 'config' => $path );
}

# ---- worker planning ---------------------------------------------------------

subtest 'plans one worker per web set plus syslog when configured' => sub {
	my $m = manager_for(
		"run_dir: /run/allani-test\n"
			. "syslog_socket: /run/allani-test/syslog.ingest.sock\n"
			. "web_logs:\n"
			. "  geoip: /x.mmdb\n"
			. "  foo:\n    access: /a/*.log\n"
			. "  bar:\n    access: /b/*.log\n"
	);

	is_deeply(
		[ sort keys %{ $m->{'workers'} } ],
		[ 'syslog', 'web-bar', 'web-foo' ],
		'a worker per set (geoip reserved, not a set) + syslog'
	);
	is_deeply( $m->{'workers'}{'web-foo'}{'args'}, [ '--name', 'foo' ], 'web worker args' );
	is_deeply( $m->{'workers'}{'syslog'}{'args'},  ['--syslog'],        'syslog worker args' );
};

subtest 'no syslog worker without a syslog_socket' => sub {
	my $m = manager_for( "web_logs:\n  foo:\n    access: /a/*.log\n" );
	is_deeply( [ sort keys %{ $m->{'workers'} } ], ['web-foo'], 'only the web worker' );
	ok( !exists( $m->{'workers'}{'syslog'} ), 'no syslog worker' );
};

# ---- paths -------------------------------------------------------------------

subtest 'paths honor run_dir' => sub {
	my $m = manager_for("run_dir: /run/allani-test\nweb_logs:\n  foo:\n    access: /a/*.log\n");
	is( $m->pid_path,       '/run/allani-test/allani.pid',    'manager pid path' );
	is( $m->manager_socket, '/run/allani-test/manager.sock',  'manager control socket' );
};

is( Allani::Manager::socket_path_for( { 'run_dir' => '/x' } ), '/x/manager.sock', 'socket_path_for honors run_dir' );
is( Allani::Manager::socket_path_for( {} ), '/var/run/allani/manager.sock', 'socket_path_for default' );

# ---- status response ---------------------------------------------------------

subtest 'status reports workers down before they are spawned' => sub {
	my $m      = manager_for("web_logs:\n  foo:\n    access: /a/*.log\n");
	my $status = $m->_cmd_status;
	is( $status->{'workers'}{'web-foo'}{'up'}, 0, 'worker is down before start' );
	is( $status->{'uptime'}, undef, 'no uptime before start_server' );
};

done_testing();
