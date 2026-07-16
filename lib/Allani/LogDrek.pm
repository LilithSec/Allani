package Allani::LogDrek;

use 5.006;
use strict;
use warnings;
use Exporter    qw( import );
use Sys::Syslog qw( closelog openlog syslog );

=pod

=head1 NAME

Allani::LogDrek - Exportable syslog helper shared by the Allani bins and modules.

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

our @EXPORT_OK = qw( log_drek );

=head1 SYNOPSIS

    use Allani::LogDrek qw( log_drek );

    log_drek( 'info', 'manager starting' );
    log_drek( 'err',  'config load failed' );
    log_drek( 'info', 'ishara "www" stdout... tailing', undef, 'ishara-www' );

=head1 DESCRIPTION

Holds the C<log_drek> sub used by C<allani> (the manager) and C<ishara> (the
workers) as well as the App::Allani modules for logging what they do. It is a
plain function -- no object needed -- exported on request, so everything shares
one implementation.

=head1 EXPORTS

Nothing is exported by default. L</log_drek> is available via C<@EXPORT_OK>.

=head1 FUNCTIONS

=head2 log_drek

Writes a message to syslog.

    log_drek( $level, $message, $tracking_int, $ident );

C<$level> defaults to 'info' when undef. When C<$tracking_int> is defined it is
prepended as C<< $tracking_int . ' : ' . $message >>. C<$ident> is the syslog
ident and defaults to 'allani'; ishara workers should pass
C<< 'ishara-' . $name >> so lines are attributable per instance.

=cut

sub log_drek {
	my ( $level, $message, $tracking_int, $ident ) = @_;

	if ( !defined($level) ) {
		$level = 'info';
	}

	if ( !defined($message) ) {
		$message = '';
	}

	chomp($message);

	if ( defined($tracking_int) ) {
		$message = $tracking_int . ' : ' . $message;
	}

	if ( !defined($ident) ) {
		$ident = 'allani';
	}

	openlog( $ident, 'cons,pid', 'daemon' );
	syslog( $level, '%s', $message );
	closelog();

	return;
} ## end sub log_drek

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

1;
