package FS::access_user_log;
use base qw( FS::Record );

use strict;
use FS::UID qw( dbh );
#use FS::Record qw( qsearch qsearchs );
use FS::CurrentUser;

=head1 NAME

FS::access_user_log - Object methods for access_user_log records

=head1 SYNOPSIS

  use FS::access_user_log;

  $record = new FS::access_user_log \%hash;
  $record = new FS::access_user_log { 'column' => 'value' };

  $error = $record->insert;

  $error = $new_record->replace($old_record);

  $error = $record->delete;

  $error = $record->check;

=head1 DESCRIPTION

An FS::access_user_log object represents a backoffice web server log entry.
  FS::access_user_log inherits from FS::Record.  The following fields are
currently supported:

=over 4

=item lognum

primary key

=item usernum

usernum

=item path

path

=item _date

_date

=item render_seconds

=back

=item pid

=back

=head1 METHODS

=over 4

=item new HASHREF

Creates a new log entry.  To add the log entry to the database, see L<"insert">.

Note that this stores the hash reference, not a distinct copy of the hash it
points to.  You can ask the object for a copy with the I<hash> method.

=cut

sub table { 'access_user_log'; }

=item insert_new_path PATH

Adds a log entry for PATH for the current user and timestamp.

=cut

sub insert_new_path {
  my( $class, $path, $render_seconds ) = @_;

  return '' unless defined $FS::CurrentUser::CurrentUser;

  my $self = $class->new( {
    'usernum'        => $FS::CurrentUser::CurrentUser->usernum,
    'path'           => $path,
    '_date'          => time,
    'render_seconds' => $render_seconds,
    'pid'            => $$,
  } );

  #so we can still log pages after a transaction-aborting SQL error (and then
  # show the # error page)
  local($FS::UID::dbh) = dbh->clone;
    #if current transaction is aborted (if we had a way to check for it)

  my $error = $self->insert;
  die $error if $error;

}

=item insert

Adds this record to the database.  If there is an error, returns the error,
otherwise returns false.

=item delete

Delete this record from the database.

=item replace OLD_RECORD

Replaces the OLD_RECORD with this one in the database.  If there is an error,
returns the error, otherwise returns false.

=item check

Checks all fields to make sure this is a valid log entry.  If there is
an error, returns the error, otherwise returns false.  Called by the insert
and replace methods.

=cut

sub check {
  my $self = shift;

  my $error = 
    $self->ut_numbern('lognum')
    || $self->ut_foreign_key('usernum', 'access_user', 'usernum')
    || $self->ut_text('path')
    || $self->ut_number('_date')
    || $self->ut_numbern('render_seconds')
    || $self->ut_numbern('pid')
  ;
  return $error if $error;

  $self->SUPER::check;
}

=back

=cut

sub _upgrade_schema {
  my ($class, %opts) = @_;

  my $sql = 'DROP TABLE IF EXISTS h_access_user_log';

  my $sth = dbh->prepare($sql) or die dbh->errstr;
  $sth->execute or die $sth->errstr;
}

=head1 BUGS

=head1 SEE ALSO

L<FS::Record>

=cut

1;

