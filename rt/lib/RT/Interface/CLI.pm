# $Header: /home/cvs/cvsroot/freeside/rt/lib/RT/Interface/CLI.pm,v 1.1 2002-08-12 06:17:08 ivan Exp $
# RT is (c) 1996-2001 Jesse Vincent <jesse@fsck.com>

package RT::Interface::CLI;

use strict;


BEGIN {
    use Exporter ();
    use vars qw ($VERSION  @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
    
    # set the version for version checking
    $VERSION = do { my @r = (q$Revision: 1.1 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r }; # must be all one line, for MakeMaker
    
    @ISA         = qw(Exporter);
    
    # your exported package globals go here,
    # as well as any optionally exported functions
    @EXPORT_OK   = qw(&CleanEnv &LoadConfig &DBConnect 
		      &GetCurrentUser &GetMessageContent &debug);
}

=head1 NAME

  RT::Interface::CLI - helper functions for creating a commandline RT interface

=head1 SYNOPSIS

  use lib "!!RT_LIB_PATH!!";
  use lib "!!RT_ETC_PATH!!";

  use RT::Interface::CLI  qw(CleanEnv LoadConfig DBConnect 
	  		   GetCurrentUser GetMessageContent);

  #Clean out all the nasties from the environment
  CleanEnv();

  #Load etc/config.pm and drop privs
  LoadConfig();

  #Connect to the database and get RT::SystemUser and RT::Nobody loaded
  DBConnect();


  #Get the current user all loaded
  my $CurrentUser = GetCurrentUser();

=head1 DESCRIPTION


=head1 METHODS

=begin testing

ok(require RT::TestHarness);
ok(require RT::Interface::CLI);

=end testing

=cut


=head2 CleanEnv

Removes some of the nastiest nasties from the user\'s environment.

=cut

sub CleanEnv {
    $ENV{'PATH'} = '/bin:/usr/bin';    # or whatever you need
    $ENV{'CDPATH'} = '' if defined $ENV{'CDPATH'};
    $ENV{'SHELL'} = '/bin/sh' if defined $ENV{'SHELL'};
    $ENV{'ENV'} = '' if defined $ENV{'ENV'};
    $ENV{'IFS'} = ''		if defined $ENV{'IFS'};
}



=head2 LoadConfig

Loads RT's config file and then drops setgid privileges.

=cut

sub LoadConfig {
    
    #This drags in  RT's config.pm
    use config;
    
}	



=head2 DBConnect

  Calls RT::Init, which creates a database connection and then creates $RT::Nobody
  and $RT::SystemUser

=cut


sub DBConnect {
    use RT;
    RT::Init();
}



# {{{ sub GetCurrentUser 

=head2 GetCurrentUser

  Figures out the uid of the current user and returns an RT::CurrentUser object
loaded with that user.  if the current user isn't found, returns a copy of RT::Nobody.

=cut
sub GetCurrentUser  {
    
    my ($Gecos, $CurrentUser);
    
    require RT::CurrentUser;
    
    #Instantiate a user object
    
    $Gecos=(getpwuid($<))[0];

    #If the current user is 0, then RT will assume that the User object
    #is that of the currentuser.

    $CurrentUser = new RT::CurrentUser();
    $CurrentUser->LoadByGecos($Gecos);
    
    unless ($CurrentUser->Id) {
	$RT::Logger->debug("No user with a unix login of '$Gecos' was found. ");
    }
    return($CurrentUser);
}
# }}}

# {{{ sub GetMessageContent

=head2 GetMessageContent

Takes two arguments a source file and a boolean "edit".  If the source file
is undef or "", assumes an empty file.  Returns an edited file as an 
array of lines.

=cut

sub GetMessageContent {
    my %args = (  Source => undef,
		  Content => undef,
		  Edit => undef,
		  CurrentUser => undef,
		 @_);
    my $source = $args{'Source'};

    my $edit = $args{'Edit'};
    
    my $currentuser = $args{'CurrentUser'};
    my @lines;

    use File::Temp qw/ tempfile/;
    
    #Load the sourcefile, if it's been handed to us
    if ($source) {
	open (SOURCE, "<$source");
	@lines = (<SOURCE>);
	close (SOURCE);
    }
    elsif ($args{'Content'}) {
	@lines = split('\n',$args{'Content'});
    }
    #get us a tempfile.
    my ($fh, $filename) = tempfile();
	
    #write to a tmpfile
    for (@lines) {
	print $fh $_;
    }
    close ($fh);
    
    #Edit the file if we need to
    if ($edit) {	

	unless ($ENV{'EDITOR'}) {
	    $RT::Logger->crit('No $EDITOR variable defined'. "\n");
	    return undef;
	}
	system ($ENV{'EDITOR'}, $filename);
    }	
    
    open (READ, "<$filename");
    my @newlines = (<READ>);
    close (READ);

    unlink ($filename) unless (debug());
    return(\@newlines);
    
}

# }}}

# {{{ sub debug

sub debug {
    my $val = shift;
    my ($debug);
    if ($val) {
	$RT::Logger->debug($val."\n");
	if ($debug) {
	    print STDERR "$val\n";
	}
    }
    if ($debug) {
	return(1);
    }	
}

# }}}


1;
