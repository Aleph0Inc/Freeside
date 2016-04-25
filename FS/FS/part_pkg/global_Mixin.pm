package FS::part_pkg::global_Mixin;

use strict;
use vars qw(%info);

use Tie::IxHash;
tie my %a2billing_types, 'Tie::IxHash', (
  0 => 'Prepaid',
  1 => 'Postpaid',
);

tie my %a2billing_simultaccess, 'Tie::IxHash', (
  0 => 'Disabled',
  1 => 'Enabled',
);

# much false laziness with FS::Record::ut_money
sub validate_moneyn {
  my ($option, $valref) = @_;
  if ( $$valref eq '' ) {
    return '';
  } elsif ( $$valref =~ /^\s*(\d*)(\.\d{1})\s*$/ ) {
    #handle one decimal place without barfing out
    $$valref = ( ($1||''). ($2||''). ($3.'0') ) || 0;
  } elsif ( $$valref =~ /^\s*(\d*)(\.\d{2})?\s*$/ ) {
    $$valref = ( ($1||''). ($2||''). ($3||'') ) || 0;
  } else {
    return "Illegal (money) $option: ". $$valref;
  }
  return '';
}


%info = (
  'disabled' => 1,
  'fields' => {
    'setup_fee' => { 
      'name' => 'Setup fee for this package',
      'default' => 0,
      'validate' => \&validate_moneyn,
    },
    'recur_fee' => { 
      'name' => 'Recurring fee for this package',
      'default' => 0,
      'validate' => \&validate_moneyn,
    },
    'unused_credit_cancel' => {
      'name' => 'Credit the customer for the unused portion of service at '.
                 'cancellation',
      'type' => 'checkbox',
    },
    'unused_credit_suspend' => {
      'name' => 'Credit the customer for the unused portion of service when '.
                'suspending',
      'type' => 'checkbox',
    },
    'unused_credit_change' => {
      'name' => 'Credit the customer for the unused portion of service when '.
                'changing packages',
      'type' => 'checkbox',
    },
    'delay_cancel' => {
      'name' => 'Automatic suspension period before cancelling (configuration setting part_pkg-delay_cancel-days)',
      'type' => 'checkbox',
    },

    # miscellany--maybe put this in a separate module?

    'a2billing_tariff' => {
      'name'        => 'A2Billing tariff group ID',
      'display_if'  => sub {
        FS::part_export->count("exporttype = 'a2billing'") > 0;
      }
    },
    'a2billing_type' => {
      'name'        => 'A2Billing card type',
      'display_if'  => sub {
        FS::part_export->count("exporttype = 'a2billing'") > 0;
      },
      'type'        => 'select',
      'select_options' => \%a2billing_types,
    },
    'a2billing_simultaccess' => {
      'name'        => 'A2Billing Simultaneous Access',
      'display_if'  => sub {
        FS::part_export->count("exporttype = 'a2billing'") > 0;
      },
      'type'        => 'select',
      'select_options' => \%a2billing_simultaccess,
    },  
    'a2billing_carrier_cost_min' => {
      'name'        => 'A2Billing inbound carrier cost',
      'display_if'  => sub {
        FS::part_export->count("exporttype = 'a2billing'") > 0;
      },
    },
   'a2billing_carrer_initblock_offp' => {
      'name'        => 'A2Billing inbound carrier min duration',
      'display_if'  => sub {
        FS::part_export->count("exporttype = 'a2billing'") > 0;
      },
    },
    'a2billing_carrier_increment_offp' => {
      'name'        => 'A2Billing inbound carrier billing block',
      'display_if'  => sub {
        FS::part_export->count("exporttype = 'a2billing'") > 0;
      },
    },
    'a2billing_retail_cost_min_offp' => {
      'name'        => 'A2Billing inbound retail cost',
      'display_if'  => sub {
        FS::part_export->count("exporttype = 'a2billing'") > 0;
      },
    },
    'a2billing_retail_initblock_offp' => {
      'name'        => 'A2Billing inbound retail min duration',
      'display_if'  => sub {
        FS::part_export->count("exporttype = 'a2billing'") > 0;
      },
    },
    'a2billing_retail_increment_offp' => {
      'name'        => 'A2Billing inbound retail billing block',
      'display_if'  => sub {
        FS::part_export->count("exporttype = 'a2billing'") > 0;
     },
   },

 },
  'fieldorder' => [ qw(
    setup_fee
    recur_fee
    unused_credit_cancel
    unused_credit_suspend
    unused_credit_change
    delay_cancel

    a2billing_tariff
    a2billing_type
    a2billing_simultaccess
    a2billing_carrier_cost_min
    a2billing_carrer_initblock_offp
    a2billing_carrier_increment_offp
    a2billing_retail_cost_min_offp
    a2billing_retail_initblock_offp
    a2billing_retail_increment_offp
  )],
);

1;
