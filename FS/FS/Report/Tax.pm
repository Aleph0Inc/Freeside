package FS::Report::Tax;

use strict;
use vars qw($DEBUG);
use FS::Record qw(dbh qsearch qsearchs group_concat_sql);
use Date::Format qw( time2str );

use Data::Dumper;

$DEBUG = 0;

=item report_internal OPTIONS

Constructor.  Generates a tax report using the internal tax rate system 
(L<FS::cust_main_county>).

Required parameters:

- beginning, ending: the date range as Unix timestamps.
- taxname: the name of the tax (corresponds to C<cust_bill_pkg.itemdesc>).
- country: the country code.

Optional parameters:
- agentnum: limit to this agentnum.num.
- breakdown: hashref of the fields to group by.  Keys can be 'city', 'district',
  'pkgclass', or 'taxclass'; values should be true.
- debug: sets the debug level.  1 will warn the data collected for the report;
  2 will also warn all of the SQL statements.

=cut

sub report_internal {
  my $class = shift;
  my %opt = @_;

  $DEBUG ||= $opt{debug};

  my $conf = new FS::Conf;

  my($beginning, $ending) = @opt{'beginning', 'ending'};

  my ($taxname, $country, %breakdown);

  # taxname can contain arbitrary punctuation; escape it properly and 
  # include $taxname unquoted elsewhere
  $taxname = dbh->quote($opt{'taxname'});

  if ( $opt{country} =~ /^(\w\w)$/ ) {
    $country = $1;
  } else {
    die "country required";
  }

  # %breakdown: short name => field identifier
  # null classnum should remain null, not be converted to zero
  %breakdown = (
    'taxclass'  => 'cust_main_county.taxclass',
    'pkgclass'  => 'COALESCE(part_fee.classnum,part_pkg.classnum)',
    'city'      => 'cust_main_county.city',
    'district'  => 'cust_main_county.district',
    'state'     => 'cust_main_county.state',
    'county'    => 'cust_main_county.county',
  );
  foreach (qw(taxclass pkgclass city district)) {
    delete $breakdown{$_} unless $opt{breakdown}->{$_};
  }

  my $join_cust =     '      JOIN cust_bill     USING ( invnum  )
                        LEFT JOIN cust_main     USING ( custnum ) ';

  my $join_cust_pkg = $join_cust.
                      ' LEFT JOIN cust_pkg      USING ( pkgnum  )
                        LEFT JOIN part_pkg      USING ( pkgpart )
                        LEFT JOIN part_fee      USING ( feepart ) ';

  my $from_join_cust_pkg = " FROM cust_bill_pkg $join_cust_pkg "; 

  # all queries MUST be linked to both cust_bill and cust_main_county

  # Either or both of these can be used to link cust_bill_pkg to 
  # cust_main_county. This one links a taxed line item (billpkgnum) to a tax rate
  # (taxnum), and gives the amount of tax charged on that line item under that
  # rate (as tax_amount).
  my $pkg_tax = "SELECT SUM(amount) as tax_amount, taxnum, ".
    "taxable_billpkgnum AS billpkgnum ".
    "FROM cust_bill_pkg_tax_location JOIN cust_bill_pkg USING (billpkgnum) ".
    "GROUP BY taxable_billpkgnum, taxnum";

  # This one links a tax-exempted line item (billpkgnum) to a tax rate
  # (taxnum), and gives the amount of the tax exemption.  EXEMPT_WHERE must 
  # be replaced with an expression to further limit the tax exemptions
  # that will be included, or "TRUE" to not limit them.
  #
  # Note that tax exemptions with non-null creditbillpkgnum are always
  # excluded. Those are "negative exemptions" created by crediting a sale 
  # that had received an exemption.
  my $pkg_tax_exempt = "SELECT SUM(amount) AS exempt_charged, billpkgnum, taxnum ".
    "FROM cust_tax_exempt_pkg WHERE
      ( EXEMPT_WHERE )
      AND cust_tax_exempt_pkg.creditbillpkgnum IS NULL
     GROUP BY billpkgnum, taxnum";

  my $where = "WHERE cust_bill._date >= $beginning AND cust_bill._date <= $ending ".
              "AND COALESCE(cust_main_county.taxname,'Tax') = $taxname ".
              "AND cust_main_county.country = '$country'";
  # SELECT/GROUP clauses for first-level queries
  my $select = "SELECT ";
  my $group = "GROUP BY ";
  foreach (qw(pkgclass taxclass state county city district)) {
    if ( $breakdown{$_} ) {
      $select .= "$breakdown{$_} AS $_, ";
      $group  .= "$breakdown{$_}, ";
    } else {
      $select .= "NULL AS $_, ";
    }
  }
  $select .= group_concat_sql('DISTINCT(cust_main_county.taxnum)', ',') .
             ' AS taxnums, ';
  $group =~ s/, $//;

  # SELECT/GROUP clauses for second-level (totals) queries
  # breakdown by package class only, if anything
  my $select_all = "SELECT NULL AS pkgclass, ";
  my $group_all = "";
  if ( $breakdown{pkgclass} ) {
    $select_all = "SELECT $breakdown{pkgclass} AS pkgclass, ";
    $group_all = "GROUP BY $breakdown{pkgclass}";
  }
  $select_all .= group_concat_sql('DISTINCT(cust_main_county.taxnum)', ',') .
                 ' AS taxnums, ';

  my $agentnum;
  if ( $opt{agentnum} and $opt{agentnum} =~ /^(\d+)$/ ) {
    $agentnum = $1;
    my $agent = qsearchs('agent', { 'agentnum' => $agentnum } );
    die "agent not found" unless $agent;
    $where .= " AND cust_main.agentnum = $agentnum";
  }

  my $nottax = 
    '(cust_bill_pkg.pkgnum != 0 OR cust_bill_pkg.feepart IS NOT NULL)';

  # one query for each column of the report
  # plus separate queries for the totals row
  my (%sql, %all_sql);

  # SALES QUERIES (taxable sales, all types of exempt sales)
  # -------------

  # general form
  my $exempt = "$select SUM(exempt_charged)
    FROM cust_main_county
    JOIN ($pkg_tax_exempt) AS pkg_tax_exempt
    USING (taxnum)
    JOIN cust_bill_pkg USING (billpkgnum)
    $join_cust_pkg $where AND $nottax
    $group";

  my $all_exempt = "$select_all SUM(exempt_charged)
    FROM cust_main_county
    JOIN ($pkg_tax_exempt) AS pkg_tax_exempt
    USING (taxnum)
    JOIN cust_bill_pkg USING (billpkgnum)
    $join_cust_pkg $where AND $nottax
    $group_all";

  # sales to tax-exempt customers
  $sql{exempt_cust} = $exempt;
  $sql{exempt_cust} =~ s/EXEMPT_WHERE/exempt_cust = 'Y' OR exempt_cust_taxname = 'Y'/;
  $all_sql{exempt_cust} = $all_exempt;
  $all_sql{exempt_cust} =~ s/EXEMPT_WHERE/exempt_cust = 'Y' OR exempt_cust_taxname = 'Y'/;

  # sales of tax-exempt packages
  $sql{exempt_pkg} = $exempt;
  $sql{exempt_pkg} =~ s/EXEMPT_WHERE/exempt_setup = 'Y' OR exempt_recur = 'Y'/;
  $all_sql{exempt_pkg} = $all_exempt;
  $all_sql{exempt_pkg} =~ s/EXEMPT_WHERE/exempt_setup = 'Y' OR exempt_recur = 'Y'/;

  # monthly per-customer exemptions
  $sql{exempt_monthly} = $exempt;
  $sql{exempt_monthly} =~ s/EXEMPT_WHERE/exempt_monthly = 'Y'/;
  $all_sql{exempt_monthly} = $all_exempt;
  $all_sql{exempt_monthly} =~ s/EXEMPT_WHERE/exempt_monthly = 'Y'/;

  # credits applied to taxable sales
  # Note that negative exemptions (from exempt sales being credited) are NOT
  # counted when calculating the exempt amount. (See above.) Therefore we need
  # to NOT include any credits against exempt sales in this amount, either.
  # These two subqueries implement that. They have joins to cust_credit_bill
  # and cust_bill so that credits can be filtered by application date if
  # requested.

  # Each row here is the sum of credits applied to a line item.
  my $sales_credit =
    "SELECT billpkgnum, SUM(cust_credit_bill_pkg.amount) AS credited
    FROM cust_credit_bill_pkg
    JOIN cust_credit_bill USING (creditbillnum)
    JOIN cust_bill USING (invnum)
    WHERE cust_bill._date >= $beginning AND cust_bill._date <= $ending
    GROUP BY billpkgnum
    ";

  # Each row here is the sum of negative exemptions applied to a combination
  # of line item and tax definition.
  my $exempt_credit =
    "SELECT cust_credit_bill_pkg.billpkgnum, taxnum,
      0 - SUM(cust_tax_exempt_pkg.amount) AS exempt_credited
    FROM cust_credit_bill_pkg
    LEFT JOIN cust_tax_exempt_pkg USING (creditbillpkgnum)
    JOIN cust_credit_bill USING (creditbillnum)
    JOIN cust_bill USING (invnum)
    WHERE cust_bill._date >= $beginning AND cust_bill._date <= $ending
    GROUP BY cust_credit_bill_pkg.billpkgnum, taxnum
    ";
  
  if ( $opt{credit_date} eq 'cust_credit_bill' ) {
    $sales_credit =~ s/cust_bill._date/cust_credit_bill._date/g;
    $exempt_credit =~ s/cust_bill._date/cust_credit_bill._date/g;
  }

  $sql{sales_credited} = "$select
    SUM(COALESCE(credited, 0) - COALESCE(exempt_credited, 0))
    FROM cust_main_county
    JOIN ($pkg_tax) AS pkg_tax USING (taxnum)
    JOIN cust_bill_pkg USING (billpkgnum)
    LEFT JOIN ($sales_credit) AS sales_credit USING (billpkgnum)
    LEFT JOIN ($exempt_credit) AS exempt_credit USING (billpkgnum, taxnum)
    $join_cust_pkg $where AND $nottax
    $group
    ";

  $all_sql{sales_credited} = "$select_all
    SUM(COALESCE(credited, 0) - COALESCE(exempt_credited, 0))
    FROM cust_main_county
    JOIN ($pkg_tax) AS pkg_tax USING (taxnum)
    JOIN cust_bill_pkg USING (billpkgnum)
    LEFT JOIN ($sales_credit) AS sales_credit USING (billpkgnum)
    LEFT JOIN ($exempt_credit) AS exempt_credit USING (billpkgnum, taxnum)
    $join_cust_pkg $where AND $nottax
    $group_all
    ";

  # also include the exempt-sales credit amount, for the credit report
  $sql{exempt_credited} = "$select
    SUM(COALESCE(exempt_credited, 0))
    FROM cust_main_county
    LEFT JOIN ($exempt_credit) AS exempt_credit USING (taxnum)
    JOIN cust_bill_pkg USING (billpkgnum)
    $join_cust_pkg $where AND $nottax
    $group
    ";

  $all_sql{exempt_credited} = "$select_all
    SUM(COALESCE(exempt_credited, 0))
    FROM cust_main_county
    LEFT JOIN ($exempt_credit) AS exempt_credit USING (taxnum)
    JOIN cust_bill_pkg USING (billpkgnum)
    $join_cust_pkg $where AND $nottax
    $group_all
    ";

  # taxable sales
  $sql{taxable} = "$select
    SUM(cust_bill_pkg.setup + cust_bill_pkg.recur
      - COALESCE(exempt_charged, 0)
      - COALESCE(credited, 0)
      + COALESCE(exempt_credited, 0)
    )
    FROM cust_main_county
    JOIN ($pkg_tax) AS pkg_tax USING (taxnum)
    JOIN cust_bill_pkg USING (billpkgnum)
    LEFT JOIN ($pkg_tax_exempt) AS pkg_tax_exempt USING (billpkgnum, taxnum)
    LEFT JOIN ($sales_credit) AS sales_credit USING (billpkgnum)
    LEFT JOIN ($exempt_credit) AS exempt_credit USING (billpkgnum, taxnum)
    $join_cust_pkg $where AND $nottax 
    $group";

  $all_sql{taxable} = "$select_all
    SUM(cust_bill_pkg.setup + cust_bill_pkg.recur
      - COALESCE(exempt_charged, 0)
      - COALESCE(credited, 0)
      + COALESCE(exempt_credited, 0)
    )
    FROM cust_main_county
    JOIN ($pkg_tax) AS pkg_tax USING (taxnum)
    JOIN cust_bill_pkg USING (billpkgnum)
    LEFT JOIN ($pkg_tax_exempt) AS pkg_tax_exempt USING (billpkgnum, taxnum)
    LEFT JOIN ($sales_credit) AS sales_credit USING (billpkgnum)
    LEFT JOIN ($exempt_credit) AS exempt_credit USING (billpkgnum, taxnum)
    $join_cust_pkg $where AND $nottax 
    $group_all";

  $sql{taxable} =~ s/EXEMPT_WHERE/TRUE/; # unrestricted
  $all_sql{taxable} =~ s/EXEMPT_WHERE/TRUE/;

  # estimated tax (taxable * rate)
  $sql{estimated} = "$select
    SUM(cust_main_county.tax / 100 * 
      (cust_bill_pkg.setup + cust_bill_pkg.recur
      - COALESCE(exempt_charged, 0)
      - COALESCE(credited, 0)
      + COALESCE(exempt_credited, 0)
      )
    )
    FROM cust_main_county
    JOIN ($pkg_tax) AS pkg_tax USING (taxnum)
    JOIN cust_bill_pkg USING (billpkgnum)
    LEFT JOIN ($pkg_tax_exempt) AS pkg_tax_exempt USING (billpkgnum, taxnum)
    LEFT JOIN ($sales_credit) AS sales_credit USING (billpkgnum)
    LEFT JOIN ($exempt_credit) AS exempt_credit USING (billpkgnum, taxnum)
    $join_cust_pkg $where AND $nottax 
    $group";

  $all_sql{estimated} = "$select_all
    SUM(cust_main_county.tax / 100 * 
      (cust_bill_pkg.setup + cust_bill_pkg.recur
      - COALESCE(exempt_charged, 0)
      - COALESCE(credited, 0)
      + COALESCE(exempt_credited, 0)
      )
    )
    FROM cust_main_county
    JOIN ($pkg_tax) AS pkg_tax USING (taxnum)
    JOIN cust_bill_pkg USING (billpkgnum)
    LEFT JOIN ($pkg_tax_exempt) AS pkg_tax_exempt USING (billpkgnum, taxnum)
    LEFT JOIN ($sales_credit) AS sales_credit USING (billpkgnum)
    LEFT JOIN ($exempt_credit) AS exempt_credit USING (billpkgnum, taxnum)
    $join_cust_pkg $where AND $nottax 
    $group_all";

  $sql{estimated} =~ s/EXEMPT_WHERE/TRUE/; # unrestricted
  $all_sql{estimated} =~ s/EXEMPT_WHERE/TRUE/;

  # there isn't one for 'sales', because we calculate sales by adding up 
  # the taxable and exempt columns.
  
  # TAX QUERIES (billed tax, credited tax, collected tax)
  # -----------

  # sum of billed tax:
  # join cust_bill_pkg to cust_main_county via cust_bill_pkg_tax_location
  my $taxfrom = " FROM cust_bill_pkg 
                  $join_cust 
                  LEFT JOIN cust_bill_pkg_tax_location USING ( billpkgnum )
                  LEFT JOIN cust_main_county USING ( taxnum )";

  if ( $breakdown{pkgclass} ) {
    # If we're not grouping by package class, this is unnecessary, and
    # probably really expensive.
    # Remember that fees also have package classes.
    $taxfrom .= "
                  LEFT JOIN cust_bill_pkg AS taxable
                    ON (cust_bill_pkg_tax_location.taxable_billpkgnum = taxable.billpkgnum)
                  LEFT JOIN cust_pkg ON (taxable.pkgnum = cust_pkg.pkgnum)
                  LEFT JOIN part_pkg USING (pkgpart)
                  LEFT JOIN part_fee ON (taxable.feepart = part_fee.feepart) ";
  }

  my $istax = "cust_bill_pkg.pkgnum = 0 and cust_bill_pkg.feepart is null";

  $sql{tax} = "$select COALESCE(SUM(cust_bill_pkg_tax_location.amount),0)
               $taxfrom
               $where AND $istax
               $group";

  $all_sql{tax} = "$select_all COALESCE(SUM(cust_bill_pkg_tax_location.amount),0)
               $taxfrom
               $where AND $istax
               $group_all";

  # sum of credits applied against billed tax
  # ($creditfrom includes join of taxable item to part_pkg/part_fee if 
  # with_pkgclass is on)
  my $creditfrom = $taxfrom .
    ' JOIN cust_credit_bill_pkg USING (billpkgtaxlocationnum)' .
    ' JOIN cust_credit_bill     USING (creditbillnum)';
  my $creditwhere = $where . 
    ' AND billpkgtaxratelocationnum IS NULL';

  # if the credit_date option is set to application date, change
  # $creditwhere accordingly
  if ( $opt{credit_date} eq 'cust_credit_bill' ) {
    $creditwhere     =~ s/cust_bill._date/cust_credit_bill._date/g;
  }

  $sql{tax_credited} = "$select COALESCE(SUM(cust_credit_bill_pkg.amount),0)
                  $creditfrom
                  $creditwhere AND $istax
                  $group";

  $all_sql{tax_credited} = "$select_all COALESCE(SUM(cust_credit_bill_pkg.amount),0)
                  $creditfrom
                  $creditwhere AND $istax
                  $group_all";

  # sum of tax paid
  # this suffers from the same ambiguity as anything else that applies 
  # received payments to specific packages, but in reality the discrepancy
  # should be minimal since people either pay their bill or don't.
  # the join is on billpkgtaxlocationnum to avoid cross-producting.
 
  my $paidfrom = $taxfrom .
    ' JOIN cust_bill_pay_pkg'.
    ' ON (cust_bill_pay_pkg.billpkgtaxlocationnum ='.
    ' cust_bill_pkg_tax_location.billpkgtaxlocationnum)';

  $sql{tax_paid} = "$select COALESCE(SUM(cust_bill_pay_pkg.amount),0)
                    $paidfrom
                    $where AND $istax
                    $group";

  $all_sql{tax_paid} = "$select_all COALESCE(SUM(cust_bill_pay_pkg.amount),0)
                    $paidfrom
                    $where AND $istax
                    $group_all";

  my %data;
  my %total;
  # note that we use keys(%sql) here and keys(%all_sql) later. nothing
  # obligates us to use the same set of variables for the total query 
  # as for the individual category queries
  foreach my $k (keys(%sql)) {
    my $stmt = $sql{$k};
    warn "\n".uc($k).":\n".$stmt."\n" if $DEBUG > 1;
    my $sth = dbh->prepare($stmt);
    # eight columns: pkgclass, taxclass, state, county, city, district
    # taxnums (comma separated), value
    $sth->execute 
      or die "failed to execute $k query: ".$sth->errstr;
    while ( my $row = $sth->fetchrow_arrayref ) {
      my $bin = $data
                {$row->[0]} # pkgclass
                {$row->[1]  # taxclass
                  || ($breakdown{taxclass} ? 'Unclassified' : '')}
                {$row->[2]} # state
                {$row->[3] ? $row->[3] . ' County' : ''} # county
                {$row->[4]} # city
                {$row->[5]} # district
              ||= [];
      push @$bin, [ $k, $row->[6], $row->[7] ];
    }
  }
  warn "DATA:\n".Dumper(\%data) if $DEBUG;

  foreach my $k (keys %all_sql) {
    warn "\nTOTAL ".uc($k).":\n".$all_sql{$k}."\n" if $DEBUG;
    my $sth = dbh->prepare($all_sql{$k});
    # three columns: pkgclass, taxnums (comma separated), value
    $sth->execute 
      or die "failed to execute $k totals query: ".$sth->errstr;
    while ( my $row = $sth->fetchrow_arrayref ) {
      my $bin = $total{$row->[0]} ||= [];
      push @$bin, [ $k, $row->[1], $row->[2] ];
    }
  }
  warn "TOTALS:\n".Dumper(\%total) if $DEBUG > 1;

  # $data{$pkgclass}{$taxclass}{$state}{$county}{$city}{$district} = [
  #   [ 'taxable',     taxnums, amount ],
  #   [ 'exempt_cust', taxnums, amount ],
  #   ...
  # ]
  # non-requested grouping levels simply collapse into key = ''

  # the much-maligned "out of taxable region"...
  # find sales that are not linked to any tax with this name
  # but are still inside the date range/agent criteria.
  #
  # This doesn't use $select_all/$group_all because we want a single number,
  # not a breakdown by pkgclass. Unless someone needs that eventually, 
  # in which case we'll turn it into an %all_sql query.
  
  my $outside_where =
    "WHERE cust_bill._date >= $beginning AND cust_bill._date <= $ending";
  if ( $agentnum ) {
    $outside_where .= " AND cust_main.agentnum = $agentnum";
  }
  my $sql_outside = "SELECT SUM(cust_bill_pkg.setup + cust_bill_pkg.recur)
    FROM cust_bill_pkg
    $join_cust_pkg
    $outside_where
    AND $nottax
    AND NOT EXISTS(
      SELECT 1 FROM cust_tax_exempt_pkg
        JOIN cust_main_county USING (taxnum)
        WHERE cust_tax_exempt_pkg.billpkgnum = cust_bill_pkg.billpkgnum
          AND COALESCE(cust_main_county.taxname,'Tax') = $taxname
          AND cust_tax_exempt_pkg.creditbillpkgnum IS NULL
    )
    AND NOT EXISTS(
      SELECT 1 FROM cust_bill_pkg_tax_location
        JOIN cust_main_county USING (taxnum)
        WHERE cust_bill_pkg_tax_location.taxable_billpkgnum = cust_bill_pkg.billpkgnum
          AND COALESCE(cust_main_county.taxname,'Tax') = $taxname
    )
  ";
  warn "\nOUTSIDE:\n$sql_outside\n" if $DEBUG;
  my $total_outside = FS::Record->scalar_sql($sql_outside);

  my %taxrates;
  foreach my $tax (
    qsearch('cust_main_county', {
              country => $country,
              tax => { op => '>', value => 0 }
            }) )
    {
    $taxrates{$tax->taxnum} = $tax->tax;
  }

  # return the data
  bless {
    'opt'       => \%opt,
    'data'      => \%data,
    'total'     => \%total,
    'taxrates'  => \%taxrates,
    'outside'   => $total_outside,
  }, $class;
}

sub opt {
  my $self = shift;
  $self->{opt};
}

sub data {
  my $self = shift;
  $self->{data};
}

# sub fetchall_array...

sub table {
  my $self = shift;
  my @columns = (qw(pkgclass taxclass state county city district));
  # taxnums, field headings, and amounts
  my @rows;
  my %row_template;

  # de-treeify this thing
  my $descend;
  $descend = sub {
    my ($tree, $level) = @_;
    if ( ref($tree) eq 'HASH' ) {
      foreach my $k ( sort {
           -1*($b eq '')    # sort '' to the end
          or  ($a eq '')    # sort '' to the end
          or  ($a <=> $b)   # sort numbers as numbers
          or  ($a cmp $b)   # sort alphabetics as alphabetics
        } keys %$tree )
      {
        $row_template{ $columns[$level] } = $k;
        &{ $descend }($tree->{$k}, $level + 1);
        if ( $level == 0 ) {
          # then insert the total row for the pkgclass
          $row_template{'total'} = 1; # flag it as a total
          &{ $descend }($self->{total}->{$k}, 1);
          $row_template{'total'} = 0;
        }
      }
    } elsif ( ref($tree) eq 'ARRAY' ) {
      # then we've reached the bottom; elements of this array are arrayrefs
      # of [ field, taxnums, amount ].
      # start with the inherited location-element fields
      my %this_row = %row_template;
      my %taxnums;
      foreach my $x (@$tree) {
        # accumulate taxnums
        foreach (split(',', $x->[1])) {
          $taxnums{$_} = 1;
        }
        # and money values
        $this_row{ $x->[0] } = $x->[2];
      }
      # store combined taxnums
      $this_row{taxnums} = join(',', sort { $a cmp $b } keys %taxnums);
      # and calculate row totals
      $this_row{sales} = sprintf('%.2f',
                          $this_row{taxable} +
                          $this_row{sales_credited} +
                          $this_row{exempt_cust} +
                          $this_row{exempt_pkg} + 
                          $this_row{exempt_monthly}
                        );
      $this_row{credits} = sprintf('%.2f',
                          $this_row{sales_credited} +
                          $this_row{exempt_credited} +
                          $this_row{tax_credited}
                        );
      # and give it a label
      if ( $this_row{total} ) {
        $this_row{label} = 'Total';
      } else {
        $this_row{label} = join(', ', grep $_,
                            $this_row{taxclass},
                            $this_row{state},
                            $this_row{county}, # already has ' County' suffix
                            $this_row{city},
                            $this_row{district}
                           );
      }
      # and indicate the tax rate, if any
      my $rate;
      foreach (keys %taxnums) {
        $rate ||= $self->{taxrates}->{$_};
        if ( $rate != $self->{taxrates}->{$_} ) {
          $rate = 'variable';
          last;
        }
      }
      if ( $rate eq 'variable' ) {
        $this_row{rate} = 'variable';
      } elsif ( $rate > 0 ) {
        $this_row{rate} = sprintf('%.2f', $rate);
      }
      push @rows, \%this_row;
    }
  };

  &{ $descend }($self->{data}, 0);

  warn "TABLE:\n".Dumper(\@rows) if $self->{opt}->{debug};
  return @rows;
}

sub taxrates {
  my $self = shift;
  $self->{taxrates}
}

sub title {
  my $self = shift;
  my $string = '';
  if ( $self->{opt}->{agentnum} ) {
    my $agent = qsearchs('agent', { agentnum => $self->{opt}->{agentnum} });
    $string .= $agent->agent . ' ';
  }
  $string .= 'Tax Report: '; # XXX localization
  if ( $self->{opt}->{beginning} ) {
    $string .= time2str('%h %o %Y ', $self->{opt}->{beginning});
  }
  $string .= 'through ';
  if ( $self->{opt}->{ending} and $self->{opt}->{ending} < 4294967295 ) {
    $string .= time2str('%h %o %Y', $self->{opt}->{ending});
  } else {
    $string .= 'now';
  }
  $string .= ' - ' . $self->{opt}->{taxname};
  return $string;
}

1;
