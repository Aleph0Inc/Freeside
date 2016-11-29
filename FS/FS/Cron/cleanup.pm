package FS::Cron::cleanup;
use base 'Exporter';
use vars '@EXPORT_OK';
use FS::queue;
use FS::Record qw( qsearch );

@EXPORT_OK = qw( cleanup cleanup_before_backup );

# start janitor jobs
sub cleanup {
  my %opt = @_;

  # fix locations that are missing coordinates
  my $job = FS::queue->new({
      'job'     => 'FS::cust_location::process_set_coord',
      'status'  => 'new'
  });
  $job->insert('_JOB');

  # check card number tokenization
  $job = FS::queue->new({
      'job'     => 'FS::cust_main::Billing_Realtime::token_check',
      'status'  => 'new'
  });
  $job->insert(
    %opt,
    'queue' => 1,
    'daily' => 1,
  );

}

sub cleanup_before_backup {
  #remove outdated cacti_page entries
  foreach my $export (qsearch({
    'table' => 'part_export',
    'hashref' => { 'exporttype' => 'cacti' }
  })) {
    $export->cleanup;
  }
  #remove cache files
  my $deldir = "$FS::UID::cache_dir/cache.$FS::UID::datasrc/";
  unlink <${deldir}.invoice*>;
  unlink <${deldir}.letter*>;
  unlink <${deldir}.CGItemp*>;
}

1;
