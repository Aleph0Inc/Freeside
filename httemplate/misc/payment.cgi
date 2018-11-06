<& /elements/header.html, mt("Process [_1] payment",$type{$payby})  &>
<& /elements/small_custview.html, $cust_main, '', '', popurl(2) . "view/cust_main.cgi" &>
<FORM NAME="OneTrueForm" ACTION="process/payment.cgi" METHOD="POST" onSubmit="document.OneTrueForm.process.disabled=true">
<INPUT TYPE="hidden" NAME="custnum"   VALUE="<% $custnum %>">
<INPUT TYPE="hidden" NAME="payby"     VALUE="<% $payby %>">
<INPUT TYPE="hidden" NAME="payunique" VALUE="<% $payunique %>">
<INPUT TYPE="hidden" NAME="balance"   VALUE="<% $balance %>">

<& /elements/init_overlib.html &>

<% ntable('#cccccc') %>

  <& /elements/tr-amount_fee.html,
       'amount'             => $amount,
       'process-pkgpart'    => 
          scalar($conf->config('manual_process-pkgpart', $cust_main->agentnum)),
       'process-display'    => scalar($conf->config('manual_process-display')),
       'process-skip_first' => $conf->exists('manual_process-skip_first'),
       'num_payments'       => scalar($cust_main->cust_pay), 
       'surcharge_percentage' =>
         ( $payby eq 'CARD'
             ? scalar($conf->config('credit-card-surcharge-percentage', $cust_main->agentnum))
             : 0
         ),
       'surcharge_flatfee' =>
         ( $payby eq 'CARD'
             ? scalar($conf->config('credit-card-surcharge-flatfee', $cust_main->agentnum))
             : 0
         ),
         'processing_fee' => scalar($conf->config('processing-fee', $cust_main->agentnum)),
  &>

% if ( $conf->exists('part_pkg-term_discounts') ) {
    <& /elements/tr-select-discount_term.html,
         'custnum'   => $custnum,
         'amount_id' => 'amount',
    &>
% }

% if ( $payby eq 'CARD' ) {
%
%   my( $payinfo, $paycvv, $month, $year ) = ( '', '', '', '' );
%   my $payname = $cust_main->first. ' '. $cust_main->getfield('last');
%   if ( $cust_main->payby =~ /^(CARD|DCRD)$/ ) {
%     $payinfo = $cust_main->paymask;
%     ( $paycvv = $cust_main->paycvv ) =~ s/./*/g;
%     ( $month, $year ) = $cust_main->paydate_monthyear;
%     $payname = $cust_main->payname if $cust_main->payname;
%   } elsif ($disable_payauto_default) {
%     $auto = 0;
%   }

    <TR>
      <TH ALIGN="right"><% mt('Card number') |h %></TH>
      <TD COLSPAN=7>
        <TABLE>
          <TR>
            <TD>
              <INPUT TYPE="text" NAME="payinfo" SIZE=20 MAXLENGTH=19 VALUE="<%$payinfo%>"<% ($auto && $disable_payauto_default) ? $possibly_uncheck_auto : '' %>> </TD>
            <TH><% mt('Exp.') |h %></TH>
            <TD>
              <SELECT NAME="month">
% for ( map{ sprintf('%02d',$_) } (1..12) ) {
                  <OPTION VALUE="<% $_ %>"<% $_ == $month ? ' SELECTED' : '' %>><% $_ %></OPTION>
% } 

              </SELECT>
            </TD>
            <TD> / </TD>
            <TD>
              <SELECT NAME="year">
% my @a = localtime; for ( $a[5]+1900 .. $a[5]+1915 ) { 
                  <OPTION VALUE="<% $_ %>"<% $_ == $year ? ' SELECTED' : '' %>><% $_ %></OPTION>
% } 

              </SELECT>
            </TD>
          </TR>
        </TABLE>
      </TD>
    </TR>
    <TR>
      <TH ALIGN="right"><% mt('CVV2') |h %></TH>
      <TD><INPUT TYPE="text" NAME="paycvv" VALUE="<% $paycvv %>" SIZE=4 MAXLENGTH=4>
          (<A HREF="javascript:void(0);" onClick="overlib( OLiframeContent('../docs/cvv2.html', 480, 352, 'cvv2_popup' ), CAPTION, 'CVV2 Help', STICKY, AUTOSTATUSCAP, CLOSECLICK, DRAGGABLE ); return false;"><% mt('help') |h %></A>)
      </TD>
    </TR>
    <TR>
      <TH ALIGN="right"><% mt('Exact name on card') |h %></TH>
      <TD><INPUT TYPE="text" SIZE=32 MAXLENGTH=80 NAME="payname" VALUE="<%$payname%>"></TD>
    </TR>

    <& /elements/location.html,
                  'object'         => $cust_main->bill_location,
                  'no_asterisks'   => 1,
                  'address1_label' => emt('Card billing address'),
    &>

% } elsif ( $payby eq 'CHEK' ) {
%
%   my( $account, $aba, $branch, $payname, $ss, $paytype, $paystate,
%       $stateid, $stateid_state )
%     = ( '', '', '', '', '', '', '', '', '' );
%   if ( $cust_main->payby =~ /^(CHEK|DCHK)$/ ) {
%     $cust_main->paymask =~ /^([\dx]+)\@([\d\.x]*)$/i
%       or die "unparsable payinfo ". $cust_main->payinfo;
%     ($account, $aba) = ($1, $2);
%     ($branch,$aba) = split('\.',$aba)
%       if $conf->config('echeck-country') eq 'CA';
%     $payname = $cust_main->payname;
%     $ss = $cust_main->ss;
%     $paytype = $cust_main->getfield('paytype');
%     $paystate = $cust_main->getfield('paystate');
%     $stateid = $cust_main->getfield('stateid');
%     $stateid_state = $cust_main->getfield('stateid_state');
%   } elsif ($disable_payauto_default) {
%     $auto = 0;
%   }
%
%  #false laziness w/{edit,view}/cust_main/billing.html
%  my $routing_label = $conf->config('echeck-country') eq 'US'
%                        ? 'ABA/Routing number'
%                        : 'Routing number';
%  my $routing_size      = $conf->config('echeck-country') eq 'CA' ? 4 : 10;
%  my $routing_maxlength = $conf->config('echeck-country') eq 'CA' ? 3 : 9;

    <INPUT TYPE="hidden" NAME="month" VALUE="12">
    <INPUT TYPE="hidden" NAME="year" VALUE="2037">
    <TR>
      <TD ALIGN="right"><% mt('Account number') |h %></TD>
      <TD><INPUT TYPE="text" SIZE=10 NAME="payinfo1" VALUE="<%$account%>"<% ($auto && $disable_payauto_default) ? $possibly_uncheck_auto : '' %>></TD>
      <TD ALIGN="right"><% mt('Type') |h %></TD>
      <TD><SELECT NAME="paytype"><% join('', map { qq!<OPTION VALUE="$_" !.($paytype eq $_ ? 'SELECTED' : '').">$_</OPTION>" } @FS::cust_main::paytypes) %></SELECT></TD>
    </TR>
    <TR>
      <TD ALIGN="right"><% mt($routing_label) |h %></TD>
      <TD>
        <INPUT TYPE="text" SIZE="<% $routing_size %>" MAXLENGTH="<% $routing_maxlength %>" NAME="payinfo2" VALUE="<%$aba%>"<% ($auto && $disable_payauto_default) ? $possibly_uncheck_auto : '' %>>
        (<A HREF="javascript:void(0);" onClick="overlib( OLiframeContent('../docs/ach.html', 380, 240, 'ach_popup' ), CAPTION, 'ACH Help', STICKY, AUTOSTATUSCAP, CLOSECLICK, DRAGGABLE ); return false;"><% mt('help') |h %></A>)
      </TD>
    </TR>
%   if ( $conf->config('echeck-country') eq 'CA' ) {
      <TR>
        <TD ALIGN="right"><% mt('Branch number') |h %></TD>
        <TD>
          <INPUT TYPE="text" NAME="payinfo3" VALUE="<%$branch%>" SIZE=6 MAXLENGTH=5<% ($auto && $disable_payauto_default) ? $possibly_uncheck_auto : '' %>>
        </TD>
      </TR>
%   }
    <TR>
      <TD ALIGN="right"><% mt('Bank name') |h %></TD>
      <TD><INPUT TYPE="text" NAME="payname" VALUE="<%$payname%>"></TD>
    </TR>

%   if ( $conf->exists('show_bankstate') ) {
      <TR>
        <TD ALIGN="right"><% mt('Bank state') |h %></TD>
        <TD><& /elements/select-state.html,
                         'disable_empty' => 0,
                         'empty_label'   => emt('(choose)'),
                         'state'         => $paystate,
                         'country'       => $cust_main->country,
                         'prefix'        => 'pay',
            &>
        </TD>
      </TR>
%   } else {
      <INPUT TYPE="hidden" NAME="paystate" VALUE="<% $paystate %>">
%   }

%   if ( $conf->exists('show_ss') ) {
      <TR>
        <TD ALIGN="right">
          <% mt('Account holder') |h %><BR>
          <% mt('Social security or tax ID #') |h %> 
        </TD>
        <TD><INPUT TYPE="text" NAME="ss" VALUE="<% $ss %>"></TD>
      </TR>
%   } else {
      <INPUT TYPE="hidden" NAME="ss" VALUE="<% $ss %>"></TD>
%   }

%   if ( $conf->exists('show_stateid') ) {
      <TR>
        <TD ALIGN="right">
          <% mt('Account holder') |h %><BR>
          <% mt("Driver's license or state ID #") |h %> 
        </TD>
        <TD><INPUT TYPE="text" NAME="stateid" VALUE="<% $stateid %>"></TD>
        <TD ALIGN="right"><% mt('State') |h %></TD>
        <TD><& /elements/select-state.html,
                         'disable_empty' => 0,
                         'empty_label'   => emt('(choose)'),
                         'state'         => $stateid_state,
                         'country'       => $cust_main->country,
                         'prefix'        => 'stateid_',
            &>
        </TD>
      </TR>
%   } else {
      <INPUT TYPE="hidden" NAME="stateid" VALUE="<% $stateid %>">
      <INPUT TYPE="hidden" NAME="stateid_state" VALUE="<% $stateid_state %>">
%   }

% } #end CARD/CHEK-specific section


<TR>
  <TD COLSPAN=2>
    <INPUT TYPE="checkbox" CHECKED NAME="save" VALUE="1">
    <% mt('Remember this information') |h %>
  </TD>
</TR>

% my $disallow_no_auto_apply = 0;
% if ( $conf->exists("batch-enable")
%      || grep $payby eq $_, $conf->config('batch-enable_payby')
%    ) {
%
%     if ( grep $payby eq $_, $conf->config('realtime-disable_payby') ) {
%       $disallow_no_auto_apply = 1;

          <INPUT TYPE="hidden" NAME="batch" VALUE="1">

%     } else {

          <TR>
            <TD COLSPAN=2>
              <INPUT TYPE="checkbox" NAME="batch" VALUE="1" ID="batch_checkbox" ONCHANGE="change_batch_checkbox()">
              <% mt('Add to current batch') |h %> 
            </TD>
          </TR>

%     }
% }

<TR>
  <TD COLSPAN=2>
    <INPUT ID="auto_checkbox" TYPE="checkbox"<% $auto ? ' CHECKED' : '' %> NAME="auto" VALUE="1" onClick="if (this.checked) { document.OneTrueForm.save.checked=true; }">
    <% mt("Charge future payments to this [_1] automatically",$type{$payby}) |h %> 
  </TD>
</TR>

% unless ($disallow_no_auto_apply) {
%   # false laziness with edit/cust_pay.cgi

<TR ID="apply_box_row">
  <TD COLSPAN=2>
    <% mt('Auto-apply to invoices') |h %>
    <SELECT NAME="apply" ID="apply_box">
      <OPTION VALUE="yes" SELECTED><% mt('yes') |h %></OPTION> 
      <OPTION VALUE=""><% mt('not now') |h %></OPTION>
      <OPTION VALUE="never"><% mt('never') |h %></OPTION>
    </SELECT>
  </TD>
</TR>

% # this can go away if no_auto_apply handling gets added to batch payment processing
<SCRIPT>
function change_batch_checkbox () {
  if (document.getElementById('batch_checkbox').checked) {
    document.getElementById('apply_box').disabled = true;
    document.getElementById('apply_box_row').style.display = 'none';
  } else {
    document.getElementById('apply_box').disabled = false;
    document.getElementById('apply_box_row').style.display = '';
  }
}
</SCRIPT>

% }

% if ($auto && $disable_payauto_default) {
<SCRIPT>
var unchecked_auto = false;
function possibly_uncheck_auto () {
  if (!unchecked_auto) {
    unchecked_auto = true;
    document.getElementById('auto_checkbox').checked = false;
  }
}
</SCRIPT>
% }

</TABLE>

<BR>
<INPUT TYPE="submit" NAME="process" VALUE="<% mt('Process payment') |h %>">
</FORM>

<& /elements/footer.html &>
<%init>

die "access denied"
  unless $FS::CurrentUser::CurrentUser->access_right('Process payment');

my %type = ( 'CARD' => 'credit card',
             'CHEK' => 'electronic check (ACH)',
           );

$cgi->param('payby') =~ /^(CARD|CHEK)$/
  or die "unknown payby ". $cgi->param('payby');
my $payby = $1;

$cgi->param('custnum') =~ /^(\d+)$/
  or die "illegal custnum ". $cgi->param('custnum');
my $custnum = $1;

my $cust_main = qsearchs( 'cust_main', { 'custnum'=>$custnum } );
die "unknown custnum $custnum" unless $cust_main;

my $location = $cust_main->bill_location;
# no proper error handling on this anyway, but when we have it,
# remember to repopulate fields in $location

my $balance = $cust_main->balance;

my $payinfo = '';

my $conf = new FS::Conf;

my $auto = ( ( $payby eq 'CARD' && $cust_main->payby ne 'DCRD' ) || ( $payby eq 'CHEK' && $cust_main->payby eq 'CHEK' ) ) ? 1 : 0;
my $disable_payauto_default = $conf->exists('disable_payauto_default');
my $possibly_uncheck_auto = ' ONCHANGE="possibly_uncheck_auto()"';

#false laziness w/selfservice make_payment.html shortcut for one-country
my %states = map { $_->state => 1 }
               qsearch('cust_main_county', {
                 'country' => $conf->config('countrydefault') || 'US'
               } );
my @states = sort { $a cmp $b } keys %states;

my $amount = '';
if ( $balance > 0 ) {
  # when configured to do so, amount will only auto-fill with balance
  # if balance represents a single invoice
  $amount = $balance
    unless $conf->exists('manual_process-single_invoice_amount')
      && ($cust_main->open_cust_bill != 1);
}

my $payunique = "webui-payment-". time. "-$$-". rand() * 2**32;

</%init>
