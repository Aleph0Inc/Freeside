#$Header: /home/cvs/cvsroot/freeside/rt/lib/RT/ScripConditions.pm,v 1.1 2002-08-12 06:17:07 ivan Exp $

=head1 NAME

  RT::ScripConditions - Collection of Action objects

=head1 SYNOPSIS

  use RT::ScripConditions;


=head1 DESCRIPTION



=begin testing

ok (require RT::TestHarness);
ok (require RT::ScripConditions);

=end testing

=head1 METHODS

=cut

package RT::ScripConditions;
use RT::EasySearch;
use RT::ScripCondition;
@ISA= qw(RT::EasySearch);

# {{{ sub _Init
sub _Init { 
  my $self = shift;
  $self->{'table'} = "ScripConditions";
  $self->{'primary_key'} = "id";
  return ( $self->SUPER::_Init(@_));
}
# }}}

# {{{ sub LimitToType 
sub LimitToType  {
  my $self = shift;
  my $type = shift;
  $self->Limit (ENTRYAGGREGATOR => 'OR',
		FIELD => 'Type',
		VALUE => "$type")
      if defined $type;
  $self->Limit (ENTRYAGGREGATOR => 'OR',
		FIELD => 'Type',
		VALUE => "Correspond")
      if $type eq "Create";
  $self->Limit (ENTRYAGGREGATOR => 'OR',
		FIELD => 'Type',
		VALUE => 'any');
  
}
# }}}

# {{{ sub NewItem 
sub NewItem  {
  my $self = shift;
  return(RT::ScripCondition->new($self->CurrentUser));
}
# }}}


1;

