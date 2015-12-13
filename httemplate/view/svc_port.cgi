<% include('elements/svc_Common.html',
            'table'     => 'svc_port',
	    'fields'	=> \@fields,
	    'labels'	=> \%labels,
	    'html_foot' => $html_foot,
          )
%>
<%init>

use Date::Parse 'str2time';

my $conf = new FS::Conf;
my $date_format = $conf->config('date_format') || '%m/%d/%Y';

my $fields = FS::svc_port->table_info->{'fields'};
my %labels = map { $_ =>  ( ref($fields->{$_})
                             ? $fields->{$_}{'label'}
                             : $fields->{$_}
                         );
                 } keys %$fields;
my @fields = keys %$fields;

my $start = $cgi->param('start');
my $end = $cgi->param('end');

sub preset_range {
    my($start,$end,$label,$date_format) = (shift,shift,shift,shift);
    $start = time2str($date_format,$start);
    $end = time2str($date_format,$end);
    return '<A HREF="javascript:void(0);" onclick="preset_range(\''
	    .$start.'\',\''.$end.'\')">'.$label.'</A>';
}

my $html_foot = sub {
    my $svc_port = shift;
    my $svcnum = $svc_port->svcnum;
    my $default_end = time;
    my $default_start = $default_end-86400;
    my $graph = '';

    my $nms = new FS::NetworkMonitoringSystem;
    my $url = $nms->port_graphs_link($svc_port->serviceid);
    my $link = $url ? qq(<A HREF="$url">Torrus Graphs</A><BR><BR>) : '';

    if ( $start && $end ) {
        my($s, $e) = ($start, $end);
        if ( $date_format eq '%d/%m/%Y' ) {
          $start =~ /^\s*(\d+)\D+(\d+)\D+(\d+)\s*$/ and $s = "$2/$1/$3";
          $end   =~ /^\s*(\d+)\D+(\d+)\D+(\d+)\s*$/ and $e = "$2/$1/$3";
        }
        $graph = "<BR><BR><IMG SRC=${p}/view/port_graph.html?svcnum=$svcnum".
                                  ";start=".str2time("$s 00:00:00").
                                  ";end=".  str2time("$e 23:59:59").
                         ">";
    }

    return '
    <script type="text/javascript">
	function preset_range(start,end){
	    document.getElementById(\'start_text\').value = start;
	    document.getElementById(\'end_text\').value = end;
	}
    </script>
    <FORM ACTION=? METHOD="GET">
    <INPUT TYPE="HIDDEN" NAME="svcnum" VALUE="'.$svcnum.'">
    '.$link.'
    <B>Bandwidth Graph</B><BR>
&nbsp; '.preset_range($default_start,$default_end,'Last Day',$date_format)
    .' | '.preset_range($default_end-86400*7,$default_end,'Last Week',$date_format)
    .' | '.preset_range($default_end-86400*30,$default_end,'Last Month',$date_format)
    .' | '.preset_range($default_end-86400*365,$default_end,'Last Year',$date_format)
    .' <BR>
    <TABLE>'
	. include('/elements/tr-input-date-field.html', { 
		'name' => 'start',
		'label' => 'Start Date',
		'value' => $start,
	    }) 
	. include('/elements/tr-input-date-field.html', { 
		'name' => 'end',
		'label' => 'End Date',
		'noinit' => 1,
		'value' => $end,
	    }) 
	. '<TR><TD colspan="2"><input type="submit" value="Display"></TR>
    </TABLE>
    </FORM>'.$graph;
};

</%init>
