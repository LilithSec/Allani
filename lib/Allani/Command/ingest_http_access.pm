package Allani::Command::ingest_http_access;

use strict;
use warnings;
use Allani -command;
use Allani::Ingest::HttpAccess;
use Sys::Hostname qw(hostname);

sub opt_spec {
	return (
		[ 'host|H=s',  'host (server) the logs are from (default: system hostname)' ],
		[ 'vhost=s',   'virtual host name to tag rows with' ],
		[ 'port|P=i',  'virtual host port to tag rows with' ],
	);
}

sub abstract { 'ingest HTTP access log lines from stdin' }

sub description {
	return
		"Reads HTTP access log lines (Apache/nginx combined or common format) from stdin,\n"
		. "one request per line, parses each through the configured Log::Munger rules, and\n"
		. "inserts it into the http_access table. It reads until stdin closes, so it is\n"
		. "typically an Apache CustomLog pipe:\n"
		. "\n"
		. "    CustomLog \"|/usr/local/bin/allani ingest_http_access -H web01 --vhost www.example.com -P 443\" combined\n"
		. "\n"
		. "A bare access line carries no host/vhost/port, so those are supplied as options and\n"
		. "tag every row. munger_rules must include http_access_logs. A line that fails is\n"
		. "warned about on stderr and skipped.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );

	my $munger = $self->{'app'}->build_munger;
	if ( !defined($munger) ) {
		die("HTTP access ingest needs munger_rules configured (include http_access_logs)\n");
	}

	my $dbh  = $self->{'app'}->connect_dbi;
	my $host = defined( $opt->host ) ? $opt->host : hostname();

	my $ingester = Allani::Ingest::HttpAccess->new(
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
