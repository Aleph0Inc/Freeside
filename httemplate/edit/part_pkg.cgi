<% include( 'elements/edit.html',
              'post_url'    => popurl(1).'process/part_pkg.cgi',
              'name'        => "Package definition",
              'table'       => 'part_pkg',
              #'viewall_dir' => 'browse',
              'viewall_url' => $p.'browse/part_pkg.cgi',
              'html_init'   => include('/elements/init_overlib.html').
                               $freq_changed,
              'html_bottom' => $html_bottom,
              'new_hashref_callback' => $new_hashref_callback,
              'new_object_callback'  => $new_object_callback,
              'new_callback'         => $new_callback,
              'edit_callback'        => $edit_callback,
              'error_callback'       => $error_callback,

              'labels' => { 
                            'pkgpart'          => 'Package Definition',
                            'pkg'              => 'Package (customer-visible)',
                            'comment'          => 'Comment (customer-hidden)',
                            'classnum'         => 'Package class',
                            'promo_code'       => 'Promotional code',
                            'freq'             => 'Recurring fee frequency',
                            'setuptax'         => 'Setup fee tax exempt',
                            'recurtax'         => 'Recurring fee tax exempt',
                            'taxclass'         => 'Tax class',
                            'plan'             => 'Price plan',
                            'disabled'         => 'Disable new orders',
                            'pay_weight'       => 'Payment weight',
                            'credit_weight'    => 'Credit weight',
                            'agentnum'         => '',
                            'setup_fee'        => 'Setup fee',
                            'recur_fee'        => 'Recurring fee',
                            'bill_dst_pkgpart' => 'Include line item(s) from package',
                            'svc_dst_pkgpart'  => 'Include services of package',
                          },

              'fields' => [
                            { field=>'clone',  type=>'hidden' },
                            { field=>'pkgnum', type=>'hidden' },

                            { type => 'columnstart' },
                            
                              {field=>'pkg',      type=>'text', size=>40 }, #32
                              {field=>'comment',  type=>'text', size=>40 }, #32
                              {field=>'classnum', type=>'select-pkg_class' },
                              {field=>'disabled', type=>'checkbox', value=>'Y'},

                              { type  => 'tablebreak-tr-title',
                                value => 'Pricing', #better name?
                              },
                              { field => 'plan',
                                type  => 'selectlayers-select',
                                options => [ keys %plan_labels ],
                                labels  => \%plan_labels,
                              },
                              { field => 'setup_fee',
                                type  => 'money',
                              },
                              { field    => 'freq',
                                type     => 'part_pkg_freq',
                                onchange => 'freq_changed',
                              },
                              { field    => 'recur_fee',
                                type     => 'money',
                                disabled => sub { $recur_disabled },
                              },
                                
                              #price plan
                              #setup fee
                              #recurring frequency
                              #recurring fee (auto-disable)

                            { type => 'columnnext' },

                              {type=>'justtitle', value=>'Taxation' },
                              {field=>'setuptax', type=>'checkbox', value=>'Y'},
                              {field=>'recurtax', type=>'checkbox', value=>'Y'},
                              {field=>'classnum', type=>'select-taxclass' },
                              {field=>'taxproductnum', type=>'select-taxproduct' },

                              { type  => 'tablebreak-tr-title',
                                value => 'Promotions', #better name?
                              },
                              { field=>'promo_code', type=>'text', size=>15 },

                              { type  => 'tablebreak-tr-title',
                                value => 'Line-item revenue recogition', #better name?
                              },
                              { field=>'pay_weight',    type=>'text', size=>6 },
                              { field=>'credit_weight', type=>'text', size=>6 },

                            { type => 'columnnext' },

                              { field=>'agent_type',
                                type => 'select-agent_types',
                                curr_value_callback => sub {
                                  my($cgi, $object, $field) = @_;
                                  #in the other callbacks..?  hmm.
                                  \@agent_type;
                                },
                              },

                            { type => 'columnend' },

                            { 'type'  => 'tablebreak-tr-title',
                              'value' => 'Pricing add-ons',
                            },
                            { 'field'      => 'bill_dst_pkgpart',
                              'type'       => 'select-part_pkg',
                              'm2_label'   => 'Include line item(s) from package',
                              'm2m_method' => 'bill_part_pkg_link',
                              'm2m_dstcol' => 'dst_pkgpart',
                              'm2_error_callback' =>
                                &{$m2_error_callback_maker}('bill'),
                            },

                            { type  => 'tablebreak-tr-title',
                              value => 'Services',
                            },
                            { type => 'pkg_svc', },

                            { 'field'      => 'svc_dst_pkgpart',
                              'label'      => 'Also include services from package: ',
                              'type'       => 'select-part_pkg',
                              'm2_label'   => 'Include services of package: ',
                              'm2m_method' => 'svc_part_pkg_link',
                              'm2m_dstcol' => 'dst_pkgpart',
                              'm2_error_callback' =>
                                &{$m2_error_callback_maker}('svc'),
                            },

                            { type  => 'tablebreak-tr-title',
                              value => 'Price plan options',
                            },

                          ],

           )
%>
<%init>

my $curuser = $FS::CurrentUser::CurrentUser;

die "access denied"
  unless $curuser->access_right('Edit package definitions')
      || $curuser->access_right('Edit global package definitions')
      || ( $cgi->param('pkgnum') && $curuser->access_right('Customize customer package') );

#XXX
# - tr-part_pkg_freq: month_increments_only (from price plans)
# - display add-ons in browse... yeah
# -QIS- thank goodness
# - test cloning
# - test custom pricing
#recur_flat->recur_fee migration, ugh
# - move the selectlayer divs away from lame layer_callback

#my ($query) = $cgi->keywords;
#
#my $part_pkg = '';

my @agent_type = ();
my $tax_override;

my $clone_part_pkg = '';

my %options = ();
my $recur_disabled = 1;
my $error_callback = sub {
  my($cgi, $object, $fields) = @_;
  (@agent_type) = $cgi->param('agent_type');
  $tax_override = $cgi->param('tax_override');
  $clone_part_pkg= qsearchs('part_pkg', { 'pkgpart' => $cgi->param('clone') } );

  $recur_disabled = $cgi->param('freq') ? 0 : 1;

  #some false laziness w/process
  $cgi->param('plan') =~ /^(\w+)$/ or die 'unparsable plan';
  my $plan = $1;
  my $options = $cgi->param($plan."__OPTIONS");
  my @options = split(',', $options);
  %options =
    map { my $optionname = $_;
          my $param = $plan."__$optionname";
          my $value = join(', ', $cgi->param($param));
          ( $optionname => $value );
        }
        @options;

  #$cgi->param($_, $options{$_}) foreach (qw( setup_fee recur_fee ));
  $object->set($_ => scalar($cgi->param($_)) )
    foreach (qw( setup_fee recur_fee ));

};

my $new_hashref_callback = sub { { 'plan' => 'flat' }; };

my $new_object_callback = sub {
  my( $cgi, $hashref, $fields, $opt ) = @_;

  my $part_pkg = '';
  if ( $cgi->param('clone') ) {
    $opt->{action} = 'Custom';
    $clone_part_pkg = qsearchs('part_pkg', { pkgpart=>$cgi->param('clone') } );
    $part_pkg = $clone_part_pkg->clone;
    $part_pkg->disabled('Y');
    %options = $clone_part_pkg->options;
  } else {
    $part_pkg = FS::part_pkg->new( $hashref );
  }

  $part_pkg->set($_ => '0')
    foreach (qw( setup_fee recur_fee ));

  $part_pkg;

};

my $edit_callback = sub {
  my( $cgi, $object, $fields ) = @_;

  $recur_disabled = $object->freq ? 0 : 1;

  (@agent_type) = map {$_->typenum} qsearch('type_pkgs',{'pkgpart'=>$1});
  $tax_override =
    join (",", map {$_->taxclassnum}
               qsearch( 'part_pkg_taxoverride', {'pkgpart' => $1} )
         );

#    join (",", map {$_->taxclassnum}
#               $part_pkg->part_pkg_taxrate( 'cch', $conf->config('defaultloc')
#         );
#      unless $tax_override;

  %options = $object->options;

  $object->set($_ => $object->option($_))
    foreach (qw( setup_fee recur_fee ));

};

my $new_callback = sub {
  my( $cgi, $object, $fields ) = @_;

  my $conf = new FS::Conf; 
  if ( $conf->exists('agent_defaultpkg') ) {
    #my @all_agent_types = map {$_->typenum} qsearch('agent_type',{});
    @agent_type = map {$_->typenum} qsearch('agent_type',{});
  }

};

my $m2_error_callback_maker = sub {
  my $link_type = shift; #yay closures
  return sub {
    my( $cgi, $object ) = @_;
      map  {
             new FS::part_pkg_link {
               'link_type'   => $link_type,
               'src_pkgpart' => $object->pkgpart,
               'dst_pkgpart' => $_,
             };
           }
      grep $_,
      map  $cgi->param($_),
      grep /^${link_type}_dst_pkgpart(\d+)$/, $cgi->param;
  };
};

my $freq_changed = <<'END';
  <SCRIPT TYPE="text/javascript">

    function freq_changed(what) {
      var freq = what.options[what.selectedIndex].value;

      if ( freq == '0' ) {
        what.form.recur_fee.disabled = true;
        what.form.recur_fee.style.backgroundColor = '#dddddd';
      } else {
        what.form.recur_fee.disabled = false;
        what.form.recur_fee.style.backgroundColor = '#ffffff';
      }

    }

  </SCRIPT>
END

tie my %plans, 'Tie::IxHash', %{ FS::part_pkg::plan_info() };

tie my %plan_labels, 'Tie::IxHash',
  map {  $_ => ( $plans{$_}->{'shortname'} || $plans{$_}->{'name'} ) }
      keys %plans;

my $html_bottom = sub {
  my( $object ) = @_;

  #warn join("\n", map { "$_: $options{$_}" } keys %options ). "\n";

  my $layer_callback = sub {
  
    my $layer = shift;
    my $html = ntable("#cccccc",2);
  
    #$html .= '
    #  <TR>
    #    <TD ALIGN="right">Recurring fee frequency </TD>
    #    <TD><SELECT NAME="freq">
    #';
    #
    #my @freq = keys %freq;
    #@freq = grep { /^\d+$/ } @freq
  #XXX this bit#  #  if exists($plans{$layer}->{'freq'}) && $plans{$layer}->{'freq'} eq 'm';
    #foreach my $freq ( @freq ) {
    #  $html .= qq(<OPTION VALUE="$freq");
    #  $html .= ' SELECTED' if $freq eq $part_pkg->freq;
    #  $html .= ">$freq{$freq}";
    #}
    #$html .= '</SELECT></TD></TR>';
  
    my $href = $plans{$layer}->{'fields'};
    my @fields = exists($plans{$layer}->{'fieldorder'})
                   ? @{$plans{$layer}->{'fieldorder'}}
                   : keys %{ $href };
  
    foreach my $field ( grep $_ !~ /^(setup|recur)_fee$/, @fields ) {
  
      $html .= '<TR><TD ALIGN="right">'. $href->{$field}{'name'}. '</TD><TD>';
  
      my $format = sub { shift };
      $format = $href->{$field}{'format'} if exists($href->{$field}{'format'});

      #XXX these should use elements/ fields... (or this whole thing should
      #just use layer_fields instead of layer_callback)
  
      if ( ! exists($href->{$field}{'type'}) ) {
  
        $html .= qq!<INPUT TYPE="text" NAME="${layer}__$field" VALUE="!.
                 ( exists($options{$field})
                     ? &$format($options{$field})
                     : $href->{$field}{'default'} ).
                 qq!">!;
  
      } elsif ( $href->{$field}{'type'} eq 'checkbox' ) {
  
        $html .= qq!<INPUT TYPE="checkbox" NAME="${layer}__$field" VALUE=1 !.
                 ( exists($options{$field}) && $options{$field}
                   ? ' CHECKED'
                   : ''
                 ). '>';
  
      } elsif ( $href->{$field}{'type'} =~ /^select/ ) {
  
        $html .= '<SELECT';
        $html .= ' MULTIPLE'
          if $href->{$field}{'type'} eq 'select_multiple';
        $html .= qq! NAME="${layer}__$field">!;
  
        if ( $href->{$field}{'select_table'} ) {
          foreach my $record (
            qsearch( $href->{$field}{'select_table'},
                     $href->{$field}{'select_hash'}   )
          ) {
            my $value = $record->getfield($href->{$field}{'select_key'});
            $html .= qq!<OPTION VALUE="$value"!.
                     (  $options{$field} =~ /(^|, *)$value *(,|$)/ #?
                          ? ' SELECTED'
                          : ''
                     ).
                     '>'. $record->getfield($href->{$field}{'select_label'});
          }
        } elsif ( $href->{$field}{'select_options'} ) {
          foreach my $key ( keys %{ $href->{$field}{'select_options'} } ) {
            my $label = $href->{$field}{'select_options'}{$key};
            $html .= qq!<OPTION VALUE="$key"!.
                     ( $options{$field} =~ /(^|, *)$key *(,|$)/ #?
                         ? ' SELECTED'
                         : ''
                     ).
                     '>'. $label;
          }
  
        } else {
          $html .= '<font color="#ff0000">warning: '.
                   "don't know how to retreive options for $field select field".
                   '</font>';
        }
        $html .= '</SELECT>';
  
      } elsif ( $href->{$field}{'type'} eq 'radio' ) {
  
        my $radio =
          qq!<INPUT TYPE="radio" NAME="${layer}__$field"!;
  
        foreach my $key ( keys %{ $href->{$field}{'options'} } ) {
          my $label = $href->{$field}{'options'}{$key};
          $html .= qq!$radio VALUE="$key"!.
                   ( $options{$field} =~ /(^|, *)$key *(,|$)/ #?
                       ? ' CHECKED'
                       : ''
                   ).
                   "> $label<BR>";
        }
  
      }
  
      $html .= '</TD></TR>';
    }
    $html .= '</TABLE>';
  
    $html .= qq(<INPUT TYPE="hidden" NAME="${layer}__OPTIONS" VALUE=").
             join(',', keys %{ $href } ). '">';
  
    $html;
  
  };

  my %selectlayers = (
    field          => 'plan',
    options        => [ keys %plan_labels ],
    labels         => \%plan_labels,
    curr_value     => $object->plan,
    layer_callback => $layer_callback,
  );

  include('/elements/selectlayers.html', %selectlayers, 'layers_only'=>1 ).
  '<SCRIPT TYPE="text/javascript">'.
    include('/elements/selectlayers.html', %selectlayers, 'js_only'=>1 ).
  '</SCRIPT>';

};

</%init>
