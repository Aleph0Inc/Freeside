package FS::ClientAPI::MyAccount;

use strict;
use vars qw($cache);
use subs qw(_cache);
use Digest::MD5 qw(md5_hex);
use Date::Format;
use Business::CreditCard;
use Time::Duration;
use FS::CGI qw(small_custview); #doh
use FS::UI::Web;
use FS::Conf;
use FS::Record qw(qsearch qsearchs);
use FS::Msgcat qw(gettext);
use FS::Misc qw(card_types);
use FS::ClientAPI_SessionCache;
use FS::svc_acct;
use FS::svc_domain;
use FS::svc_external;
use FS::part_svc;
use FS::cust_main;
use FS::cust_bill;
use FS::cust_main_county;
use FS::cust_pkg;
use HTML::Entities;

#false laziness with FS::cust_main
BEGIN {
  eval "use Time::Local;";
  die "Time::Local minimum version 1.05 required with Perl versions before 5.6"
    if $] < 5.006 && !defined($Time::Local::VERSION);
  eval "use Time::Local qw(timelocal_nocheck);";
}

use vars qw( @cust_main_editable_fields );
@cust_main_editable_fields = qw(
  first last company address1 address2 city
    county state zip country daytime night fax
  ship_first ship_last ship_company ship_address1 ship_address2 ship_city
    ship_state ship_zip ship_country ship_daytime ship_night ship_fax
  payby payinfo payname paystart_month paystart_year payissue payip
);

use subs qw(_provision);

sub _cache {
  $cache ||= new FS::ClientAPI_SessionCache( {
               'namespace' => 'FS::ClientAPI::MyAccount',
             } );
}

#false laziness w/FS::ClientAPI::passwd::passwd
sub login {
  my $p = shift;

  my $svc_domain = qsearchs('svc_domain', { 'domain' => $p->{'domain'} } )
    or return { error => 'Domain '. $p->{'domain'}. ' not found' };

  my $svc_acct = qsearchs( 'svc_acct', { 'username'  => $p->{'username'},
                                         'domsvc'    => $svc_domain->svcnum, }
                         );
  return { error => 'User not found.' } unless $svc_acct;

  my $conf = new FS::Conf;
  my $pkg_svc = $svc_acct->cust_svc->pkg_svc;
  return { error => 'Only primary user may log in.' } 
    if $conf->exists('selfservice_server-primary_only')
       && ( ! $pkg_svc || $pkg_svc->primary_svc ne 'Y' );

  return { error => 'Incorrect password.' }
    unless $svc_acct->check_password($p->{'password'});

  my $session = {
    'svcnum' => $svc_acct->svcnum,
  };

  my $cust_pkg = $svc_acct->cust_svc->cust_pkg;
  if ( $cust_pkg ) {
    my $cust_main = $cust_pkg->cust_main;
    $session->{'custnum'} = $cust_main->custnum;
  }

  my $session_id;
  do {
    $session_id = md5_hex(md5_hex(time(). {}. rand(). $$))
  } until ( ! defined _cache->get($session_id) ); #just in case

  _cache->set( $session_id, $session, '1 hour' );

  return { 'error'      => '',
           'session_id' => $session_id,
         };
}

sub logout {
  my $p = shift;
  if ( $p->{'session_id'} ) {
    _cache->remove($p->{'session_id'});
    return { 'error' => '' };
  } else {
    return { 'error' => "Can't resume session" }; #better error message
  }
}

sub customer_info {
  my $p = shift;

  my($context, $session, $custnum) = _custoragent_session_custnum($p);
  return { 'error' => $session } if $context eq 'error';

  my %return;
  if ( $custnum ) { #customer record

    my $search = { 'custnum' => $custnum };
    $search->{'agentnum'} = $session->{'agentnum'} if $context eq 'agent';
    my $cust_main = qsearchs('cust_main', $search )
      or return { 'error' => "unknown custnum $custnum" };

    $return{balance} = $cust_main->balance;

    my @open = map {
                     {
                       invnum => $_->invnum,
                       date   => time2str("%b %o, %Y", $_->_date),
                       owed   => $_->owed,
                     };
                   } $cust_main->open_cust_bill;
    $return{open_invoices} = \@open;

    my $conf = new FS::Conf;
    $return{small_custview} =
      small_custview( $cust_main, $conf->config('countrydefault') );

    $return{name} = $cust_main->first. ' '. $cust_main->get('last');

    for (@cust_main_editable_fields) {
      $return{$_} = $cust_main->get($_);
    }

    if ( $cust_main->payby =~ /^(CARD|DCRD)$/ ) {
      $return{payinfo} = $cust_main->paymask;
      @return{'month', 'year'} = $cust_main->paydate_monthyear;
    }

    $return{'invoicing_list'} =
      join(', ', grep { $_ !~ /^(POST|FAX)$/ } $cust_main->invoicing_list );
    $return{'postal_invoicing'} =
      0 < ( grep { $_ eq 'POST' } $cust_main->invoicing_list );

  } elsif ( $session->{'svcnum'} ) { #no customer record

    my $svc_acct = qsearchs('svc_acct', { 'svcnum' => $session->{'svcnum'} } )
      or die "unknown svcnum";
    $return{name} = $svc_acct->email;

  } else {

    return { 'error' => 'Expired session' }; #XXX redirect to login w/this err!

  }

  return { 'error'          => '',
           'custnum'        => $custnum,
           %return,
         };

}

sub edit_info {
  my $p = shift;
  my $session = _cache->get($p->{'session_id'})
    or return { 'error' => "Can't resume session" }; #better error message

  my $custnum = $session->{'custnum'}
    or return { 'error' => "no customer record" };

  my $cust_main = qsearchs('cust_main', { 'custnum' => $custnum } )
    or return { 'error' => "unknown custnum $custnum" };

  my $new = new FS::cust_main { $cust_main->hash };
  $new->set( $_ => $p->{$_} )
    foreach grep { exists $p->{$_} } @cust_main_editable_fields;

  if ( $p->{'payby'} =~ /^(CARD|DCRD)$/ ) {
    $new->paydate($p->{'year'}. '-'. $p->{'month'}. '-01');
    if ( $new->payinfo eq $cust_main->paymask ) {
      $new->payinfo($cust_main->payinfo);
    } else {
      $new->paycvv($p->{'paycvv'});
    }
  }

  my @invoicing_list;
  if ( exists $p->{'invoicing_list'} || exists $p->{'postal_invoicing'} ) {
    #false laziness with httemplate/edit/process/cust_main.cgi
    @invoicing_list = split( /\s*\,\s*/, $p->{'invoicing_list'} );
    push @invoicing_list, 'POST' if $p->{'postal_invoicing'};
  } else {
    @invoicing_list = $cust_main->invoicing_list;
  }

  my $error = $new->replace($cust_main, \@invoicing_list);
  return { 'error' => $error } if $error;
  #$cust_main = $new;
  
  return { 'error' => '' };
}

sub payment_info {
  my $p = shift;
  my $session = _cache->get($p->{'session_id'})
    or return { 'error' => "Can't resume session" }; #better error message

  ##
  #generic
  ##

  use vars qw($payment_info); #cache for performance
  unless ( $payment_info ) {

    my $conf = new FS::Conf;
    my %states = map { $_->state => 1 }
                   qsearch('cust_main_county', {
                     'country' => $conf->config('countrydefault') || 'US'
                   } );

    $payment_info = {

      #list all counties/states/countries
      'cust_main_county' => 
        [ map { $_->hashref } qsearch('cust_main_county', {}) ],

      #shortcut for one-country folks
      'states' =>
        [ sort { $a cmp $b } keys %states ],

      'card_types' => card_types(),

    };

  }

  ##
  #customer-specific
  ##

  my %return = %$payment_info;

  my $custnum = $session->{'custnum'};

  my $cust_main = qsearchs('cust_main', { 'custnum' => $custnum } )
    or return { 'error' => "unknown custnum $custnum" };

  $return{balance} = $cust_main->balance;

  $return{payname} = $cust_main->payname
                     || ( $cust_main->first. ' '. $cust_main->get('last') );

  $return{$_} = $cust_main->get($_) for qw(address1 address2 city state zip);

  $return{payby} = $cust_main->payby;

  if ( $cust_main->payby =~ /^(CARD|DCRD)$/ ) {
    $return{card_type} = cardtype($cust_main->payinfo);
    $return{payinfo} = $cust_main->payinfo;

    @return{'month', 'year'} = $cust_main->paydate_monthyear;

  }

  #doubleclick protection
  my $_date = time;
  $return{paybatch} = "webui-MyAccount-$_date-$$-". rand() * 2**32;

  return { 'error' => '',
           %return,
         };

};

#some false laziness with httemplate/process/payment.cgi - look there for
#ACH and CVV support stuff
sub process_payment {

  my $p = shift;

  my $session = _cache->get($p->{'session_id'})
    or return { 'error' => "Can't resume session" }; #better error message

  my %return;

  my $custnum = $session->{'custnum'};

  my $cust_main = qsearchs('cust_main', { 'custnum' => $custnum } )
    or return { 'error' => "unknown custnum $custnum" };

  $p->{'payname'} =~ /^([\w \,\.\-\']+)$/
    or return { 'error' => gettext('illegal_name'). " payname: ". $p->{'payname'} };
  my $payname = $1;

  $p->{'paybatch'} =~ /^([\w \!\@\#\$\%\&\(\)\-\+\;\:\'\"\,\.\?\/\=]*)$/
    or return { 'error' => gettext('illegal_text'). " paybatch: ". $p->{'paybatch'} };
  my $paybatch = $1;

  my $payinfo;
  my $paycvv = '';
  #if ( $payby eq 'CHEK' ) {
  #
  #  $p->{'payinfo1'} =~ /^(\d+)$/
  #    or return { 'error' => "illegal account number ". $p->{'payinfo1'} };
  #  my $payinfo1 = $1;
  #   $p->{'payinfo2'} =~ /^(\d+)$/
  #    or return { 'error' => "illegal ABA/routing number ". $p->{'payinfo2'} };
  #  my $payinfo2 = $1;
  #  $payinfo = $payinfo1. '@'. $payinfo2;
  # 
  #} elsif ( $payby eq 'CARD' ) {
   
    $payinfo = $p->{'payinfo'};
    $payinfo =~ s/\D//g;
    $payinfo =~ /^(\d{13,16})$/
      or return { 'error' => gettext('invalid_card') }; # . ": ". $self->payinfo
    $payinfo = $1;
    validate($payinfo)
      or return { 'error' => gettext('invalid_card') }; # . ": ". $self->payinfo
    return { 'error' => gettext('unknown_card_type') }
      if cardtype($payinfo) eq "Unknown";

    if ( defined $cust_main->dbdef_table->column('paycvv') ) {
      if ( length($p->{'paycvv'} ) ) {
        if ( cardtype($payinfo) eq 'American Express card' ) {
          $p->{'paycvv'} =~ /^(\d{4})$/
            or return { 'error' => "CVV2 (CID) for American Express cards is four digits." };
          $paycvv = $1;
        } else {
          $p->{'paycvv'} =~ /^(\d{3})$/
            or return { 'error' => "CVV2 (CVC2/CID) is three digits." };
          $paycvv = $1;
        }
      }
    }
  
  #} else {
  #  die "unknown payby $payby";
  #}

  my $error = $cust_main->realtime_bop( 'CC', $p->{'amount'},
    'quiet'    => 1,
    'payinfo'  => $payinfo,
    'paydate'  => $p->{'year'}. '-'. $p->{'month'}. '-01',
    'payname'  => $payname,
    'paybatch' => $paybatch,
    'paycvv'   => $paycvv,
    map { $_ => $p->{$_} } qw( paystart_month paystart_year payissue payip
                               address1 address2 city state zip )
  );
  return { 'error' => $error } if $error;

  $cust_main->apply_payments;

  if ( $p->{'save'} ) {
    my $new = new FS::cust_main { $cust_main->hash };
    $new->set( $_ => $p->{$_} )
      foreach qw( payname paystart_month paystart_year payissue payip
                  address1 address2 city state zip payinfo );
    $new->set( 'paydate' => $p->{'year'}. '-'. $p->{'month'}. '-01' );
    $new->set( 'payby' => $p->{'auto'} ? 'CARD' : 'DCRD' );
    my $error = $new->replace($cust_main);
    return { 'error' => $error } if $error;
    $cust_main = $new;
  }

  return { 'error' => '' };

}

sub process_prepay {

  my $p = shift;

  my $session = _cache->get($p->{'session_id'})
    or return { 'error' => "Can't resume session" }; #better error message

  my %return;

  my $custnum = $session->{'custnum'};

  my $cust_main = qsearchs('cust_main', { 'custnum' => $custnum } )
    or return { 'error' => "unknown custnum $custnum" };

  my( $amount, $seconds, $upbytes, $downbytes, $totalbytes ) = ( 0, 0, 0, 0, 0 );
  my $error = $cust_main->recharge_prepay( $p->{'prepaid_cardnum'},
                                           \$amount,
                                           \$seconds,
                                           \$upbytes,
                                           \$downbytes,
                                           \$totalbytes,
                                         );

  return { 'error' => $error } if $error;

  return { 'error'     => '',
           'amount'    => $amount,
           'seconds'   => $seconds,
           'duration'  => duration_exact($seconds),
           'upbytes'   => $upbytes,
           'upload'    => FS::UI::Web::bytecount_unexact($upbytes),
           'downbytes' => $downbytes,
           'download'  => FS::UI::Web::bytecount_unexact($downbytes),
           'totalbytes'=> $totalbytes,
           'totalload' => FS::UI::Web::bytecount_unexact($totalbytes),
         };

}

sub invoice {
  my $p = shift;
  my $session = _cache->get($p->{'session_id'})
    or return { 'error' => "Can't resume session" }; #better error message

  my $custnum = $session->{'custnum'};

  my $invnum = $p->{'invnum'};

  my $cust_bill = qsearchs('cust_bill', { 'invnum'  => $invnum,
                                          'custnum' => $custnum } )
    or return { 'error' => "Can't find invnum" };

  #my %return;

  return { 'error'        => '',
           'invnum'       => $invnum,
           'invoice_text' => join('', $cust_bill->print_text ),
           'invoice_html' => $cust_bill->print_html,
         };

}

sub invoice_logo {
  my $p = shift;

  #sessioning for this?  how do we get the session id to the backend invoice
  # template so it can add it to the link, blah

  my $templatename = $p->{'templatename'};

  #false laziness-ish w/view/cust_bill-logo.cgi

  my $conf = new FS::Conf;
  if ( $templatename =~ /^([^\.\/]*)$/ && $conf->exists("logo_$1.png") ) {
    $templatename = "_$1";
  } else {
    $templatename = '';
  }

  my $filename = "logo$templatename.png";

  return { 'error'        => '',
           'logo'         => $conf->config_binary($filename),
           'content_type' => 'image/png', #should allow gif, jpg too
         };
}


sub list_invoices {
  my $p = shift;
  my $session = _cache->get($p->{'session_id'})
    or return { 'error' => "Can't resume session" }; #better error message

  my $custnum = $session->{'custnum'};

  my $cust_main = qsearchs('cust_main', { 'custnum' => $custnum } )
    or return { 'error' => "unknown custnum $custnum" };

  my @cust_bill = $cust_main->cust_bill;

  return  { 'error'       => '',
            'invoices'    =>  [ map { { 'invnum' => $_->invnum,
                                        '_date'  => $_->_date,
                                      }
                                    } @cust_bill
                              ]
          };
}

sub cancel {
  my $p = shift;
  my $session = _cache->get($p->{'session_id'})
    or return { 'error' => "Can't resume session" }; #better error message

  my $custnum = $session->{'custnum'};

  my $cust_main = qsearchs('cust_main', { 'custnum' => $custnum } )
    or return { 'error' => "unknown custnum $custnum" };

  my @errors = $cust_main->cancel( 'quiet'=>1 );

  my $error = scalar(@errors) ? join(' / ', @errors) : '';

  return { 'error' => $error };

}

sub list_pkgs {
  my $p = shift;

  my($context, $session, $custnum) = _custoragent_session_custnum($p);
  return { 'error' => $session } if $context eq 'error';

  my $search = { 'custnum' => $custnum };
  $search->{'agentnum'} = $session->{'agentnum'} if $context eq 'agent';
  my $cust_main = qsearchs('cust_main', $search )
    or return { 'error' => "unknown custnum $custnum" };

  #return { 'cust_pkg' => [ map { $_->hashref } $cust_main->ncancelled_pkgs ] };

  my $conf = new FS::Conf;

  { 'svcnum'   => $session->{'svcnum'},
    'custnum'  => $custnum,
    'cust_pkg' => [ map {
                          { $_->hash,
                            $_->part_pkg->hash,
                            part_svc =>
                              [ map $_->hashref, $_->available_part_svc ],
                            cust_svc => 
                              [ map { my $ref = { $_->hash,
                                                  label => [ $_->label ],
                                                };
                                      $ref->{_password} = $_->svc_x->_password
                                        if $context eq 'agent'
                                        && $conf->exists('agent-showpasswords')
                                        && $_->part_svc->svcdb eq 'svc_acct';
                                      $ref;
                                    } $_->cust_svc
                              ],
                          };
                        } $cust_main->ncancelled_pkgs
                  ],
    'small_custview' =>
      small_custview( $cust_main, $conf->config('countrydefault') ),
  };

}

sub list_svcs {
  my $p = shift;

  my($context, $session, $custnum) = _custoragent_session_custnum($p);
  return { 'error' => $session } if $context eq 'error';

  my $search = { 'custnum' => $custnum };
  $search->{'agentnum'} = $session->{'agentnum'} if $context eq 'agent';
  my $cust_main = qsearchs('cust_main', $search )
    or return { 'error' => "unknown custnum $custnum" };

  my @cust_svc = ();
  #foreach my $cust_pkg ( $cust_main->ncancelled_pkgs ) {
  foreach my $cust_pkg ( $p->{'ncancelled'} 
                         ? $cust_main->ncancelled_pkgs
                         : $cust_main->unsuspended_pkgs ) {
    push @cust_svc, @{[ $cust_pkg->cust_svc ]}; #@{[ ]} to force array context
  }
  @cust_svc = grep { $_->part_svc->svcdb eq $p->{'svcdb'} } @cust_svc
    if $p->{'svcdb'};

  #@svc_x = sort { $a->domain cmp $b->domain || $a->username cmp $b->username }
  #              @svc_x;

  { 
    #no#'svcnum'   => $session->{'svcnum'},
    'custnum'  => $custnum,
    'svcs'     => [ map { 
                          my $svc_x = $_->svc_x;
                          my($label, $value) = $_->label;
                          my $part_pkg = $svc_x->cust_svc->cust_pkg->part_pkg;

                          { 'svcnum'    => $_->svcnum,
                            'label'     => $label,
                            'value'     => $value,
                            'username'  => $svc_x->username,
                            'email'     => $svc_x->email,
                            'seconds'   => $svc_x->seconds,
                            'upbytes'   => $svc_x->upbytes,
                            'downbytes' => $svc_x->downbytes,
                            'totalbytes'=> $svc_x->totalbytes,
                            'recharge_amount' => $part_pkg->option('recharge_amount', 1),
                            'recharge_seconds' => $part_pkg->option('recharge_seconds', 1),
                            'recharge_upbytes' => $part_pkg->option('recharge_upbytes', 1),
                            'recharge_downbytes' => $part_pkg->option('recharge_downbytes', 1),
                            'recharge_totalbytes' => $part_pkg->option('recharge_totalbytes', 1),
                            # more...
                          };
                        }
                        @cust_svc
                  ],
  };

}

sub list_svc_usage {
  my $p = shift;

  my($context, $session, $custnum) = _custoragent_session_custnum($p);
  return { 'error' => $session } if $context eq 'error';

  my $search = { 'svcnum' => $p->{'svcnum'} };
  $search->{'agentnum'} = $session->{'agentnum'} if $context eq 'agent';
  my $svc_acct = qsearchs ( 'svc_acct', $search );
  return { 'error' => 'No service selected in list_svc_usage' } 
    unless $svc_acct;

  my $freq   = $svc_acct->cust_svc->cust_pkg->part_pkg->freq;
  my $start  = $svc_acct->cust_svc->cust_pkg->setup;
  my $end    = $svc_acct->cust_svc->cust_pkg->bill; # or time?

  unless($p->{beginning}){
    $p->{beginning} = $svc_acct->cust_svc->cust_pkg->last_bill;
    $p->{ending} = $end;
  }
  my @usage = ();

  foreach my $part_export ( 
    map { qsearch ( 'part_export', { 'exporttype' => $_ } ) }
    qw (sqlradius sqlradius_withdomain')
  ) {

    push @usage, @ { $part_export->usage_sessions($p->{beginning},
                                                  $p->{ending},
                                                  $svc_acct)
                   };
  }

  #kinda false laziness with FS::cust_main::bill, but perhaps
  #we should really change this bit to DateTime and DateTime::Duration
  #
  #change this bit to use Date::Manip? CAREFUL with timezones (see
  # mailing list archive)
  my ($nsec,$nmin,$nhour,$nmday,$nmon,$nyear) =
    (localtime($p->{ending}) )[0,1,2,3,4,5];
  my ($psec,$pmin,$phour,$pmday,$pmon,$pyear) =
    (localtime($p->{beginning}) )[0,1,2,3,4,5];

  if ( $freq =~ /^\d+$/ ) {
    $nmon += $freq;
    until ( $nmon < 12 ) { $nmon -= 12; $nyear++; }
    $pmon -= $freq;
    until ( $pmon >= 0 ) { $pmon += 12; $pyear--; }
  } elsif ( $freq =~ /^(\d+)w$/ ) {
    my $weeks = $1;
    $nmday += $weeks * 7;
    $pmday -= $weeks * 7;
  } elsif ( $freq =~ /^(\d+)d$/ ) {
    my $days = $1;
    $nmday += $days;
    $pmday -= $days;
  } elsif ( $freq =~ /^(\d+)h$/ ) {
    my $hours = $1;
    $nhour += $hours;
    $phour -= $hours;
  } else {
    return { 'error' => "unparsable frequency: ". $freq };
  }
  
  my $previous  = timelocal_nocheck($psec,$pmin,$phour,$pmday,$pmon,$pyear);
  my $next      = timelocal_nocheck($nsec,$nmin,$nhour,$nmday,$nmon,$nyear);


  { 
    'error'     => '',
    'svcnum'    => $p->{svcnum},
    'beginning' => $p->{beginning},
    'ending'    => $p->{ending},
    'previous'  => ($previous > $start) ? $previous : $start,
    'next'      => ($next < $end) ? $next : $end,
    'usage'     => \@usage,
  };
}

sub order_pkg {
  my $p = shift;

  my($context, $session, $custnum) = _custoragent_session_custnum($p);
  return { 'error' => $session } if $context eq 'error';

  my $search = { 'custnum' => $custnum };
  $search->{'agentnum'} = $session->{'agentnum'} if $context eq 'agent';
  my $cust_main = qsearchs('cust_main', $search )
    or return { 'error' => "unknown custnum $custnum" };

  #false laziness w/ClientAPI/Signup.pm

  my $cust_pkg = new FS::cust_pkg ( {
    'custnum' => $custnum,
    'pkgpart' => $p->{'pkgpart'},
  } );
  my $error = $cust_pkg->check;
  return { 'error' => $error } if $error;

  my @svc = ();
  unless ( $p->{'svcpart'} eq 'none' ) {

    my $svcdb;
    my $svcpart = '';
    if ( $p->{'svcpart'} =~ /^(\d+)$/ ) {
      $svcpart = $1;
      my $part_svc = qsearchs('part_svc', { 'svcpart' => $svcpart } );
      return { 'error' => "Unknown svcpart $svcpart" } unless $part_svc;
      $svcdb = $part_svc->svcdb;
    } else {
      $svcdb = 'svc_acct';
    }
    $svcpart ||= $cust_pkg->part_pkg->svcpart($svcdb);

    my %fields = (
      'svc_acct'     => [ qw( username _password sec_phrase popnum ) ],
      'svc_domain'   => [ qw( domain ) ],
      'svc_external' => [ qw( id title ) ],
    );
  
    my $svc_x = "FS::$svcdb"->new( {
      'svcpart'   => $svcpart,
      map { $_ => $p->{$_} } @{$fields{$svcdb}}
    } );
    
    if ( $svcdb eq 'svc_acct' ) {
      my @acct_snarf;
      my $snarfnum = 1;
      while ( length($p->{"snarf_machine$snarfnum"}) ) {
        my $acct_snarf = new FS::acct_snarf ( {
          'machine'   => $p->{"snarf_machine$snarfnum"},
          'protocol'  => $p->{"snarf_protocol$snarfnum"},
          'username'  => $p->{"snarf_username$snarfnum"},
          '_password' => $p->{"snarf_password$snarfnum"},
        } );
        $snarfnum++;
        push @acct_snarf, $acct_snarf;
      }
      $svc_x->child_objects( \@acct_snarf );
    }
    
    my $y = $svc_x->setdefault; # arguably should be in new method
    return { 'error' => $y } if $y && !ref($y);
  
    $error = $svc_x->check;
    return { 'error' => $error } if $error;

    push @svc, $svc_x;

  }

  use Tie::RefHash;
  tie my %hash, 'Tie::RefHash';
  %hash = ( $cust_pkg => \@svc );
  #msgcat
  $error = $cust_main->order_pkgs( \%hash, '', 'noexport' => 1 );
  return { 'error' => $error } if $error;

  my $conf = new FS::Conf;
  if ( $conf->exists('signup_server-realtime') ) {

    my $bill_error = _do_bop_realtime( $cust_main );

    if ($bill_error) {
      $cust_pkg->cancel('quiet'=>1);
      return $bill_error;
    } else {
      $cust_pkg->reexport;
    }

  } else {
    $cust_pkg->reexport;
  }

  return { error => '', pkgnum => $cust_pkg->pkgnum };

}

sub change_pkg {
  my $p = shift;

  my($context, $session, $custnum) = _custoragent_session_custnum($p);
  return { 'error' => $session } if $context eq 'error';

  my $search = { 'custnum' => $custnum };
  $search->{'agentnum'} = $session->{'agentnum'} if $context eq 'agent';
  my $cust_main = qsearchs('cust_main', $search )
    or return { 'error' => "unknown custnum $custnum" };

  my $cust_pkg = qsearchs('cust_pkg', { 'pkgnum' => $p->{pkgnum} } )
    or return { 'error' => "unknown package $p->{pkgnum}" };

  my @newpkg;
  my $error = FS::cust_pkg::order( $custnum,
                                   [$p->{pkgpart}],
                                   [$p->{pkgnum}],
                                   \@newpkg,
                                 );

  my $conf = new FS::Conf;
  if ( $conf->exists('signup_server-realtime') ) {

    my $bill_error = _do_bop_realtime( $cust_main );

    if ($bill_error) {
      $newpkg[0]->suspend;
      return $bill_error;
    } else {
      $newpkg[0]->reexport;
    }

  } else {  
    $newpkg[0]->reexport;
  }

  return { error => '', pkgnum => $cust_pkg->pkgnum };

}

sub order_recharge {
  my $p = shift;

  my($context, $session, $custnum) = _custoragent_session_custnum($p);
  return { 'error' => $session } if $context eq 'error';

  my $search = { 'custnum' => $custnum };
  $search->{'agentnum'} = $session->{'agentnum'} if $context eq 'agent';
  my $cust_main = qsearchs('cust_main', $search )
    or return { 'error' => "unknown custnum $custnum" };

  my $cust_svc = qsearchs( 'cust_svc', { 'svcnum' => $p->{'svcnum'} } )
    or return { 'error' => "unknown service " . $p->{'svcnum'} };

  my $svc_x = $cust_svc->svc_x;
  my $part_pkg = $cust_svc->cust_pkg->part_pkg;

  my %vhash =
    map { $_ =~ /^recharge_(.*)$/; $1, $part_pkg->option($_, 1) } 
    qw ( recharge_seconds recharge_upbytes recharge_downbytes
         recharge_totalbytes );
  my $amount = $part_pkg->option('recharge_amount', 1); 
  
  my ($l, $v, $d) = $cust_svc->label;  # blah
  my $pkg = "Recharge $v"; 

  my $bill_error = $cust_main->charge($amount, $pkg,
     "time: $vhash{seconds}, up: $vhash{upbytes}," . 
     "down: $vhash{downbytes}, total: $vhash{totalbytes}",
     $part_pkg->taxclass); #meh

  my $conf = new FS::Conf;
  if ( $conf->exists('signup_server-realtime') && !$bill_error ) {

    $bill_error = _do_bop_realtime( $cust_main );

    if ('bill_error') {
      return $bill_error;
    } else {
      my $error = $svc_x->recharge (\%vhash);
      return { 'error' => $error } if $error;
    }

  } else {  
    my $error = $bill_error;
    $error ||= $svc_x->recharge (\%vhash);
    return { 'error' => $error } if $error;
  }

  return { error => '', svc => $cust_svc->part_svc->svc };

}

sub _do_bop_realtime {
  my ($cust_main) = @_;

    my $old_balance = $cust_main->balance;

    my $bill_error = $cust_main->bill;

    $cust_main->apply_payments_and_credits;
    $bill_error = $cust_main->collect('realtime' => 1);

    if (    $cust_main->balance > $old_balance
         && $cust_main->balance > 0
         && $cust_main->payby !~ /^(BILL|DCRD|DCHK)$/ ) {
      #this makes sense.  credit is "un-doing" the invoice
      $cust_main->credit( sprintf("%.2f", $cust_main->balance - $old_balance ),
                          'self-service decline' );
      $cust_main->apply_credits( 'order' => 'newest' );

      return { 'error' => '_decline', 'bill_error' => $bill_error };
    }

    '';
}

sub cancel_pkg {
  my $p = shift;
  my $session = _cache->get($p->{'session_id'})
    or return { 'error' => "Can't resume session" }; #better error message

  my $custnum = $session->{'custnum'};

  my $cust_main = qsearchs('cust_main', { 'custnum' => $custnum } )
    or return { 'error' => "unknown custnum $custnum" };

  my $pkgnum = $p->{'pkgnum'};

  my $cust_pkg = qsearchs('cust_pkg', { 'custnum' => $custnum,
                                        'pkgnum'  => $pkgnum,   } )
    or return { 'error' => "unknown pkgnum $pkgnum" };

  my $error = $cust_pkg->cancel( 'quiet'=>1 );
  return { 'error' => $error };

}

sub provision_acct {
  my $p = shift;

  return { 'error' => gettext('passwords_dont_match') }
    if $p->{'_password'} ne $p->{'_password2'};
  return { 'error' => gettext('empty_password') }
    unless length($p->{'_password'});

  _provision( 'FS::svc_acct',
              [qw(username _password)],
              [qw(username _password)],
              $p,
              @_
            );
}

sub provision_external {
  my $p = shift;
  #_provision( 'FS::svc_external', [qw(id title)], [qw(id title)], $p, @_ );
  _provision( 'FS::svc_external',
              [],
              [qw(id title)],
              $p,
              @_
            );
}

sub _provision {
  my( $class, $fields, $return_fields, $p ) = splice(@_, 0, 4);

  my($context, $session, $custnum) = _custoragent_session_custnum($p);
  return { 'error' => $session } if $context eq 'error';

  my $search = { 'custnum' => $custnum };
  $search->{'agentnum'} = $session->{'agentnum'} if $context eq 'agent';
  my $cust_main = qsearchs('cust_main', $search )
    or return { 'error' => "unknown custnum $custnum" };

  my $pkgnum = $p->{'pkgnum'};

  my $cust_pkg = qsearchs('cust_pkg', { 'custnum' => $custnum,
                                        'pkgnum'  => $pkgnum,
                                                               } )
    or return { 'error' => "unknown pkgnum $pkgnum" };

  my $part_svc = qsearchs('part_svc', { 'svcpart' => $p->{'svcpart'} } )
    or return { 'error' => "unknown svcpart $p->{'svcpart'}" };

  my $svc_x = $class->new( {
    'pkgnum'  => $p->{'pkgnum'},
    'svcpart' => $p->{'svcpart'},
    map { $_ => $p->{$_} } @$fields
  } );
  my $error = $svc_x->insert;
  $svc_x = qsearchs($svc_x->table, { 'svcnum' => $svc_x->svcnum })
    unless $error;

  return { 'svc'   => $part_svc->svc,
           'error' => $error,
           map { $_ => $svc_x->get($_) } @$return_fields
         };

}

sub part_svc_info {
  my $p = shift;

  my($context, $session, $custnum) = _custoragent_session_custnum($p);
  return { 'error' => $session } if $context eq 'error';

  my $search = { 'custnum' => $custnum };
  $search->{'agentnum'} = $session->{'agentnum'} if $context eq 'agent';
  my $cust_main = qsearchs('cust_main', $search )
    or return { 'error' => "unknown custnum $custnum" };

  my $pkgnum = $p->{'pkgnum'};

  my $cust_pkg = qsearchs('cust_pkg', { 'custnum' => $custnum,
                                        'pkgnum'  => $pkgnum,
                                                               } )
    or return { 'error' => "unknown pkgnum $pkgnum" };

  my $svcpart = $p->{'svcpart'};

  my $pkg_svc = qsearchs('pkg_svc', { 'pkgpart' => $cust_pkg->pkgpart,
                                      'svcpart' => $svcpart,           } )
    or return { 'error' => "unknown svcpart $svcpart for pkgnum $pkgnum" };
  my $part_svc = $pkg_svc->part_svc;

  my $conf = new FS::Conf;

  return {
    'svc'     => $part_svc->svc,
    'svcdb'   => $part_svc->svcdb,
    'pkgnum'  => $pkgnum,
    'svcpart' => $svcpart,
    'custnum' => $custnum,

    'security_phrase' => 0, #XXX !
    'svc_acct_pop'    => [], #XXX !
    'popnum'          => '',
    'init_popstate'   => '',
    'popac'           => '',
    'acstate'         => '',

    'small_custview' =>
      small_custview( $cust_main, $conf->config('countrydefault') ),

  };

}

sub unprovision_svc {
  my $p = shift;

  my($context, $session, $custnum) = _custoragent_session_custnum($p);
  return { 'error' => $session } if $context eq 'error';

  my $search = { 'custnum' => $custnum };
  $search->{'agentnum'} = $session->{'agentnum'} if $context eq 'agent';
  my $cust_main = qsearchs('cust_main', $search )
    or return { 'error' => "unknown custnum $custnum" };

  my $svcnum = $p->{'svcnum'};

  my $cust_svc = qsearchs('cust_svc', { 'svcnum'  => $svcnum, } )
    or return { 'error' => "unknown svcnum $svcnum" };

  return { 'error' => "Service $svcnum does not belong to customer $custnum" }
    unless $cust_svc->cust_pkg->custnum == $custnum;

  my $conf = new FS::Conf;

  return { 'svc'   => $cust_svc->part_svc->svc,
           'error' => $cust_svc->cancel,
           'small_custview' =>
             small_custview( $cust_main, $conf->config('countrydefault') ),
         };

}

sub myaccount_passwd {
  my $p = shift;
  my($context, $session, $custnum) = _custoragent_session_custnum($p);
  return { 'error' => $session } if $context eq 'error';

  return { 'error' => "New passwords don't match." }
    if $p->{'new_password'} ne $p->{'new_password2'};

  return { 'error' => 'Enter new password' }
    unless length($p->{'new_password'});

  #my $search = { 'custnum' => $custnum };
  #$search->{'agentnum'} = $session->{'agentnum'} if $context eq 'agent';
  $custnum =~ /^(\d+)$/ or die "illegal custnum";
  my $search = " AND custnum = $1";
  $search .= " AND agentnum = ". $session->{'agentnum'} if $context eq 'agent';

  my $svc_acct = qsearchs( {
    'table'     => 'svc_acct',
    'addl_from' => 'LEFT JOIN cust_svc  USING ( svcnum  ) '.
                   'LEFT JOIN cust_pkg  USING ( pkgnum  ) '.
                   'LEFT JOIN cust_main USING ( custnum ) ',
    'hashref'   => { 'svcnum' => $p->{'svcnum'}, },
    'extra_sql' => $search, #important
  } )
    or return { 'error' => "Service not found" };

  $svc_acct->_password($p->{'new_password'});
  my $error = $svc_acct->replace();

  my($label, $value) = $svc_acct->cust_svc->label;

  return { 'error' => $error,
           'label' => $label,
           'value' => $value,
         };

}

#--

sub _custoragent_session_custnum {
  my $p = shift;

  my($context, $session, $custnum);
  if ( $p->{'session_id'} ) {

    $context = 'customer';
    $session = _cache->get($p->{'session_id'})
      or return ( 'error' => "Can't resume session" ); #better error message
    $custnum = $session->{'custnum'};

  } elsif ( $p->{'agent_session_id'} ) {

    $context = 'agent';
    my $agent_cache = new FS::ClientAPI_SessionCache( {
      'namespace' => 'FS::ClientAPI::Agent',
    } );
    $session = $agent_cache->get($p->{'agent_session_id'})
      or return ( 'error' => "Can't resume session" ); #better error message
    $custnum = $p->{'custnum'};

  } else {
    return ( 'error' => "Can't resume session" ); #better error message
  }

  ($context, $session, $custnum);

}

1;

