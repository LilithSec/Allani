package Allani::Command::enrich;

use strict;
use warnings;
use Allani -command;
use JSON::XS ();

my %TS_COLUMNS = ( 'c_isodate' => 1, 'r_isodate' => 1, 's_isodate' => 1 );

sub opt_spec {
	return (
		[ 'since=s',   'only rows within this window (e.g. 30d, 24h)' ],
		[ 'program=s', 'only rows with this PROGRAM' ],
		[ 'column=s',  'timestamp column --since compares against (default r_isodate)' ],
		[ 'limit=i',   'stop after this many rows have been scanned' ],
		[ 'batch=i',   'rows fetched per round (default 1000)' ],
		[ 'all',       'required to run with no --since/--program filter' ],
		[ 'dry-run|n', 'report what would change without writing' ],
	);
}

sub abstract { 're-run enrichment over already-ingested rows' }

sub description {
	return
		"Re-runs the configured Log::Munger rules over rows already in the syslog table and\n"
		. "rewrites the \"enriched\" block inside raw. Use it after adding or fixing rules to\n"
		. "apply them to logs already received. A row is only written when its enrichment\n"
		. "actually changes. Scans are keyset-paginated by id. Without --since or --program\n"
		. "you must pass --all, to avoid accidentally rewriting the whole table.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );

	my $munger = $self->{'app'}->build_munger;
	if ( !defined($munger) ) {
		die("no munger_rules are configured, so there is nothing to enrich with\n");
	}

	my $column = defined( $opt->column ) ? $opt->column : 'r_isodate';
	if ( !$TS_COLUMNS{$column} ) {
		die( '--column must be one of ' . join( ', ', sort keys %TS_COLUMNS ) . "\n" );
	}

	my @where;
	my @filter_binds;
	if ( defined( $opt->since ) ) {
		push( @where,        $column . ' >= now() - ?::interval' );
		push( @filter_binds, Allani::duration_to_interval( $opt->since ) );
	}
	if ( defined( $opt->program ) ) {
		push( @where,        'program = ?' );
		push( @filter_binds, $opt->program );
	}
	if ( !@where && !$opt->all ) {
		die("refusing to scan the whole table without a filter; pass --since/--program or --all\n");
	}

	my $dbh = $self->{'app'}->connect_dbi;

	my $batch = ( defined( $opt->batch ) && $opt->batch > 0 ) ? $opt->batch : 1000;
	my $limit = $opt->limit;
	my $codec = JSON::XS->new->canonical;

	my $update = $dbh->prepare('UPDATE syslog SET raw = ?::jsonb WHERE id = ?');

	my $last_id = 0;
	my $scanned = 0;
	my $changed = 0;

	SCAN: while (1) {
		my $sql = 'SELECT id, raw FROM syslog WHERE id > ?';
		my @binds = ($last_id);
		if (@where) {
			$sql .= ' AND ' . join( ' AND ', @where );
			push( @binds, @filter_binds );
		}
		$sql .= ' ORDER BY id LIMIT ?';
		push( @binds, $batch );

		my $sth = $dbh->prepare($sql);
		$sth->execute(@binds);
		my $rows = $sth->fetchall_arrayref;
		last if ( !@{$rows} );

		foreach my $row ( @{$rows} ) {
			my ( $id, $raw ) = @{$row};
			$last_id = $id;
			$scanned++;

			my $record = eval { $codec->decode($raw); };
			if ( $@ || ref($record) ne 'HASH' ) {
				next;    # an unparseable/odd row is left untouched
			}

			my $old = exists( $record->{'enriched'} ) ? $codec->encode( $record->{'enriched'} ) : '';
			delete $record->{'enriched'};

			my $fields = eval { $munger->process_item( 'item' => $record ); };
			if ( !$@ && defined($fields) && ref($fields) eq 'HASH' && keys( %{$fields} ) ) {
				$record->{'enriched'} = $fields;
			}
			my $new = exists( $record->{'enriched'} ) ? $codec->encode( $record->{'enriched'} ) : '';

			if ( $old ne $new ) {
				$changed++;
				if ( !$opt->dry_run ) {
					my $encoded = eval { $codec->encode($record); };
					if ( !$@ && defined($encoded) ) {
						eval { $update->execute( $encoded, $id ); };
						if ($@) { warn( 'failed to update id ' . $id . '... ' . $@ ); }
					}
				}
			}

			if ( defined($limit) && $scanned >= $limit ) { last SCAN; }
		} ## end foreach my $row ( @{$rows} )
	} ## end SCAN: while (1)

	print 'scanned '
		. $scanned
		. ' row(s), '
		. ( $opt->dry_run ? 'would change ' : 'changed ' )
		. $changed . "\n";

	return 1;
} ## end sub execute

1;
