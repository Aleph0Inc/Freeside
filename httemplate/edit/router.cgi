<% include('elements/edit.html',
     'post_url'    => popurl(1).'process/router.cgi',
     'name'        => 'router',
     'table'       => 'router',
     'viewall_url' => "${p}browse/router.cgi",
     'labels'      => { 'routernum'  => 'Router',
                        'routername' => 'Name',
                        'svc_part'   => 'Service',
                        'agentnum'   => 'Agent',
                        'manual_addr'  => 'Assign IP addresses manually',
                      },
     'fields'      => [
                        { 'field'=>'routername', 'type'=>'text', 'size'=>32 },
                        { 'field'=>'agentnum',   'type'=>'select-agent' },
                        { 'field'=>'svcnum',     'type'=>'hidden' },
                        { 'field'=>'manual_addr','type'=>'checkbox','value'=>'Y'},
                      ],
     'error_callback' => $callback,
     'edit_callback'  => $callback,
     'new_callback'   => $callback,
     'html_table_bottom' => $html_table_bottom,
   )
%>
<%init>

my $curuser = $FS::CurrentUser::CurrentUser;

die "access denied"
  unless $curuser->access_right('Broadband configuration')
    || $curuser->access_right('Broadband global configuration');

my @svc_x = 'svc_broadband';
if ( FS::Conf->new->exists('svc_acct-ip_addr') ) {
  push @svc_x, 'svc_acct';
}

my $callback = sub {
  my ($cgi, $object, $fields) = (shift, shift, shift);

  my $extra_sql = ' AND svcdb IN(' . join(',', map { "'$_'" } @svc_x) . ')';
  unless ($object->svcnum) {
    push @{$fields},
      { 'type'          => 'tablebreak-tr-title',
        'value'         => 'Select the service types available on this router',
      },
      { 'type'          => 'checkboxes-table',
        'target_table'  => 'part_svc',
        'link_table'    => 'part_svc_router',
        'name_col'      => 'svc',
        'hashref'       => { 'disabled' => '' },
        'extra_sql'     => $extra_sql,
      };
  }
};

my $html_table_bottom = sub {
  my $router = shift;
  my $html = '';
  foreach my $field ($router->virtual_fields) {
    $html .= $router->pvf($field)->widget('HTML', 'edit', $router->get($field));
  }
  $html;
};
</%init>
