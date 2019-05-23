package FS::cdr::telapi_voip;
use base qw( FS::cdr );

use strict;
use vars qw( @ISA %info $CDR_TYPES );
use FS::Record qw( qsearch );
use FS::cdr qw( _cdr_date_parser_maker _cdr_min_parser_maker );

%info = (
  'name'          => 'telapi_voip',
  'weight'        => 601,
  'header'        => 1,
  'type'          => 'csv',
  'import_fields' => [
    _cdr_date_parser_maker('startdate'),  #'date gmt'
    'src',                                # source
    'dst',                                # destination
    'clid',                               # callerid
    skip(1),                              # hangup code
    skip(1),                              # sip account
    'src_ip_addr',                        # orig ip
    'duration',                           # duration
    skip(1),                              # per minute
    'upstream_price',                     # callcost
    sub {
      my($cdr, $cdrtypename, $conf, $param) = @_;
      return unless length($cdrtypename);
      _init_cdr_types();
      unless (defined $CDR_TYPES->{$cdrtypename}) {
        warn "Skipping Record: CDR type name $cdrtypename does not exist!";
        $param->{skiprow} = 1;
      }
      $cdr->cdrtypenum($CDR_TYPES->{$cdrtypename});
    },                                   # type 
    _cdr_min_parser_maker('billsec'),     #PriceDurationMins
  ],
);

sub skip { map {''} (1..$_[0]) }

sub _init_cdr_types {
  unless ($CDR_TYPES) {
    $CDR_TYPES = {};
    foreach my $cdr_type ( qsearch('cdr_type') ) {
      die "multiple cdr_types with same cdrtypename".$cdr_type->cdrtypename
        if defined $CDR_TYPES->{$cdr_type->cdrtypename};
      $CDR_TYPES->{$cdr_type->cdrtypename} = $cdr_type->cdrtypenum;
    }
  }
}

1;