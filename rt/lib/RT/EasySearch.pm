#$Header: /home/cvs/cvsroot/freeside/rt/lib/RT/Attic/EasySearch.pm,v 1.1 2002-08-12 06:17:07 ivan Exp $

=head1 NAME

  RT::EasySearch - a baseclass for RT collection objects

=head1 SYNOPSIS

=head1 DESCRIPTION


=head1 METHODS


=begin testing

ok (require RT::EasySearch);

=end testing


=cut

package RT::EasySearch;
use DBIx::SearchBuilder;
@ISA= qw(DBIx::SearchBuilder);

# {{{ sub _Init 
sub _Init  {
    my $self = shift;
    
    $self->{'user'} = shift;
    unless(defined($self->CurrentUser)) {
	use Carp;
	Carp::confess("$self was created without a CurrentUser");
	$RT::Logger->err("$self was created without a CurrentUser\n"); 
	return(0);
    }
    $self->SUPER::_Init( 'Handle' => $RT::Handle);
}
# }}}

# {{{ sub LimitToEnabled

=head2 LimitToEnabled

Only find items that haven\'t been disabled

=cut

sub LimitToEnabled {
    my $self = shift;
    
    $self->Limit( FIELD => 'Disabled',
		  VALUE => '0',
		  OPERATOR => '=' );
}
# }}}

# {{{ sub LimitToDisabled

=head2 LimitToDeleted

Only find items that have been deleted.

=cut

sub LimitToDeleted {
    my $self = shift;
    
    $self->{'find_disabled_rows'} = 1;
    $self->Limit( FIELD => 'Disabled',
		  OPERATOR => '=',
		  VALUE => '1'
		);
}
# }}}


# {{{ sub Limit 

=head2 Limit PARAMHASH

This Limit sub calls SUPER::Limit, but defaults "CASESENSITIVE" to 1, thus
making sure that by default lots of things don't do extra work trying to 
match lower(colname) agaist lc($val);

=cut

sub Limit {
	my $self = shift;
	my %args = ( CASESENSITIVE => 1,
		     @_ );

   return $self->SUPER::Limit(%args);
}

# {{{ sub CurrentUser 

=head2 CurrentUser

  Returns the current user as an RT::User object.

=cut

sub CurrentUser  {
  my $self = shift;
  return ($self->{'user'});
}
# }}}
    

1;


