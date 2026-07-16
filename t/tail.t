#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

BEGIN { use_ok('Allani::Command::tail'); }

# --- fakes: opt, app, dbh, sth ------------------------------------------------

{

	package FakeOpt;
	our $AUTOLOAD;
	sub new { my ( $c, %h ) = @_; return bless {%h}, $c; }

	sub AUTOLOAD {
		my $self = shift;
		my $name = $AUTOLOAD;
		$name =~ s/.*:://;
		return if ( $name eq 'DESTROY' );
		return $self->{$name};
	}
}
{

	package FakeSth;
	sub new { return bless { 'rows' => $_[1] }, $_[0]; }
	sub execute { return 1; }
	sub fetchall_arrayref { return $_[0]->{'rows'}; }
}
{

	package FakeDbh;
	sub new { return bless { 'rows' => $_[1] }, $_[0]; }
	sub prepare { return FakeSth->new( $_[0]->{'rows'} ); }
}
{

	package FakeApp;
	sub new { return bless { 'dbh' => $_[1] }, $_[0]; }
	sub read_in_config { return 1; }
	sub connect_dbi    { return $_[0]->{'dbh'}; }
}

sub captured {
	my ($code) = @_;
	my $out = '';
	open( my $fh, '>', \$out ) or die $!;
	my $old = select($fh);
	$code->();
	select($old);
	close($fh);
	return $out;
}

# --- seed path: last N rows come back newest-first, shown oldest-first --------

subtest 'seed batch is reversed to oldest-first' => sub {
	# rows as the DESC seed query would return them (id 3,2,1)
	my $rows = [
		[ 3, 't3', 'h', 'p', 'msg3' ],
		[ 2, 't2', 'h', 'p', 'msg2' ],
		[ 1, 't1', 'h', 'p', 'msg1' ],
	];
	my $cmd = bless { 'app' => FakeApp->new( FakeDbh->new($rows) ) }, 'Allani::Command::tail';
	my $opt = FakeOpt->new( 'source' => 'syslog', 'lines' => 10, 'follow' => 0, 'json' => 0 );

	my $out = captured( sub { $cmd->execute( $opt, [] ) } );

	is( $out, join( "\n",
			"id\ttime\thost\tprogram\tmessage",
			"1\tt1\th\tp\tmsg1",
			"2\tt2\th\tp\tmsg2",
			"3\tt3\th\tp\tmsg3",
		) . "\n",
		'header then rows ascending by id (newest at the bottom)'
	);
};

subtest 'json seed prints raw, no header' => sub {
	my $rows = [ [ 2, '{"b":2}' ], [ 1, '{"a":1}' ] ];
	my $cmd = bless { 'app' => FakeApp->new( FakeDbh->new($rows) ) }, 'Allani::Command::tail';
	my $opt = FakeOpt->new( 'source' => 'http_access', 'lines' => 10, 'follow' => 0, 'json' => 1 );

	my $out = captured( sub { $cmd->execute( $opt, [] ) } );
	is( $out, "{\"a\":1}\n{\"b\":2}\n", 'raw JSON, oldest first, no header' );
};

subtest 'bad --source is rejected' => sub {
	my $cmd = bless { 'app' => FakeApp->new( FakeDbh->new( [] ) ) }, 'Allani::Command::tail';
	my $opt = FakeOpt->new( 'source' => 'bogus' );
	eval { $cmd->execute( $opt, [] ) };
	like( $@, qr/--source must be one of/, 'unknown source dies before querying' );
};

done_testing();
