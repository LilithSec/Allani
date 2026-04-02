use utf8;
package Allani::Schema::Result::Syslog;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Allani::Schema::Result::Syslog

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<syslog>

=cut

__PACKAGE__->table("syslog");

=head1 ACCESSORS

=head2 id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'syslog_id_seq'

=head2 c_isodate

  data_type: 'timestamp with time zone'
  is_nullable: 1

=head2 r_isodate

  data_type: 'timestamp with time zone'
  is_nullable: 1

=head2 s_isodate

  data_type: 'timestamp with time zone'
  is_nullable: 1

=head2 facility

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 host

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 host_from

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 pid

  data_type: 'bigint'
  is_nullable: 1

=head2 priority

  data_type: 'varchar'
  is_nullable: 1
  size: 64

=head2 program

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 sourceip

  data_type: 'inet'
  is_nullable: 1

=head2 raw

  data_type: 'jsonb'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "syslog_id_seq",
  },
  "c_isodate",
  { data_type => "timestamp with time zone", is_nullable => 1 },
  "r_isodate",
  { data_type => "timestamp with time zone", is_nullable => 1 },
  "s_isodate",
  { data_type => "timestamp with time zone", is_nullable => 1 },
  "facility",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "host",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "host_from",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "pid",
  { data_type => "bigint", is_nullable => 1 },
  "priority",
  { data_type => "varchar", is_nullable => 1, size => 64 },
  "program",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "sourceip",
  { data_type => "inet", is_nullable => 1 },
  "raw",
  { data_type => "jsonb", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2026-03-30 20:22:40
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:t5c1O7FJVEJREnla40DMyA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
