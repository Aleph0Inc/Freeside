package FS::TaxEngine::internal;

use strict;
use base 'FS::TaxEngine';
use FS::Record qw(dbh qsearch qsearchs);
use FS::Conf;
use vars qw( $conf );

FS::UID->install_callback(sub {
    $conf = FS::Conf->new;
});

=head1 SUMMARY

FS::TaxEngine::internal: the classic Freeside "internal tax engine".
Uses tax rates and localities defined in L<FS::cust_main_county>.

=cut

my %part_pkg_cache;

sub add_sale {
  my ($self, $cust_bill_pkg) = @_;

  my $part_item = $cust_bill_pkg->part_X;
  my $location = $cust_bill_pkg->tax_location;
  my $custnum = $self->{cust_main}->custnum;

  push @{ $self->{items} }, $cust_bill_pkg;

  my %taxhash = map { $_ => $location->get($_) }
                qw( district county state country );
  # city names in cust_main_county are uppercase
  $taxhash{'city'} = uc($location->get('city'));

  $taxhash{'taxclass'} = $part_item->taxclass;

  my @taxes = (); # entries are cust_main_county objects
  my %taxhash_elim = %taxhash;
  my @elim = qw( district city county state );
  do {

    #first try a match with taxclass
    @taxes = qsearch( 'cust_main_county', \%taxhash_elim );

    if ( !scalar(@taxes) && $taxhash_elim{'taxclass'} ) {
      #then try a match without taxclass
      my %no_taxclass = %taxhash_elim;
      $no_taxclass{ 'taxclass' } = '';
      @taxes = qsearch( 'cust_main_county', \%no_taxclass );
    }

    $taxhash_elim{ shift(@elim) } = '';
  } while ( !scalar(@taxes) && scalar(@elim) );

  foreach my $tax (@taxes) {
    my $taxnum = $tax->taxnum;
    $self->{taxes}->{$taxnum} ||= [ $tax ];
    $cust_bill_pkg->set_exemptions( $tax, 'custnum' => $custnum );
    push @{ $self->{taxes}->{$taxnum} }, $cust_bill_pkg;
  }
}

sub taxline {
  my ($self, %opt) = @_;
  my $tax_object = $opt{tax};
  my $taxables = $opt{sales};
  my $taxnum = $tax_object->taxnum;
  my $exemptions = $self->{exemptions}->{$taxnum} ||= [];
  
  my $taxable_total = 0;
  my $tax_cents = 0;

  my $round_per_line_item = $conf->exists('tax-round_per_line_item');

  my $cust_main = $self->{cust_main};
  my $custnum   = $cust_main->custnum;
  my $invoice_time = $self->{invoice_time};

  # set a flag if the customer is tax-exempt
  my $exempt_cust;
  my $conf = FS::Conf->new;
  if ( $conf->exists('cust_class-tax_exempt') ) {
    my $cust_class = $cust_main->cust_class;
    $exempt_cust = $cust_class->tax if $cust_class;
  } else {
    $exempt_cust = $cust_main->tax;
  }
  # set a flag if the customer is exempt from this tax here
  my $exempt_cust_taxname = $cust_main->tax_exemption($tax_object->taxname)
    if $tax_object->taxname;

  # Gather any exemptions that are already attached to these cust_bill_pkgs
  # so that we can deduct them from the customer's monthly limit.
  my @existing_exemptions = @{ $exemptions };
  push @existing_exemptions, @{ $_->cust_tax_exempt_pkg }
    foreach @$taxables;

  my @tax_links;

  foreach my $cust_bill_pkg (@$taxables) {

    my $cust_pkg  = $cust_bill_pkg->cust_pkg;
    my $part_pkg  = $cust_bill_pkg->part_pkg;
    my @new_exemptions;
    my $taxable_charged = $cust_bill_pkg->setup + $cust_bill_pkg->recur
      or next; # don't create zero-amount exemptions

    # XXX the following procedure should probably be in cust_bill_pkg

    if ( $exempt_cust ) {

      push @new_exemptions, FS::cust_tax_exempt_pkg->new({
          amount => $taxable_charged,
          exempt_cust => 'Y',
        });
      $taxable_charged = 0;

    } elsif ( $exempt_cust_taxname ) {

      push @new_exemptions, FS::cust_tax_exempt_pkg->new({
          amount => $taxable_charged,
          exempt_cust_taxname => 'Y',
        });
      $taxable_charged = 0;

    }

    if ( ($part_pkg->setuptax eq 'Y' or $tax_object->setuptax eq 'Y')
        and $cust_bill_pkg->setup > 0 and $taxable_charged > 0 ) {

      push @new_exemptions, FS::cust_tax_exempt_pkg->new({
          amount => $cust_bill_pkg->setup,
          exempt_setup => 'Y'
      });
      $taxable_charged -= $cust_bill_pkg->setup;

    }
    if ( ($part_pkg->recurtax eq 'Y' or $tax_object->recurtax eq 'Y')
        and $cust_bill_pkg->recur > 0 and $taxable_charged > 0 ) {

      push @new_exemptions, FS::cust_tax_exempt_pkg->new({
          amount => $cust_bill_pkg->recur,
          exempt_recur => 'Y'
      });
       $taxable_charged -= $cust_bill_pkg->recur;

    }

    if ( $tax_object->exempt_amount && $tax_object->exempt_amount > 0
      and $taxable_charged > 0 ) {
      # If the billing period extends across multiple calendar months, 
      # there may be several months of exemption available.
      my $sdate = $cust_bill_pkg->sdate || $invoice_time;
      my $start_month = (localtime($sdate))[4] + 1;
      my $start_year  = (localtime($sdate))[5] + 1900;
      my $edate = $cust_bill_pkg->edate || $invoice_time;
      my $end_month   = (localtime($edate))[4] + 1;
      my $end_year    = (localtime($edate))[5] + 1900;

      # If the partial last month + partial first month <= one month,
      # don't use the exemption in the last month
      # (unless the last month is also the first month, e.g. one-time
      # charges)
      if ( (localtime($sdate))[3] >= (localtime($edate))[3]
           and ($start_month != $end_month or $start_year != $end_year)
     ) {
        $end_month--;
        if ( $end_month == 0 ) {
          $end_year--;
          $end_month = 12;
        }
      }

      # number of months of exemption available
      my $freq = ($end_month - $start_month) +
                 ($end_year  - $start_year) * 12 +
                 1;

      # divide equally among all of them
      my $permonth = sprintf('%.2f', $taxable_charged / $freq);

      #call the whole thing off if this customer has any old
      #exemption records...
      my @cust_tax_exempt =
        qsearch( 'cust_tax_exempt' => { custnum=> $custnum } );
      if ( @cust_tax_exempt ) {
        return
          'this customer still has old-style tax exemption records; '.
          'run bin/fs-migrate-cust_tax_exempt?';
      }

      my ($mon, $year) = ($start_month, $start_year);
      while ($taxable_charged > 0.005 and
             ($year < $end_year or
               ($year == $end_year and $mon <= $end_month)
             )
      ) {

        # find the sum of the exemption used by this customer, for this tax,
        # in this month
        my $sql = "
          SELECT SUM(amount)
            FROM cust_tax_exempt_pkg
              LEFT JOIN cust_bill_pkg USING ( billpkgnum )
              LEFT JOIN cust_bill     USING ( invnum     )
            WHERE custnum = ?
             AND taxnum  = ?
              AND year    = ?
              AND month   = ?
              AND exempt_monthly = 'Y'
        ";
        my $sth = dbh->prepare($sql) or
          return "fatal: can't lookup existing exemption: ". dbh->errstr;
        $sth->execute(
          $custnum,
          $tax_object->taxnum,
          $year,
          $mon,
        ) or
          return "fatal: can't lookup existing exemption: ". dbh->errstr;
        my $existing_exemption = $sth->fetchrow_arrayref->[0] || 0;

        # add any exemption we're already using for another line item
       foreach ( grep { $_->taxnum == $tax_object->taxnum &&
                         $_->exempt_monthly eq 'Y'   &&
                         $_->month  == $mon          &&
                         $_->year   == $year
                       } @existing_exemptions
                )
        {
          $existing_exemption += $_->amount;
        }

        my $remaining_exemption =
          $tax_object->exempt_amount - $existing_exemption;
        if ( $remaining_exemption > 0 ) {
          my $addl = $remaining_exemption > $permonth
            ? $permonth
            : $remaining_exemption;
          $addl = $taxable_charged if $addl > $taxable_charged;

          push @new_exemptions, FS::cust_tax_exempt_pkg->new({
              amount          => sprintf('%.2f', $addl),
              exempt_monthly  => 'Y',
              year            => $year,
              month           => $mon,
            });

          $taxable_charged -= $addl;
        }
        # if they're using multiple months of exemption for a multi-month
        # package, then record the exemptions in separate months
        $mon++;
        if ( $mon > 12 ) {
          $mon -= 12;
          $year++;
        }

      }
    } # if exempt_amount

    # attach them to the line item
    foreach my $ex (@new_exemptions) {

      $ex->set('taxnum', $taxnum);

      if ( $cust_bill_pkg->billpkgnum ) {
        # the exempted item is already inserted (it should be, these days) so
        # insert the exemption record now:
        $ex->set('billpkgnum', $cust_bill_pkg->billpkgnum);
        my $error = $ex->insert;
        return "inserting tax exemption record: $error" if $error;

      } else {
        # defer it until the item is inserted
        push @{ $cust_bill_pkg->cust_tax_exempt_pkg }, $ex;
      }
    }

    # and remember we've used the exemption
    push @existing_exemptions, @new_exemptions;

    $taxable_charged = sprintf( "%.2f", $taxable_charged);
    next if $taxable_charged == 0;

    my $this_tax_cents = $taxable_charged * $tax_object->tax;
    if ( $round_per_line_item ) {
      # Round the tax to the nearest cent for each line item, instead of
      # across the whole invoice.
      $this_tax_cents = sprintf('%.0f', $this_tax_cents);
    } else {
      # Otherwise truncate it so that rounding error is always positive.
      $this_tax_cents = int($this_tax_cents);
    }

    my $location = FS::cust_bill_pkg_tax_location->new({
        'taxnum'      => $tax_object->taxnum,
        'taxtype'     => ref($tax_object),
        'cents'       => $this_tax_cents,
        'pkgnum'      => $cust_bill_pkg->pkgnum,
        'locationnum' => $cust_bill_pkg->cust_pkg->tax_locationnum,
        'taxable_cust_bill_pkg' => $cust_bill_pkg,
    });
    push @tax_links, $location;

    $taxable_total += $taxable_charged;
    $tax_cents += $this_tax_cents;
  } #foreach $cust_bill_pkg

  # calculate tax and rounding error for the whole group: total taxable
  # amount times tax rate (as cents per dollar), minus the tax already
  # charged
  # and force 0.5 to round up
  my $extra_cents = sprintf('%.0f',
    ($taxable_total * $tax_object->tax) - $tax_cents + 0.00000001
  );

  # if we're rounding per item, then ignore that and don't distribute any
  # extra cents.
  if ( $round_per_line_item ) {
    $extra_cents = 0;
  }

  if ( $extra_cents < 0 ) {
    die "nonsense extra_cents value $extra_cents";
  }
  $tax_cents += $extra_cents;
  my $i = 0;
  foreach (@tax_links) { # can never require more than a single pass, yes?
    my $cents = $_->get('cents');
    if ( $extra_cents > 0 ) {
      $cents++;
      $extra_cents--;
    }
    $_->set('amount', sprintf('%.2f', $cents/100));
  }

  return @tax_links;
}

sub info {
 +{
    batch       => 0,
    override    => 0,
    rate_table  => 'cust_main_county',
    link_table  => 'cust_bill_pkg_tax_location',
  }
}

1; 
