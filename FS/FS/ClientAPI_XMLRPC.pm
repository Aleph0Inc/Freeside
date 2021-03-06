package FS::ClientAPI_XMLRPC;

=head1 NAME

FS::ClientAPI_XMLRPC - Freeside XMLRPC accessible self-service API, on the backend

=head1 SYNOPSIS

This module implements the self-service API offered by xmlrpc.cgi and friends,
but on a backend machine.

=head1 DESCRIPTION

Use this API to implement your own client "self-service" module vi XMLRPC.

Each routine described in L<FS::SelfService> is available vi XMLRPC as the
method FS.SelfService.XMLRPC.B<method>.  All values are passed to the
selfservice-server in a struct of strings.  The return values are in a
struct as strings, arrays, or structs as appropriate for the values
described in L<FS::SelfService>.

=head1 BUGS

=head1 SEE ALSO

L<FS::SelfService::XMLRPC>, L<FS::SelfService>

=cut

use strict;

use vars qw($DEBUG $AUTOLOAD);
use Encode;
use FS::XMLRPC_Lite; #XMLRPC::Lite, for XMLRPC::Data
use FS::ClientAPI;

$DEBUG = 0;
$FS::ClientAPI::DEBUG = $DEBUG;

#false laziness w/FS::SelfService/XMLRPC.pm, same problem as below but worse
our %typefix_skin_info = (
  'logo'              => 'base64',
  'title_left_image'  => 'base64',
  'title_right_image' => 'base64',
  'menu_top_image'    => 'base64',
  'menu_body_image'   => 'base64',
  'menu_bottom_image' => 'base64',
);
our %typefix = (
  'invoice_pdf'          => { 'invoice_pdf' => 'base64', },
  'legacy_invoice_pdf'   => { 'invoice_pdf' => 'base64', },
  'skin_info'            => \%typefix_skin_info,
  'payment_only_skin_info' => \%typefix_skin_info,
  'login_info'           => \%typefix_skin_info,
  'logout'               => \%typefix_skin_info,
  'access_info'          => \%typefix_skin_info,
  'reset_passwd'         => \%typefix_skin_info,
  'check_reset_passwd'   => \%typefix_skin_info,
  'process_reset_passwd' => \%typefix_skin_info,
  'invoice_logo'         => { 'logo' => 'base64', },
  'login_banner_image'   => { 'image' => 'base64', },
  'quotation_print'      => { 'document' => 'base64' },
);

sub AUTOLOAD {
  my $call = $AUTOLOAD;
  $call =~ s/^FS::(SelfService::|ClientAPI_)XMLRPC:://;

  warn "FS::ClientAPI_XMLRPC::AUTOLOAD $call\n" if $DEBUG;

  my $autoload = &ss2clientapi;

  if (exists($autoload->{$call})) {

    shift; #discard package name;


    #$call = "FS::SelfService::$call";
    #no strict 'refs';
    #&{$call}(@_);
    #FS::ClientAPI->dispatch($autoload->{$call}, @_);

    my %hash = @_;
    #XXX doesn't deep-fix multi-level data structs, but at least doesn't mangle
    # them anymore
    $hash{$_} = decode(utf8=>$hash{$_})
      foreach grep !ref($hash{$_}), keys %hash;

    my $return = FS::ClientAPI->dispatch($autoload->{$call}, \%hash );

    if ( exists($typefix{$call}) ) {
      my $typefix = $typefix{$call};
      foreach my $field ( grep exists($return->{$_}), keys %$typefix ) {
        my $type = $typefix->{$field};
        $return->{$field} = XMLRPC::Data->value($return->{$field})
                                        ->type($type);
      }
    }

    $return;

  } else {
    die "No such procedure: $call";
  }
}

#terrible false laziness w/SelfService.pm
# - fix at build time, by including some file in both selfserv and backend libs?
# - or fix at runtime, by having selfservice client ask server for the list?
sub ss2clientapi {
  {
  'passwd'                    => 'passwd/passwd',
  'chfn'                      => 'passwd/passwd',
  'chsh'                      => 'passwd/passwd',
  'login_info'                => 'MyAccount/login_info',
  'login_banner_image'        => 'MyAccount/login_banner_image',
  'login'                     => 'MyAccount/login',
  'logout'                    => 'MyAccount/logout',
  'switch_acct'               => 'MyAccount/switch_acct',
  'switch_cust'               => 'MyAccount/switch_cust',
  'customer_info'             => 'MyAccount/customer_info',
  'customer_info_short'       => 'MyAccount/customer_info_short',
  'customer_recurring'        => 'MyAccount/customer_recurring',

  'contact_passwd'            => 'MyAccount/contact/contact_passwd',
  'list_contacts'             => 'MyAccount/contact/list_contacts',
  'edit_contact'              => 'MyAccount/contact/edit_contact',
  'delete_contact'            => 'MyAccount/contact/delete_contact',
  'new_contact'               => 'MyAccount/contact/new_contact',

  'billing_history'           => 'MyAccount/billing_history',
  'edit_info'                 => 'MyAccount/edit_info',     #add to ss cgi!
  'invoice'                   => 'MyAccount/invoice',
  'invoice_pdf'               => 'MyAccount/invoice_pdf',
  'legacy_invoice'            => 'MyAccount/legacy_invoice',
  'legacy_invoice_pdf'        => 'MyAccount/legacy_invoice_pdf',
  'invoice_logo'              => 'MyAccount/invoice_logo',
  'list_invoices'             => 'MyAccount/list_invoices', #?
  'list_payments'             => 'MyAccount/list_payments',
  'payment_receipt'           => 'MyAccount/payment_receipt',
  'list_payby'                => 'MyAccount/list_payby',
  'insert_payby'              => 'MyAccount/insert_payby',
  'update_payby'              => 'MyAccount/update_payby',
  'delete_payby'              => 'MyAccount/delete_payby',
  'cancel'                    => 'MyAccount/cancel',        #add to ss cgi!
  'payment_info'              => 'MyAccount/payment_info',
  'payment_info_renew_info'   => 'MyAccount/payment_info_renew_info',
  'process_payment'           => 'MyAccount/process_payment',
  'store_payment'             => 'MyAccount/store_payment',
  'process_stored_payment'    => 'MyAccount/process_stored_payment',
  'process_payment_order_pkg' => 'MyAccount/process_payment_order_pkg',
  'process_payment_change_pkg' => 'MyAccount/process_payment_change_pkg',
  'process_payment_order_renew' => 'MyAccount/process_payment_order_renew',
  'process_prepay'            => 'MyAccount/process_prepay',
  'start_thirdparty'          => 'MyAccount/start_thirdparty',
  'finish_thirdparty'         => 'MyAccount/finish_thirdparty',
  'realtime_collect'          => 'MyAccount/realtime_collect',
  'list_pkgs'                 => 'MyAccount/list_pkgs',     #add to ss (added?)
  'pkg_info'                  => 'MyAccount/pkg_info',
  'list_svcs'                 => 'MyAccount/list_svcs',     #add to ss (added?)
  'list_svc_usage'            => 'MyAccount/list_svc_usage',   
  'svc_status_html'           => 'MyAccount/svc_status_html',
  'svc_status_hash'           => 'MyAccount/svc_status_hash',
  'set_svc_status_hash'       => 'MyAccount/set_svc_status_hash',
  'set_svc_status_listadd'    => 'MyAccount/set_svc_status_listadd',
  'set_svc_status_listdel'    => 'MyAccount/set_svc_status_listdel',
  'set_svc_status_vacationadd'=> 'MyAccount/set_svc_status_vacationadd',
  'set_svc_status_vacationdel'=> 'MyAccount/set_svc_status_vacationdel',
  'acct_forward_info'         => 'MyAccount/acct_forward_info',
  'process_acct_forward'      => 'MyAccount/process_acct_forward',
  'list_dsl_devices'          => 'MyAccount/list_dsl_devices',   
  'add_dsl_device'            => 'MyAccount/add_dsl_device',   
  'delete_dsl_device'         => 'MyAccount/delete_dsl_device',   
  'port_graph'                => 'MyAccount/port_graph',   
  'list_cdr_usage'            => 'MyAccount/list_cdr_usage',   
  'list_support_usage'        => 'MyAccount/list_support_usage',   
  'order_pkg'                 => 'MyAccount/order_pkg',     #add to ss cgi!
  'change_pkg'                => 'MyAccount/change_pkg', 
  'order_recharge'            => 'MyAccount/order_recharge',
  'renew_info'                => 'MyAccount/renew_info',
  'order_renew'               => 'MyAccount/order_renew',
  'cancel_pkg'                => 'MyAccount/cancel_pkg',    #add to ss cgi!
  'suspend_pkg'               => 'MyAccount/suspend_pkg',   #add to ss cgi!
  'charge'                    => 'MyAccount/charge',        #?
  'part_svc_info'             => 'MyAccount/part_svc_info',
  'provision_acct'            => 'MyAccount/provision_acct',
  'provision_phone'           => 'MyAccount/provision_phone',
  'provision_pbx'             => 'MyAccount/provision_pbx',
  'provision_external'        => 'MyAccount/provision_external',
  'unprovision_svc'           => 'MyAccount/unprovision_svc',
  'myaccount_passwd'          => 'MyAccount/myaccount_passwd',
  'reset_passwd'              => 'MyAccount/reset_passwd',
  'check_reset_passwd'        => 'MyAccount/check_reset_passwd',
  'process_reset_passwd'      => 'MyAccount/process_reset_passwd',
  'validate_passwd'           => 'MyAccount/validate_passwd',
  'list_tickets'              => 'MyAccount/list_tickets',
  'create_ticket'             => 'MyAccount/create_ticket',
  'get_ticket'                => 'MyAccount/get_ticket',
  'adjust_ticket_priority'    => 'MyAccount/adjust_ticket_priority',
  'did_report'                => 'MyAccount/did_report',
  'signup_info'               => 'Signup/signup_info',
  'skin_info'                 => 'MyAccount/skin_info',
  'access_info'               => 'MyAccount/access_info',
  'domain_select_hash'        => 'Signup/domain_select_hash',  # expose?
  'new_customer'              => 'Signup/new_customer',
  'new_customer_minimal'      => 'Signup/new_customer_minimal',
  'capture_payment'           => 'Signup/capture_payment',
  'clear_signup_cache'        => 'Signup/clear_cache',
  'new_prospect'              => 'Signup/new_prospect',
  'new_agent'                 => 'Agent/new_agent',
  'agent_login'               => 'Agent/agent_login',
  'agent_logout'              => 'Agent/agent_logout',
  'agent_info'                => 'Agent/agent_info',
  'agent_list_customers'      => 'Agent/agent_list_customers',
  'check_username'            => 'Agent/check_username',
  'suspend_username'          => 'Agent/suspend_username',
  'unsuspend_username'        => 'Agent/unsuspend_username',
  'mason_comp'                => 'MasonComponent/mason_comp',
  'payment_only_mason_comp'   => 'MasonComponent/payment_only_mason_comp',
  'call_time'                 => 'PrepaidPhone/call_time',
  'call_time_nanpa'           => 'PrepaidPhone/call_time_nanpa',
  'phonenum_balance'          => 'PrepaidPhone/phonenum_balance',

  'list_quotations'           => 'MyAccount/quotation/list_quotations',
  'quotation_new'             => 'MyAccount/quotation/quotation_new',
  'quotation_delete'          => 'MyAccount/quotation/quotation_delete',
  'quotation_info'            => 'MyAccount/quotation/quotation_info',
  'quotation_print'           => 'MyAccount/quotation/quotation_print',
  'quotation_add_pkg'         => 'MyAccount/quotation/quotation_add_pkg',
  'quotation_remove_pkg'      => 'MyAccount/quotation/quotation_remove_pkg',
  'quotation_order'           => 'MyAccount/quotation/quotation_order',
  'ip_login'                  => 'PaymentOnly/ip_login',
  'ip_logout'                 => 'PaymentOnly/ip_logout',
  'get_mac_address'           => 'PaymentOnly/get_mac_address',
  'payment_only_skin_info'    => 'PaymentOnly/payment_only_skin_info',
  'payment_only_payment_info' => 'PaymentOnly/payment_only_payment_info',
  'payment_only_process_payment' => 'PaymentOnly/payment_only_process_payment',

  'freesideinc_service'       => 'Freeside/freesideinc_service',
  };
}

1;
