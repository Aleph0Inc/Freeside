# $Header: /home/cvs/cvsroot/freeside/rt/lib/RT/Attic/Watchers.pm,v 1.1 2002-08-12 06:17:07 ivan Exp $
# (c) 1996-2000 Jesse Vincent <jesse@fsck.com>
# This software is redistributable under the terms of the GNU GPL

=head1 NAME

  RT::Watchers - Collection of RT Watcher objects

=head1 SYNOPSIS

  use RT::Watchers;
  my $watchers = new RT::Watchers($CurrentUser);
  while (my $watcher = $watchers->Next()) {
    print $watcher->Id . "is a watcher";
  }  

=head1 DESCRIPTION

This module should never be called directly by client code. it's an internal module which
should only be accessed through exported APIs in Ticket, Queue and other similar objects.


=head1 METHODS

=begin testing

ok(require RT::TestHarness);
ok(require RT::Watchers);

=end testing

=cut

package RT::Watchers;

use strict;
use vars qw( @ISA );


require RT::EasySearch;
require RT::Watcher;
@ISA= qw(RT::EasySearch);


# {{{ sub _Init
sub _Init  {
  my $self = shift;
  
  $self->{'table'} = "Watchers";
  $self->{'primary_key'} = "id";
  return($self->SUPER::_Init(@_));
}
# }}}

# {{{ sub Limit 

=head2 Limit

  A wrapper around RT::EasySearch::Limit which sets
the default entry aggregator to 'AND'

=cut

sub Limit  {
  my $self = shift;
  my %args = ( ENTRYAGGREGATOR => 'AND',
	       @_);

  $self->SUPER::Limit(%args);
}
# }}}

# {{{ sub LimitToTicket

=head2 LimitToTicket

Takes a single arg which is a ticket id
Limits to watchers of that ticket

=cut

sub LimitToTicket { 
  my $self = shift;
  my $ticket = shift;
  $self->Limit( ENTRYAGGREGATOR => 'OR',
		FIELD => 'Value',
		VALUE => $ticket);
  $self->Limit (ENTRYAGGREGATOR => 'AND',
		FIELD => 'Scope',
		VALUE => 'Ticket');
}
# }}}

# {{{ sub LimitToQueue 

=head2 LimitToQueue

Takes a single arg, which is a queue id
Limits to watchers of that queue.

=cut

sub LimitToQueue  {
  my $self = shift;
  my $queue = shift;
  $self->Limit (ENTRYAGGREGATOR => 'OR',
		FIELD => 'Value',
		VALUE => $queue);
  $self->Limit (ENTRYAGGREGATOR => 'AND',
		FIELD => 'Scope',
		VALUE => 'Queue');
}
# }}}

# {{{ sub LimitToType 

=head2 LimitToType

Takes a single string as its argument. That string is a watcher type
which is one of 'Requestor', 'Cc' or 'AdminCc'
Limits to watchers of that type

=cut


sub LimitToType  {
  my $self = shift;
  my $type = shift;
  $self->Limit(FIELD => 'Type',
	       VALUE => "$type");
}
# }}}

# {{{ sub LimitToRequestors 

=head2 LimitToRequestors

Limits to watchers of type 'Requestor'

=cut

sub LimitToRequestors  {
  my $self = shift;
  $self->LimitToType("Requestor");
}
# }}}

# {{{ sub LimitToCc 

=head2 LimitToCc

Limits to watchers of type 'Cc'

=cut

sub LimitToCc  {
    my $self = shift;
    $self->LimitToType("Cc");
}
# }}}

# {{{ sub LimitToAdminCc 

=head2 LimitToAdminCc

Limits to watchers of type AdminCc

=cut

sub LimitToAdminCc  {
    my $self = shift;
    $self->LimitToType("AdminCc");
}
# }}}

# {{{ sub Emails 

=head2 Emails

# Return a (reference to a) list of emails

=cut

sub Emails  {
    my $self = shift;
    my @list;    # List is a list of watcher email addresses

    # $watcher is an RT::Watcher object
    while (my $watcher=$self->Next()) {
	push(@list, $watcher->Email);
    }
    return \@list;
}
# }}}

# {{{ sub EmailsAsString

=head2 EmailsAsString

# Returns the RT::Watchers->Emails as a comma seperated string

=cut

sub EmailsAsString {
    my $self = shift;
    return(join(", ",@{$self->Emails}));
}
# }}}

# {{{ sub NewItem 



sub NewItem  {
    my $self = shift;
    
    use RT::Watcher;
    my  $item = new RT::Watcher($self->CurrentUser);
    return($item);
}
# }}}
1;




