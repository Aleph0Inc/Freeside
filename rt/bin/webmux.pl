# $Header: /home/cvs/cvsroot/freeside/rt/bin/Attic/webmux.pl,v 1.1 2002-08-12 06:17:07 ivan Exp $
# RT is (c) 1996-2000 Jesse Vincent (jesse@fsck.com);

use strict;
$ENV{'PATH'} = '/bin:/usr/bin';    # or whatever you need
$ENV{'CDPATH'} = '' if defined $ENV{'CDPATH'};
$ENV{'SHELL'} = '/bin/sh' if defined $ENV{'SHELL'};
$ENV{'ENV'} = '' if defined $ENV{'ENV'};
$ENV{'IFS'} = ''          if defined $ENV{'IFS'};


# We really don't want apache to try to eat all vm
# see http://perl.apache.org/guide/control.html#Preventing_mod_perl_Processes_Fr


package RT::Mason;

use CGI qw(-private_tempfiles); #bring this in before mason, to make sure we
				#set private_tempfiles
use HTML::Mason::ApacheHandler (args_method => 'CGI');
use HTML::Mason;  # brings in subpackages: Parser, Interp, etc.

use vars qw($VERSION %session $Nobody $SystemUser $r $m);

# List of modules that you want to use from components (see Admin
# manual for details)

#Clean up our umask...so that the session files aren't world readable, writable or executable
umask(0077);


	  
$VERSION="!!RT_VERSION!!";

use lib "!!RT_LIB_PATH!!";
use lib "!!RT_ETC_PATH!!";

#This drags in  RT's config.pm
use config;
use Carp;

{  
	    package HTML::Mason::Commands;
	    use vars qw(%session $m);
	  
	    use RT; 
	    use RT::Ticket;
	    use RT::Tickets;
	    use RT::Transaction;
	    use RT::Transactions;
	    use RT::User;
	    use RT::Users;
	    use RT::CurrentUser;
	    use RT::Template;
	    use RT::Templates;
	    use RT::Queue;
	    use RT::Queues;
	    use RT::ScripAction;
	    use RT::ScripActions;
	    use RT::ScripCondition;
	    use RT::ScripConditions;
	    use RT::Scrip;
	    use RT::Scrips;
	    use RT::Group;
	    use RT::Groups;
	    use RT::Keyword;
	    use RT::Keywords;
	    use RT::ObjectKeyword;
	    use RT::ObjectKeywords;
	    use RT::KeywordSelect;
	    use RT::KeywordSelects;
	    use RT::GroupMember;
	    use RT::GroupMembers;
	    use RT::Watcher;
	    use RT::Watchers;
	    use RT::Handle;
	    use RT::Interface::Web;    
	    use MIME::Entity;
	    use Text::Wrapper;
	    use Apache::Cookie;
	    use Date::Parse;
	    use HTML::Entities;
	    
	    #TODO: make this use DBI
	    use Apache::Session::File;

	    # Set this page's content type to whatever we are called with
	    sub SetContentType {
		my $type = shift;
		$RT::Mason::r->content_type($type);
	    }

	    sub CGIObject {
		$m->cgi_object();
	    }

	}
my ($parser, $interp, $ah);
if ($HTML::Mason::VERSION < 1.0902) {
 $parser = &RT::Interface::Web::NewParser(allow_globals => [%session]);

 $interp = &RT::Interface::Web::NewInterp(parser=>$parser,
                                          allow_recursive_autohandlers => 1,
                                                              );

 $ah = &RT::Interface::Web::NewApacheHandler($interp);
} else {
 $ah = &RT::Interface::Web::NewMason11ApacheHandler();
}
# Activate the following if running httpd as root (the normal case).
# Resets ownership of all files created by Mason at startup.
#
chown (Apache->server->uid, Apache->server->gid, 
		[$RT::MasonSessionDir]);


chown (Apache->server->uid, Apache->server->gid, 
		$ah->interp->files_written);

# Die if WebSessionDir doesn't exist or we can't write to it

stat ($RT::MasonSessionDir);
die "Can't read and write $RT::MasonSessionDir"
  unless (( -d _ ) and ( -r _ ) and ( -w _ ));


sub handler {
    ($r) = @_;
    
    RT::Init();
 
    # We don't need to handle non-text items
    return -1 if defined($r->content_type) && $r->content_type !~ m|^text/|io;
    
    #This is all largely cut and pasted from mason's session_handler.pl
    
    my %cookies = Apache::Cookie::parse($r->header_in('Cookie'));
    
    eval { 
	tie %HTML::Mason::Commands::session, 'Apache::Session::File',
	  ( $cookies{'AF_SID'} ? $cookies{'AF_SID'}->value() : undef ), 
	    { Directory => $RT::MasonSessionDir,
	      LockDirectory => $RT::MasonSessionDir,
	    }	;
    };
    
    if ( $@ ) {
	# If the session is invalid, create a new session.
	if ( $@ =~ m#^Object does not exist in the data store# ) {
	     tie %HTML::Mason::Commands::session, 'Apache::Session::File', undef,
	     { Directory => $RT::MasonSessionDir,
	       LockDirectory => $RT::MasonSessionDir,
	     };
	     undef $cookies{'AF_SID'};
	}
	  else {
	     die "RT Couldn't write to session directory '$RT::MasonSessionDir'. Check that this directory's permissions are correct.";
	  }
    }
    
    if ( !$cookies{'AF_SID'} ) {
	my $cookie = new Apache::Cookie
	  ($r,
	   -name=>'AF_SID', 
	   -value=>$HTML::Mason::Commands::session{_session_id}, 
	   -path => '/',);
	$cookie->bake;

    }
    my $status = $ah->handle_request($r);
    untie %HTML::Mason::Commands::session;
    
    return $status;
    
  }
1;

