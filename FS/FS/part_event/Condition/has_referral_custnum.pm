package FS::part_event::Condition::has_referral_custnum;

use strict;
use FS::cust_main;

use base qw( FS::part_event::Condition );

sub description { 'Customer has a referring customer'; }

sub option_fields {
  (
    'active' => { 'label' => 'Referring customer is active',
                  'type'  => 'checkbox',
                  'value' => 'Y',
                },
    'check_bal' => { 'label' => 'Check referring customer balance',
                     'type'  => 'checkbox',
                     'value' => 'Y',
                   },
    'balance' => { 'label'      => 'Referring customer balance under (or equal to)',
                   'type'       => 'money',
                   'value'      => '0.00', #default
                 },
    'age'     => { 'label'      => 'Referring customer balance age',
                   'type'       => 'freq',
                 },
  );
}

sub condition {
  my($self, $object, %opt) = @_;

  my $cust_main = $self->cust_main($object);
  return 0 unless $cust_main; #sanity check
  return 0 unless $cust_main->referral_custnum;

  my $referring_cust_main = $cust_main->referral_custnum_cust_main;
  return 0 unless $referring_cust_main; #sanity check;

  #referring customer must sign up before referred customer
  return 0 unless $cust_main->signupdate > $referring_cust_main->signupdate;

  if ( $self->option('active') ) {
    #check for no cust_main for referral_custnum? (deleted?)
    return 0 unless $referring_cust_main->status eq 'active';
  }

  return 1 unless $self->option('check_bal');

  #false laziness w/ balance_age_under
  my $under = $self->option('balance');
  $under = 0 unless length($under);

  my $age = $self->option_age_from('age', $opt{'time'} );

  $referring_cust_main->balance_date($age) <= $under;

}

sub condition_sql {
  my( $class, $table, %opt ) = @_;

  my $active_sql = FS::cust_main->active_sql;
  $active_sql =~ s/cust_main.custnum/cust_main.referral_custnum/;

  my $under = $class->condition_sql_option_money('balance');

  my $age = $class->condition_sql_option_age_from('age', $opt{'time'});
  my $balance_date_sql = FS::cust_main->balance_date_sql($age);
  $balance_date_sql =~ s/cust_main.custnum/cust_main.referral_custnum/;
  my $bal_sql = "$balance_date_sql <= $under";

  "cust_main.referral_custnum IS NOT NULL
    AND (". $class->condition_sql_option('active').    " IS NULL OR $active_sql)
    AND (". $class->condition_sql_option('check_bal'). " IS NULL OR $bal_sql   )
  ";
}

1;
