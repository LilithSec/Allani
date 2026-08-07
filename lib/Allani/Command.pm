package Allani::Command;
use App::Cmd::Setup -command;

# The base class every Allani::Command::* module inherits from. It exists to
# hang two pieces of shared behaviour off: letting each command declare its own
# options, and making --help work the same way everywhere.

# The App::Cmd hook naming the options a command accepts. Allani defers the
# whole list to the command itself, so a command declares its options in one
# place (its own options method) rather than splitting them between two.
#
#   - $class :: The command class App::Cmd is preparing, e.g.
#       Allani::Command::search.
#
#   - $app :: The Allani application object the command belongs to.
#
# Returns whatever the command's options method returns: a list of
# Getopt::Long::Descriptive option specs, one array ref per option, each holding
# the spec string and its help text.
#
# Not called directly; App::Cmd invokes it while preparing a command. Given a
# command with:
#
#     sub options { return ( [ 'limit=i', 'maximum rows to return' ] ); }
#
# ...this returns that single spec, and --limit becomes available on it.
sub global_opt_spec {
	my ( $class, $app ) = @_;
	return (
		$class->options($app),
	);
} ## end sub global_opt_spec

# The App::Cmd hook run after a command's options are parsed but before execute.
# It intercepts --help so that `allani search --help` prints the search help
# rather than being handed to the command as an option it does not understand,
# then defers to the command's own validate for anything else.
#
#   - $opt :: The parsed options object for this invocation.
#
#   - $args :: An array ref of the remaining command line arguments, after the
#       options have been removed.
#
# Returns whatever the command's validate returns -- by convention 1 -- when the
# arguments are acceptable. Never returns when --help was given: the help
# command is run and the process exits 0. A command that rejects its arguments
# does so by dying from its own validate.
#
# Not called directly; App::Cmd invokes it. In effect:
#
#     allani search --help      # prints the search help, exits
#     allani search --limit 5   # falls through to Allani::Command::search::validate
sub validate_args {
	my ( $self, $opt, $args ) = @_;
	if ( $opt->{help} ) {
		my ($command) = $self->command_names;
		$self->app->execute_command( $self->app->prepare_command( "help", $command ) );
		exit;
	}
	$self->validate( $opt, $args );
} ## end sub validate_args

return 1;
