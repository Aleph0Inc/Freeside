# $Header: /home/cvs/cvsroot/freeside/rt/lib/RT/Transaction.pm,v 1.1 2002-08-12 06:17:07 ivan Exp $
# Copyright 1999-2001 Jesse Vincent <jesse@fsck.com>
# Released under the terms of the GNU Public License

=head1 NAME

  RT::Transaction - RT\'s transaction object

=head1 SYNOPSIS

  use RT::Transaction;


=head1 DESCRIPTION


Each RT::Transaction describes an atomic change to a ticket object 
or an update to an RT::Ticket object.
It can have arbitrary MIME attachments.


=head1 METHODS

=begin testing

ok(require RT::TestHarness);
ok(require RT::Transaction);

=end testing

=cut

package RT::Transaction;

use RT::Record;
@ISA= qw(RT::Record);
    
use RT::Attachments;

# {{{ sub _Init 
sub _Init  {
    my $self = shift;
  $self->{'table'} = "Transactions";
  return ($self->SUPER::_Init(@_));

}
# }}}

# {{{ sub Create 

=head2 Create

Create a new transaction.

This routine should _never_ be called anything other Than RT::Ticket. It should not be called 
from client code. Ever. Not ever.  If you do this, we will hunt you down. and break your kneecaps.
Then the unpleasant stuff will start.

TODO: Document what gets passed to this

=cut

sub Create  {
    my $self = shift;
    my %args = ( id => undef,
		 TimeTaken => 0,
		 Ticket => 0 ,
		 Type => 'undefined',
		 Data => '',
		 Field => undef,
		 OldValue => undef,
		 NewValue => undef,
		 MIMEObj => undef,
		 ActivateScrips => 1,
		 @_
	       );
    
    #if we didn't specify a ticket, we need to bail
    unless ( $args{'Ticket'} ) {
	return(0, "RT::Transaction->Create couldn't, as you didn't specify a ticket id");
    }
        
    #lets create our transaction
    my $id = $self->SUPER::Create(Ticket => $args{'Ticket'},
	                          TimeTaken => $args{'TimeTaken'},
				  Type => $args{'Type'},
				  Data => $args{'Data'},
				  Field => $args{'Field'},
				  OldValue => $args{'OldValue'},
				  NewValue => $args{'NewValue'},
				  Created => $args{'Created'}
				 );
    $self->Load($id);
    $self->_Attach($args{'MIMEObj'})
      if defined $args{'MIMEObj'};
    
    #Provide a way to turn off scrips if we need to
    if ($args{'ActivateScrips'}) {

	#We're really going to need a non-acled ticket for the scrips to work
	my $TicketAsSystem = RT::Ticket->new($RT::SystemUser);
	$TicketAsSystem->Load($args{'Ticket'}) || 
	  $RT::Logger->err("$self couldn't load ticket $args{'Ticket'}\n");
	
	my $TransAsSystem = RT::Transaction->new($RT::SystemUser);
	$TransAsSystem->Load($self->id) ||
	  $RT::Logger->err("$self couldn't load a copy of itself as superuser\n");
	
	# {{{ Deal with Scrips
    
    #Load a scripscopes object
    use RT::Scrips;
    my $PossibleScrips = RT::Scrips->new($RT::SystemUser);
    
    $PossibleScrips->LimitToQueue($TicketAsSystem->QueueObj->Id); #Limit it to  $Ticket->QueueObj->Id
    $PossibleScrips->LimitToGlobal(); # or to "global"
    my $ConditionsAlias = $PossibleScrips->NewAlias('ScripConditions');
    
    $PossibleScrips->Join(ALIAS1 => 'main',  FIELD1 => 'ScripCondition',
			  ALIAS2 => $ConditionsAlias, FIELD2=> 'id');
    
    
    #We only want things where the scrip applies to this sort of transaction
    $PossibleScrips->Limit(ALIAS=> $ConditionsAlias,
			   FIELD=>'ApplicableTransTypes',
			   OPERATOR => 'LIKE',
			   VALUE => $args{'Type'},
			   ENTRYAGGREGATOR => 'OR',
			  );
    
    # Or where the scrip applies to any transaction
    $PossibleScrips->Limit(ALIAS=> $ConditionsAlias,
			   FIELD=>'ApplicableTransTypes',
			   OPERATOR => 'LIKE',
			   VALUE => "Any",
			   ENTRYAGGREGATOR => 'OR',
			  );			    
    
    #Iterate through each script and check it's applicability.
    
    while (my $Scrip = $PossibleScrips->Next()) {
      
      #TODO: properly deal with errors raised in this scrip loop
	
      #$RT::Logger->debug("$self now dealing with ".$Scrip->Id. "\n");      
	eval {
	  local $SIG{__DIE__} = sub { $RT::Logger->error($_[0])};
	  
	  
	  #Load the scrip's Condition object
	  $Scrip->ConditionObj->LoadCondition(TicketObj => $TicketAsSystem, 
					      TransactionObj => $TransAsSystem);	  
	  
	  
	  #If it's applicable, prepare and commit it
	  
	$RT::Logger->debug ("$self: Checking condition ".$Scrip->ConditionObj->Name. "...\n");
	  
	  if ( $Scrip->IsApplicable() ) {
	      
		$RT::Logger->debug ("$self: Matches condition ".$Scrip->ConditionObj->Name. "...\n");
	      #TODO: handle some errors here
	      
	      $Scrip->ActionObj->LoadAction(TicketObj => $TicketAsSystem, 
					   TransactionObj => $TransAsSystem);
	  
	      
	      if ($Scrip->Prepare()) {
		  $RT::Logger->debug("$self: Prepared " .
				   $Scrip->ActionObj->Name . "\n");
		  if ($Scrip->Commit()) {
			$RT::Logger->debug("$self: Committed " .
					   $Scrip->ActionObj->Name . "\n");
	     	  }
		  else {
			$RT::Logger->info("$self: Failed to commit ".
					   $Scrip->ActionObj->Name . "\n");
		  } 
	      }
	      else {
		  $RT::Logger->info("$self: Failed to prepare " .
				     $Scrip->ActionObj->Name . "\n");
	      }

	      #We're done with it. lets clean up.
	      #TODO: something else isn't letting these get garbage collected. check em out.
	      $Scrip->ActionObj->DESTROY();
	      $Scrip->ConditionObj->DESTROY;
	  }
	  
	  
	else {
	    $RT::Logger->debug ("$self: Doesn't match condition ".$Scrip->ConditionObj->Name. "...\n");

	    # TODO: why doesn't this catch all the ScripObjs we create. 
	    # and why do we explictly need to destroy them?
	    $Scrip->ConditionObj->DESTROY;
	}
      }	
    }

    # }}}
	
    }

    return ($id, "Transaction Created");
}

# }}}

# {{{ sub Delete

sub Delete {
    my $self = shift;
    return (0, 'Deleting this object could break referential integrity');
}

# }}}

# {{{ Routines dealing with Attachments

# {{{ sub Message 

=head2 Message

  Returns the RT::Attachments Object which contains the "top-level" object
  attachment for this transaction

=cut

sub Message  {

    my $self = shift;
    
    if (!defined ($self->{'message'}) ){
	
	$self->{'message'} = new RT::Attachments($self->CurrentUser);
	$self->{'message'}->Limit(FIELD => 'TransactionId',
				  VALUE => $self->Id);
	
	$self->{'message'}->ChildrenOf(0);
    } 
    return($self->{'message'});
}
# }}}

# {{{ sub Content

=head2 Content PARAMHASH

If this transaction has attached mime objects, returns the first text/ part.
Otherwise, returns undef.

Takes a paramhash.  If the $args{'Quote'} parameter is set, wraps this message 
at $args{'Wrap'}.  $args{'Wrap'} defaults to 70.


=cut

sub Content {
    my $self = shift;
    my %args = ( Quote => 0,
		 Wrap => 70,
		 @_ );

    my $content = undef;

    # If we don\'t have any content, return undef now.
    unless ($self->Message->First) {
	return (undef);
    }	
    
    # Get the set of toplevel attachments to this transaction.
    my $MIMEObj = $self->Message->First();
    
    # If it's a message or a plain part, just return the
    # body. 
    if ($MIMEObj->ContentType() =~ '^(text|message)(/|$)') {
	$content = $MIMEObj->Content();
    }
    
    # If it's a multipart object, first try returning the first 
    # text/plain part. 
    
    elsif ($MIMEObj->ContentType() =~ '^multipart/') {
	my $plain_parts = $MIMEObj->Children();
	$plain_parts->ContentType(VALUE => 'text/plain');
	
	# If we actully found a part, return its content
	if ($plain_parts->First && 
        $plain_parts->First->Content ne '') {
	    $content = $plain_parts->First->Content;		
	}	
	
	# If that fails, return the  first text/ or message/ part 
	# which has some content.
    
	else {
	    my $all_parts = $MIMEObj->Children();
	    while (($content == undef) && 
		   (my $part = $all_parts->Next)) {
		if (($part->ContentType() =~ '^(text|message)(/|$)') and
		    ($part->Content())) {
		    $content = $part->Content;
		}	
	    }
	}	

    }
    # If all else fails, return a message that we couldn't find
    # any content
    else { 
        $content = 'This transaction appears to have no content';
    }	

    if ($args{'Quote'}) {
	# Remove quoted signature.
	$content =~ s/\n-- \n(.*)$//s;

	# What's the longest line like?
	foreach (split (/\n/,$content)) {
	    $max=length if ( length > $max);
	}

	if ($max>76) {
	    require Text::Wrapper;
	    my $wrapper=new Text::Wrapper
		(
		 columns => $args{'Wrap'}, 
		 body_start => ($max > 70*3 ? '   ' : ''),
		 par_start => ''
		 );
	    $content=$wrapper->wrap($content);
	}

	$content =~ s/^/> /gm;
	$content = '[' . $self->CreatorObj->Name() . ' - ' . $self->CreatedAsString()
	            . "]:\n\n"
   	        . $content . "\n\n";

    }

    return ($content); 
}
# }}}

# {{{ sub Subject

=head2 Subject

If this transaction has attached mime objects, returns the first one's subject
Otherwise, returns null
  
=cut

sub Subject {
    my $self = shift;
    if ($self->Message->First) {
	return ($self->Message->First->Subject);
    }
    else {
	return (undef);
    }
}
# }}}

# {{{ sub Attachments 

=head2 Attachments

  Returns all the RT::Attachment objects which are attached
to this transaction. Takes an optional parameter, which is
a ContentType that Attachments should be restricted to.

=cut


sub Attachments  {
    my $self = shift;
    my $Types = '';
    $Types = shift if (@_);

    my $Attachments = new RT::Attachments($self->CurrentUser);
    
    #If it's a comment, return an empty object if they don't have the right to see it
    if ($self->Type eq 'Comment') {
	unless ($self->CurrentUserHasRight('ShowTicketComments')) {
	    return ($Attachments);
	}
    }	
    #if they ain't got rights to see, return an empty object
    else {
	unless ($self->CurrentUserHasRight('ShowTicket')) {
	    return ($Attachments);
	}
    }
    
    $Attachments->Limit(FIELD => 'TransactionId',
			VALUE => $self->Id);

    # Get the attachments in the order they're put into
    # the database.  Arguably, we should be returning a tree
    # of attachments, not a set...but no current app seems to need
    # it. 

    $Attachments->OrderBy(ALIAS => 'main', 
			  FIELD => 'Id',
			  ORDER => 'asc');

    if ($Types) {
	$Attachments->ContentType( VALUE => "$Types",
				   OPERATOR => "LIKE");
    }
    
    
    return($Attachments);
    
}

# }}}

# {{{ sub _Attach 

=head2 _Attach

A private method used to attach a mime object to this transaction.

=cut

sub _Attach  {
    my $self = shift;
    my $MIMEObject = shift;
    
    if (!defined($MIMEObject)) {
	$RT::Logger->error("$self _Attach: We can't attach a mime object if you don't give us one.\n");
	return(0, "$self: no attachment specified");
    }
    
  
    use RT::Attachment;
    my $Attachment = new RT::Attachment ($self->CurrentUser);
    $Attachment->Create(TransactionId => $self->Id,
			Attachment => $MIMEObject);
    return ($Attachment, "Attachment created");
    
}

# }}}

# }}}

# {{{ Routines dealing with Transaction Attributes

# {{{ sub TicketObj

=head2 TicketObj

Returns this transaction's ticket object.

=cut

sub TicketObj {
    my $self = shift;
    if (! exists $self->{'TicketObj'}) {
	$self->{'TicketObj'} = new RT::Ticket($self->CurrentUser);
	$self->{'TicketObj'}->Load($self->Ticket);
    }
    
    return $self->{'TicketObj'};
}
# }}}

# {{{ sub Description 

=head2 Description

Returns a text string which describes this transaction

=cut


sub Description  {
    my $self = shift;

    #Check those ACLs
    #If it's a comment, we need to be extra special careful
    if ($self->__Value('Type') eq 'Comment') {
     	unless ($self->CurrentUserHasRight('ShowTicketComments')) {
	    return (0, "Permission Denied");
	}
    }	

    #if they ain't got rights to see, don't let em
    else {
	unless ($self->CurrentUserHasRight('ShowTicket')) {
	    return (0, "Permission Denied");
	}
    }

    if (!defined($self->Type)) {
	return("No transaction type specified");
    }
    
    return ($self->BriefDescription . " by " . $self->CreatorObj->Name);
}

# }}}

# {{{ sub BriefDescription 

=head2 BriefDescription

Returns a text string which briefly describes this transaction

=cut


sub BriefDescription  {
    my $self = shift;

    #Check those ACLs
    #If it's a comment, we need to be extra special careful
    if ($self->__Value('Type') eq 'Comment') {
     	unless ($self->CurrentUserHasRight('ShowTicketComments')) {
	    return (0, "Permission Denied");
	}
    }	

    #if they ain't got rights to see, don't let em
    else {
	unless ($self->CurrentUserHasRight('ShowTicket')) {
	    return (0, "Permission Denied");
	}
    }

    if (!defined($self->Type)) {
	return("No transaction type specified");
    }
    
    if ($self->Type eq 'Create'){
	return("Ticket created");
    }
    elsif ($self->Type =~ /Status/) {
	if ($self->Field eq 'Status') {
	    if ($self->NewValue eq 'dead') {
		return ("Ticket killed");
      }
	    else {
		return( "Status changed from ".  $self->OldValue . 
			" to ". $self->NewValue);

	    }
	}
	# Generic:
	return ($self->Field." changed from ".($self->OldValue||"(empty value)").
	  " to ".$self->NewValue );
      }
    
    if ($self->Type eq 'Correspond')    {
	return("Correspondence added");
    }
    
    elsif ($self->Type eq 'Comment')  {
	return( "Comments added");
    }
    
    elsif ($self->Type eq 'Keyword') {

	my $field = 'Keyword';

	if ($self->Field) {
	    my $keywordsel = new RT::KeywordSelect ($self->CurrentUser);
	    $keywordsel->Load($self->Field);
	    $field = $keywordsel->Name();
	}

	if ($self->OldValue eq '') {
	    return ($field." ".$self->NewValue." added");
	}
	elsif ($self->NewValue eq '') {
	    return ($field." ".$self->OldValue." deleted"); 
	    
	}
	else {
	    return ($field." ".$self->OldValue . " changed to ". 
		     $self->NewValue);
	}	
    }
    
    elsif ($self->Type eq 'Untake'){
	    return( "Untaken");
	}
    
    elsif ($self->Type eq "Take") {
	return( "Taken");
    }
    
    elsif ($self->Type eq "Force") {
        my $Old = RT::User->new($self->CurrentUser);
        $Old->Load($self->OldValue);
        my $New = RT::User->new($self->CurrentUser);
        $New->Load($self->NewValue);
	return "Owner forcibly changed from ".$Old->Name . " to ". $New->Name;
    }
    elsif ($self->Type eq "Steal") {
	my $Old = RT::User->new($self->CurrentUser);
	$Old->Load($self->OldValue);
	return "Stolen from ".$Old->Name;
    }
    
    elsif ($self->Type eq "Give") {
	my $New = RT::User->new($self->CurrentUser);
	$New->Load($self->NewValue);
	return( "Given to ".$New->Name);
    }
    
    elsif ($self->Type eq 'AddWatcher'){
	return( $self->Field." ". $self->NewValue ." added");
    }
    
    elsif ($self->Type eq 'DelWatcher'){
	return( $self->Field." ".$self->OldValue ." deleted");
    }
    
    elsif ($self->Type eq 'Subject') {
	return( "Subject changed to ".$self->Data);
    }
    elsif ($self->Type eq 'Told') {
	return( "User notified");
    }
    
    elsif ($self->Type eq 'AddLink') {
	return ($self->Data);
    }
    elsif ($self->Type eq 'DeleteLink') {
	return ($self->Data);
    }
    elsif ($self->Type eq 'Set') {
	if ($self->Field eq 'Queue') {
	    my $q1 = new RT::Queue($self->CurrentUser);
	    $q1->Load($self->OldValue);
	    my $q2 = new RT::Queue($self->CurrentUser);
	    $q2->Load($self->NewValue);
	    return ($self->Field . " changed from " . $q1->Name . " to ".
		    $q2->Name);
	}

        # Write the date/time change at local time:                    
    elsif ($self->Field =~  /Due|Starts|Started|Told/) {           
        my $t1 = new RT::Date($self->CurrentUser);                 
        $t1->Set(Format => 'ISO', Value => $self->NewValue);       
        my $t2 = new RT::Date($self->CurrentUser);                 
        $t2->Set(Format => 'ISO', Value => $self->OldValue);       
        return ($self->Field . " changed from " . $t2->AsString .  
                    " to ".$t1->AsString);      
    }                
	else {
	    return ($self->Field . " changed from " . $self->OldValue . 
		    " to ".$self->NewValue);
	}	
    }
    elsif ($self->Type eq 'PurgeTransaction') {
	return ("Transaction ".$self->Data. " purged");
    }
    else {
	return ("Default: ". $self->Type ."/". $self->Field . 
		" changed from " . $self->OldValue . 
		" to ".$self->NewValue);
	
    }
}

# }}}

# {{{ Utility methods

# {{{ sub IsInbound

=head2 IsInbound

Returns true if the creator of the transaction is a requestor of the ticket.
Returns false otherwise

=cut

sub IsInbound {
    my $self=shift;
    return ($self->TicketObj->IsRequestor($self->CreatorObj));
}

# }}}

# }}}

# {{{ sub _Accessible 

sub _Accessible  {
  my $self = shift;
  my %Cols = (
	      TimeTaken => 'read',
	      Ticket => 'read/public',
	      Type=> 'read',
	      Field => 'read',
	      Data => 'read',
	      NewValue => 'read',
	      OldValue => 'read',
	      Creator => 'read/auto',
	      Created => 'read/auto',
	     );
  return $self->SUPER::_Accessible(@_, %Cols);
}

# }}}

# }}}

# {{{ sub _Set

sub _Set {
    my $self = shift;
    return(0, 'Transactions are immutable');
}

# }}}

# {{{ sub _Value 

=head2 _Value

Takes the name of a table column.
Returns its value as a string, if the user passes an ACL check

=cut

sub _Value  {

    my $self = shift;
    my $field = shift;
    
    
    #if the field is public, return it.
    if ($self->_Accessible($field, 'public')) {
	return($self->__Value($field));
	
    }
    #If it's a comment, we need to be extra special careful
    if ($self->__Value('Type') eq 'Comment') {
	unless ($self->CurrentUserHasRight('ShowTicketComments')) {
	    return (undef);
	}
    }	
    #if they ain't got rights to see, don't let em
    else {
	unless ($self->CurrentUserHasRight('ShowTicket')) {
	    return (undef);
	}
    }	
    
    return($self->__Value($field));
    
}

# }}}

# {{{ sub CurrentUserHasRight

=head2 CurrentUserHasRight RIGHT

Calls $self->CurrentUser->HasQueueRight for the right passed in here.
passed in here.

=cut

sub CurrentUserHasRight {
    my $self = shift;
    my $right = shift;
    return ($self->CurrentUser->HasQueueRight(Right => "$right", 
                                              TicketObj => $self->TicketObj));            
}

# }}}

1;
