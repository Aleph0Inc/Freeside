#$Header: /home/cvs/cvsroot/freeside/rt/lib/RT/Action/NotifyAsComment.pm,v 1.1 2002-08-12 06:17:07 ivan Exp $

package RT::Action::NotifyAsComment;
require RT::Action::Notify;
@ISA = qw(RT::Action::Notify);


=head2 SetReturnAddress

Tell SendEmail that this message should come out as a comment. 
Calls SUPER::SetReturnAddress.

=cut

sub SetReturnAddress {
	my $self = shift;
	
	# Tell RT::Action::SendEmail that this should come 
	# from the relevant comment email address.
	$self->{'comment'} = 1;
	
	return($self->SUPER::SetReturnAddress(is_comment => 1));
}
1;

