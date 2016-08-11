package AFA::JobAgent;

use strict;
use SOAP::Lite;
use Date::Manip qw(UnixDate ParseDate Date_Cmp);
use Data::Dumper;
use Encode qw(_utf8_off _utf8_on is_utf8);
use Fcntl ':flock';
use CEC;
use AFA::Logger;
use AFA::DB;
use AFA::Config qw(%afa_config);
use AFA::AcctAgent;

# Inherit from AFA::DB, since we use AFA::DBI->do_transaction
# Methods in AFA::DB needs to be able to find it's methods within this class.
our @ISA = qw( AFA::DB );

=begin

$Id: JobAgent.pm,v 1.43 2006/08/15 05:56:04 scpham Exp $
$Author: scpham $
$Date: 2006/08/15 05:56:04 $
$Revision: 1.43 $

=cut

sub new {
  my $class = shift;
  my $self  = {};
  bless( $self, $class );
  $self->_init();
  return $self;
}

sub _init() {
  my ($self) = @_;
  $self->{db}     = AFA::DB->new();
  $self->{aagent} = AFA::AcctAgent->new();
  $self->{cec}    = CEC->new();
  $self->{job_return_queue} =  [];
  my $logger = $self->{logger} = get_logger('AFA::JobAgent');
  my $uri   = $afa_config{onramp_uri};
  my $proxy = $afa_config{onramp_proxy};
  $logger->debug("URI: $uri");
  $logger->debug("PROXY: $proxy");
  $self->{soap} = sub {
    my $method = shift;
    my @args   = @_;
    my $soap_server;
    eval {
      #local $SIG{__DIE__} = 'DEFAULT';
      $soap_server =
        SOAP::Lite->uri($uri)->proxy( $proxy, timeout => 100000 )->$method(@args);
    };
    if ($@) {
      $logger->fatal("Failed SOAP Call on method: $method");
      die $@;
    }
    if ( $soap_server->fault ) {
      $logger->error("Fault Encountered in SOAP CALL");
      $logger->error(
        join ( '|',
          $soap_server->faultcode, $soap_server->faultstring)
      );
      my $fault_detail = &Dumper($soap_server->faultdetail);
      # If something occurs on the recieving end we need to stamp jobs to
      # resend back when services are retored
      if( $method eq 'acct_job_report' ){
        my $jobs = $self->{jobs};
        foreach my $job(@$jobs){
          if( $job->status eq 'COMPLETED' ){
            $job->status('RESEND');
            $job->update;
          }
        }
      }
      die join("\n",$soap_server->faultstring,$fault_detail);
    }
    return $soap_server->result;
  };
  # Exit if there is another process running.
  open(SELF, "< $0") or die "Failed to open: $0\n";
  flock(SELF, LOCK_EX|LOCK_NB) or exit 1;
}

sub SOAP::Transport::HTTP::Client::get_basic_credentials {
  my $user = $afa_config{onramp_uua_soap_user};
  my $pass = $afa_config{onramp_uua_password};
  return ( $user, $pass );
}


=item B<requeueJob($job)>

Public Method. Method to requeue job. Recieves OnRamp Job Object.

=cut

sub requeueJob(){
  my( $self, $job ) = @_;
  my $logger = $self->{logger};
  my $db     = $self->{db};
  if( $job->{requeued} ){
    $logger->info("Requeue Requested By OnRamp");
  }
  foreach my $tid( @{ $job->{tasks} }){
    my $return_ref = $db->getRec('EAMS_Job_Queue',{jobid => $job->{job_id},
                                                   taskid => $tid});
    foreach my $row(@$return_ref){
      $row->status('QUEUED');
      $row->message('');
      $row->update;
      $logger->info("Requeued Job [" . $job->{job_id} . "] TaskID [" . $tid . "]");
    }
  }
}

=item B<getJobsFromOnRamp()>

Public Method. Queries OnRamp SOAP server for jobs to process.
Loads jobs into EAMS_Job_Queue.

=cut

sub getJobsFromOnRamp() {
  my ($self) = @_;
  my %jobs;
  my $logger = $self->{logger};
  my $job    = $self->{soap}->('next_acct_job');
  if( ref($job) ne 'HASH'  ) {
    $logger->info("No OnRamp Jobs Found");
    return 0;
  }
  $self->chkUTF($job);
  if( $job->{requeued} == 1 ){
    $logger->info("OnRamp Requesting Account Agent Requeue Job [" . $job->{job_id} . "]");
    $self->requeueJob($job);
    return 1;
  }
  my $work_area = $afa_config{job_agent_work_area};;
  if( ! -e $work_area ){
    $logger->debug("Creating Job Agent Work Area: $work_area");
    mkdir $work_area;
  }
  my $job_file = $work_area . "/job." . $job->{job_id};
  open(JOBFILE,">$job_file") || die " Can't open job file to write: $job_file\n";
  print JOBFILE Dumper($job);
  close JOBFILE;
  my $db = $self->{db};
  $logger->info( "Onramp Job ID: " . $job->{job_id} );
  foreach my $tid ( @{ $job->{tasks} } ) {
    $logger->info("Job $job->{job_id} Task ID: $tid");
    my $func      = $job->{data}->{$tid}->{func};
    my $user_args = $job->{data}->{$tid}->{args};
    my $username  = $user_args->{username};
    $user_args->{host} =~ s/\.cisco\.com$//;
    &dumpDebug( "TaskID: $tid User Args\n", $user_args );
    my $hostname = $db->getHostRecord( $user_args->{host} );
    
    my @userargs;
    while ( my ( $k, $v ) = each %$user_args ) {
      $v =~ s/'/`/g;
      push ( @userargs, "$k => \'$v\'" );
    }
    $self->chkUTF( \@userargs );
    $self->chkUTF( \$username );
    my $uargs_str = join ( ',', @userargs );
    $uargs_str = '{' . $uargs_str . '}';
    
    #Checkin for NO Operation FLAG
    my $NO_OP = $afa_config{no_op};
    if( $NO_OP ){
      $logger->info("NO OP Set: $NO_OP . skipping host validation check");
      $logger->info("Adding [" . $user_args->{host} . "]" . " as dummy host record");
      if ( $hostname eq undef ){
        $hostname = $db->find_or_add('EAMS_Hosts', {hostname => $user_args->{host},
                                                    platform => 'dummy',
                                                    shadowfile => 'Y'});
      }
    } 
    $db->loadJobToEAMS($username, $hostname, $job->{job_id}, $tid, $func, $uargs_str );
  }
  return 1;
}

=item B<getJobsFromEAMS()>

Public Method. Gets jobs that are 'queued' status in EAMS_Jobs_Queue.

=cut

sub getJobsFromEAMS() {
  my ($self) = @_;
  my $db       = $self->{db};
  my $logger   = $self->{logger};
  my $jobs_ref = $db->getEAMSJobs();
  if ( $jobs_ref and scalar @$jobs_ref ) {
    $logger->info( "EAMS Jobs to process: [" . @$jobs_ref . ']' );
    $logger->debug("Loaded Jobs into \$self->{jobs}");
    my ( %job_queue, %seen, @jobs_q_temp );
    foreach my $job (@$jobs_ref) {
      my $args = eval $job->userargs;
      if (exists $seen{ $job->hostname->hostname . ':' . $args->{username} } ){
        $self->{skipped_jobs}++;
        $logger->info("Skipping JobID [" . $job->jobid . "] TaskID [" . $job->taskid .
                       "] already performing 1 job for " . $args->{username} . " on host " . $args->{host});
        $logger->info("JobID [" . $job->jobid . "] TaskID [" . $job->taskid . "] Requeued");
        next;
      }
      # Lets set this flag right now, so no other agent picks it up.
      $job->status('PROCESSING');
      $job->update;
      my $user_key = join ( ':', $args->{username}, $args->{uid}, $args->{host} );
      $seen{ $job->hostname->hostname . ':' . $args->{username} }++;
      $job_queue{$user_key}{ $job->action }{ $job->jobid }{ $job->taskid } = $job;
      push ( @jobs_q_temp, $job );
    }
    $self->{jobs}      = \@jobs_q_temp;
    $self->{job_queue} = \%job_queue;
  }
  else {
    $logger->info("No Jobs to perform in EAMS");
  }
}

=item B<chkUTF($ref)>

Public Method. Takes array/hash/scalar ref as an arg. This chks and removes the UTF8 flag
if it's turned on. The reason why this is required is due to SOAP::Lite encoding in UTF8
for transport. This is currently a recursive method. This method will be revisited later,
to remove the recursion.

=cut

sub chkUTF() {
  my ( $self, $ref ) = @_;
  if ( ref($ref) eq 'ARRAY' ) {
    for (@$ref) {
      if ( ref($_) eq 'ARRAY' ) {
        $self->chkUTF($_);
      }
      elsif ( ref($_) eq 'HASH' ) {
        $self->chkUTF($_);
      }
      elsif ( ref($_) eq 'SCALAR' ) {
        $self->chkUTF($_);
      }
      else {
        $self->setUTF8( \$_ );
      }
    }
  }
  elsif ( ref($ref) eq 'HASH' ) {
    foreach ( values %$ref ) {
      if ( ref($_) eq 'ARRAY' ) {
        $self->chkUTF($_);
      }
      elsif ( ref($_) eq 'HASH' ) {
        $self->chkUTF($_);
      }
      elsif ( ref($_) eq 'SCALAR' ) {
        $self->chkUTF($_);
      }
      else {
        $self->setUTF8( \$_ );
      }
    }
  }
  elsif( ref($ref) eq 'SCALAR' ){
    $self->setUTF8( $ref );
  }
  else{
    $self->setUTF8( \$ref );
  }
}

=item B<setUTF8($string)>

Public Method. This method 'turns' off the UTF flag. Required due to SOAP::Lite and
UTF8 encoding. This is needed to load data into Oracle, when it comes from SOAP::Lite.
Since the XML is UTF-8 encoding.

=cut

sub setUTF8() {
  my ( $self, $string ) = @_;
  my $logger = $self->{logger};
  if ( is_utf8($$string) ) {

    #$logger->debug("Turning Off UTF8 flag for: $$string");
    _utf8_off($$string);

    #$logger->debug("Turning Off UTF8 flag for: $$string");
  }
}

=item B<doJob()>

=cut

sub doJob() {
  my ($self) = @_;
  my $logger   = $self->{logger};
  if ( !exists $self->{jobs} ) {
    $logger->info("No Jobs to perform: Have you ran getJobsFromEAMS method yet?");
    exit 1;
  }
  
  my $NO_OP    = $afa_config{no_op};
  
  my $jobs_ref = $self->{jobs};
  
  my $db       = $self->{db};

  my (
    %completed_jobs, %jobs_status,      %create_status,
    %change_status,  %case_status,      %hosts,
    %downed_hosts,   @job_return_queue, %host_jobs
  );
  $self->{job_return_queue} = \@job_return_queue;
  
  # Process the Job that is in EAMS for AFA.
  # This determines if it's only a DB change, which will trickle down to the host,
  # or if it's a request that requires retrieving information after the changes has
  # been pushed to the host (ie. Creating homedirs,shell changes).
  
  # Bypass Job Delivery function -- Used for testing profile loads.
  if( $NO_OP ){
    $logger->info("NO OP Set: $NO_OP . Loading into JOB Queue only");
    foreach my $eams_job(@$jobs_ref){
      $logger->info("Setting COMPLETED status for job[" . $eams_job->jobid . "] taskid[" .
                    $eams_job->taskid . "]");
      $eams_job->status("COMPLETED");
      $eams_job->update;
      my $ref = { task_id => $eams_job->taskid,
                  status  => '1' };
      push(@job_return_queue,$ref);
    }
    $logger->info("Uploading Job Statsu to OnRamp");
    $self->uploadJobStatusToOnRamp(\@job_return_queue);
    return;
  }
  
  foreach my $job_row (@$jobs_ref) {

    #$job_row->status('ACTIVE');
    #$job_row->update();
    $logger->debug( "Job for Hostname: " . $job_row->hostname->hostname );

    # Turn the userargs data in EAMS_Job_Queue back to a hash ref
    my $userargs = eval $job_row->userargs;

    #if ( $userargs->{TYPE} eq 'REGULAR' ) {
    #  delete $userargs->{TYPE};
    #}
    my $group;

    next if $self->chkUserArgs( $job_row, $userargs, \@job_return_queue );

    #my $user_key = $userargs->{username} . ':' . $userargs->{uid} . ':' . $userargs->{host};
    my $user_key =
      join ( ':', $userargs->{username}, $userargs->{uid}, $userargs->{host} );
    $logger->debug("First Creation of User Key: " . $user_key);
    my $action = $job_row->action;
    $logger->debug("Loading Job into Job Status: " . $user_key . " Action " .$action);
    $jobs_status{$user_key}{$action} = $job_row;
    if( exists $host_jobs{ $job_row->hostname->hostname } ){
      my $aref = $host_jobs{ $job_row->hostname->hostname };
      push(@$aref,$job_row);
      $host_jobs{ $job_row->hostname->hostname } = $aref;
    }
    else{
      my @array = ($job_row);
      $host_jobs{ $job_row->hostname->hostname } = \@array;
    }
    $hosts{ $job_row->hostname->hostname }{ $job_row->jobid . ':' . $job_row->taskid }++;

    delete $userargs->{TYPE} if $job_row->action ne 'createUser';

    if ( $job_row->action eq 'createUser' ) {
      $job_row->status('ACTIVE');
      $job_row->update();

      # Remove group key first, since CreateAcct does not use this key
      my $group;
      if ( exists $userargs->{group} ) {
        $group = $userargs->{group};
        delete $userargs->{group};
      }

      # Call this method, before adding the user to the group
      my %user_args = %$userargs;
      &dumpDebug("Calling doCreate with args:\n",$userargs);
      $self->doCreate( $job_row, $userargs, \%jobs_status );

      if ($group) {
        my $arg = { unixgroup => $group };
        $self->doAddGroup( $user_args{host}, $arg );
        my $ref = {
          unixgroup => $group,
          username  => $user_args{username},
          uidnum    => $user_args{uid}
        };
        $self->doAddUserToGroup( $user_args{host}, $ref );
      }
    }
    elsif ( $job_row->action eq 'deleteUser' ) {
      $job_row->status('ACTIVE');
      $job_row->update();
      $self->doDelete( $job_row->hostname->hostname, $userargs );
      $completed_jobs{$user_key}{ $job_row->action } = $job_row;
    }
    elsif ( $job_row->action eq 'changeShell' ) {
      $job_row->status('ACTIVE');
      $job_row->update();
      $self->doChangeShell( $job_row->hostname->hostname, $userargs );
    }
    elsif ( $job_row->action eq 'changeUsername' ) {
      $job_row->status('ACTIVE');
      $job_row->update();
      $self->doChangeUsername( $job_row->hostname->hostname, $userargs );
      $completed_jobs{$user_key}{ $job_row->action } = $job_row;
    }
    elsif ( $job_row->action eq 'changeUserHome' ) {
      $job_row->status('ACTIVE');
      $job_row->update();
      $self->doChangeUserHome( $job_row->hostname->hostname, $userargs );
    }
    elsif ( $job_row->action eq 'lockUser' ) {
      $job_row->status('ACTIVE');
      $job_row->update();
      $self->doLockUser( $job_row->hostname->hostname, $userargs );
      $completed_jobs{$user_key}{ $job_row->action } = $job_row;
    }
    elsif ( $job_row->action eq 'unlockUser' ) {
      $job_row->status('ACTIVE');
      $job_row->update();
      $self->doUnLockUser( $job_row->hostname->hostname, $userargs );
      $completed_jobs{$user_key}{ $job_row->action } = $job_row;
    }
    elsif ( $job_row->action eq 'addUserToGroup' ) {
      $job_row->status('ACTIVE');
      $job_row->update();
      $self->doAddUserToGroup( $job_row->hostname->hostname, $userargs );
      $completed_jobs{$user_key}{ $job_row->action } = $job_row;
    }
    elsif ( $job_row->action eq 'removeUserFromGroup' ) {
      $job_row->status('ACTIVE');
      $job_row->update();
      $self->doRemoveUserFromGroup( $job_row->hostname->hostname, $userargs );
      $completed_jobs{$user_key}{ $job_row->action } = $job_row;
    }
    elsif ( $job_row->action eq 'addGroup' ) {
      $job_row->status('ACTIVE');
      $job_row->update();
      $self->doAddGroup( $job_row->hostname->hostname, $userargs );
      $completed_jobs{$user_key}{ $job_row->action } = $job_row;
    }
    elsif ( $job_row->action eq 'deleteGroup' ) {
      $job_row->status('ACTIVE');
      $job_row->update();
      $self->doDeleteGroup( $job_row->hostname->hostname, $userargs );
      $completed_jobs{$user_key}{ $job_row->action } = $job_row;
    }
    elsif ( $job_row->action eq 'DefaultUserGroup' ) {
      $job_row->status('ACTIVE');
      $job_row->update();
      $self->doSetDefault( $job_row->hostname->hostname, $userargs );
      $completed_jobs{$user_key}{ $job_row->action } = $job_row;
    }
  }

  #Push changes to hosts.
  my $aagent = $self->{aagent};
  foreach my $host ( keys %hosts ) {
    my ( $res_ref, $err_ref ) = $aagent->deliverFiles($host);
    if ( scalar @$err_ref ) {
      $logger->error( "Error Received from $host: " . join ( "\n", @$err_ref ) );
      $downed_hosts{$host}++;
      next;
    }
    foreach my $line (@$res_ref) {
      my ( $type, $action, $data ) = split ( /:/, $line );
      if ( $type eq 'alert' ) {
        $logger->info( "Alert Received:" . $action . ':' . $data );
        if ( $action eq 'create' ) {
          $logger->debug("Alert Action Create Called");
          $self->alertCreate( $host, $data, \%create_status );
        }
        elsif ( $action eq 'changeshell' or $action eq 'changehome' ) {
          $self->alertChange( $host, $data, \%change_status );
        }
        elsif ( $action eq 'case' ) {
          $self->alertCase( $host, $data, \%case_status );
        }
        else{
          $logger->debug("Did not find any action");
        }
      }
      elsif ( $type eq 'debug' ) {

        # $action becomes the message field, if type eq debug
        $logger->debug( $host . ':' . $action );
      }
    }
  }
  #dumpDebug( "JOB_RETURN  ", \@job_return_queue );
$self->updateJobs(
      \%jobs_status,    \%create_status,    \%case_status,  \%change_status,
      \%completed_jobs, \@job_return_queue, \%downed_hosts, \%host_jobs
    );
  
  # Upload JOBS to ONRAMP
  $self->uploadJobStatusToOnRamp( \@job_return_queue );
  
  my $total_num_of_jobs = @{ $self->{jobs} };
  my $requeued_jobs_num = $self->{requeued_jobs};
  my $total = $total_num_of_jobs - $requeued_jobs_num;
  my $num_skipped_jobs = $self->{skipped_jobs};
  $logger->info("Number of jobs skipped: " . $num_skipped_jobs) if exists $self->{skipped_jobs};
  $logger->info("Number of jobs requeued: " . $requeued_jobs_num) if $requeued_jobs_num;
  $logger->info("Number of jobs processed: " . $total);
}

=item B<updateJobs( $job_status, $create_status, $case_status, $change_status, $job_return_q)>

=cut

sub updateJobs() {
  my (
    $self,             $jobs_status,   $create_status,
    $case_status,      $change_status, $completed_jobs,
    $job_return_queue, $downed_hosts,  $host_jobs
    )
    = @_;
  my $logger = $self->{logger};
  foreach my $d_host ( keys %$downed_hosts ) {
    $logger->error("Host $d_host unreachable....");
    my $host_jobs_array = $host_jobs->{$d_host} ;
    foreach my $j (@$host_jobs_array) {
      my $args = eval $j->userargs;
      my $user_key = join(':',$args->{username},$args->{uid},$args->{host});
      delete $jobs_status->{$user_key};
      $logger->info("Requeued JobID [" . $j->jobid . '] TaskID [' . $j->taskid . ']' .
                    ' for user ' . $args->{username} . ' on host ' . $args->{host});
      $j->status('QUEUED');
      $j->update();
      $self->{requeued_jobs}++;
    }
  }
  &dumpDebug("Completed Jobs Ref\n",$completed_jobs);
  #Update all jobs we know are successful
  #&dumpDebug("Completed Jobs Hash\n",$completed_jobs);
  foreach my $user_key ( keys %$completed_jobs ) {
    foreach my $action ( keys %{ $completed_jobs->{$user_key} } ) {
      my $job = $completed_jobs->{$user_key}{$action};
      $self->taskRef( $job, '1', $job_return_queue );
      $self->updateEAMSJob( $job, 'COMPLETED', '1',
        "Successfully Ran Job: " . $job->action );
      my($user,$uid,$host)=split(/:/,$user_key);
      $logger->info($job->action . " Successful for user " . $user . " on host " . $host);
    }
  }
  #&dumpDebug("Jobs Status Hash\n",$jobs_status);
  my %jb_seen;
  &dumpDebug("Job_status Ref\n",$jobs_status);
  &dumpDebug("Create Status Ref\n",$create_status);
  foreach my $user_key ( keys %$jobs_status ) {
    
    #next if exists $jb_seen{$user_key} ;
    #$jb_seen{$user_key}++;
    
    my ( $user, $uid, $host ) = split ( /:/, $user_key );

    my $job;
    my $db    = $self->{db};
    my $h_ref = {};
    $h_ref->{username} = $user;
    $h_ref->{uidnum} = $uid if defined $uid;
    my $passwd_entry = $db->getHostPasswdEntry( $host, $h_ref );

    #push (@job_return_queue, $self->createTaskStatusRef( $job_row->taskid, '1'));
    #$self->updateEAMSJob( $job_row, 'COMPLETED', '1', 'SuccessFully Unlocked User');
    if (  exists $create_status->{$user_key}{home}
      and exists $create_status->{$user_key}{shell}
      and exists $jobs_status->{$user_key}{createUser} )
    {
      $job = $jobs_status->{$user_key}{createUser};
      my $message = 'home ['
        . $create_status->{$user_key}{home} . '] -- '
        . 'shell ['
        . $create_status->{$user_key}{shell} . ']';

      $passwd_entry->status('ACTIVE');
      $passwd_entry->update();

      #Update Job Status for createUser
      
      $self->taskRef( $job, '1', $job_return_queue );
      $logger->info("Successfully created " . $user . " on host " . $host . ' for JobID [' . $job->jobid .
                    '] TaskID [' . $job->taskid . ']');
      $self->updateEAMSJob( $job, 'COMPLETED', '1', $message );
    }

    # Home doesn't exists, we will keep the account in 'NOTCREATED' status
    elsif ( exists $jobs_status->{$user_key}{createUser}
      and !exists $create_status->{$user_key}{home} )
    {
      &dumpDebug("Create_status ref for: $user_key\n",$create_status->{$user_key});
      $job = $jobs_status->{$user_key}{createUser};
      $logger->info("Job Failed to create home dir for " . $user . " on host " . $host);
      my $args = $case_status->{$user_key}{case};
      if ( !defined $job->message ) {
        $job->message( $args->{message} );
        $job->returncode('-1');
        $job->status('QUEUED');
        $logger->info("JobID [" . $job->jobid . "] TaskID [" . $job->taskid . "] Requeued");
      }
      else {
        if ( $self->checkJobDate($job) ) {
          $job->status('COMPLETED');
          $self->taskRef( $job, '-1', $job_return_queue, $args->{message},
            $args->{subject} );
          $logger->info("Too many failed attempts for job [" . $job->jobid . "] taskid [" . $job->taskid .           "] Setting to Completed Status");
        }
        else {
          $job->status('QUEUED');
          $logger->info("JobID [" . $job->jobid . "] TaskID [" . $job->taskid . "] Requeued");
        }
      }
      $job->update();
    }
    if ( exists $jobs_status->{$user_key}{changeHome} ) {
      $job = $jobs_status->{$user_key}{changeHome};
      if ( exists $change_status->{$user_key}{changehome} ) {
        $passwd_entry->status('ACTIVE');
        $passwd_entry->update();
        $self->taskRef( $job, '1', $job_return_queue );
        my $message = $change_status->{$user_key}{changeHome};
        $self->updateEAMSJob( $job, 'COMPLETED', '1', $message );
        $logger->info("Successfully changed home dir for " . $user . " on host " . $host);
      }
      elsif ( exists $case_status->{$user_key}{home} ) {
        my $args = $case_status->{$user_key}{case};
        if ( !defined $job->message ) {
          $job->message( $args->{message} );
          $job->returncode('-1');
          $job->status('QUEUED');
          $job->update();
        }
        else {
          if ( $self->checkJobStatus($job) ) {
            $job->status('COMPLETED');
            $self->taskRef( $job, '-1', $job_return_queue, $args->{message},
              $args->{subject} );
            
          }
          else {
            $job->status('QUEUED');
          }
        }
      }
    }
  }
}

=item B<checkJobDate($job)>

Method to Check job dates. If today's date is pass 7 days from job creation date, we will
close out the job.

=cut

sub checkJobDate() {
  my ( $self, $job ) = @_;
  my $today = &ParseDate("today");

  #  my $date_boundry = &DateCalc( $job->createddate(),"+1 days" );
  my $date_boundry = $job->created();
  my $date_flag = &Date_Cmp( $today, $date_boundry );
  if ( $date_flag < 0 ) {
    return 0;
  }
  elsif ( $date_flag == 0 ) {
    return 1;
  }
  else {
    return 1;
  }
}

=item B<doAddUserToGroup($host, $args)>

=cut

sub doAddUserToGroup() {
  my ( $self, $host, $args ) = @_;
  my $logger = $self->{logger};
  my @temp_args = ($host, $args);
  &dumpDebug("Calling doAddUserToGroup with args:\n",\@temp_args);
  my $result;
  eval {
    $result = AFA::DBI->do_transaction( \&AFA::DB::addUserToGroup, $self, $host, $args );
  };
  if ( $@ =~ /Transaction/ and $@ !~ /unique constraints/ ) {
    die $@;
  }
}

=item B<doRemoveUserFromGroup($host,$args)>

=cut

sub doRemoveUserFromGroup() {
  my ( $self, $host, $args ) = @_;
  my $logger = $self->{logger};
  my @temp_args = ($host,$args);
  &dumpDebug("Calling doRemoveUserFromGroup with args:\n",\@temp_args);
  my $result;
  eval {
    $result =
      AFA::DBI->do_transaction( \&AFA::DB::removeUserFromGroup, $self, $host, $args );
  };
  if ( $@ =~ /Transaction/ and $@ !~ /unique constraint/ ) {
    die $@;
  }
}

=item B<doAddGroup( $host,$args )>

=cut

sub doAddGroup() {
  my ( $self, $host, $args ) = @_;
  my $logger = $self->{logger};
  my @temp_args = ($host,$args);
  &dumpDebug("Calling doAddGroup with args:\n",\@temp_args);
  my $result;
  eval {
    $result = AFA::DBI->do_transaction( \&AFA::DB::addGroupToHost, $self, $host, $args );
  };
  if ( $@ =~ /Transaction/ and $@ !~ /unique constraint/ ) {
    die $@;
  }
}

=item B<doDeleteGroup($host,$args)>

=cut

sub doDeleteGroup() {
  my ( $self, $host, $args ) = @_;
  my $logger = $self->{logger};
  my @temp_args = ($host,$args);
  &dumpDebug("Called doDeleteGroup with args:\n",\@temp_args);
  my $result;
  eval {
    $result =
      AFA::DBI->do_transaction( \&AFA::DB::deleteGroupFromHost, $self, $host, $args );
  };
  if ( $@ =~ /Transaction/ and $@ !~ /unique constraint/ ) {
    die $@;
  }
}

=item B<alertCreate($host,$data,$create_status_ref)>

=cut

sub alertCreate() {
  my ( $self, $host, $data, $create_status_ref ) = @_;
  my ( $user, $uid, $category, $message, $val ) = split ( /\|/, $data );
  my $user_key = join ( ':', $user, $uid, $host );
  my $logger = $self->{logger};
  $logger->debug("alertCreate Data: " . $data);
  #my $user_key     = join(':',$user,$host);
  my $logger       = $self->{logger};
  my $db           = $self->{db};
  my $args         = { username => $user, uidnum => $uid };
  my $passwd_entry = $db->getHostPasswdEntry( $host, $args );
  $logger->debug("alertCreate Category: " . $category);
  if ( $category eq 'home' ) {
    $passwd_entry->home($val);
    $create_status_ref->{$user_key}{home} = $message;
  }
  elsif ( $category eq 'shell' ) {
    $passwd_entry->shell($val);
    $create_status_ref->{$user_key}{shell} = $message;
  }
  $passwd_entry->update();
}

=item B<alertChange($host,$data,$change_status_ref)>

=cut

sub alertChange() {
  my ( $self, $host, $data, $change_status_ref ) = @_;
  my ( $user, $uid, $category, $message, $val ) = split ( /\|/, $data );
  my $user_key = join ( ':', $user, $uid, $host );
  my $args         = { username => $user, uidnum => $uid };
  my $db           = $self->{db};
  my $passwd_entry = $db->getHostPasswdEntry( $host, $args );
  if ( $category eq 'changeshell' ) {
    $passwd_entry->shell($val);
    $change_status_ref->{$user_key}{changeshell} = $message;
  }
  elsif ( $category eq 'changehome' ) {
    $passwd_entry->home($val);
    $change_status_ref->{$user_key}{changehome} = $message;
  }
  $passwd_entry->update();
}

=item B<alertCase($host,$data,$case_status_ref)>

=cut

sub alertCase() {
  my ( $self, $host, $data, $case_status_ref ) = @_;
  my ( $user, $uid, $category, $subject, $message ) = split ( /\|/, $data );
  my $user_key = join ( ':', $user, $uid, $host );
  if ( $category eq 'home' ) {
    $case_status_ref->{$user_key}{case} = {
      subject => $subject,
      type    => $category,
      message => $message
    };
  }
}

=item B<doCreate($job_row, $userargs, $user_objs_ref, $job_return_queue_ref)>

Public Method. Creates Accounts in EAMS_Users table and in EAMS_User_Mapping.

=cut

sub doCreate() {
  my ( $self, $job_row, $userargs, $jobs_status ) = @_;
  my $logger = $self->{logger};
  my $db     = $self->{db};
  my $job_return_queue = $self->{job_return_queue};
  #&dumpDebug("doCreated Recieved Args:\n",$userargs);
  #&dumpDebug("doCreate Job Object:\n",$job_row);
  $userargs->{type}   = 'host';
  $userargs->{uidnum} = $userargs->{uid};
  delete $userargs->{uid};
  $userargs->{primarygid} = '25';
  $userargs->{hostname}   = $job_row->hostname->id;

  my $hostname = $userargs->{host};
  delete $userargs->{host};

  # This is done due to changing the values to the primary key id of the record in EAMS_Users
  my $username = $userargs->{username};
  my $uid      = $userargs->{uidnum};

  # Check for duplicate usernames
  my $host_record = $db->getHostRecord($hostname);
  my @users_rows = EAMS_Users->search( { username => $username } );
  foreach my $u (@users_rows) {
    my @return_rows =
      EAMS_User_Mapping->search( { hostname => $host_record->id, username => $u->id } );
    if ( scalar @return_rows ) {
      foreach my $r (@return_rows) {
        if ( $r->username->uidnum != $uid ) {
          #$r->status('NOTCREATED');
          #$r->update;
          &dumpDebug( "Duplicate Username Found\n", $r );
          $logger->debug( "Duplicate Username: ["
              . $r->username->username
              . "] with uid: ["
              . $r->username->uidnum .
              "] EMAN uid [" . $userargs->{uidnum} . "]");
          $logger->info("Account [$username] already exists on host [" . $host_record->hostname .
                        "] with a different uid then specified by EMAN");
          # Work around for duplicate usernames with different uid on the same host.
          my $olduserkey = join ( ':', $username, $uid, $hostname );
          #my $newuserkey =
           # join ( ':', $r->username->username, $r->username->uidnum, $hostname );
          #my $job_row_obj = $jobs_status->{$olduserkey}{createUser};
          #$jobs_status->{$newuserkey}{createUser} = $job_row_obj;
          delete $jobs_status->{$olduserkey}{createUser};
          $userargs->{uidnum} = $r->username->uidnum;
          
          $logger->debug("Setting Job status to 'COMPLETED' for JobID [" .
                         $job_row->jobid . "] TaskID [" .
                         $job_row->taskid . "]");
          $self->taskRef($job_row,'1',$job_return_queue);
          $job_row->status('COMPLETED');
          $job_row->message("Account Already Exists with different uid");
          $job_row->update;
          return;
        }

      }
    }
  }

  my $result;
  eval {
    my @result_ar =
      AFA::DBI->do_transaction( \&AFA::DB::createAcct, $self,
      $job_row->hostname->hostname, $userargs );
    $result = $result_ar[0];
  };
  if ( $@ =~ /Transaction/ and $@ =~ /ORA-00001: unique constraint/ ) {
    $logger->error("$@");
    my $passwd_entry = $db->getHostPasswdEntry(
      $hostname,
      {
        username => $username,
        uidnum   => $uid
      }
    );

    #Reset flag to 'NOTCREATED'. This will force the account to re-process itself
    #$passwd_entry->status('NOTCREATED');

    $logger->info( "Account Already Exist - Setting Job Status flag to 'COMPLETED' for ["
                  . $passwd_entry->username->username . "] on host ["
                  . $passwd_entry->hostname->hostname  . "] with JobID["
                  . $job_row->jobid . "] TaskID["
                  . $job_row->taskid . "]");

    #$passwd_entry->update;
    $self->taskRef($job_row,'1',$job_return_queue);
    $job_row->status('COMPLETED');
    $job_row->message('Account Already Exists');
    $job_row->update;
    return;
  }
  else {
    $logger->info( "Created Account " . $result->username->username . " on host " .
                  $result->hostname->hostname . " With Record ID: " . $result->id .
                  " for JobID [" . $job_row->jobid . '] TaskID [' . $job_row->taskid . ']');
    $result->status('NOTCREATED');
    $result->hash( $self->getPassword($username) );
    $result->update();
  }
}

=item B<doDelete( $host, $hash_ref )>

=cut

sub doDelete() {
  my ( $self, $host, $userargs ) = @_;
  my $logger = $self->{logger};
  my @temp_args = ($host,$userargs);
  &dumpDebug("Calling doDelete with ARGS:\n",\@temp_args);
  #my $db = $self->{db};
  my ( $ret, $msg );
  eval {
    my @temp =
      AFA::DBI->do_transaction( \&AFA::DB::deleteUserFromHost, $self, $host, $userargs );
    $ret = $temp[0];
  };
  if ($@) {
    die $@;
  }
  if ($ret) {
    $msg = "Successfully deleted " . $userargs->{username} . " from " . $host;
    $logger->info($msg);
  }
  else {
    $msg =
      "Failed to delete " . $userargs->{username} . " from " . $host . " no record found";
    $logger->info($msg);
  }
  return $msg;
}

=item B<doChangeShell( $job_row, $host, $hash_ref )>

=cut

sub doChangeShell() {
  my ( $self, $job_row, $host, $userargs ) = @_;
  my $logger = $self->{logger};
  my @temp = ($host,$userargs);
  &dumpDebug("Calling doChangeShell with args:\n",\@temp);
  #my $db = $self->{db};
  my ($ret);
  eval { AFA::DBI->do_transaction( \&AFA::DB::changeShell, $self, $host, $userargs ); };
  if ( $@ =~ /Transaction/ and $@ =~ /ORA-00001: unique constraint/ ) {
    $logger->error($@);
  }
  elsif ($@) {
    die $@;
  }
}

=item B<doSetDefaultGroup( $host, $hash_ref )>

=cut

sub doSetDefaultGroup() {
  my ( $self, $host, $args ) = @_;
  my $logger = $self->{logger};
  my $result;
  eval {
    $result = AFA::DBI->do_transaction( \&AFA::DB::setDefaultGroup, $self, $host, $args );
  };
  if ( $@ =~ /Transaction/ and $@ !~ /unique constraint/ ) {
    die $@;
  }
}

=item B<doChangeUsername( $hash_ref )>

=cut

sub doChangeUsername() {
  my ( $self, $userargs ) = @_;
  my $logger = $self->{logger};
  my ( $ret, $msg );
  eval { AFA::DBI->do_transaction( \&AFA::DB::changeUsername, $self, $userargs ); };
  if ( $@ =~ /Transaction/ and $@ =~ /ORA-00001: unique constraint/ ) {
    $logger->error($@);
    $msg = "Successfully changed username";
  }
  elsif ($@) {
    $logger->fatal($@);
    $msg = 'Failed to change username';
  }
  return $msg;
}

=item B<doChangeUserHome($host, $hash_ref )>

=cut

sub doChangeUserHome() {
  my ( $self, $host, $userargs ) = @_;
  return 1 if $userargs->{TYPE} ne 'GENERIC';
  my $logger = $self->{logger};
  delete $userargs->{TYPE};
  delete $userargs->{host};
  eval { AFA::DBI->do_transaction( \&AFA::DB::changeUserHome, $self, $host, $userargs ); };
  if ($@) {
    $logger->error($@);
  }
}

=item B<doLockUser( $host, $hash_ref )>

=cut

sub doLockUser() {
  my ( $self, $host, $userargs ) = @_;
  my $logger = $self->{logger};
  my @temp_args = ($host,$userargs);
  &dumpDebug("Called doLockUser with args:\n",\@temp_args);
  eval { AFA::DBI->do_tansaction( \&AFA::DB::lockUser, $self, $host, $userargs ); };
  if ($@) {
    $logger->error($@);
  }
}

=item B<doUnLockUser( $host, $hash_ref )>

=cut

sub doUnLockUser() {
  my ( $self, $host, $userargs ) = @_;
  my $logger = $self->{logger};
  my @temp_args = ($host,$userargs);
  &dumpDebug("Called doUnLockUser with args:\n",\@temp_args);
  eval { AFA::DBI->do_transaction( \&AFA::DB::unlockUser, $self, $host, $userargs ); };
  if ($@) {
    $logger->error($@);
  }
}

=item B<updateEAMSJob( $job_obj, $status, $returncode, $message )>

=cut

sub updateEAMSJob() {
  my ( $self, $job, $status, $returncode, $message ) = @_;
  my $logger = $self->{logger};
  $job->status($status);
  $job->returncode($returncode);
  $job->message($message);
  EAMS_Job_Queue->sql_set_completed()->execute( $job->id );
  $logger->info( "Updating EAMS JobID [" . $job->jobid . "] TaskID [" . $job->taskid . ']');
  $job->update;
}

=item B<uploadJobStatusToOnRamp( $job_obj )>

=cut

sub uploadJobStatusToOnRamp() {
  my ( $self, $job_q_ref ) = @_;
  my $logger = $self->{logger};
  $self->resendJobs();
  &dumpDebug("Job Status Stack To Upload to OnRamp\n",$job_q_ref);
  my $ret;
  if ( scalar @$job_q_ref ) {
    $logger->info("Uploading jobs status to OnRamp");
    $ret = $self->{soap}->( 'acct_job_report', $job_q_ref );
    if ($ret) {
      $logger->error("Received Error from OnRamp while calling acct_job_report");
      $logger->error("Job Server Reported Error: $ret");
    }
    else {
      $logger->info("Upload Successful");
    }
    return;
  }
  $logger->info("Upload jobs called, but nothing to upload");
}

=item B<resendJobs()>

=cut

sub resendJobs(){
  my ($self) = @_;
  my $logger = $self->{logger};
  $logger->debug("Checking If there are jobs with 'RESEND' status");
  my @resend_rows = EAMS_Job_Queue->search_resend();
  if( scalar @resend_rows ){
    $logger->info("Found jobs to resend");
  }
  else{
    $logger->info("No Jobs with 'RESEND' flag found");
    return;
  }
  my @resend_job_stack = ();
  foreach my $r_job(@resend_rows){
    my $ref = { status => $r_job->status,
                error_code => $r_job->returncode
              };
    if( defined $r_job->message ){
      $ref->{error_msg} = $r_job->message;
    }
    $logger->info("Adding JobID [" . $r_job->jobid . "] TaskID [" . $r_job->taskid .
                   "] to resend job return stack");
    push(@resend_job_stack,$ref);
  }
  &dumpDebug('Resend Job Return Stack',\@resend_job_stack);
  my $ret = $self->{soap}->('acct_job_report',\@resend_job_stack);
  if($ret){
    $logger->error("Received Error from OnRamp while calling acct_job_report");
    $logger->error("Job Server Reported Error: $ret");
  }
  else{
    $logger->info("Successfully Uploaded Jobs with 'RESEND' Status");
    foreach my $j(@resend_rows){
      $j->status('COMPLETED');
      $j->update;
    }
  }
}
                
  
=item B<createTaskReturn()>

=cut

sub taskRef() {
  my ( $self, $job, $status, $job_return_queue, $message, $subject ) = @_;
  my %task;
  my $hostname = $job->hostname->hostname;
  my $taskid   = $job->taskid;
  $task{'status'}  = $status;
  $task{'task_id'} = $taskid;
  my $logger = $self->{logger};
  my $db     = $self->{db};
  my ( $support_cti, $support_email, $alert_type );

  if ( $status == -1 ) {
    $support_cti = $db->getCTI($hostname);
    $alert_type  = 'case';
  }
  elsif ( $status == 0 ) {
    $support_cti = $db->getCTI($hostname);
    $alert_type  = $db->getSupportEmail($hostname);
  }

  if ( $status != 1 ) {
    my $error_code = join ( ':', $alert_type, $support_cti, $subject );
    $task{error_msg}  = $message;
    $task{error_code} = $error_code;
  }
  #&dumpDebug( "TASKREF\n", \%task );
  push ( @$job_return_queue, \%task );
}

=item B<getPassword()>

Stub method right now

=cut

sub getPassword() {
  my ( $self, $username ) = @_;
  my $cec      = $self->{cec};
  my $password = $cec->getPassword($username);
  if ( !$password ) {
    $password = 'NOPASSWD';
  }
  return $password;
}

=item B<chkUserArgs($func,$user_ref)>

Public Method. Checks ARGS from OnRamp to verify that all requird args for a certain function is met.

=cut

sub chkUserArgs() {
  my ( $self, $job_row, $user_ref, $job_return_queue ) = @_;
  my $status;
  my $logger =  $self->{logger};
  $logger->debug((caller(0))[3]);
  &dumpDebug( "JOB Object:\n", $job_row );

  if ( $user_ref->{TYPE} eq 'GENERIC' ) {
    if ( !exists $user_ref->{home} ) {
      $self->taskRef(
        $job_row, '0', $job_return_queue,
        'Type is set to Generic, but no home was specified for JobID[' . $job_row->jobid .
        '] TaskID[' . $job_row->jobid . ']',
        'No Home Specified for Generic Account ' . $user_ref->{username} . ' on host ' . $user_ref->{host}
      );
      
      $self->updateEAMSJob( $job_row, 'COMPLETED', '0',
        'No Home Specified for Generic Account' . $user_ref->{username} . ' on host ' . $user_ref->{host});
      $status = 1;
    }
    else{
      if( $user_ref->{home} =~ /(^\/bin|^\/sbin|^\/usr|^\/etc|^\/root|^\/dev|
                                 ^\/lib|^\/proc|^\/boot|^\/tmp|^\/mnt|
                                 ^\/misc|^\/var|^\/stand)/){
        $self->taskRef( $job_row, '0', $job_return_queue,
                       "System directory specifed for home dir: " . $1,
                       "System directory specified for JobID[" . $job_row->jobid . '] TaskID[' .
                       $job_row->taskid . ']');
        $self->updateEAMSJob( $job_row, 'COMPLETED', '0',
                               'Username [' . $user_ref->{username} .
                               '] Home Directory [' . $user_ref->{home} . ']');
        $status = 1;
      }
    }
  }
  if ( !exists $user_ref->{desc} ) {
    $user_ref->{gecos} = uc $user_ref->{username};
  }
  else {
    $user_ref->{gecos} = $user_ref->{desc};
    delete $user_ref->{desc};
  }
  if ( exists $user_ref->{uid} and $user_ref->{uid} !~ /^[0-9]+$/ ) {
    $self->taskRef(
      $job_row, '0', $job_return_queue,
      'Malformed UID Recieved',
      "Invalid UID specified: $user_ref->{uid} for taskid: " . $job_row->taskid
    );
    $self->updateEAMSJob( $job_row, 'COMPLETED', '0',
      "MalFormed UID: " . $user_ref->{uid} );
    $status = 1;
  }
  if ( exists $user_ref->{uid} and $user_ref->{uid} <= 10 ) {
    $self->taskRef(
      $job_row,
      '0',
      $job_return_queue,
      "Priviledged UID Supplied: " . $user_ref->{uid} . " for taskid " . $job_row->taskid,
      'Priviledged UID Supplied'
    );
    $self->updateEAMSJob( $job_row, 'COMPLETED', '0',
      "UID supplied is reserved: " . $user_ref->{uid} );
    $status = 1;
  }
  if ( !exists $user_ref->{username} or !exists $user_ref->{uid} ) {
    $self->taskRef(
      $job_row, '0', $job_return_queue,
      "Username or UID not specified for JobID[" . $job_row->jobid . "] TaskID[" . $job_row->taskid . "]\n"       . "Username: " . $self->{username} . " Uid: " . $self->{uid},
      'Username or UID not specified for JobID[' . $job_row->jobid . '] TaskID[' . $job_row->jobid . ']'
    );
    $self->updateEAMSJob( $job_row, 'COMPLETED', '0', 'Username/UID not specified' );
    $status = 1;
  }
  if ( $user_ref->{username} =~ /\W/ and $user_ref->{username} !~ /\-|\_/ ) {
    $self->taskRef(
      $job_row, '0', $job_return_queue,
      'Invalid Character found in username ' . $user_ref->{username},
      'Invalid Character Found in Username'
    );
    $self->updateEAMSJob( $job_row, 'COMPLETED', '0',
      'Invalid Character Found in Username' );
    $status = 1;

  }
  my @regex_ary = qw/home shell desc username gecos/;
  foreach my $keyname(@regex_ary){
    if( exists $user_ref->{$keyname}){
      if( $user_ref->{$keyname} =~ /\:|\||\*/ ){
        $self->taskRef($job_row, '0', $job_return_queue,
                       "Invalid character found in user key [" . $keyname .
                       "] JobID [" . $job_row->jobid . " TaskID [" . $job_row->taskid . "] Username [" .
                       $user_ref->{username} . "] on host [" . $user_ref->{host},
                       "Invalid character found in user key [" . $keyname .
                       "] JobID [" . $job_row->jobid . " TaskID [" . $job_row->taskid . "]");
        
        $self->updateEAMSJob( $job_row, 'COMPLETED', '0',
                             "Invalid character found in user key [" . $keyname .
                       "] JobID [" . $job_row->jobid . " TaskID [" . $job_row->taskid . "] Username [" .
                       $user_ref->{username} . "] on host [" . $user_ref->{host} );
        $status = 1;
        last;
      }
    }
  }
  
  $user_ref->{uidnum} = $user_ref->{uid};
  return $status;

}

sub loadJobs() {
  my ( $self, $filename, $key ) = @_;
  my $result = $self->{soap}->( 'load_acct_test', $filename, $key );
}

1;

