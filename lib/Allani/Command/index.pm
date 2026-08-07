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

# Checks that a table name is one Allani may index, and returns it.
#
# Index DDL cannot be written with placeholders, so the table name reaches the
# SQL as text. Everything that builds that SQL passes through here first, and
# the whitelist is what makes doing so safe -- an arbitrary name is rejected
# rather than interpolated.
#
#   - $t :: The table name as it came off the command line, or undef when the
#       argument was omitted. Not a method argument -- this is a plain function.
#
# Returns the table name unchanged when it is one of syslog, http_access, or
# http_error. Dies otherwise with a newline-terminated message, so App::Cmd
# prints it without a source line.
#
#     _valid_table('syslog');      # 'syslog'
#     _valid_table('pg_authid');   # dies
sub _valid_table {
	my ($t) = @_;
	if ( !defined($t) || !$TABLES{$t} ) {
		die( "table must be one of " . join( ', ', sort keys %TABLES ) . ", got '"
				. ( defined($t) ? $t : 'undef' )
				. "'\n" );
	}
	return $t;
} ## end sub _valid_table

# Checks that an enriched field name is safe to embed in index DDL, and returns
# it.
#
# Unlike the table name there is no whitelist to check against -- rules may
# define any field, and indexing them is the point -- so the guard is the shape
# of the name instead. Word characters cannot close the quoted string the field
# is interpolated into, which is what keeps the DDL safe.
#
#   - $f :: The field name as it came off the command line, or undef when the
#       argument was omitted. Not a method argument -- this is a plain function.
#
# Returns the field name unchanged when it is made only of word characters --
# letters, digits, and underscores. Dies otherwise with a newline-terminated
# message. Note that this is stricter than --field accepts when searching, which
# also allows dots; such a field cannot currently be indexed.
#
#     _valid_field('dovecot_event');   # 'dovecot_event'
#     _valid_field("x'; DROP ...");    # dies
sub _valid_field {
	my ($f) = @_;
	if ( !defined($f) || $f !~ /\A\w+\z/ ) {
		die( "field must be word characters, got '" . ( defined($f) ? $f : 'undef' ) . "'\n" );
	}
	return $f;
} ## end sub _valid_field

# Works out the name an index gets. Every managed index is named by this one
# function, from create through to drop, which is what lets the name itself
# carry meaning.
#
# The allani_ix_ prefix is load-bearing rather than cosmetic: drop refuses to
# touch anything without it, and sync --prune only ever considers indexes
# matching it. That is what makes it impossible for either to reach a
# schema-required index -- the primary keys, the GIN index on raw, the
# composites, the timestamp btrees -- or a hand-made one.
#
#   - $table :: The table, already checked by _valid_table.
#
#   - $field :: The enriched field, already checked by _valid_field.
#
#   - $trigram :: True for a trigram index, false for a btree. The two are
#       distinguished by a _trgm suffix, so both kinds may exist on one field.
#
# Not method arguments -- this is a plain function.
#
# Returns the index name, truncated to 63 characters, which is PostgreSQL's
# identifier limit. A very long field name can therefore collide with another
# that shares its first characters; the unique constraint on index_name catches
# that rather than letting two entries fight over one index.
#
#     _index_name( 'syslog', 'dovecot_event', 0 );   # 'allani_ix_syslog_dovecot_event'
#     _index_name( 'syslog', 'url', 1 );             # 'allani_ix_syslog_url_trgm'
sub _index_name {
	my ( $table, $field, $trigram ) = @_;
	return substr( 'allani_ix_' . $table . '_' . $field . ( $trigram ? '_trgm' : '' ), 0, 63 );
}

# Builds the CREATE INDEX statement for one managed index.
#
# The index is on the expression that extracts the field from the jsonb, not on
# a column, because there is no column -- enriched fields live inside raw. The
# expression written here has to match the one Allani::Sources generates when
# searching, or the planner will not use the index.
#
# Which kind to build depends on how the field will be searched. A btree serves
# ordering and comparison, so it is what >, <, >=, and <= want. A trigram GIN
# index serves substring and pattern matching instead, which is what ~, !~, and
# =~ want, and it needs the pg_trgm extension present.
#
#   - $table :: The table, already checked by _valid_table.
#
#   - $field :: The enriched field, already checked by _valid_field.
#
#   - $trigram :: True for a trigram GIN index, false for a btree.
#
#   - $name :: The index name, from _index_name.
#
# Not method arguments -- this is a plain function.
#
# Returns the DDL as a string, without a trailing semicolon. Callers wanting a
# non-blocking build rewrite the leading 'CREATE INDEX ' to add CONCURRENTLY.
#
#     _ddl( 'syslog', 'dovecot_event', 0, 'allani_ix_syslog_dovecot_event' );
#     # CREATE INDEX allani_ix_syslog_dovecot_event ON syslog ((raw->'enriched'->>'dovecot_event'))
sub _ddl {
	my ( $table, $field, $trigram, $name ) = @_;
	my $expr = "raw->'enriched'->>'" . $field . "'";
	return $trigram
		? 'CREATE INDEX ' . $name . ' ON ' . $table . ' USING gin ((' . $expr . ') gin_trgm_ops)'
		: 'CREATE INDEX ' . $name . ' ON ' . $table . ' ((' . $expr . '))';
} ## end sub _ddl

# Reads a boolean the way PostgreSQL might have handed it over. The trigram
# column is a boolean, but what DBD::Pg returns for one depends on the driver
# and its settings -- it may be 1 or 0, or the strings 't' and 'f', or 'true'
# and 'false'. Rather than depend on which, every form is accepted.
#
#   - $v :: The value as it came back from the database. Not a method argument
#       -- this is a plain function.
#
# Returns 1 for anything that is not undef, empty, or one of the recognised
# false spellings -- 0, f, false, no, in any case -- and 0 otherwise.
#
#     _truthy('t');       # 1
#     _truthy('false');   # 0
#     _truthy(undef);     # 0
sub _truthy {
	my ($v) = @_;
	return ( defined($v) && $v ne '' && $v !~ /\A(?:0|f|false|no)\z/i ) ? 1 : 0;
}

# Asks the database whether an index of a given name actually exists.
#
# The managed_indexes table records what should exist, which is not the same as
# what does: an index may have been created outside Allani, dropped by hand, or
# left unbuilt because a CONCURRENTLY build failed. This is what lets list show
# the difference and sync act on it.
#
#   - $dbh :: A connected database handle.
#
#   - $name :: The index name to look for.
#
# Not method arguments -- this is a plain function.
#
# Returns 1 when pg_indexes has a row for that name, and 0 otherwise. The lookup
# is not restricted by table or schema, so a name colliding with an index
# elsewhere in the database would read as existing -- which the allani_ix_
# prefix makes unlikely.
#
#     _index_exists( $dbh, 'allani_ix_syslog_dovecot_event' );   # 1
sub _index_exists {
	my ( $dbh, $name ) = @_;
	my $row = $dbh->selectrow_arrayref( 'SELECT 1 FROM pg_indexes WHERE indexname = ?', undef, $name );
	return $row ? 1 : 0;
}

# Turns a legacy 'indexes' config block into the list of indexes it describes,
# so the import verb can move them into managed_indexes. Indexes used to be
# declared in the config; they now live in the database, and this exists to
# carry an older config across.
#
# Both spellings the config allowed are accepted: a bare field name, meaning a
# btree, or a hash naming the field and whether it should be a trigram index.
#
#   - $indexes :: The 'indexes' block from the config, a hash ref mapping a
#       table name to an array ref of entries, each entry either a field name
#       string or a hash ref with 'field' and optionally 'trigram'. Not a method
#       argument -- this is a plain function.
#
# Returns a list of hash refs, one per index, each holding:
#
#   - table :: The table name, checked by _valid_table.
#
#   - field :: The enriched field name, checked by _valid_field.
#
#   - trigram :: 1 for a trigram index, 0 for a btree.
#
#   - name :: The index name, from _index_name.
#
# Dies with a newline-terminated message when the block is not a hash, when a
# table's value is not a list, when an entry is neither a string nor a hash, or
# when a table or field name fails its check.
#
#     _plan( { 'syslog' => [ 'dovecot_event', { 'field' => 'url', 'trigram' => 1 } ] } );
#     # two entries: a btree on dovecot_event and a trigram index on url
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
#
# One sub per verb, all sharing a signature so execute can dispatch to them from
# a table. Each receives ( $self, $dbh, $opt, $args ) and returns 1.

# The list verb, and the default when no verb is given: prints every tracked
# index and whether it actually exists in the database.
#
# The exists column is the useful part. A NO there means the index is tracked
# but missing -- created and later dropped by hand, or left unbuilt by a failed
# CONCURRENTLY build -- and searches on that field are doing a sequential scan
# while looking, from the config's point of view, indexed. `allani index sync`
# is the answer to a NO.
#
#   - $dbh :: A connected database handle.
#
#   - $opt :: The parsed options. Only --all is read, which appends every index
#       on the Allani tables, schema-required ones included, each marked
#       'managed' or 'schema'.
#
#   - $args :: The remaining arguments. Unused by this verb.
#
# Returns 1. The listing goes to stdout as an aligned table.
#
#     allani index
#     allani index list --all
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

# The add verb: starts tracking an enriched field and builds its index.
#
# The row is recorded before the index is built, and with ON CONFLICT DO
# NOTHING, so that adding something already tracked is not an error and a build
# that fails still leaves the intent recorded for sync to finish later.
#
# On a large table this is the slow operation, and by default it holds a lock
# that blocks ingest for the duration. --concurrently avoids that lock at the
# cost of a slower build.
#
#   - $dbh :: A connected database handle.
#
#   - $opt :: The parsed options. --trigram builds a trigram GIN index rather
#       than a btree, for ~, !~, and =~ searches; --concurrently builds without
#       blocking ingest; --dry-run prints the DDL instead of running anything.
#
#   - $args :: The remaining arguments: the table at [0] and the enriched field
#       at [1], checked by _valid_table and _valid_field.
#
# Returns 1. Dies when either argument fails its check, when the pg_trgm
# extension is needed and cannot be created -- which needs privileges the
# ordinary allani role may not have -- or when the build itself fails.
#
#     allani index add syslog dovecot_event
#     allani index add syslog url --trigram --concurrently
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

# The drop verb: removes an index and stops tracking it.
#
# This is the one verb that destroys something, so it is guarded twice. The name
# must begin with allani_ix_, and it must already be tracked in
# managed_indexes. Between them, nothing Allani did not create is reachable --
# not the primary keys, not the GIN index on raw, not the composites or the
# timestamp btrees, and not an index made by hand. Dropping a schema-required
# index would leave the database quietly and badly slow, which is why --name
# exists but cannot be used to reach one.
#
#   - $dbh :: A connected database handle.
#
#   - $opt :: The parsed options. --name targets an index by name directly,
#       instead of by table and field, which is how a stale entry is removed;
#       --trigram selects the trigram index rather than the btree when naming
#       the field; --concurrently drops without blocking ingest; --dry-run
#       reports what would happen instead.
#
#   - $args :: The remaining arguments: the table at [0] and the enriched field
#       at [1]. Both are ignored when --name is given.
#
# Returns 1. Dies when the name fails either guard, when the table or field
# fails its check, or when the drop itself fails. The managed_indexes row is
# only deleted once the index is gone.
#
#     allani index drop syslog dovecot_event
#     allani index drop --name allani_ix_syslog_url_trgm
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

# The sync verb: makes the database match what managed_indexes says should be
# there.
#
# Since the tracking lives in the database rather than the config, this is what
# reconciles the two when they have drifted -- after a restore that brought the
# rows back without the indexes, after a failed CONCURRENTLY build, or after
# someone dropped one by hand. It is safe to run at any time; an index that
# already exists is left alone.
#
# A build that fails is warned about and the rest continue, since one field that
# cannot be indexed should not stop the others from being.
#
#   - $dbh :: A connected database handle.
#
#   - $opt :: The parsed options. --prune additionally drops allani_ix_* indexes
#       that exist but are no longer tracked, which is the tidy-up after a drop
#       that did not complete; --concurrently builds and drops without blocking
#       ingest; --dry-run reports what would happen instead.
#
#   - $args :: The remaining arguments. Unused by this verb.
#
# Returns 1. Dies only when the pg_trgm extension is needed and cannot be
# created. Note that --prune only ever considers indexes whose names begin with
# allani_ix_, so it cannot reach a schema-required or hand-made index.
#
#     allani index sync
#     allani index sync --prune --concurrently
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

# The import verb: seeds managed_indexes from a legacy 'indexes' config block.
#
# Indexes used to be declared in the config and are now tracked in the database.
# This is the one-off migration between the two, and it only records the
# intent -- nothing is built here, so importing is cheap and reversible. The
# closing message says what to do next.
#
#   - $dbh :: A connected database handle.
#
#   - $opt :: The parsed options. Only --dry-run is read, which lists what would
#       be imported instead of writing anything.
#
#   - $args :: The remaining arguments. Unused by this verb.
#
# Returns 1, having said so and done nothing when the config has no 'indexes'
# block. Rows are inserted with ON CONFLICT DO NOTHING, so importing twice is
# harmless. Dies when the block is malformed or names an unknown table or an
# unsafe field -- see _plan.
#
#     allani index import --dry-run
#     allani index import
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
