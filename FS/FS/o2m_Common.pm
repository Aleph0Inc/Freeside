package FS::o2m_Common;

use strict;
use vars qw( $DEBUG $me );
use Carp;
use FS::Schema qw( dbdef );
use FS::Record qw( qsearch qsearchs dbh );

$DEBUG = 0;

$me = '[FS::o2m_Common]';

=head1 NAME

FS::o2m_Common - Mixin class for tables with a related table

=head1 SYNOPSIS

use FS::o2m_Common;

@ISA = qw( FS::o2m_Common FS::Record );

=head1 DESCRIPTION

FS::o2m_Common is intended as a mixin class for classes which have a
related table.

=head1 METHODS

=over 4

=item process_o2m OPTION => VALUE, ...

Available options:

table (required) - Table into which the records are inserted.

fields (required) - Arrayref of the field names in the "many" table.

params (required) - Hashref of keys and values, often passed as
C<scalar($cgi->Vars)> from a form. This will be scanned for keys of the form
"pkeyNN" (where pkey is the primary key column name, and NN is an integer).
Each of these designates one record in the "many" table. The contents of
that record will be taken from other parameters with the names
"pkeyNN_myfield" (where myfield is one of the fields in the 'fields'
array).

num_col (optional) - Name of the foreign key column in the "many" table, which
links to the primary key of the base table. If not specified, it is assumed
this has the same name as in the base table.

=cut

#a little more false laziness w/m2m_Common.pm than m2_name_Common.pm
# still, far from the worse of it.  at least we're a reuable mixin!
sub process_o2m {
  my( $self, %opt ) = @_;

  my $self_pkey = $self->dbdef_table->primary_key;
  my $link_sourcekey = $opt{'num_col'} || $self_pkey;

  my $hashref = {}; #$opt{'hashref'} || {};
  $hashref->{$link_sourcekey} = $self->$self_pkey();

  my $table = $self->_load_table($opt{'table'});
  my $table_pkey = dbdef->table($table)->primary_key;

#  my $link_static = $opt{'link_static'} || {};

  warn "$me processing o2m from ". $self->table. ".$link_sourcekey".
       " to $table\n"
    if $DEBUG;

  #if ( ref($opt{'params'}) eq 'ARRAY' ) {
  #  $opt{'params'} = { map { $_=>1 } @{$opt{'params'}} };
  #}

  local $SIG{HUP} = 'IGNORE';
  local $SIG{INT} = 'IGNORE';
  local $SIG{QUIT} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{TSTP} = 'IGNORE';
  local $SIG{PIPE} = 'IGNORE';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  my @fields = grep { /^$table_pkey\d+$/ }
               keys %{ $opt{'params'} };

  my %edits = map  { $opt{'params'}->{$_} => $_ }
              grep { $opt{'params'}->{$_} }
              @fields;

  foreach my $del_obj (
    grep { ! $edits{$_->$table_pkey()} }
         $self->process_o2m_qsearch( $table, $hashref )
  ) {
    my $error = $del_obj->delete;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }
  }

  foreach my $pkey_value ( keys %edits ) {
    my $old_obj = $self->process_o2m_qsearchs( $table, { %$hashref, $table_pkey => $pkey_value } );
    my $add_param = $edits{$pkey_value};
    my %hash = ( $table_pkey => $pkey_value,
                 map { $_ => $opt{'params'}->{$add_param."_$_"} }
                     @{ $opt{'fields'} }
               );
    &{ $opt{'hash_callback'} }( \%hash, $old_obj ) if $opt{'hash_callback'};
    #next unless grep { $_ =~ /\S/ } values %hash;

    my $new_obj = "FS::$table"->new( { %$hashref, %hash } );
    my $error = $new_obj->replace($old_obj);
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }
  }

  foreach my $add_param ( grep { ! $opt{'params'}->{$_} } @fields ) {

    my %hash = map { $_ => $opt{'params'}->{$add_param."_$_"} }
               @{ $opt{'fields'} };
    &{ $opt{'hash_callback'} }( \%hash ) if $opt{'hash_callback'};
    next unless grep { $_ =~ /\S/ } values %hash;

    my $add_obj = "FS::$table"->new( { %$hashref, %hash } );
    my $error = $add_obj->insert;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      return $error;
    }
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';
}

sub process_o2m_qsearch  { my $self = shift; qsearch(  @_ ); }
sub process_o2m_qsearchs { my $self = shift; qsearchs( @_ ); }

sub _load_table {
  my( $self, $table ) = @_;
  eval "use FS::$table";
  die $@ if $@;
  $table;
}

=back

=head1 BUGS

=head1 SEE ALSO

L<FS::Record>

=cut

1;

