use utf8;
package Allani::Schema::Result::HttpError;

=head1 NAME

Allani::Schema::Result::HttpError

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<http_error>

=cut

__PACKAGE__->table("http_error");

=head1 ACCESSORS

=head2 id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'http_error_id_seq'

=head2 r_isodate

  data_type: 'timestamp with time zone'
  is_nullable: 0

=head2 err_isodate

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

=head2 loglevel

  data_type: 'varchar'
  is_nullable: 1
  size: 32

=head2 pid

  data_type: 'bigint'
  is_nullable: 1

=head2 code

  data_type: 'varchar'
  is_nullable: 1
  size: 64

=head2 server

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 request

  data_type: 'text'
  is_nullable: 1

=head2 message

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
    sequence          => "http_error_id_seq",
  },
  "r_isodate",
  { data_type => "timestamp with time zone", is_nullable => 0 },
  "err_isodate",
  { data_type => "timestamp with time zone", is_nullable => 1 },
  "host",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "vhost",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "vhost_port",
  { data_type => "integer", is_nullable => 1 },
  "client_ip",
  { data_type => "inet", is_nullable => 1 },
  "loglevel",
  { data_type => "varchar", is_nullable => 1, size => 32 },
  "pid",
  { data_type => "bigint", is_nullable => 1 },
  "code",
  { data_type => "varchar", is_nullable => 1, size => 64 },
  "server",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "request",
  { data_type => "text", is_nullable => 1 },
  "message",
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
