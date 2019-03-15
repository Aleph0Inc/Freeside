package FS::cust_main::Billing_Batch;

use strict;
use vars qw( $conf );
use FS::Record qw( qsearch qsearchs dbh );
use FS::pay_batch;
use FS::cust_pay_batch;
use FS::cust_bill_pay_batch;

install_callback FS::UID sub { 
  $conf = new FS::Conf;
  #yes, need it for stuff below (prolly should be cached)
};

=item batch_card OPTION => VALUE...

Adds a payment for this invoice to the pending credit card batch (see
L<FS::cust_pay_batch>), or, if the B<realtime> option is set to a true value,
runs the payment using a realtime gateway.

Options may include:

B<amount>: the amount to be paid; defaults to the customer's balance minus
any payments in transit.

B<realtime>: runs this as a realtime payment instead of adding it to a 
batch.  Deprecated.

B<invnum>: sets cust_pay_batch.invnum.

B<address1>, B<address2>, B<city>, B<state>, B<zip>, B<country>: sets 
the billing address for the payment; defaults to the customer's billing
location.

B<payby>, B<payinfo>, B<paydate>, B<payname>: sets the payment method, 
payment account, expiration date, and name; defaults to those fields 
in cust_main.

=cut

sub batch_card {
  my ($self, %options) = @_;

  my $amount;
  if (exists($options{amount})) {
    $amount = $options{amount};
  }else{
    $amount = sprintf("%.2f", $self->balance - $self->in_transit_payments);
  }
  if ($amount <= 0) {
    warn(sprintf("Customer balance %.2f - in transit amount %.2f is <= 0.\n",
        $self->balance,
        $self->in_transit_payments
    ));
    return;
  }
  
  #my $invnum = delete $options{invnum};
  my $invnum = $options{invnum};

  #pay fields should all come from either cust_payby or options, not both
  #  in theory, could just pass payby, and use it to select cust_payby,
  #  but nothing currently needs that, so not implementing it now
  die "Incomplete payment details" 
    if  ($options{payby} || $options{payinfo} || $options{paydate} || $options{payname})
    && !($options{payby} && $options{payinfo} && $options{paydate} && $options{payname});

  #false laziness with Billing_Realtime
  my @cust_payby = $self->cust_payby('CARD','CHEK');

  # batch can't try out every one like realtime, just use first one
  my $cust_payby = $cust_payby[0];

  die "No customer payment info found"
    unless $options{payinfo} || $cust_payby;
                                                   
  my $payby = $options{payby} || $cust_payby->payby;

  if ($options{'realtime'}) {
    return $self->realtime_bop( FS::payby->payby2bop($payby),
                                $amount,
                                %options,
                              );
  }

  my $paycode= $options{paycode} || '';
  my $batch_type = "DEBIT";
  $batch_type = "CREDIT" if $paycode eq 'C';

  my $oldAutoCommit = $FS::UID::AutoCommit;
  local $FS::UID::AutoCommit = 0;
  my $dbh = dbh;

  #this needs to handle mysql as well as Pg, like svc_acct.pm
  #(make it into a common function if folks need to do batching with mysql)
  $dbh->do("LOCK TABLE pay_batch IN SHARE ROW EXCLUSIVE MODE")
    or die "Cannot lock pay_batch: " . $dbh->errstr;

  my %pay_batch = (
    'status' => 'O',
    'payby'  => FS::payby->payby2payment($payby),
    'type'   => $batch_type,
  );
  $pay_batch{agentnum} = $self->agentnum if $conf->exists('batch-spoolagent');

  my $pay_batch = qsearchs( 'pay_batch', \%pay_batch );

  unless ( $pay_batch ) {
    $pay_batch = new FS::pay_batch \%pay_batch;
    my $error = $pay_batch->insert;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      die "error creating new batch: $error\n";
    }
  }

  my $old_cust_pay_batch = qsearchs('cust_pay_batch', {
      'batchnum' => $pay_batch->batchnum,
      'custnum'  => $self->custnum,
  } );

  foreach (qw( address1 address2 city state zip country latitude longitude
               payby payinfo paydate payname paycode paytype ))
  {
    $options{$_} = '' unless exists($options{$_});
  }

  my $loc = $self->bill_location;

  my $cust_pay_batch = new FS::cust_pay_batch ( {
    'batchnum' => $pay_batch->batchnum,
    'invnum'   => $invnum || 0,                    # is there a better value?
                                                   # this field should be
                                                   # removed...
                                                   # cust_bill_pay_batch now
    'custnum'  => $self->custnum,
    'last'     => $self->getfield('last'),
    'first'    => $self->getfield('first'),
    'address1' => $options{address1} || $loc->address1,
    'address2' => $options{address2} || $loc->address2,
    'city'     => $options{city}     || $loc->city,
    'state'    => $options{state}    || $loc->state,
    'zip'      => $options{zip}      || $loc->zip,
    'country'  => $options{country}  || $loc->country,
    'payby'    => $options{payby}    || $cust_payby->payby,
    'payinfo'  => $options{payinfo}  || $cust_payby->payinfo,
    'exp'      => $options{paydate}  || $cust_payby->paydate,
    'payname'  => $options{payname}  || $cust_payby->payname,
    'paytype'  => $options{paytype}  || $cust_payby->{'Hash'}->{'paytype'},
    'amount'   => $amount,                         # consolidating
    'paycode'  => $options{paycode}  || '',
  } );
  
  $cust_pay_batch->paybatchnum($old_cust_pay_batch->paybatchnum)
    if $old_cust_pay_batch;

  my $error;
  if ($old_cust_pay_batch) {
    $error = $cust_pay_batch->replace($old_cust_pay_batch)
  } else {
    $error = $cust_pay_batch->insert;
  }

  if ( $error ) {
    $dbh->rollback if $oldAutoCommit;
    #die $error;
    return $error; # e.g. "Illegal zip" ala RT#75998
  }

  if ($options{'processing-fee'} > 0) {
    my $pf_cust_pkg;
    my $processing_fee_text = 'Payment Processing Fee';

    unless ( $invnum ) { # probably from a payment screen
      # do we have any open invoices? pick earliest
      # uses the fact that cust_main->cust_bill sorts by date ascending
      my @open = $self->open_cust_bill;
      $invnum = $open[0]->invnum if scalar(@open);
    }

    unless ( $invnum ) {  # still nothing? pick last closed invoice
      # again uses fact that cust_main->cust_bill sorts by date ascending
      my @closed = $self->cust_bill;
      $invnum = $closed[$#closed]->invnum if scalar(@closed);
    }

    unless ( $invnum ) {
      # XXX: unlikely case - pre-paying before any invoices generated
      # what it should do is create a new invoice and pick it
      warn '\PROCESS FEE AND NO INVOICES PICKED TO APPLY IT!';
      return '';
    }

    my $pf_change_error = $self->charge({
            'amount'  => $options{'processing-fee'},
            'pkg'   => $processing_fee_text,
            'setuptax'  => 'Y',
            'cust_pkg_ref' => \$pf_cust_pkg,
    });

    if($pf_change_error) {
      warn 'Unable to add payment processing fee';
      return '';
    }

    $pf_cust_pkg->setup(time);
    my $pf_error = $pf_cust_pkg->replace;
    if($pf_error) {
      warn 'Unable to set setup time on cust_pkg for processing fee';
      # but keep going...
    }

    my $cust_bill = qsearchs('cust_bill', { 'invnum' => $invnum });
    unless ( $cust_bill ) {
      warn "race condition + invoice deletion just happened";
      return '';
    }

    my $grand_pf_error =
      $cust_bill->add_cc_surcharge($pf_cust_pkg->pkgnum,$options{'processing-fee'});

    warn "cannot add Processing fee to invoice #$invnum: $grand_pf_error"
      if $grand_pf_error;
  }

  my $unapplied =   $self->total_unapplied_credits
                  + $self->total_unapplied_payments
                  + $self->in_transit_payments;
  foreach my $cust_bill ($self->open_cust_bill) {
    #$dbh->commit or die $dbh->errstr if $oldAutoCommit;
    my $cust_bill_pay_batch = new FS::cust_bill_pay_batch {
      'invnum' => $cust_bill->invnum,
      'paybatchnum' => $cust_pay_batch->paybatchnum,
      'amount' => $cust_bill->owed,
      '_date' => time,
    };
    if ($unapplied >= $cust_bill_pay_batch->amount){
      $unapplied -= $cust_bill_pay_batch->amount;
      next;
    }else{
      $cust_bill_pay_batch->amount(sprintf ( "%.2f", 
                                   $cust_bill_pay_batch->amount - $unapplied ));      $unapplied = 0;
    }
    $error = $cust_bill_pay_batch->insert;
    if ( $error ) {
      $dbh->rollback if $oldAutoCommit;
      die $error;
    }
  }

  $dbh->commit or die $dbh->errstr if $oldAutoCommit;
  '';
}

=item cust_pay_batch [ OPTION => VALUE... | EXTRA_QSEARCH_PARAMS_HASHREF ]

Returns all batched payments (see L<FS::cust_pay_batch>) for this customer.

Optionally, a list or hashref of additional arguments to the qsearch call can
be passed.

=cut

sub cust_pay_batch {
  my $self = shift;
  my $opt = ref($_[0]) ? shift : { @_ };

  #return $self->num_cust_statement unless wantarray || keys %$opt;

  $opt->{'table'} = 'cust_pay_batch';
  $opt->{'hashref'} ||= {}; #i guess it would autovivify anyway...
  $opt->{'hashref'}{'custnum'} = $self->custnum;
  $opt->{'order_by'} ||= 'ORDER BY paybatchnum ASC';

  map { $_ } #behavior of sort undefined in scalar context
    sort { $a->paybatchnum <=> $b->paybatchnum }
      qsearch($opt);
}

=item in_transit_payments

Returns the total of requests for payments for this customer pending in 
batches in transit to the bank.  See L<FS::pay_batch> and L<FS::cust_pay_batch>

=cut

sub in_transit_payments {
  my $self = shift;
  my $in_transit_payments = 0;
  foreach my $pay_batch ( qsearch('pay_batch', {
    'status' => 'I',
  } ) ) {
    foreach my $cust_pay_batch ( qsearch('cust_pay_batch', {
      'batchnum' => $pay_batch->batchnum,
      'custnum' => $self->custnum,
      'status'  => '',
    } ) ) {
      $in_transit_payments += $cust_pay_batch->amount;
    }
  }
  sprintf( "%.2f", $in_transit_payments );
}

1;
