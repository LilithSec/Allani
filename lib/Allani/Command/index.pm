package Allani::Command::index;

use strict;
use warnings;
use Allani -command;

# tables whose enriched fields may be indexed (whitelist -- never interpolate an
# arbitrary table name into DDL)
my %TABLES = map { $_ => 1 } qw(syslog http_access http_error);

sub opt_spec {
	return (
		[ 'trigram|t',      'add: make a trigram (pg_trgm) GIN index for ~ / =~ / ILIKE' ],
		[ 'name=s',         'drop: target an index by name' ],
		[ 'all|a',          'list: also show schema/other indexes on the tables' ],
		[ 'prune',          'sync: also drop managed indexes no longer tracked' ],
		[ 'concurrently|c', 'build/drop CONCURRENTLY (no ingest lock; not inside a transaction)' ],
		[ 'dry-run|n',      'print what would happen without changing anything' ],
	);
}

sub abstract { 'manage per-enriched-field indexes (list/add/drop/sync/import)' }

sub description {
	return
		"Manages btree / trigram indexes on individual enriched fields, so non-equality\n"
		. "--field searches (>, <, ~, =~, ...) on those fields are fast. The set of managed\n"
		. "indexes lives in the managed_indexes table, not the config.\n"
		. "\n"
		. "    allani index                     # (list) the managed indexes and whether they exist\n"
		. "    allani index list --all          # also show schema/other indexes on the tables\n"
		. "    allani index add syslog dovecot_event\n"
		. "    allani index add syslog url --trigram\n"
		. "    allani index drop syslog dovecot_event\n"
		. "    allani index sync [--prune]      # create missing (and drop untracked) indexes\n"
		. "    allani index import              # seed the table from a legacy 'indexes' config\n"
		. "\n"
		. "drop only ever touches allani_ix_* indexes tracked in managed_indexes, so the\n"
		. "schema-required indexes (primary keys, the raw GIN, the composites, the timestamp\n"
		. "btrees) can never be dropped.";
}

sub validate { return 1 }

sub execute {
	my ( $self, $opt, $args ) = @_;

	$self->{'app'}->read_in_config( 'config' => $self->{'app'}{'global_options'}{'config'} );

	my $verb = shift( @{$args} );
	$verb = 'list' if ( !defined($verb) );

	my %dispatch = (
		'list'   => \&_list,
		'add'    => \&_add,
		'drop'   => \&_drop,
		'sync'   => \&_sync,
		'import' => \&_import,
	);
	my $fn = $dispatch{$verb};
	if ( !defined($fn) ) {
		die( "unknown verb '" . $verb . "' (list, add, drop, sync, import)\n" );
	}

	my $dbh = $self->{'app'}->connect_dbi;

	return $fn->( $self, $dbh, $opt, $args );
} ## end sub execute

# ---- helpers -----------------------------------------------------------------

sub _valid_table {
	my ($t) = @_;
	if ( !defined($t) || !$TABLES{$t} ) {
		die( "table must be one of " . join( ', ', sort keys %TABLES ) . ", got '"
				. ( defined($t) ? $t : 'undef' )
				. "'\n" );
	}
	return $t;
} ## end sub _valid_table

sub _valid_field {
	my ($f) = @_;
	if ( !defined($f) || $f !~ /\A\w+\z/ ) {
		die( "field must be word characters, got '" . ( defined($f) ? $f : 'undef' ) . "'\n" );
	}
	return $f;
} ## end sub _valid_field

sub _index_name {
	my ( $table, $field, $trigram ) = @_;
	return substr( 'allani_ix_' . $table . '_' . $field . ( $trigram ? '_trgm' : '' ), 0, 63 );
}

sub _ddl {
	my ( $table, $field, $trigram, $name ) = @_;
	my $expr = "raw->'enriched'->>'" . $field . "'";
	return $trigram
		? 'CREATE INDEX ' . $name . ' ON ' . $table . ' USING gin ((' . $expr . ') gin_trgm_ops)'
		: 'CREATE INDEX ' . $name . ' ON ' . $table . ' ((' . $expr . '))';
} ## end sub _ddl

sub _truthy {
	my ($v) = @_;
	return ( defined($v) && $v ne '' && $v !~ /\A(?:0|f|false|no)\z/i ) ? 1 : 0;
}

sub _index_exists {
	my ( $dbh, $name ) = @_;
	my $row = $dbh->selectrow_arrayref( 'SELECT 1 FROM pg_indexes WHERE indexname = ?', undef, $name );
	return $row ? 1 : 0;
}

# turn a legacy 'indexes' config block into a list of { table, field, trigram,
# name }. Dies on an unknown table or unsafe field name. Not a method.
sub _plan {
	my ($indexes) = @_;

	if ( ref($indexes) ne 'HASH' ) {
		die("the 'indexes' config is not a map of table => [ fields ]\n");
	}

	my @plan;
	foreach my $table ( sort keys( %{$indexes} ) ) {
		_valid_table($table);
		my $list = $indexes->{$table};
		if ( ref($list) ne 'ARRAY' ) {
			die( 'indexes.' . $table . " is not a list\n" );
		}
		foreach my $entry ( @{$list} ) {
			my ( $field, $trigram );
			if ( ref($entry) eq 'HASH' ) {
				$field   = $entry->{'field'};
				$trigram = $entry->{'trigram'} ? 1 : 0;
			} elsif ( ref($entry) eq '' ) {
				$field   = $entry;
				$trigram = 0;
			} else {
				die( 'indexes.' . $table . ' has an entry with ref "' . ref($entry) . "\"\n" );
			}
			_valid_field($field);
			push(
				@plan,
				{
					'table'   => $table,
					'field'   => $field,
					'trigram' => $trigram,
					'name'    => _index_name( $table, $field, $trigram ),
				}
			);
		} ## end foreach my $entry ( @{$list} )
	} ## end foreach my $table ( sort keys...)

	return @plan;
} ## end sub _plan

# ---- verbs -------------------------------------------------------------------

sub _list {
	my ( $self, $dbh, $opt, $args ) = @_;

	my $rows = $dbh->selectall_arrayref(
		'SELECT tbl, field, trigram, index_name FROM managed_indexes ORDER BY tbl, field',
		{ 'Slice' => {} } );

	printf( "%-7s %-8s %-38s %-14s %s\n", 'exists', 'type', 'name', 'table', 'field' );
	foreach my $r ( @{$rows} ) {
		printf(
			"%-7s %-8s %-38s %-14s %s\n",
			( _index_exists( $dbh, $r->{'index_name'} ) ? 'yes' : 'NO' ),
			( _truthy( $r->{'trigram'} ) ? 'trigram' : 'btree' ),
			$r->{'index_name'}, $r->{'tbl'}, $r->{'field'}
		);
	} ## end foreach my $r ( @{$rows} )

	if ( $opt->all ) {
		print "\n-- all indexes on the Allani tables --\n";
		my $all = $dbh->selectall_arrayref(
			"SELECT tablename, indexname FROM pg_indexes"
				. " WHERE tablename IN ('syslog','http_access','http_error','managed_indexes')"
				. ' ORDER BY tablename, indexname',
			{ 'Slice' => {} }
		);
		foreach my $r ( @{$all} ) {
			printf( "%-10s %-14s %s\n",
				( $r->{'indexname'} =~ /\Aallani_ix_/ ? 'managed' : 'schema' ),
				$r->{'tablename'}, $r->{'indexname'} );
		}
	} ## end if ( $opt->all )

	return 1;
} ## end sub _list

sub _add {
	my ( $self, $dbh, $opt, $args ) = @_;

	my $table   = _valid_table( $args->[0] );
	my $field   = _valid_field( $args->[1] );
	my $trigram = $opt->trigram ? 1 : 0;
	my $name    = _index_name( $table, $field, $trigram );
	my $ddl     = _ddl( $table, $field, $trigram, $name );
	$ddl =~ s/\ACREATE INDEX /CREATE INDEX CONCURRENTLY / if ( $opt->concurrently );

	if ( $opt->dry_run ) {
		print "would track $table.$field (name $name) in managed_indexes\n";
		print "CREATE EXTENSION IF NOT EXISTS pg_trgm;\n" if ($trigram);
		print $ddl . ";\n";
		return 1;
	}

	if ($trigram) {
		eval { $dbh->do('CREATE EXTENSION IF NOT EXISTS pg_trgm'); };
		die( 'failed to create the pg_trgm extension (needs suitable privileges)... ' . $@ ) if ($@);
	}

	$dbh->do(
		'INSERT INTO managed_indexes (tbl, field, trigram, index_name) VALUES (?,?,?,?)'
			. ' ON CONFLICT (index_name) DO NOTHING',
		undef, $table, $field, ( $trigram ? 'true' : 'false' ), $name
	);

	if ( _index_exists( $dbh, $name ) ) {
		print 'tracked (index already exists): ' . $name . "\n";
		return 1;
	}

	eval { $dbh->do($ddl); };
	die( 'failed to create ' . $name . '... ' . $@ ) if ($@);
	print 'created: ' . $name . "\n";

	return 1;
} ## end sub _add

sub _drop {
	my ( $self, $dbh, $opt, $args ) = @_;

	my $name;
	if ( defined( $opt->name ) ) {
		$name = $opt->name;
	} else {
		my $table   = _valid_table( $args->[0] );
		my $field   = _valid_field( $args->[1] );
		my $trigram = $opt->trigram ? 1 : 0;
		$name = _index_name( $table, $field, $trigram );
	}

	# guard 1: Allani only ever manages allani_ix_* indexes, so nothing else --
	# primary keys, the raw GIN, the composites, hand-made indexes -- is reachable
	if ( $name !~ /\Aallani_ix_/ ) {
		die( "refusing to drop '" . $name . "': not an Allani-managed index (schema-required indexes are protected)\n" );
	}

	# guard 2: it must actually be tracked in managed_indexes
	my $row = $dbh->selectrow_arrayref( 'SELECT id FROM managed_indexes WHERE index_name = ?', undef, $name );
	if ( !$row ) {
		die( "refusing to drop '" . $name . "': not tracked in managed_indexes\n" );
	}

	if ( $opt->dry_run ) {
		print "would drop index $name and its managed_indexes row\n";
		return 1;
	}

	my $drop = 'DROP INDEX ' . ( $opt->concurrently ? 'CONCURRENTLY ' : '' ) . 'IF EXISTS ' . $name;
	eval { $dbh->do($drop); };
	die( 'failed to drop ' . $name . '... ' . $@ ) if ($@);
	$dbh->do( 'DELETE FROM managed_indexes WHERE index_name = ?', undef, $name );
	print 'dropped: ' . $name . "\n";

	return 1;
} ## end sub _drop

sub _sync {
	my ( $self, $dbh, $opt, $args ) = @_;

	my $rows = $dbh->selectall_arrayref(
		'SELECT tbl, field, trigram, index_name FROM managed_indexes ORDER BY tbl, field',
		{ 'Slice' => {} } );

	my $want_trgm = grep { _truthy( $_->{'trigram'} ) } @{$rows};
	if ( $want_trgm && !$opt->dry_run ) {
		eval { $dbh->do('CREATE EXTENSION IF NOT EXISTS pg_trgm'); };
		die( 'failed to create the pg_trgm extension... ' . $@ ) if ($@);
	}

	# create the missing ones
	foreach my $r ( @{$rows} ) {
		next if ( _index_exists( $dbh, $r->{'index_name'} ) );
		my $ddl = _ddl( $r->{'tbl'}, $r->{'field'}, _truthy( $r->{'trigram'} ), $r->{'index_name'} );
		$ddl =~ s/\ACREATE INDEX /CREATE INDEX CONCURRENTLY / if ( $opt->concurrently );
		if ( $opt->dry_run ) { print 'would create: ' . $r->{'index_name'} . "\n"; next; }
		eval { $dbh->do($ddl); };
		if ($@) { warn( 'failed to create ' . $r->{'index_name'} . '... ' . $@ ); next; }
		print 'created: ' . $r->{'index_name'} . "\n";
	} ## end foreach my $r ( @{$rows} )

	# --prune: drop allani_ix_* indexes present in the DB but no longer tracked.
	# The LIKE 'allani_ix_%' filter keeps this from ever touching a schema index.
	if ( $opt->prune ) {
		my %tracked = map { $_->{'index_name'} => 1 } @{$rows};
		my $dbidx   = $dbh->selectall_arrayref(
			"SELECT indexname FROM pg_indexes"
				. " WHERE tablename IN ('syslog','http_access','http_error')"
				. " AND indexname LIKE 'allani\\_ix\\_%'",
			{ 'Slice' => {} }
		);
		foreach my $r ( @{$dbidx} ) {
			next if ( $tracked{ $r->{'indexname'} } );
			if ( $opt->dry_run ) { print 'would prune: ' . $r->{'indexname'} . "\n"; next; }
			eval {
				$dbh->do( 'DROP INDEX ' . ( $opt->concurrently ? 'CONCURRENTLY ' : '' ) . 'IF EXISTS ' . $r->{'indexname'} );
			};
			print 'pruned: ' . $r->{'indexname'} . "\n" if ( !$@ );
		} ## end foreach my $r ( @{$dbidx} )
	} ## end if ( $opt->prune )

	return 1;
} ## end sub _sync

sub _import {
	my ( $self, $dbh, $opt, $args ) = @_;

	my $indexes = $self->{'app'}->config->{'indexes'};
	if ( !defined($indexes) ) {
		print "no legacy 'indexes' block in the config to import\n";
		return 1;
	}

	my @plan = _plan($indexes);
	foreach my $ix (@plan) {
		if ( $opt->dry_run ) {
			print 'would import: ' . $ix->{'name'} . "\n";
			next;
		}
		$dbh->do(
			'INSERT INTO managed_indexes (tbl, field, trigram, index_name) VALUES (?,?,?,?)'
				. ' ON CONFLICT (index_name) DO NOTHING',
			undef, $ix->{'table'}, $ix->{'field'}, ( $ix->{'trigram'} ? 'true' : 'false' ), $ix->{'name'}
		);
		print 'imported: ' . $ix->{'name'} . "\n";
	} ## end foreach my $ix (@plan)

	print "now run 'allani index sync' to create them, then remove 'indexes' from the config\n"
		if ( !$opt->dry_run );

	return 1;
} ## end sub _import

1;
