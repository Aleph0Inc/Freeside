# $Header: /home/cvs/cvsroot/freeside/rt/lib/RT/Condition/StatusChange.pm,v 1.1 2002-08-12 06:17:08 ivan Exp $
# Copyright 1996-2001 Jesse Vincent <jesse@fsck.com> 
# Released under the terms of the GNU General Public License

package RT::Condition::StatusChange;
require RT::Condition::Generic;

@ISA = qw(RT::Condition::Generic);


=head2 IsApplicable

If the argument passed in is equivalent to the new value of
the Status Obj

=cut

sub IsApplicable {
    my $self = shift;
    if (($self->TransactionObj->Field eq 'Status') and 
    ($self->Argument eq $self->TransactionObj->NewValue())) {
	return(1);
    } 
    else {
	return(undef);
    }
}

1;

