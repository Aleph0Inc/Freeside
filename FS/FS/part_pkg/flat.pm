package FS::part_pkg::flat;
use base qw( FS::part_pkg::prorate_Mixin
             FS::part_pkg::discount_Mixin
             FS::part_pkg
           );

use strict;
use vars qw( $conf $money_char %info
             %usage_recharge_fields @usage_recharge_fieldorder
           );
use FS::UID;
use FS::Record qw( qsearch );
use FS::cust_credit_source_bill_pkg;
use Tie::IxHash;
use List::Util qw( min );
use FS::UI::bytecount;
use FS::Conf;
use Time::Local 'timelocal';

#ask FS::UID to run this stuff for us later
FS::UID->install_callback( sub {
  $conf = new FS::Conf;
  $money_char = $conf->config('money_char') || '$';
});

tie my %temporalities, 'Tie::IxHash',
  'upcoming'  => "Upcoming (future)",
  'preceding' => "Preceding (past)",
;

tie my %contract_years, 'Tie::IxHash', (
  '' => '(none)',
  map { $_*12 => $_ } (1..5),
);

%info = (
  'name' => 'Flat rate (anniversary billing)',
  'shortname' => 'Anniversary',
  'inherit_fields' => [ 'prorate_Mixin', 'usage_Mixin', 'global_Mixin' ],
  'fields' => {
    #false laziness w/voip_cdr.pm
    'recur_temporality' => { 'name' => 'Charge recurring fee for period',
                             'type' => 'select',
                             'select_options' => \%temporalities,
                           },

    #used in cust_pkg.pm so could add to any price plan where it made sense
    'start_1st'     => { 'name' => 'Auto-add a start date to the 1st, ignoring the current month.',
                         'type' => 'checkbox',
                       },
    'sync_bill_date' => { 'name' => 'Prorate first month to synchronize '.
                                    'with the customer\'s other packages',
                          'type' => 'checkbox',
                        },
    'prorate_defer_bill' => { 
                          'name' => 'When synchronizing, defer the bill until '.
                                    'the customer\'s next bill date',
                          'type' => 'checkbox',
                        },
    'prorate_round_day' => {
                          'name' => 'When synchronizing, round the prorated '.
                                    'period',
                          'type' => 'select',
                          'select_options' => \%FS::part_pkg::prorate_Mixin::prorate_round_day_opts,
                        },
    'add_full_period' => { 'disabled' => 1 }, # doesn't make sense with sync?

    'suspend_bill' => { 'name' => 'Continue recurring billing while suspended',
                        'type' => 'checkbox',
                      },
    'unsuspend_adjust_bill' => 
                        { 'name' => 'Adjust next bill date forward when '.
                                    'unsuspending',
                          'type' => 'checkbox',
                        },
    'bill_recur_on_cancel' => {
                        'name' => 'Bill the last period on cancellation',
                        'type' => 'checkbox',
                        },
    'bill_suspend_as_cancel' => {
                        'name' => 'Bill immediately upon suspension', #desc?
                        'type' => 'checkbox',
                        },
    'externalid' => { 'name'   => 'Optional External ID',
                      'default' => '',
                    },
  },
  'fieldorder' => [ qw( recur_temporality 
                        start_1st
                        sync_bill_date prorate_defer_bill prorate_round_day
                        suspend_bill unsuspend_adjust_bill
                        bill_recur_on_cancel
                        bill_suspend_as_cancel
                        externalid ),
                  ],
  'weight' => 10,
);

sub price_info {
  my $self = shift;
  my %opt = @_;

  my $setup = $opt{cust_pkg} ? $self->base_setup( $opt{cust_pkg} )
                             : ($self->option('setup_fee') || 0);
  my $recur = $opt{cust_pkg} ? $self->base_recur( $opt{cust_pkg} )
                             : ($self->option('recur_fee', 1) || 0);
  $recur += $self->usageprice_recur( $opt{cust_pkg} ) if $opt{cust_pkg};

  my $str = '';
  $str = $money_char . $setup . ($recur ? ' setup' : ' one-time') if $setup;
  $str .= ', ' if ($setup && $recur);
  $str .= $money_char. $recur. '/'. $self->freq_pretty if $recur;
  $str;
}

sub calc_setup {
  my($self, $cust_pkg, $time, $details, $param ) = @_;

  return 0 if $self->prorate_setup($cust_pkg, $time);

  my $i = 0;
  my $count = $self->option( 'additional_count', 'quiet' ) || 0;
  while ($i < $count) {
    push @$details, $self->option( 'additional_info' . $i++ );
  }

  my $charge = $self->base_setup($cust_pkg, $time, $details);

  my $discount = 0;
  if ( $charge > 0 ) {
      $param->{'setup_charge'} = $charge;
      $discount = $self->calc_discount($cust_pkg, \$time, $details, $param);
      delete $param->{'setup_charge'};
  }

  sprintf( '%.2f', ($cust_pkg->quantity || 1) * ($charge - $discount) );
}

sub base_setup {
  my($self, $cust_pkg, $time, $details ) = @_;
  $self->option('setup_fee', 1) || 0;
}

sub calc_recur {
  my $self = shift;
  my($cust_pkg, $sdate, $details, $param ) = @_;

  #my $last_bill = $cust_pkg->last_bill;
  my $last_bill = $cust_pkg->get('last_bill'); #->last_bill falls back to setup

  return 0
    if $self->recur_temporality eq 'preceding' && !$last_bill;

  my $charge = $self->base_recur($cust_pkg, $sdate);
  # always treat cutoff_day as a list
  if ( my @cutoff_day = $self->cutoff_day($cust_pkg) ) {
    $charge = $self->calc_prorate(@_, @cutoff_day);
  }
  elsif ( $param->{freq_override} ) {
    # XXX not sure if this should be mutually exclusive with sync_bill_date.
    # Given the very specific problem that freq_override is meant to 'solve',
    # it probably should.
    $charge *= $param->{freq_override} if $param->{freq_override};
  }

  $charge += $self->usageprice_recur($cust_pkg, $sdate);
  $cust_pkg->apply_usageprice(); #$sdate for prorating?

  my $discount = $self->calc_discount($cust_pkg, $sdate, $details, $param);

  sprintf( '%.2f', ($cust_pkg->quantity || 1) * ($charge - $discount) );
}

sub cutoff_day {
  my $self = shift;
  my $cust_pkg = shift;
  my $cust_main = $cust_pkg->cust_main;
  # force it to act like a prorate package, is what this means
  # because we made a distinction once between prorate and flat packages
  if ( $cust_main->force_prorate_day  and $cust_main->prorate_day ) {
     return ( $cust_main->prorate_day );
  }
  if ( $self->option('sync_bill_date',1) ) {
    my $next_bill = $cust_pkg->cust_main->next_bill_date;
    if ( $next_bill ) {
      return (localtime($next_bill))[3];
    } else {
      # This is the customer's only active package and hasn't been billed
      # yet, so set the cutoff day to either today or tomorrow, whichever
      # would result in a full period after rounding.
      my $setup = $cust_pkg->setup; # because it's "now"
      my $rounding_mode = $self->option('prorate_round_day',1);
      return () if !$setup or !$rounding_mode;
      my ($sec, $min, $hour, $mday, $mon, $year) = localtime($setup);

      if (   ( $rounding_mode == 1 and $hour >= 12 )
          or ( $rounding_mode == 3 and ( $sec > 0 or $min > 0 or $hour > 0 ))
      ) {
        # then the prorate period will be rounded down to start from
        # midnight tomorrow, so the cutoff day should be the current day +
        # 1.
        $setup = timelocal(59,59,23,$mday,$mon,$year) + 1;
        $mday = (localtime($setup))[3];
      }
      # otherwise, it will be rounded up, so leave the cutoff day at today.
      return $mday;
    }
  }
  return ();
}

sub base_recur {
  my($self, $cust_pkg, $sdate) = @_;
  $self->option('recur_fee', 1) || 0;
}

sub base_recur_permonth {
  my($self, $cust_pkg) = @_;

  return 0 unless $self->freq =~ /^\d+$/ && $self->freq > 0;

  sprintf('%.2f', $self->base_recur($cust_pkg) / $self->freq );
}

sub usageprice_recur {
  my($self, $cust_pkg, $sdate) = @_;

  my $recur = 0;
  $recur += $_->price foreach $cust_pkg->cust_pkg_usageprice;

  sprintf('%.2f', $recur);
}

sub calc_cancel {
  my $self = shift;
  if ( $self->recur_temporality eq 'preceding'
       and $self->option('bill_recur_on_cancel', 1) ) {
    # run another recurring cycle
    return $self->calc_recur(@_);
  } elsif ( $conf->exists('bill_usage_on_cancel') # should be a package option?
          and $self->can('calc_usage') ) {
    # bill for outstanding usage
    return $self->calc_usage(@_);
  } else {
    return 'NOTHING'; # numerically zero, but has special meaning
  }
}

# no longer used; see credit_remaining in FS::cust_pkg

sub calc_remain {
  my ($self, $cust_pkg, %options) = @_;

  my $time;
  if ($options{'time'}) {
    $time = $options{'time'};
  } else {
    $time = time;
  }

  my $next_bill = $cust_pkg->getfield('bill') || 0;

  return 0 if    ! $self->base_recur($cust_pkg, \$time)
              || ! $next_bill
              || $next_bill < $time;

  # Use actual charge for this period, not base_recur (for discounts).
  # Use sdate < $time and edate >= $time because when billing on 
  # cancellation, edate = $time.
  my $credit = 0;
  foreach my $cust_bill_pkg ( 
    qsearch('cust_bill_pkg', { 
      pkgnum => $cust_pkg->pkgnum,
      edate => {op => '>=', value => $time},
      recur => {op => '>' , value => 0},
    })
  ) {

    # hack to deal with the weird behavior of edate on package cancellation
    my $edate = $cust_bill_pkg->edate;
    if ( $self->recur_temporality eq 'preceding' ) {
      $edate = $self->add_freq($cust_bill_pkg->sdate);
    }

    # this will also get any package charges that are _entirely_ after the
    # cancellation date (can happen with advance billing). in that case,
    # use the entire recurring charge:
    my $amount = $cust_bill_pkg->recur - $cust_bill_pkg->usage;

    # but if the cancellation happens during the interval, prorate it:
    # (XXX obey prorate_round_day here?)
    if ( $cust_bill_pkg->sdate < $time ) {
      $amount = $amount * ($edate - $time) / ($edate - $cust_bill_pkg->sdate);
    }

    $credit += $amount;

    push @{ $options{'cust_credit_source_bill_pkg'} },
      new FS::cust_credit_source_bill_pkg {
        'billpkgnum' => $cust_bill_pkg->billpkgnum,
        'amount'     => sprintf('%.2f', $amount),
        'currency'   => $cust_bill_pkg->cust_bill->currency,
      }
        if $options{'cust_credit_source_bill_pkg'};

  } 

  sprintf('%.2f', $credit);

}

sub is_free_options {
  qw( setup_fee recur_fee );
}

sub is_prepaid { 0; } #no, we're postpaid

sub can_start_date {
  my $self = shift;
  my %opt = @_;
  return 0 if $self->start_on_hold;

  ! $self->option('start_1st', 1) && (   ! $self->option('sync_bill_date',1)
                                      || ! $self->option('prorate_defer_bill',1)
                                      || ! $opt{'num_ncancelled_pkgs'}
                                     ); 
}

sub can_discount { 1; }

sub can_usageprice { 1; }

sub recur_temporality {
  my $self = shift;
  $self->option('recur_temporality', 1);
}

sub usage_valuehash {
  my $self = shift;
  map { $_, $self->option($_) }
    grep { $self->option($_, 'hush') } 
    qw(seconds upbytes downbytes totalbytes);
}

sub reset_usage {
  my($self, $cust_pkg, %opt) = @_;
  warn "   resetting usage counters" if defined($opt{debug}) && $opt{debug} > 1;
  my %values = $self->usage_valuehash;
  if ($self->option('usage_rollover', 1)) {
    $cust_pkg->recharge(\%values);
  }else{
    $cust_pkg->set_usage(\%values, %opt);
  }
}

1;
