package Allani::Command::munge;

use strict;
use warnings;
use Allani -command;
use JSON::XS ();

sub opt_spec {
	return (
		[ 'program|p=s', 'PROGRAM to gate on when the input is a bare MESSAGE line' ],
		[ 'explain|e',   'show which rule and pattern fired, not just the fields' ],
		[ 'full|a',      'print the whole record with the enrichment merged in (as stored)' ],
	);
}

sub abstract { 'preview enrichment for a log line without storing it' }

sub description {
	return
		"Runs a log line through the configured Log::Munger rules and prints what would\n"
		. "land under the \"enriched\" key, without touching the database. Input is taken\n"
		. "from the command line arguments or, if none are given, from stdin one line at a\n"
		. "time. Each line may be a full JSON record (as syslog-ng would send) or a bare\n"
		. "MESSAGE string; most daemon rules gate on PROGRAM, so use --program with a bare\n"
		. "line or feed a JSON record with PROGRAM set.\n"
		. "\n"
		. "By default only the extracted fields are printed. --full prints the whole record\n"
		. "with those fields merged in under \"enriched\", exactly as it would be stored.\n"
		. "--explain instead prints which rule and pattern fired.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );

	my $munger = $self->{'app'}->build_munger;
	if ( !defined($munger) ) {
		die("no munger_rules are configured, so there is nothing to munge with\n");
	}

	# ->utf8 so geoip's localized names (ja/ru/zh country names, etc.) emit as
	# UTF-8 bytes rather than triggering "Wide character in print"
	my $encoder = JSON::XS->new->utf8->canonical->pretty;
	my $decoder = JSON::XS->new->utf8;

	my @lines;
	if ( defined( $args->[0] ) ) {
		push( @lines, join( ' ', @{$args} ) );
	} else {
		while ( my $line = readline(STDIN) ) {
			chomp($line);
			next if ( $line eq '' );
			push( @lines, $line );
		}
	}

	foreach my $line (@lines) {
		my $item;
		my $decoded = eval { $decoder->decode($line); };
		if ( !$@ && ref($decoded) eq 'HASH' ) {
			$item = $decoded;
		} else {
			$item = { 'MESSAGE' => $line };
			if ( defined( $opt->program ) ) {
				$item->{'PROGRAM'} = $opt->program;
			}
		}

		my $result;
		if ( $opt->full ) {
			# the whole record with the extracted fields merged in under
			# "enriched", exactly as the ingest path would store it
			my $fields = $munger->process_item( 'item' => $item );
			$result = { %{$item} };
			if ( defined($fields) && ref($fields) eq 'HASH' && keys( %{$fields} ) ) {
				$result->{'enriched'} = $fields;
			}
		} elsif ( $opt->explain ) {
			$result = $munger->explain_item( 'item' => $item );
		} else {
			$result = $munger->process_item( 'item' => $item );
			$result = {} if ( !defined($result) );
		}

		print $encoder->encode($result);
	} ## end foreach my $line (@lines)

	return 1;
} ## end sub execute

1;
