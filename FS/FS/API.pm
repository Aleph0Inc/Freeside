package FS::API;

use FS::Conf;
use FS::Record qw( qsearch qsearchs );
use FS::cust_main;
use FS::cust_location;
use FS::cust_pay;
use FS::cust_credit;
use FS::cust_refund;
use FS::cust_pkg;

=head1 NAME

FS::API - Freeside backend API

=head1 SYNOPSIS

  use FS::API;

=head1 DESCRIPTION

This module implements a backend API for advanced back-office integration.

In contrast to the self-service API, which authenticates an end-user and offers
functionality to that end user, the backend API performs a simple shared-secret
authentication and offers full, administrator functionality, enabling
integration with other back-office systems.  Only access this API from a secure 
network from other backoffice machines. DON'T use this API to create customer 
portal functionality.

If accessing this API remotely with XML-RPC or JSON-RPC, be careful to block
the port by default, only allow access from back-office servers with the same
security precations as the Freeside server, and encrypt the communication
channel (for example, with an SSH tunnel or VPN) rather than accessing it
in plaintext.

=head1 METHODS

=over 4

=item insert_payment OPTION => VALUE, ...

Adds a new payment to a customers account. Takes a list of keys and values as
paramters with the following keys:

=over 4

=item secret

API Secret

=item custnum

Customer number

=item payby

Payment type

=item paid

Amount paid

=item _date

Option date for payment

=back

Example:

  my $result = FS::API->insert_payment(
    'secret'  => 'sharingiscaring',
    'custnum' => 181318,
    'payby'   => 'CASH',
    'paid'    => '54.32',

    #optional
    '_date'   => 1397977200, #UNIX timestamp
  );

  if ( $result->{'error'} ) {
    die $result->{'error'};
  } else {
    #payment was inserted
    print "paynum ". $result->{'paynum'};
  }

=cut

#enter cash payment
sub insert_payment {
  my($class, %opt) = @_;
  return _shared_secret_error() unless _check_shared_secret($opt{secret});

  #less "raw" than this?  we are the backoffice API, and aren't worried
  # about version migration ala cust_main/cust_location here
  my $cust_pay = new FS::cust_pay { %opt };
  my $error = $cust_pay->insert( 'manual'=>1 );
  return { 'error'  => $error,
           'paynum' => $cust_pay->paynum,
         };
}

# pass the phone number ( from svc_phone ) 
sub insert_payment_phonenum {
  my($class, %opt) = @_;
  $class->_by_phonenum('insert_payment', %opt);
}

sub _by_phonenum {
  my($class, $method, %opt) = @_;
  return _shared_secret_error() unless _check_shared_secret($opt{secret});

  my $phonenum = delete $opt{'phonenum'};

  my $svc_phone = qsearchs('svc_phone', { 'phonenum' => $phonenum } )
    or return { 'error' => 'Unknown phonenum' };

  my $cust_pkg = $svc_phone->cust_svc->cust_pkg
    or return { 'error' => 'Unlinked phonenum' };

  $opt{'custnum'} = $cust_pkg->custnum;

  $class->$method(%opt);
}

=item insert_credit OPTION => VALUE, ...

Adds a a credit to a customers account.  Takes a list of keys and values as
parameters with the following keys

=over 

=item secret

API Secret

=item custnum

customer number

=item amount

Amount of the credit

=item _date

The date the credit will be posted

=back

Example:

  my $result = FS::API->insert_credit(
    'secret'  => 'sharingiscaring',
    'custnum' => 181318,
    'amount'  => '54.32',

    #optional
    '_date'   => 1397977200, #UNIX timestamp
  );

  if ( $result->{'error'} ) {
    die $result->{'error'};
  } else {
    #credit was inserted
    print "crednum ". $result->{'crednum'};
  }

=cut

#Enter credit
sub insert_credit {
  my($class, %opt) = @_;
  return _shared_secret_error() unless _check_shared_secret($opt{secret});

  $opt{'reasonnum'} ||= FS::Conf->new->config('api_credit_reason');

  #less "raw" than this?  we are the backoffice API, and aren't worried
  # about version migration ala cust_main/cust_location here
  my $cust_credit = new FS::cust_credit { %opt };
  my $error = $cust_credit->insert;
  return { 'error'  => $error,
           'crednum' => $cust_credit->crednum,
         };
}

# pass the phone number ( from svc_phone ) 
sub insert_credit_phonenum {
  my($class, %opt) = @_;
  $class->_by_phonenum('insert_credit', %opt);
}

=item apply_payments_and_credits

Applies payments and credits for this customer.  Takes a list of keys and
values as parameter with the following keys:

=over 4

=item secret

API secret

=item custnum

Customer number

=back

=cut

#apply payments and credits
sub apply_payments_and_credits {
  my($class, %opt) = @_;
  return _shared_secret_error() unless _check_shared_secret($opt{secret});

  my $cust_main = qsearchs('cust_main', { 'custnum' => $opt{custnum} })
    or return { 'error' => 'Unknown custnum' };

  my $error = $cust_main->apply_payments_and_credits( 'manual'=>1 );
  return { 'error'  => $error, };
}

=item insert_refund OPTION => VALUE, ...

Adds a a credit to a customers account.  Takes a list of keys and values as
parmeters with the following keys: custnum, payby, refund

Example:

  my $result = FS::API->insert_refund(
    'secret'  => 'sharingiscaring',
    'custnum' => 181318,
    'payby'   => 'CASH',
    'refund'  => '54.32',

    #optional
    '_date'   => 1397977200, #UNIX timestamp
  );

  if ( $result->{'error'} ) {
    die $result->{'error'};
  } else {
    #refund was inserted
    print "refundnum ". $result->{'crednum'};
  }

=cut

#Enter cash refund.
sub insert_refund {
  my($class, %opt) = @_;
  return _shared_secret_error() unless _check_shared_secret($opt{secret});

  # when github pull request #24 is merged,
  #  will have to change over to default reasonnum like credit
  # but until then, this will do
  $opt{'reason'} ||= 'API refund';

  #less "raw" than this?  we are the backoffice API, and aren't worried
  # about version migration ala cust_main/cust_location here
  my $cust_refund = new FS::cust_refund { %opt };
  my $error = $cust_refund->insert;
  return { 'error'     => $error,
           'refundnum' => $cust_refund->refundnum,
         };
}

# pass the phone number ( from svc_phone ) 
sub insert_refund_phonenum {
  my($class, %opt) = @_;
  $class->_by_phonenum('insert_refund', %opt);
}

#---

# "2 way syncing" ?  start with non-sync pulling info here, then if necessary
# figure out how to trigger something when those things change

# long-term: package changes?

=item new_customer OPTION => VALUE, ...

Creates a new customer. Takes a list of keys and values as parameters with the
following keys:

=over 4

=item secret

API Secret

=item first

first name (required)

=item last

last name (required)

=item ss

(not typically collected; mostly used for ACH transactions)

=item company

Company name

=item address1 (required)

Address line one

=item city (required)

City

=item county

County

=item state (required)

State

=item zip (required)

Zip or postal code

=item country

2 Digit Country Code

=item latitude

latitude

=item Longitude

longitude

=item geocode

Currently used for third party tax vendor lookups

=item censustract

Used for determining FCC 477 reporting

=item censusyear

Used for determining FCC 477 reporting

=item daytime

Daytime phone number

=item night

Evening phone number

=item fax

Fax number

=item mobile

Mobile number

=item invoicing_list

comma-separated list of email addresses for email invoices. The special value 'POST' is used to designate postal invoicing (it may be specified alone or in addition to email addresses),
postal_invoicing
Set to 1 to enable postal invoicing

=item payby

CARD, DCRD, CHEK, DCHK, LECB, BILL, COMP or PREPAY

=item payinfo

Card number for CARD/DCRD, account_number@aba_number for CHEK/DCHK, prepaid "pin" for PREPAY, purchase order number for BILL

=item paycvv

Credit card CVV2 number (1.5+ or 1.4.2 with CVV schema patch)

=item paydate

Expiration date for CARD/DCRD

=item payname

Exact name on credit card for CARD/DCRD, bank name for CHEK/DCHK

=item referral_custnum

Referring customer number

=item salesnum

Sales person number

=item agentnum

Agent number

=item agent_custid

Agent specific customer number

=item referral_custnum

Referring customer number

=back

=cut

#certainly false laziness w/ClientAPI::Signup new_customer/new_customer_minimal
# but approaching this from a clean start / back-office perspective
#  i.e. no package/service, no immediate credit card run, etc.

sub new_customer {
  my( $class, %opt ) = @_;
  return _shared_secret_error() unless _check_shared_secret($opt{secret});

  #default agentnum like signup_server-default_agentnum?
 
  #same for refnum like signup_server-default_refnum

  my $cust_main = new FS::cust_main ( {
      'refnum'   => $opt{refnum}
                    || FS::Conf->new->config('signup_server-default_refnum'),
      'payby'    => 'BILL',
      'tagnum'   => [ FS::part_tag->default_tags ],

      map { $_ => $opt{$_} } qw(
        agentnum salesnum refnum agent_custid referral_custnum
        last first company 
        daytime night fax mobile
        payby payinfo paydate paycvv payname
      ),

  } );

  my @invoicing_list = $opt{'invoicing_list'}
                         ? split( /\s*\,\s*/, $opt{'invoicing_list'} )
                         : ();
  push @invoicing_list, 'POST' if $opt{'postal_invoicing'};

  my ($bill_hash, $ship_hash);
  foreach my $f (FS::cust_main->location_fields) {
    # avoid having to change this in front-end code
    $bill_hash->{$f} = $opt{"bill_$f"} || $opt{$f};
    $ship_hash->{$f} = $opt{"ship_$f"};
  }

  my $bill_location = FS::cust_location->new($bill_hash);
  my $ship_location;
  # we don't have an equivalent of the "same" checkbox in selfservice^Wthis API
  # so is there a ship address, and if so, is it different from the billing 
  # address?
  if ( length($ship_hash->{address1}) > 0 and
          grep { $bill_hash->{$_} ne $ship_hash->{$_} } keys(%$ship_hash)
         ) {

    $ship_location = FS::cust_location->new( $ship_hash );
  
  } else {
    $ship_location = $bill_location;
  }

  $cust_main->set('bill_location' => $bill_location);
  $cust_main->set('ship_location' => $ship_location);

  $error = $cust_main->insert( {}, \@invoicing_list );
  return { 'error'   => $error } if $error;
  
  return { 'error'   => '',
           'custnum' => $cust_main->custnum,
         };

}

=item update_customer

Updates an existing customer. Passing an empty value clears that field, while
NOT passing that key/value at all leaves it alone. Takes a list of keys and
values as parameters with the following keys:
 
=over 4

=item secret

API Secret (required)

=item custnum

Customer number (required)

=item first

first name 

=item last

last name 

=item company

Company name

=item address1 

Address line one

=item city 

City

=item county

County

=item state 

State

=item zip 

Zip or postal code

=item country

2 Digit Country Code

=item daytime

Daytime phone number

=item night

Evening phone number

=item fax

Fax number

=item mobile

Mobile number

=item invoicing_list

Comma-separated list of email addresses for email invoices. The special value 
'POST' is used to designate postal invoicing (it may be specified alone or in
addition to email addresses)

=item payby

CARD, DCRD, CHEK, DCHK, LECB, BILL, COMP or PREPAY

=item payinfo

Card number for CARD/DCRD, account_number@aba_number for CHEK/DCHK, prepaid 
+"pin" for PREPAY, purchase order number for BILL

=item paycvv

Credit card CVV2 number (1.5+ or 1.4.2 with CVV schema patch)

=item paydate

Expiration date for CARD/DCRD

=item payname

Exact name on credit card for CARD/DCRD, bank name for CHEK/DCHK

=item referral_custnum

Referring customer number

=item salesnum

Sales person number

=item agentnum

Agent number

=back

=cut

sub update_customer {
 my( $class, %opt ) = @_;
  return _shared_secret_error() unless _check_shared_secret($opt{secret});

  my $custnum = $opt{'custnum'}
    or return { 'error' => "no customer record" };

  my $cust_main = qsearchs('cust_main', { 'custnum' => $custnum } )
    or return { 'error' => "unknown custnum $custnum" };

  my $new = new FS::cust_main { $cust_main->hash };

  $new->set( $_ => $opt{$_} )
    foreach grep { exists $opt{$_} } qw(
        agentnum salesnum refnum agent_custid referral_custnum
        last first company
        daytime night fax mobile
        payby payinfo paydate paycvv payname
      ),

  my @invoicing_list;
  if ( exists $opt{'invoicing_list'} || exists $opt{'postal_invoicing'} ) {
    @invoicing_list = split( /\s*\,\s*/, $opt{'invoicing_list'} );
    push @invoicing_list, 'POST' if $opt{'postal_invoicing'};
  } else {
    @invoicing_list = $cust_main->invoicing_list;
  }
 
  if ( exists( $opt{'address1'} ) ) {
    my $bill_location = FS::cust_location->new({
        map { $_ => $opt{$_} } @location_editable_fields
    });
    $bill_location->set('custnum' => $custnum);
    my $error = $bill_location->find_or_insert;
    die $error if $error;

    # if this is unchanged from before, cust_main::replace will ignore it
    $new->set('bill_location' => $bill_location);
  }

  if ( exists($opt{'ship_address1'}) && length($opt{"ship_address1"}) > 0 ) {
    my $ship_location = FS::cust_location->new({
        map { $_ => $opt{"ship_$_"} } @location_editable_fields
    });

    $ship_location->set('custnum' => $custnum);
    my $error = $ship_location->find_or_insert;
    die $error if $error;

    $new->set('ship_location' => $ship_location);

   } elsif (exists($opt{'ship_address1'} ) && !grep { length($opt{"ship_$_"}) } @location_editable_fields ) {
      my $ship_location = $new->bill_location;
     $new->set('ship_location' => $ship_location);
    }

  my $error = $new->replace( $cust_main, \@invoicing_list );
  return { 'error'   => $error } if $error;

  return { 'error'   => '',
         };  
}


=item customer_info

Returns general customer information. Takes a list of keys and values as
parameters with the following keys: custnum, secret 

=cut

#some false laziness w/ClientAPI::Myaccount customer_info/customer_info_short

use vars qw( @cust_main_editable_fields @location_editable_fields );
@cust_main_editable_fields = qw(
  first last company daytime night fax mobile
);
#  locale
#  payby payinfo payname paystart_month paystart_year payissue payip
#  ss paytype paystate stateid stateid_state
@location_editable_fields = qw(
  address1 address2 city county state zip country
);

sub customer_info {
  my( $class, %opt ) = @_;
  return _shared_secret_error() unless _check_shared_secret($opt{secret});

  my $cust_main = qsearchs('cust_main', { 'custnum' => $opt{custnum} })
    or return { 'error' => 'Unknown custnum' };

  my %return = (
    'error'           => '',
    'display_custnum' => $cust_main->display_custnum,
    'name'            => $cust_main->first. ' '. $cust_main->get('last'),
    'balance'         => $cust_main->balance,
    'status'          => $cust_main->status,
    'statuscolor'     => $cust_main->statuscolor,
  );

  $return{$_} = $cust_main->get($_)
    foreach @cust_main_editable_fields;

  for (@location_editable_fields) {
    $return{$_} = $cust_main->bill_location->get($_)
      if $cust_main->bill_locationnum;
    $return{'ship_'.$_} = $cust_main->ship_location->get($_)
      if $cust_main->ship_locationnum;
  }

  my @invoicing_list = $cust_main->invoicing_list;
  $return{'invoicing_list'} =
    join(', ', grep { $_ !~ /^(POST|FAX)$/ } @invoicing_list );
  $return{'postal_invoicing'} =
    0 < ( grep { $_ eq 'POST' } @invoicing_list );

  #generally, the more useful data from the cust_main record the better.
  # well, tell me what you want

  return \%return;

}


=item location_info

Returns location specific information for the customer. Takes a list of keys
and values as paramters with the following keys: custnum, secret

=cut

#I also monitor for changes to the additional locations that are applied to
# packages, and would like for those to be exportable as well.  basically the
# location data passed with the custnum.

sub location_info {
  my( $class, %opt ) = @_;
  return _shared_secret_error() unless _check_shared_secret($opt{secret});

  my @cust_location = qsearch('cust_location', { 'custnum' => $opt{custnum} });

  my %return = (
    'error'           => '',
    'locations'       => [ map $_->hashref, @cust_location ],
  );

  return \%return;
}

=item change_package_location

Updates package location. Takes a list of keys and values 
as paramters with the following keys: 

pkgnum

secret

locationnum - pass this, or the following keys (don't pass both)

locationname

address1

address2

city

county

state

zip

addr_clean

country

censustract

censusyear

location_type

location_number

location_kind

incorporated

On error, returns a hashref with an 'error' key.
On success, returns a hashref with 'pkgnum' and 'locationnum' keys,
containing the new values.

=cut

sub change_package_location {
  my $class = shift;
  my %opt  = @_;
  return _shared_secret_error() unless _check_shared_secret($opt{'secret'});

  my $cust_pkg = qsearchs('cust_pkg', { 'pkgnum' => $opt{'pkgnum'} })
    or return { 'error' => 'Unknown pkgnum' };

  my %changeopt;

  foreach my $field ( qw(
    locationnum
    locationname
    address1
    address2
    city
    county
    state
    zip
    addr_clean
    country
    censustract
    censusyear
    location_type
    location_number
    location_kind
    incorporated
  )) {
    $changeopt{$field} = $opt{$field} if $opt{$field};
  }

  $cust_pkg->API_change(%changeopt);
}

=item bill_now OPTION => VALUE, ...

Bills a single customer now, in the same fashion as the "Bill now" link in the
UI.

Returns a hash reference with a single key, 'error'.  If there is an error,   
the value contains the error, otherwise it is empty. Takes a list of keys and
values as parameters with the following keys:

=over 4

=item secret

API Secret (required)

=item custnum

Customer number (required)

=back

=cut

sub bill_now {
  my( $class, %opt ) = @_;
  return _shared_secret_error() unless _check_shared_secret($opt{secret});

  my $cust_main = qsearchs('cust_main', { 'custnum' => $opt{custnum} })
    or return { 'error' => 'Unknown custnum' };

  my $error = $cust_main->bill_and_collect( 'fatal'      => 'return',
                                            'retry'      => 1,
                                            'check_freq' =>'1d',
                                          );

   return { 'error' => $error,
          };

}


#next.. Advertising sources?


##
# helper subroutines
##

sub _check_shared_secret {
  shift eq FS::Conf->new->config('api_shared_secret');
}

sub _shared_secret_error {
  return { 'error' => 'Incorrect shared secret' };
}

1;
