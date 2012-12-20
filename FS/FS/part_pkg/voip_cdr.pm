package FS::part_pkg::voip_cdr;
use base qw( FS::part_pkg::recur_Common );

use strict;
use vars qw( $DEBUG %info );
use List::Util qw(first min);
use Tie::IxHash;
use Date::Format;
use Text::CSV_XS;
use FS::Conf;
use FS::Record qw(qsearchs qsearch);
use FS::cdr;
use FS::rate;
use FS::rate_prefix;
use FS::rate_detail;

$DEBUG = 0;

tie my %cdr_svc_method, 'Tie::IxHash',
  'svc_phone.phonenum' => 'Phone numbers (svc_phone.phonenum)',
  'svc_pbx.title'      => 'PBX name (svc_pbx.title)',
  'svc_pbx.svcnum'     => 'Freeside service # (svc_pbx.svcnum)',
;

tie my %rating_method, 'Tie::IxHash',
  'prefix' => 'Rate calls by using destination prefix to look up a region and rate according to the internal prefix and rate tables',
#  'upstream' => 'Rate calls based on upstream data: If the call type is "1", map the upstream rate ID directly to an internal rate (rate_detail), otherwise, pass the upstream price through directly.',
  'upstream_simple' => 'Simply pass through and charge the "upstream_price" amount.',
  'single_price' => 'A single price per minute for all calls.',
;

#tie my %cdr_location, 'Tie::IxHash',
#  'internal' => 'Internal: CDR records imported into the internal CDR table',
#  'external' => 'External: CDR records queried directly from an external '.
#                'Asterisk (or other?) CDR table',
#;

tie my %temporalities, 'Tie::IxHash',
  'upcoming'  => "Upcoming (future)",
  'preceding' => "Preceding (past)",
;

tie my %granularity, 'Tie::IxHash', FS::rate_detail::granularities();

# previously "1" was "ignore"
tie my %unrateable_opts, 'Tie::IxHash',
  '' => 'Exit with a fatal error',
  1  => 'Ignore and continue',
  2  => 'Flag for later review',
;

%info = (
  'name' => 'VoIP rating by plan of CDR records in an internal (or external) SQL table',
  'shortname' => 'VoIP/telco CDR rating (standard)',
  'inherit_fields' => [ 'prorate_Mixin', 'global_Mixin' ],
  'fields' => {
    'suspend_bill' => { 'name' => 'Continue recurring billing while suspended',
                        'type' => 'checkbox',
                      },
    #false laziness w/flat.pm
    'recur_temporality' => { 'name' => 'Charge recurring fee for period',
                             'type' => 'select',
                             'select_options' => \%temporalities,
                           },

    'cutoff_day'    => { 'name' => 'Billing Day (1 - 28) for prorating or '.
                                   'subscription',
                         'default' => '1',
                       },
    'recur_method'  => { 'name' => 'Recurring fee method',
                         #'type' => 'radio',
                         #'options' => \%recur_method,
                         'type' => 'select',
                         'select_options' => \%FS::part_pkg::recur_Common::recur_method,
                       },

    'cdr_svc_method' => { 'name' => 'CDR service matching method',
                          'type' => 'radio',
                          'options' => \%cdr_svc_method,
                        },

    'rating_method' => { 'name' => 'Rating method',
                         'type' => 'radio',
                         'options' => \%rating_method,
                       },

    'ratenum'   => { 'name' => 'Rate plan',
                     'type' => 'select',
                     'select_table' => 'rate',
                     'select_key'   => 'ratenum',
                     'select_label' => 'ratename',
                   },
                   
    'intrastate_ratenum'   => { 'name' => 'Optional alternate intrastate rate plan',
                     'type' => 'select',
                     'select_table' => 'rate',
                     'select_key'   => 'ratenum',
                     'select_label' => 'ratename',
                     'disable_empty' => 0,
                     'empty_label'   => '',
                   },

    'min_included' => { 'name' => 'Minutes included when using the "single price per minute" rating method or when using the "prefix" rating method ("region group" billing)',
                    },

    'min_charge' => { 'name' => 'Charge per minute when using "single price per minute" rating method',
                    },

    'sec_granularity' => { 'name' => 'Granularity when using "single price per minute" rating method',
                           'type' => 'select',
                           'select_options' => \%granularity,
                         },

    'ignore_unrateable' => { 'name' => 'Handling of calls without a rate in the rate table',
                             'type' => 'select',
                             'select_options' => \%unrateable_opts,
                           },

    'default_prefix' => { 'name'    => 'Default prefix optionally prepended to customer DID numbers when searching for CDR records',
                          'default' => '+1',
                        },

    'disable_src' => { 'name' => 'Disable rating of CDR records based on the "src" field in addition to "charged_party"',
                       'type' => 'checkbox'
                     },

    'domestic_prefix' => { 'name'    => 'Destination prefix for domestic CDR records',
                           'default' => '1',
                         },

#    'domestic_prefix_required' => { 'name' => 'Require explicit destination prefix for domestic CDR records',
#                                    'type' => 'checkbox',
#                                  },

    'international_prefix' => { 'name'    => 'Destination prefix for international CDR records',
                                'default' => '011',
                              },

    'disable_tollfree' => { 'name' => 'Disable automatic toll-free processing',
                            'type' => 'checkbox',
                          },

    'use_amaflags' => { 'name' => 'Only charge for CDRs where the amaflags field is set to "2" ("BILL"/"BILLING").',
                        'type' => 'checkbox',
                      },

    'use_carrierid' => { 'name' => 'Only charge for CDRs where the Carrier ID is set to any of these (comma-separated) values: ',
                         },

    'use_cdrtypenum' => { 'name' => 'Only charge for CDRs where the CDR Type is set to: ',
                         },
    
    'ignore_cdrtypenum' => { 'name' => 'Do not charge for CDRs where the CDR Type is set to: ',
                         },
    
    'ignore_disposition' => { 'name' => 'Do not charge for CDRs where the Disposition is set to any of these (comma-separated) values: ',
                         },
    
    'disposition_in' => { 'name' => 'Only charge for CDRs where the Disposition is set to any of these (comma-separated) values: ',
                         },

    'skip_dst_prefix' => { 'name' => 'Do not charge for CDRs where the destination number starts with any of these values: ',
    },

    'skip_dcontext' => { 'name' => 'Do not charge for CDRs where the dcontext is set to any of these (comma-separated) values: ',
                       },

    'skip_dstchannel_prefix' => { 'name' => 'Do not charge for CDRs where the dstchannel starts with:',
                                },

    'skip_src_length_more' => { 'name' => 'Do not charge for CDRs where the source is more than this many digits:',
                              },

    'noskip_src_length_accountcode_tollfree' => { 'name' => 'Do charge for CDRs where source is equal or greater than the specified digits, when accountcode is toll free',
                                                  'type' => 'checkbox',
                                                },

    'accountcode_tollfree_ratenum' => {
      'name' => 'Optional alternate rate plan when accountcode is toll free: ',
      'type' => 'select',
      'select_table'  => 'rate',
      'select_key'    => 'ratenum',
      'select_label'  => 'ratename',
      'disable_empty' => 0,
      'empty_label'   => '',
    },

    'skip_dst_length_less' => { 'name' => 'Do not charge for CDRs where the destination is less than this many digits:',
                              },

    'noskip_dst_length_accountcode_tollfree' => { 'name' => 'Do charge for CDRs where dst is less than the specified digits, when accountcode is toll free',
                                                  'type' => 'checkbox',
                                                },

    'skip_lastapp' => { 'name' => 'Do not charge for CDRs where the lastapp matches this value: ',
                      },

    'skip_max_callers' => { 'name' => 'Do not charge for CDRs where max_callers is less than or equal to this value: ',
                          },

    'use_duration'   => { 'name' => 'Calculate usage based on the duration field instead of the billsec field',
                          'type' => 'checkbox',
                        },

    '411_rewrite' => { 'name' => 'Rewrite these (comma-separated) destination numbers to 411 for rating purposes (also ignore any carrierid check): ',
                      },

    #false laziness w/cdr_termination.pm
    'output_format' => { 'name' => 'CDR invoice display format',
                         'type' => 'select',
                         'select_options' => { FS::cdr::invoice_formats() },
                         'default'        => 'default', #XXX test
                       },

    'usage_section' => { 'name' => 'Section in which to place usage charges (whether separated or not): ',
                       },

    'summarize_usage' => { 'name' => 'Include usage summary with recurring charges when usage is in separate section',
                          'type' => 'checkbox',
                        },

    'usage_mandate' => { 'name' => 'Always put usage details in separate section',
                          'type' => 'checkbox',
                       },
    #eofalse

    'bill_every_call' => { 'name' => 'Generate an invoice immediately for every call (as well any setup fee, upon first payment).  Useful for prepaid.',
                           'type' => 'checkbox',
                         },

    'bill_inactive_svcs' => { 'name' => 'Bill for all phone numbers that were active during the billing period',
                              'type' => 'checkbox',
                            },

    'count_available_phones' => { 'name' => 'Consider for tax purposes the number of lines to be svc_phones that may be provisioned rather than those that actually are.',
                           'type' => 'checkbox',
                         },

    #XXX also have option for an external db
#    'cdr_location' => { 'name' => 'CDR database location'
#                        'type' => 'select',
#                        'select_options' => \%cdr_location,
#                        'select_callback' => {
#                          'external' => {
#                            'enable' => [ 'datasrc', 'username', 'password' ],
#                          },
#                          'internal' => {
#                            'disable' => [ 'datasrc', 'username', 'password' ],
#                          }
#                        },
#                      },
#    'datasrc' => { 'name' => 'DBI data source for external CDR table',
#                   'disabled' => 'Y',
#                 },
#    'username' => { 'name' => 'External database username',
#                    'disabled' => 'Y',
#                  },
#    'password' => { 'name' => 'External database password',
#                    'disabled' => 'Y',
#                  },

  },
  'fieldorder' => [qw(
                       recur_temporality
                       recur_method cutoff_day ),
                       FS::part_pkg::prorate_Mixin::fieldorder,
                    qw(
                       cdr_svc_method
                       rating_method ratenum intrastate_ratenum 
                       min_charge min_included sec_granularity
                       ignore_unrateable
                       default_prefix
                       disable_src
                       domestic_prefix international_prefix
                       disable_tollfree
                       use_amaflags
                       use_carrierid 
                       use_cdrtypenum ignore_cdrtypenum
                       ignore_disposition disposition_in
                       skip_dcontext skip_dst_prefix 
                       skip_dstchannel_prefix skip_src_length_more 
                       noskip_src_length_accountcode_tollfree
                       accountcode_tollfree_ratenum
                       skip_dst_length_less
                       noskip_dst_length_accountcode_tollfree
                       skip_lastapp
                       skip_max_callers
                       use_duration
                       411_rewrite
                       output_format usage_mandate summarize_usage usage_section
                       bill_every_call bill_inactive_svcs
                       count_available_phones suspend_bill 
                     )
                  ],
  'weight' => 40,
);

sub price_info {
    my $self = shift;
    my $str = $self->SUPER::price_info;
    $str .= " plus usage" if $str;
    $str;
}

sub calc_recur {
  my $self = shift;
  my($cust_pkg, $sdate, $details, $param ) = @_;

  my $charges = 0;

  $charges += $self->calc_usage(@_);
  $charges += $self->calc_recur_Common(@_);

  $charges;

}

sub calc_cancel {
  my $self = shift;
  my($cust_pkg, $sdate, $details, $param ) = @_;

  $self->calc_usage(@_);
}

#false laziness w/voip_sqlradacct calc_recur resolve it if that one ever gets used again

sub calc_usage {
  my $self = shift;
  my($cust_pkg, $sdate, $details, $param ) = @_;

  #my $last_bill = $cust_pkg->last_bill;
  my $last_bill = $cust_pkg->get('last_bill'); #->last_bill falls back to setup

  return 0
    if $self->recur_temporality eq 'preceding'
    && ( $last_bill eq '' || $last_bill == 0 );

  my $ratenum = $cust_pkg->part_pkg->option('ratenum');

  my $spool_cdr = $cust_pkg->cust_main->spool_cdr;

  my %included_min = (); #region groups w/prefix rating

  my $included_min = $self->option('min_included', 1) || 0; #single price rating

  my $charges = 0;

#  my $downstream_cdr = '';

  my $cdr_svc_method    = $self->option('cdr_svc_method',1)||'svc_phone.phonenum';
  my $rating_method     = $self->option('rating_method') || 'prefix';
  my $intl              = $self->option('international_prefix') || '011';
  my $domestic_prefix   = $self->option('domestic_prefix');
  my $disable_tollfree  = $self->option('disable_tollfree');
  my $ignore_unrateable = $self->option('ignore_unrateable', 'Hush!');
  my $use_duration      = $self->option('use_duration');
  my $region_group	= ($rating_method eq 'prefix' && ($self->option('min_included',1) || 0) > 0);
  my $region_group_included_min = $region_group ? $self->option('min_included') : 0;

  my $output_format     = $self->option('output_format', 'Hush!')
                          || ( $rating_method eq 'upstream_simple'
                                 ? 'simple'
                                 : 'default'
                             );

  my @dirass = ();
  if ( $self->option('411_rewrite') ) {
    my $dirass = $self->option('411_rewrite');
    $dirass =~ s/\s//g;
    @dirass = split(',', $dirass);
  }

  my %interval_cache = (); # for timed rates

  #for check_chargable, so we don't keep looking up options inside the loop
  my %opt_cache = ();

  my $csv = new Text::CSV_XS;

  my($svc_table, $svc_field) = split('\.', $cdr_svc_method);

  my @cust_svc;
  if( $self->option('bill_inactive_svcs',1) ) {
    #XXX in this mode do we need to restrict the set of CDRs by date also?
    @cust_svc = $cust_pkg->h_cust_svc($$sdate, $last_bill);
  }
  else {
    @cust_svc = $cust_pkg->cust_svc;
  }
  @cust_svc = grep { $_->part_svc->svcdb eq $svc_table } @cust_svc;

  foreach my $cust_svc (@cust_svc) {

    my $svc_x;
    if( $self->option('bill_inactive_svcs',1) ) {
      $svc_x = $cust_svc->h_svc_x($$sdate, $last_bill);
    }
    else {
      $svc_x = $cust_svc->svc_x;
    }
    my %options = (
        'disable_src'    => $self->option('disable_src'),
        'default_prefix' => $self->option('default_prefix'),
        'cdrtypenum'     => $self->option('use_cdrtypenum'),
        'status'         => '',
        'for_update'     => 1,
      );  # $last_bill, $$sdate )
    $options{'by_svcnum'} = 1 if $svc_field eq 'svcnum';

    my @invoice_details_sort;

    foreach my $cdr (
      $svc_x->get_cdrs( %options )
    ) {
      if ( $DEBUG > 1 ) {
        warn "rating CDR $cdr\n".
             join('', map { "  $_ => ". $cdr->{$_}. "\n" } keys %$cdr );
      }

      my $rate_detail;
      my( $rate_region, $regionnum );
      my $rate;
      my $pretty_destnum;
      my $charge = '';
      my $seconds = '';
      my $weektime = '';
      my $regionname = '';
      my $ratename = '';
      my $classnum = '';
      my $countrycode;
      my $number;

      my @call_details = ();
      if ( $rating_method eq 'prefix' ) {

        my $da_rewrote = 0;
        # this will result in those CDRs being marked as done... is that 
        # what we want?
        if ( length($cdr->dst) && grep { $cdr->dst eq $_ } @dirass ){
          $cdr->dst('411');
          $da_rewrote = 1;
        }

        my $reason = $self->check_chargable( $cdr,
                                             'da_rewrote'   => $da_rewrote,
                                             'option_cache' => \%opt_cache,
                                           );

        if ( $reason ) {

          warn "not charging for CDR ($reason)\n" if $DEBUG;
          $charge = 0;
          # this will result in those CDRs being marked as done... is that 
          # what we want?

        } else {
          
          ###
          # look up rate details based on called station id
          # (or calling station id for toll free calls)
          ###

          my( $to_or_from );
          if ( $cdr->is_tollfree && ! $disable_tollfree )
          { #tollfree call
            $to_or_from = 'from';
            $number = $cdr->src;
          } else { #regular call
            $to_or_from = 'to';
            $number = $cdr->dst;
          }

          warn "parsing call $to_or_from $number\n" if $DEBUG;

          #remove non-phone# stuff and whitespace
          $number =~ s/\s//g;
#          my $proto = '';
#          $dest =~ s/^(\w+):// and $proto = $1; #sip:
#          my $siphost = '';
#          $dest =~ s/\@(.*)$// and $siphost = $1; # @10.54.32.1, @sip.example.com

          #determine the country code
          $countrycode = '';
          if (    $number =~ /^$intl(((\d)(\d))(\d))(\d+)$/
               || $number =~ /^\+(((\d)(\d))(\d))(\d+)$/
             )
          {

            my( $three, $two, $one, $u1, $u2, $rest ) = ( $1,$2,$3,$4,$5,$6 );
            #first look for 1 digit country code
            if ( qsearch('rate_prefix', { 'countrycode' => $one } ) ) {
              $countrycode = $one;
              $number = $u1.$u2.$rest;
            } elsif ( qsearch('rate_prefix', { 'countrycode' => $two } ) ) { #or 2
              $countrycode = $two;
              $number = $u2.$rest;
            } else { #3 digit country code
              $countrycode = $three;
              $number = $rest;
            }

          } else {
            $countrycode = length($domestic_prefix) ? $domestic_prefix : '1';
            $number =~ s/^$countrycode//;# if length($number) > 10;
          }

          warn "rating call $to_or_from +$countrycode $number\n" if $DEBUG;
          $pretty_destnum = "+$countrycode $number";
          #asterisks here causes inserting the detail to barf, so:
          $pretty_destnum =~ s/\*//g;

          my $eff_ratenum = $cdr->is_tollfree('accountcode')
            ? $cust_pkg->part_pkg->option('accountcode_tollfree_ratenum')
            : '';

          my $intrastate_ratenum = $cust_pkg->part_pkg->option('intrastate_ratenum');
          if ( $intrastate_ratenum && !$cdr->is_tollfree ) {
            $ratename = 'Interstate'; #until proven otherwise
            # this is relatively easy only because:
            # -assume all numbers are valid NANP numbers NOT in a fully-qualified format
            # -disregard toll-free
            # -disregard private or unknown numbers
            # -there is exactly one record in rate_prefix for a given NPANXX
            # -default to interstate if we can't find one or both of the prefixes
            my $dstprefix = $cdr->dst;
            $dstprefix =~ /^(\d{6})/;
            $dstprefix = qsearchs('rate_prefix', {   'countrycode' => '1', 
                                                        'npa' => $1, 
                                                 }) || '';
            my $srcprefix = $cdr->src;
            $srcprefix =~ /^(\d{6})/;
            $srcprefix = qsearchs('rate_prefix', {   'countrycode' => '1',
                                                     'npa' => $1, 
                                                 }) || '';
            if ($srcprefix && $dstprefix
                && $srcprefix->state && $dstprefix->state
                && $srcprefix->state eq $dstprefix->state) {
              $eff_ratenum = $intrastate_ratenum;
              $ratename = 'Intrastate'; # XXX possibly just use the ratename?
            }
          }

          $eff_ratenum ||= $ratenum;
          $rate = qsearchs('rate', { 'ratenum' => $eff_ratenum })
            or die "ratenum $eff_ratenum not found!";

          my @ltime = localtime($cdr->startdate);
          $weektime = $ltime[0] + 
                      $ltime[1]*60 +   #minutes
                      $ltime[2]*3600 + #hours
                      $ltime[6]*86400; #days since sunday
          # if there's no timed rate_detail for this time/region combination,
          # dest_detail returns the default.  There may still be a timed rate 
          # that applies after the starttime of the call, so be careful...
          $rate_detail = $rate->dest_detail({ 'countrycode' => $countrycode,
                                              'phonenum'    => $number,
                                              'weektime'    => $weektime,
                                              'cdrtypenum'  => $cdr->cdrtypenum,
                                            });

          if ( $rate_detail ) {

            $rate_region = $rate_detail->dest_region;
            $regionnum = $rate_region->regionnum;
            $regionname = $rate_region->regionname;
            warn "  found rate for regionnum $regionnum ".
                 "and rate detail $rate_detail\n"
              if $DEBUG;

            if ( !exists($interval_cache{$regionnum}) ) {
              my @intervals = (
                sort { $a->stime <=> $b->stime }
                  map { $_->rate_time->intervals }
                    qsearch({ 'table'     => 'rate_detail',
                              'hashref'   => { 'ratenum' => $rate->ratenum },
                              'extra_sql' => 'AND ratetimenum IS NOT NULL',
                           })
              );
              $interval_cache{$regionnum} = \@intervals;
              warn "  cached ".scalar(@intervals)." interval(s)\n"
                if $DEBUG;
            }

          } elsif ( $ignore_unrateable ) {

            $rate_region = '';
            $regionnum = '';
            #code below will throw a warning & skip

          } else {

            die "FATAL: no rate_detail found in ".
                $rate->ratenum. ":". $rate->ratename. " rate plan ".
                "for +$countrycode $number (CDR acctid ". $cdr->acctid. "); ".
                "add a rate or set ignore_unrateable flag on the package def\n";
          }

        }

      } elsif ( $rating_method eq 'upstream_simple' ) {

        #XXX $charge = sprintf('%.2f', $cdr->upstream_price);
        $charge = sprintf('%.3f', $cdr->upstream_price);
        $charges += $charge;
        warn "Incrementing \$charges by $charge.  Now $charges\n" if $DEBUG;

        @call_details = ($cdr->downstream_csv( 'format' => $output_format,
                                               'charge' => $charge,
                                             )
                        );
        $classnum = $cdr->calltypenum;

      } elsif ( $rating_method eq 'single_price' ) {

        # a little false laziness w/below
        # $rate_detail = new FS::rate_detail({sec_granularity => ... }) ?

        my $granularity = length($self->option('sec_granularity'))
                            ? $self->option('sec_granularity')
                            : 60;

        $seconds = $use_duration ? $cdr->duration : $cdr->billsec;

        $seconds += $granularity - ( $seconds % $granularity )
          if $seconds      # don't granular-ize 0 billsec calls (bills them)
          && $granularity  # 0 is per call
          && $seconds % $granularity;
        my $minutes = $granularity ? ($seconds / 60) : 1;

        my $charge_min = $minutes;

        $included_min -= $minutes;
        if ( $included_min > 0 ) {
          $charge_min = 0;
        } else {
           $charge_min = 0 - $included_min;
           $included_min = 0;
        }

        $charge = sprintf('%.4f', ( $self->option('min_charge') * $charge_min )
                                  + 0.0000000001 ); #so 1.00005 rounds to 1.0001

        warn "Incrementing \$charges by $charge.  Now $charges\n" if $DEBUG;
        $charges += $charge;

        @call_details = ($cdr->downstream_csv( 'format'  => $output_format,
                                               'charge'  => $charge,
                                               'seconds' => ($use_duration ? 
                                                             $cdr->duration : 
                                                             $cdr->billsec),
                                               'granularity' => $granularity,
                                             )
                        );

      } else {
        die "don't know how to rate CDRs using method: $rating_method\n";
      }

      ###
      # find the price and add detail to the invoice
      ###

      # if $rate_detail is not found, skip this CDR... i.e. 
      # don't add it to invoice, don't set its status to done,
      # don't call downstream_csv or something on it...
      # but DO emit a warning...
      #if ( ! $rate_detail && ! scalar(@call_details) ) {}
      if ( ! $rate_detail && $charge eq '' ) {

        if ( $ignore_unrateable == 2 ) {
          # mark the CDR as unrateable
          my $error = $cdr->set_status_and_rated_price(
            'failed',
            '',
            $cust_svc->svcnum
          );
          die $error if $error;
        }
        elsif ( $ignore_unrateable == 1 ) {
          # warn and continue
          warn "no rate_detail found for CDR.acctid: ". $cdr->acctid.
               "; skipping\n"
        } #if $ignore_unrateable

      } else { # there *is* a rate_detail (or call_details), proceed...
        # About this section:
        # We don't round _anything_ (except granularizing) 
        # until the final $charge = sprintf("%.2f"...).

        unless ( @call_details || ( $charge ne '' && $charge == 0 ) ) {

          my $seconds_left = $use_duration ? $cdr->duration : $cdr->billsec;
          # charge for the first (conn_sec) seconds
          $seconds = min($seconds_left, $rate_detail->conn_sec);
          $seconds_left -= $seconds; 
          $weektime     += $seconds;
          $charge = $rate_detail->conn_charge; 

          my $etime;
          while($seconds_left) {
            my $ratetimenum = $rate_detail->ratetimenum; # may be empty

            # find the end of the current rate interval
            if(@{ $interval_cache{$regionnum} } == 0) {
              # There are no timed rates in this group, so just stay 
              # in the default rate_detail for the entire duration.
              # Set an "end" of 1 past the end of the current call.
              $etime = $weektime + $seconds_left + 1;
            } 
            elsif($ratetimenum) {
              # This is a timed rate, so go to the etime of this interval.
              # If it's followed by another timed rate, the stime of that 
              # interval should match the etime of this one.
              my $interval = $rate_detail->rate_time->contains($weektime);
              $etime = $interval->etime;
            }
            else {
              # This is a default rate, so use the stime of the next 
              # interval in the sequence.
              my $next_int = first { $_->stime > $weektime } 
                              @{ $interval_cache{$regionnum} };
              if ($next_int) {
                $etime = $next_int->stime;
              }
              else {
                # weektime is near the end of the week, so decrement 
                # it by a full week and use the stime of the first 
                # interval.
                $weektime -= (3600*24*7);
                $etime = $interval_cache{$regionnum}->[0]->stime;
              }
            }

            my $charge_sec = min($seconds_left, $etime - $weektime);

            $seconds_left -= $charge_sec;

            $included_min{$regionnum}{$ratetimenum} = $rate_detail->min_included
              unless exists $included_min{$regionnum}{$ratetimenum};

            my $granularity = $rate_detail->sec_granularity;

            my $minutes;
            if ( $granularity ) { # charge per minute
              # Round up to the nearest $granularity
              if ( $charge_sec and $charge_sec % $granularity ) {
                $charge_sec += $granularity - ($charge_sec % $granularity);
              }
              $minutes = $charge_sec / 60; #don't round this
            }
            else { # per call
              $minutes = 1;
              $seconds_left = 0;
            }

            $seconds += $charge_sec;

            $region_group_included_min -= $minutes 
                if $region_group && $rate_detail->region_group;

            $included_min{$regionnum}{$ratetimenum} -= $minutes;
            if ( ($region_group_included_min <= 0 || !$rate_detail->region_group)
			  && $included_min{$regionnum}{$ratetimenum} <= 0 ) {
              my $charge_min = 0 - $included_min{$regionnum}{$ratetimenum}; #XXX should preserve
                                                              #(display?) this
              $included_min{$regionnum}{$ratetimenum} = 0;
              $charge += ($rate_detail->min_charge * $charge_min); #still not rounded
            }
            elsif( $region_group_included_min > 0 && $region_group
                && $rate_detail->region_group ) {
                $included_min{$regionnum}{$ratetimenum} = 0 
            }

            # choose next rate_detail
            $rate_detail = $rate->dest_detail({ 'countrycode' => $countrycode,
                                                'phonenum'    => $number,
                                                'weektime'    => $etime,
                                                'cdrtypenum'  => $cdr->cdrtypenum })
                    if($seconds_left);
            # we have now moved forward to $etime
            $weektime = $etime;

          } #while $seconds_left
          # this is why we need regionnum/rate_region....
          warn "  (rate region $rate_region)\n" if $DEBUG;

          $classnum = $rate_detail->classnum;
          $charge = sprintf('%.2f', $charge + 0.000001); # NOW round it.
          warn "Incrementing \$charges by $charge.  Now $charges\n" if $DEBUG;
          $charges += $charge;

          if ( !$self->sum_usage ) {
            @call_details = (
              $cdr->downstream_csv( 'format'         => $output_format,
                                    'granularity'    => $rate_detail->sec_granularity, 
                                    'seconds'        => ($use_duration ?
                                                         $cdr->duration :
                                                         $cdr->billsec),
                                    'charge'         => $charge,
                                    'pretty_dst'     => $pretty_destnum,
                                    'dst_regionname' => $regionname,
                                  )
            );
          }
        } #if(there is a rate_detail)

        #if ( $charge > 0 ) {
        # generate a detail record for every call; filter out $charge = 0 
        # later.
        my $call_details;
        my $phonenum = $svc_x->phonenum;

        if ( scalar(@call_details) == 1 ) {
          $call_details =
          { format      => 'C',
            detail      => $call_details[0],
            amount      => $charge,
            classnum    => $classnum,
            phonenum    => $phonenum,
            accountcode => $cdr->accountcode,
            startdate   => $cdr->startdate,
            duration    => $seconds,
            regionname  => $regionname,
          };
        } else { #only used for $rating_method eq 'upstream' now
          # and for sum_ formats
          $csv->combine(@call_details);
          $call_details =
          { format      => 'C',
            detail      => $csv->string,
            amount      => $charge,
            classnum    => $classnum,
            phonenum    => $phonenum,
            accountcode => $cdr->accountcode,
            startdate   => $cdr->startdate,
            duration    => $seconds,
            regionname  => $regionname,
          };
        }
        $call_details->{'ratename'} = $ratename;

        push @invoice_details_sort, [ $call_details, $cdr->calldate_unix ];
        #} $charge > 0

        # if the customer flag is on, call "downstream_csv" or something
        # like it to export the call downstream!
        # XXX price plan option to pick format, or something...
        #$downstream_cdr .= $cdr->downstream_csv( 'format' => 'XXX format' )
        #  if $spool_cdr;

        my $error = $cdr->set_status_and_rated_price( 'done',
                                                      $charge,
                                                      $cust_svc->svcnum,
                                                    );
        die $error if $error;

      }

    } # $cdr

    if ( !$self->sum_usage ) {
      #sort them
      my @sorted_invoice_details = 
        sort { @{$a}[1] <=> @{$b}[1] } @invoice_details_sort;
      foreach my $sorted_call_detail ( @sorted_invoice_details ) {
        my $d = $sorted_call_detail->[0];
        push @$details, $d if $d->{amount} > 0;
      }
    }
    else { #$self->sum_usage
        push @$details, $self->sum_detail($svc_x, \@invoice_details_sort);
    }
  } # $cust_svc

  unshift @$details, { format => 'C',
                       detail => FS::cdr::invoice_header($output_format),
                     }
    if @$details && $rating_method ne 'upstream';

  $charges;
}

#returns a reason why not to rate this CDR, or false if the CDR is chargeable
sub check_chargable {
  my( $self, $cdr, %flags ) = @_;

  #should have some better way of checking these options from a hash
  #or something

  my @opt = qw(
    use_amaflags
    use_carrierid
    use_cdrtypenum
    ignore_cdrtypenum
    disposition_in
    ignore_disposition
    skip_dst_prefix
    skip_dcontext
    skip_dstchannel_prefix
    skip_src_length_more noskip_src_length_accountcode_tollfree
    skip_dst_length_less noskip_dst_length_accountcode_tollfree
    skip_lastapp
    skip_max_callers
  );
  foreach my $opt (grep !exists($flags{option_cache}->{$_}), @opt ) {
    $flags{option_cache}->{$opt} = $self->option($opt, 1);
  }
  my %opt = %{ $flags{option_cache} };

  return 'amaflags != 2'
    if $opt{'use_amaflags'} && $cdr->amaflags != 2;

  return "disposition NOT IN ( $opt{'disposition_in'} )"
    if $opt{'disposition_in'} =~ /\S/
    && !grep { $cdr->disposition eq $_ } split(/\s*,\s*/, $opt{'disposition_in'});
  
  return "disposition IN ( $opt{'ignore_disposition'} )"
    if $opt{'ignore_disposition'} =~ /\S/
    && grep { $cdr->disposition eq $_ } split(/\s*,\s*/, $opt{'ignore_disposition'});

  foreach(split(/\s*,\s*/, $opt{'skip_dst_prefix'})) {
    return "dst starts with '$_'"
    if length($_) && substr($cdr->dst,0,length($_)) eq $_;
  }

  return "carrierid NOT IN ( $opt{'use_carrierid'} )"
    if $opt{'use_carrierid'} =~ /\S/
    && ! $flags{'da_rewrote'} #why?
    && !grep { $cdr->carrierid eq $_ } split(/\s*,\s*/, $opt{'use_carrierid'}); #eq otherwise 0 matches ''

  # unlike everything else, use_cdrtypenum is applied in FS::svc_x::get_cdrs.
  return "cdrtypenum != $opt{'use_cdrtypenum'}"
    if length($opt{'use_cdrtypenum'})
    && $cdr->cdrtypenum ne $opt{'use_cdrtypenum'}; #ne otherwise 0 matches ''
  
  return "cdrtypenum == $opt{'ignore_cdrtypenum'}"
    if length($opt{'ignore_cdrtypenum'})
    && $cdr->cdrtypenum eq $opt{'ignore_cdrtypenum'}; #eq otherwise 0 matches ''

  return "dcontext IN ( $opt{'skip_dcontext'} )"
    if $opt{'skip_dcontext'} =~ /\S/
    && grep { $cdr->dcontext eq $_ } split(/\s*,\s*/, $opt{'skip_dcontext'});

  my $len_prefix = length($opt{'skip_dstchannel_prefix'});
  return "dstchannel starts with $opt{'skip_dstchannel_prefix'}"
    if $len_prefix
    && substr($cdr->dstchannel,0,$len_prefix) eq $opt{'skip_dstchannel_prefix'};

  my $dst_length = $opt{'skip_dst_length_less'};
  return "destination less than $dst_length digits"
    if $dst_length && length($cdr->dst) < $dst_length
    && ! ( $opt{'noskip_dst_length_accountcode_tollfree'}
            && $cdr->is_tollfree('accountcode')
         );

  return "lastapp is $opt{'skip_lastapp'}"
    if length($opt{'skip_lastapp'}) && $cdr->lastapp eq $opt{'skip_lastapp'};

  my $src_length = $opt{'skip_src_length_more'};
  if ( $src_length ) {

    if ( $opt{'noskip_src_length_accountcode_tollfree'} ) {

      if ( $cdr->is_tollfree('accountcode') ) {
        return "source less than or equal to $src_length digits"
          if length($cdr->src) <= $src_length;
      } else {
        return "source more than $src_length digits"
          if length($cdr->src) > $src_length;
      }

    } else {
      return "source more than $src_length digits"
        if length($cdr->src) > $src_length;
    }

  }

  return "max_callers <= $opt{skip_max_callers}"
    if length($opt{'skip_max_callers'})
      and length($cdr->max_callers)
      and $cdr->max_callers <= $opt{'skip_max_callers'};

  #all right then, rate it
  '';
}

sub is_free {
  0;
}

#  This equates svc_phone records; perhaps svc_phone should have a field
#  to indicate it represents a line
sub calc_units {    
  my($self, $cust_pkg ) = @_;
  my $count = 0;
  if ( $self->option('count_available_phones', 1)) {
    map { $count += ( $_->quantity || 0 ) }
      grep { $_->part_svc->svcdb eq 'svc_phone' }
      $cust_pkg->part_pkg->pkg_svc;
  } else {
    $count = 
      scalar(grep { $_->part_svc->svcdb eq 'svc_phone' } $cust_pkg->cust_svc);
  }
  $count;
}

# tells whether cust_bill_pkg_detail should return a single line for 
# each phonenum
sub sum_usage {
  my $self = shift;
  $self->option('output_format') =~ /^sum_/;
}

sub sum_detail {
  my $self = shift;
  my $svc_x = shift;
  my $invoice_details = shift || [];
  return () if !@$invoice_details;
  my $details_by_rate = {};
  # combine the entire set of CDRs
  foreach ( @$invoice_details ) {
    my $d = $_->[0];
    my $sum = $details_by_rate->{ $d->{ratename} } ||= {
      amount      => 0,
      format      => 'C',
      classnum    => '', #XXX
      duration    => 0,
      phonenum    => $svc_x->phonenum,
      accountcode => '', #XXX
      startdate   => '', #XXX
      regionname  => '',
      count       => 0,
    };
    $sum->{amount} += $d->{amount};
    $sum->{duration} += $d->{duration};
    $sum->{count}++;
  }
  my @details;
  foreach my $ratename ( sort keys(%$details_by_rate) ) {
    my $sum = $details_by_rate->{$ratename};
    next if $sum->{count} == 0;
    my $total_cdr = FS::cdr->new({
        'billsec' => $sum->{duration},
        'src'     => $sum->{phonenum},
      });
    $sum->{detail} = $total_cdr->downstream_csv(
      format    => $self->option('output_format'),
      seconds   => $sum->{duration},
      charge    => sprintf('%.2f',$sum->{amount}),
      ratename  => $ratename,
      phonenum  => $sum->{phonenum},
      count     => $sum->{count},
    );
    push @details, $sum;
  }
  @details;
}

# and whether cust_bill should show a detail line for the service label 
# (separate from usage details)
sub hide_svc_detail {
  my $self = shift;
  $self->option('output_format') =~ /^sum_/;
}


1;

