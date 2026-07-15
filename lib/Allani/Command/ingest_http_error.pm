package Allani::Command::ingest_http_error;

use strict;
use warnings;
use Allani -command;
use Allani::Ingest::HttpError;
use Sys::Hostname qw(hostname);

sub opt_spec {
	return (
		[ 'host|H=s', 'host (server) the logs are from (default: system hostname)' ],
		[ 'vhost=s',  'virtual host name to tag rows with' ],
		[ 'port|P=i', 'virtual host port to tag rows with' ],
	);
}

sub abstract { 'ingest HTTP error log lines from stdin' }

sub description {
	return
		"Reads HTTP error log lines (Apache 2.2/2.4 or nginx) from stdin, one per line,\n"
		. "parses each through the configured Log::Munger rules, and inserts it into the\n"
		. "http_error table. It reads until stdin closes, so it is typically an Apache\n"
		. "ErrorLog pipe:\n"
		. "\n"
		. "    ErrorLog \"|/usr/local/bin/allani ingest_http_error -H web01 --vhost www.example.com -P 443\"\n"
		. "\n"
		. "An error line carries no host/vhost/port, so those are supplied as options and tag\n"
		. "every row (nginx logs its own `server`, stored separately). munger_rules must\n"
		. "include http_error_logs. A line that fails is warned about on stderr and skipped.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );

	my $munger = $self->{'app'}->build_munger;
	if ( !defined($munger) ) {
		die("HTTP error ingest needs munger_rules configured (include http_error_logs)\n");
	}

	my $dbh  = $self->{'app'}->connect_dbi;
	my $host = defined( $opt->host ) ? $opt->host : hostname();

	my $ingester = Allani::Ingest::HttpError->new(
		'dbh'        => $dbh,
		'munger'     => $munger,
		'host'       => $host,
		'vhost'      => $opt->vhost,
		'vhost_port' => $opt->port,
	);

	while ( readline(STDIN) ) {
		eval { $ingester->ingest_line($_); };
		if ($@) {
			warn($@);
		}
	}

	return 1;
} ## end sub execute

1;
