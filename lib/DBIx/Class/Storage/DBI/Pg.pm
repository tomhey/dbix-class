package DBIx::Class::Storage::DBI::Pg;

use strict;
use warnings;

use base qw/
    DBIx::Class::Storage::DBI::MultiColumnIn
/;
use mro 'c3';

use Scope::Guard ();
use Context::Preserve 'preserve_context';
use DBIx::Class::Carp;
use namespace::clean;

__PACKAGE__->sql_limit_dialect ('LimitOffset');
__PACKAGE__->sql_quote_char ('"');
__PACKAGE__->datetime_parser_type ('DateTime::Format::Pg');

sub _determine_supports_insert_returning {
  return shift->_server_info->{normalized_dbms_version} >= 8.002
    ? 1
    : 0
  ;
}

sub with_deferred_fk_checks {
  my ($self, $sub) = @_;

  my $txn_scope_guard = $self->txn_scope_guard;

  $self->_do_query('SET CONSTRAINTS ALL DEFERRED');

  my $sg = Scope::Guard->new(sub {
    $self->_do_query('SET CONSTRAINTS ALL IMMEDIATE');
  });

  return preserve_context { $sub->() } after => sub { $txn_scope_guard->commit };
}

# only used when INSERT ... RETURNING is disabled
sub last_insert_id {
  my ($self,$source,@cols) = @_;

  my @values;

  my $col_info = $source->columns_info(\@cols);

  for my $col (@cols) {
    my $seq = ( $col_info->{$col}{sequence} ||= $self->dbh_do('_dbh_get_autoinc_seq', $source, $col) )
      or $self->throw_exception( sprintf(
        'could not determine sequence for column %s.%s, please consider adding a schema-qualified sequence to its column info',
          $source->name,
          $col,
      ));

    push @values, $self->_dbh->last_insert_id(undef, undef, undef, undef, {sequence => $seq});
  }

  return @values;
}

sub _sequence_fetch {
  my ($self, $function, $sequence) = @_;

  $self->throw_exception('No sequence to fetch') unless $sequence;

  my ($val) = $self->_get_dbh->selectrow_array(
    sprintf ("select %s('%s')", $function, (ref $sequence eq 'SCALAR') ? $$sequence : $sequence)
  );

  return $val;
}

sub _dbh_get_autoinc_seq {
  my ($self, $dbh, $source, $col) = @_;

  my $schema;
  my $table = $source->name;

  # deref table name if it needs it
  $table = $$table
      if ref $table eq 'SCALAR';

  # parse out schema name if present
  if( $table =~ /^(.+)\.(.+)$/ ) {
    ( $schema, $table ) = ( $1, $2 );
  }

  # get the column default using a Postgres-specific pg_catalog query
  my $seq_expr = $self->_dbh_get_column_default( $dbh, $schema, $table, $col );

  # if no default value is set on the column, or if we can't parse the
  # default value as a sequence, throw.
  unless ( defined $seq_expr and $seq_expr =~ /^nextval\(+'([^']+)'::(?:text|regclass)\)/i ) {
    $seq_expr = '' unless defined $seq_expr;
    $schema = "$schema." if defined $schema && length $schema;
    $self->throw_exception( sprintf (
      'no sequence found for %s%s.%s, check the RDBMS table definition or explicitly set the '.
      "'sequence' for this column in %s",
        $schema ? "$schema." : '',
        $table,
        $col,
        $source->source_name,
    ));
  }

  return $1;
}

# custom method for fetching column default, since column_info has a
# bug with older versions of DBD::Pg
sub _dbh_get_column_default {
  my ( $self, $dbh, $schema, $table, $col ) = @_;

  # Build and execute a query into the pg_catalog to find the Pg
  # expression for the default value for this column in this table.
  # If the table name is schema-qualified, query using that specific
  # schema name.

  # Otherwise, find the table in the standard Postgres way, using the
  # search path.  This is done with the pg_catalog.pg_table_is_visible
  # function, which returns true if a given table is 'visible',
  # meaning the first table of that name to be found in the search
  # path.

  # I *think* we can be assured that this query will always find the
  # correct column according to standard Postgres semantics.
  #
  # -- rbuels

  my $sqlmaker = $self->sql_maker;
  local $sqlmaker->{bindtype} = 'normal';

  my ($where, @bind) = $sqlmaker->where ({
    'a.attnum' => {'>', 0},
    'c.relname' => $table,
    'a.attname' => $col,
    -not_bool => 'a.attisdropped',
    (defined $schema && length $schema)
      ? ( 'n.nspname' => $schema )
      : ( -bool => \'pg_catalog.pg_table_is_visible(c.oid)' )
  });

  my ($seq_expr) = $dbh->selectrow_array(<<EOS,undef,@bind);

SELECT
  (SELECT pg_catalog.pg_get_expr(d.adbin, d.adrelid)
   FROM pg_catalog.pg_attrdef d
   WHERE d.adrelid = a.attrelid AND d.adnum = a.attnum AND a.atthasdef)
FROM pg_catalog.pg_class c
     LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid
$where

EOS

  return $seq_expr;
}


sub sqlt_type {
  return 'PostgreSQL';
}

my $type_cache;
sub bind_attribute_by_data_type {
  my ($self,$data_type) = @_;

  # Ask for a DBD::Pg with array support
  # pg uses (used?) version::qv()
  require DBD::Pg;
  if ($DBD::Pg::VERSION < 2.009002) {
    carp_once( __PACKAGE__.": DBD::Pg 2.9.2 or greater is strongly recommended\n" );
  }

  # cache the result of _is_binary_lob_type
  if (!exists $type_cache->{$data_type}) {
    $type_cache->{$data_type} = $self->_is_binary_lob_type($data_type)
      ? +{ pg_type => DBD::Pg::PG_BYTEA() }
      : undef
  }

  $type_cache->{$data_type};
}

sub _svp_begin {
    my ($self, $name) = @_;

    $self->_get_dbh->pg_savepoint($name);
}

sub _svp_release {
    my ($self, $name) = @_;

    $self->_get_dbh->pg_release($name);
}

sub _svp_rollback {
    my ($self, $name) = @_;

    $self->_get_dbh->pg_rollback_to($name);
}

sub deployment_statements {
  my $self = shift;;
  my ($schema, $type, $version, $dir, $sqltargs, @rest) = @_;

  $sqltargs ||= {};

  if (
    ! exists $sqltargs->{producer_args}{postgres_version}
      and
    my $dver = $self->_server_info->{normalized_dbms_version}
  ) {
    $sqltargs->{producer_args}{postgres_version} = $dver;
  }

  $self->next::method($schema, $type, $version, $dir, $sqltargs, @rest);
}

1;

__END__

=head1 NAME

DBIx::Class::Storage::DBI::Pg - Automatic primary key class for PostgreSQL

=head1 SYNOPSIS

  # In your result (table) classes
  use base 'DBIx::Class::Core';
  __PACKAGE__->set_primary_key('id');

=head1 DESCRIPTION

This class implements autoincrements for PostgreSQL.

=head1 POSTGRESQL SCHEMA SUPPORT

This driver supports multiple PostgreSQL schemas, with one caveat: for
performance reasons, data about the search path, sequence names, and
so forth is queried as needed and CACHED for subsequent uses.

For this reason, once your schema is instantiated, you should not
change the PostgreSQL schema search path for that schema's database
connection. If you do, Bad Things may happen.

You should do any necessary manipulation of the search path BEFORE
instantiating your schema object, or as part of the on_connect_do
option to connect(), for example:

   my $schema = My::Schema->connect
                  ( $dsn,$user,$pass,
                    { on_connect_do =>
                        [ 'SET search_path TO myschema, foo, public' ],
                    },
                  );

=head1 AUTHORS

See L<DBIx::Class/CONTRIBUTORS>

=head1 LICENSE

You may distribute this code under the same terms as Perl itself.

=cut
