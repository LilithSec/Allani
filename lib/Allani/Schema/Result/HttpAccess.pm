use utf8;
package Allani::Schema::Result::HttpAccess;

=head1 NAME

Allani::Schema::Result::HttpAccess

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<http_access>

=cut

__PACKAGE__->table("http_access");

=head1 ACCESSORS

=head2 id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'http_access_id_seq'

=head2 r_isodate

  data_type: 'timestamp with time zone'
  is_nullable: 0

=head2 req_isodate

  data_type: 'timestamp with time zone'
  is_nullable: 1

=head2 host

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 vhost

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 vhost_port

  data_type: 'integer'
  is_nullable: 1

=head2 client_ip

  data_type: 'inet'
  is_nullable: 1

=head2 ident

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 auth

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 method

  data_type: 'varchar'
  is_nullable: 1
  size: 16

=head2 request

  data_type: 'text'
  is_nullable: 1

=head2 http_version

  data_type: 'varchar'
  is_nullable: 1
  size: 16

=head2 status

  data_type: 'integer'
  is_nullable: 1

=head2 bytes

  data_type: 'bigint'
  is_nullable: 1

=head2 referrer

  data_type: 'text'
  is_nullable: 1

=head2 user_agent

  data_type: 'text'
  is_nullable: 1

=head2 raw

  data_type: 'jsonb'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "http_access_id_seq",
  },
  "r_isodate",
  { data_type => "timestamp with time zone", is_nullable => 0 },
  "req_isodate",
  { data_type => "timestamp with time zone", is_nullable => 1 },
  "host",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "vhost",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "vhost_port",
  { data_type => "integer", is_nullable => 1 },
  "client_ip",
  { data_type => "inet", is_nullable => 1 },
  "ident",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "auth",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "method",
  { data_type => "varchar", is_nullable => 1, size => 16 },
  "request",
  { data_type => "text", is_nullable => 1 },
  "http_version",
  { data_type => "varchar", is_nullable => 1, size => 16 },
  "status",
  { data_type => "integer", is_nullable => 1 },
  "bytes",
  { data_type => "bigint", is_nullable => 1 },
  "referrer",
  { data_type => "text", is_nullable => 1 },
  "user_agent",
  { data_type => "text", is_nullable => 1 },
  "raw",
  { data_type => "jsonb", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

1;
