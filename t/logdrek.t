#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

BEGIN { use_ok('Allani::LogDrek'); }

ok( Allani::LogDrek->can('log_drek'), 'log_drek exists' );

# nothing is exported by default
ok( !main->can('log_drek'), 'log_drek is not exported by default' );

# it is exportable on request
Allani::LogDrek->import('log_drek');
ok( main->can('log_drek'), 'log_drek is exported on request' );

# a thin syslog wrapper: it should not die, including on undef args
eval { log_drek( 'info', 'allani logdrek self-test' ); };
is( $@, '', 'log_drek runs' );
eval { log_drek( undef, undef ); };
is( $@, '', 'log_drek tolerates undef level/message' );
eval { log_drek( 'info', 'tagged', 42, 'ishara-test' ); };
is( $@, '', 'log_drek tolerates a tracking int and ident' );

done_testing();
