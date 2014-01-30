package FS::detail_format::default;

use strict;
use base qw(FS::detail_format);

sub name { 'Default' }

sub header_detail { 'Date,Time,Number,Destination,Duration,Price' }

sub columns {
  my $self = shift;
  my $cdr = shift;
  (
    $self->time2str_local($self->date_format, $cdr->startdate),
    $self->time2str_local('%r', $cdr->startdate),
    ($cdr->rated_pretty_dst || $cdr->dst),
    $cdr->rated_regionname,
    $self->duration($cdr),
    $self->price($cdr),
  )
}

1;
