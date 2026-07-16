use utf8;
package Allani::Schema::Result::ManagedIndex;

=head1 NAME

Allani::Schema::Result::ManagedIndex

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<managed_indexes>

=cut

__PACKAGE__->table("managed_indexes");

=head1 ACCESSORS

=head2 id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'managed_indexes_id_seq'

=head2 tbl

  data_type: 'varchar'
  is_nullable: 0
  size: 64

=head2 field

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=head2 trigram

  data_type: 'boolean'
  default_value: false
  is_nullable: 0

=head2 index_name

  data_type: 'varchar'
  is_nullable: 0
  size: 63

=head2 created

  data_type: 'timestamp with time zone'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "managed_indexes_id_seq",
  },
  "tbl",
  { data_type => "varchar", is_nullable => 0, size => 64 },
  "field",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "trigram",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "index_name",
  { data_type => "varchar", is_nullable => 0, size => 63 },
  "created",
  { data_type => "timestamp with time zone", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 UNIQUE CONSTRAINTS

=head2 C<index_name>

=head2 C<tbl_field_trigram>

=cut

__PACKAGE__->add_unique_constraint( "managed_indexes_index_name_key", ["index_name"] );
__PACKAGE__->add_unique_constraint( "managed_indexes_tbl_field_trigram_key", [ "tbl", "field", "trigram" ] );

1;
