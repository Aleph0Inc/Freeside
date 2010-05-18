#!/usr/bin/perl
# BEGIN BPS TAGGED BLOCK {{{
# 
# COPYRIGHT:
# 
# This software is Copyright (c) 1996-2009 Best Practical Solutions, LLC
#                                          <jesse@bestpractical.com>
# 
# (Except where explicitly superseded by other copyright notices)
# 
# 
# LICENSE:
# 
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
# 
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
# 
# 
# CONTRIBUTION SUBMISSION POLICY:
# 
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
# 
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
# 
# END BPS TAGGED BLOCK }}}
use strict;

package HTML::Mason::Commands;
our %session;

package RT::Mason;

our ($Nobody, $SystemUser, $Handler, $r);

sub handler {
    ($r) = @_;

    local $SIG{__WARN__};
    local $SIG{__DIE__};
    RT::InitSignalHandlers();

    if ($r->content_type =~ m/^httpd\b.*\bdirectory/i) {
        use File::Spec::Unix;
        # Our DirectoryIndex is always index.html, regardless of httpd settings
        $r->filename( File::Spec::Unix->catfile( $r->filename, 'index.html' ) );
    }

    Module::Refresh->refresh if RT->Config->Get('DevelMode');

    RT::ConnectToDatabase();

    my (%session, $status);
    {
        local $@;
        $status = eval { $Handler->handle_request($r) };
        $RT::Logger->crit( $@ ) if $@;
    }
    undef %session;

    RT::Interface::Web::Handler->CleanupRequest();

    return $status;
}

package main;

# check mod_perl version if it's mod_perl
BEGIN {
    die "RT does not support mod_perl 1.99. Please upgrade to mod_perl 2.0"
        if $ENV{'MOD_PERL'}
        and $ENV{'MOD_PERL'} =~ m{mod_perl/(?:1\.9)};
}

BEGIN {
    $ENV{'PATH'}   = '/bin:/usr/bin'; # or whatever you need
    $ENV{'CDPATH'} = '' if defined $ENV{'CDPATH'};
    $ENV{'SHELL'}  = '/bin/sh' if defined $ENV{'SHELL'};
    $ENV{'ENV'}    = '' if defined $ENV{'ENV'};
    $ENV{'IFS'}    = '' if defined $ENV{'IFS'};

    # bring this in before mason, to make sure we
    # use private tempfiles
    use CGI qw(-private_tempfiles);
}

# fix lib paths, some may be relative
BEGIN {
    require File::Spec;
    my @libs = ("lib", "local/lib");
    my $bin_path;

    for my $lib (@libs) {
        unless ( File::Spec->file_name_is_absolute($lib) ) {
            unless ($bin_path) {
                if ( File::Spec->file_name_is_absolute(__FILE__) ) {
                    $bin_path = ( File::Spec->splitpath(__FILE__) )[1];
                }
                else {
                    require FindBin;
                    no warnings "once";
                    $bin_path = $FindBin::Bin;
                }
            }
            $lib = File::Spec->catfile( $bin_path, File::Spec->updir, $lib );
        }
        unshift @INC, $lib;
    }

}

require RT;
RT::LoadConfig();
if ( RT->Config->Get('DevelMode') ) {
    require Module::Refresh;
}
RT::Init();

# check compatibility of the DB
{
    my $dbh = $RT::Handle->dbh;
    if ( $dbh ) {
        my ($status, $msg) = $RT::Handle->CheckCompatibility( $dbh, 'post' );
        die $msg unless $status;
    }
}

require RT::Interface::Web::Handler;
$RT::Mason::Handler = RT::Interface::Web::Handler->new(
    RT->Config->Get('MasonParameters')
);

# load more for mod_perl before forking
RT::InitClasses( Heavy => 1 ) if $ENV{'MOD_PERL'} || $ENV{RT_WEBMUX_HEAVY_LOAD};

# we must disconnect DB before fork
$RT::Handle->dbh(undef);
undef $RT::Handle;

if ( $ENV{'MOD_PERL'} && !RT->Config->Get('DevelMode')) {
    # Under static_source, we need to purge the component cache
    # each time we restart, so newer components may be reloaded.
    #
    # We can't do this in FastCGI or we'll blow away the component
    # root _every_ time a new server starts which happens every few
    # hits.
    
    require File::Path;
    require File::Glob;
    my @files = File::Glob::bsd_glob("$RT::MasonDataDir/obj/*");
    File::Path::rmtree([ @files ], 0, 1) if @files;
}

1;
