package FS::part_event::Condition::pkg_dundate;
use base qw( FS::part_event::Condition );

use strict;

sub description {
  "Skip until package suspension delay date";
}

sub eventtable_hashref {
  { 'cust_main' => 0,
    'cust_bill' => 0,
    'cust_pkg'  => 1,
  };
}

sub condition {
  my($self, $cust_pkg, %opt) = @_;

  #my $cust_main = $self->cust_main($cust_pkg);

  ( $cust_pkg->dundate || 0 ) <= $opt{time};

}

sub condition_sql {
  my( $class, $table, %opt ) = @_;
  return 'true' unless $table eq 'cust_pkg';
  "COALESCE($table.dundate,0) <= ". $opt{'time'};
}

1;
