package AFA::DB;
use strict;
use Exporter;
use Date::Manip qw(ParseDate UnixDate);
use Data::Dumper;
use lib '..';
use AFA::Logger;
use AFA::DBI;
use CEC;

=begin comment

$Id: DB.pm,v 1.45 2006/08/17 05:50:23 scpham Exp $
$Revision: 1.45 $
$Date: 2006/08/17 05:50:23 $
$Author: scpham $

=end comment

=head1 NAME

EAMS Account Fullfillment DB API

=cut

=head2 Available Methods

=over 12

=item B<new()>

Public method for Object instantiation
Returns $self

=cut

sub new {
  my $class = shift;
  my $self  = {
    host  => {},
    users => {}
  };
  bless( $self, $class );
  $self->{logger} = get_logger("AFA::DB");
  # Required to avoid looping
  # CEC module uses AFA::DB.
  if( ! $CEC::INIT ){
    $self->{cec} = CEC->new();
  }
  return $self;
}

=item B<find_or_add($table,$hash_ref)>

Method to add records to AFA.
Returns $rec object(row)

=cut

sub find_or_add() {
  my ( $self, $table, $href ) = @_;
  my $logger = $self->{logger};
  $logger->debug((caller(1))[3] . " calling " . (caller(0))[3]);
  #&dumpDebug( "Table: $table\n", $href );
  
  $self->checkHRef($href);
  #$logger->info( "Retrieving or Creating Record for Table $table with args:" . %$href );

  my $rec = $table->find_or_create($href);
  return $rec;
}

=item B<getUserHostEntries($username,$hostname)>

=cut

sub getUserHostEntries(){
  my ( $self, $username, $hostname ) = @_;
  my $logger = $self->{logger};
  my $host_record;
  if($hostname){
    $host_record = $self->getHostRecord($hostname);
    if(! $host_record){
      $logger->info("No Host Record found for host [$hostname]");
      print "No Host Record found for host [$hostname]\n";
      return [];
    }
  }
  my @records;
  my $user_records = $self->getRec('EAMS_Users', { username => $username });
  foreach my $u(@$user_records){
    if(!$hostname){
      push(@records,EAMS_User_Mapping->search({username => $u->id}));
    }
    else{
      push(@records,EAMS_User_Mapping->search({username => $u->id,
                                               hostname => $host_record->id}));
    }
  }
  if(! scalar @records > 0){
    $logger->info("No Records found for [$username]");
  }
  else{
    &dumpDebug("getUserHostEntries\n",\@records);
  }
  return \@records;
}

=item B<getRec($table,$hash_ref)>

Method retrieves records from EAMS.
returns array ref containing objects (row)

=cut

sub getRec() {
  my ( $self, $table, $href ) = @_;
  my $logger = $self->{logger};
  $logger->debug((caller(1))[3] . " calling " . (caller(0))[3]);
  #&dumpDebug( "Table: $table\n", $href );
  $self->checkHRef($href);
  my @rec = $table->search($href);
  return \@rec;
}

=item B<create($table,$hash_ref)>

Public Method to create records.
Returns row object

=cut

sub create() {
  my ( $self, $table, $href ) = @_;
  $self->checkHRef($href);
  my $rowobj = $table->create($href);
  return $rowobj;
}

=item B<getHostRecord($host)>

Public Method to retrieve host record from EAMS_Hosts table.
Returns row object.

=cut

sub getHostRecord() {
  my ( $self, $host ) = @_;
  die "Method requires hostname as an arg" if !defined $host;
  my $logger = $self->{logger};
  if ( exists $self->{host}->{$host} ) {
    return $self->{host}->{$host};
  }

  my $host_ref = $self->getRec( 'EAMS_Hosts', { hostname => $host } );
  if ( scalar @$host_ref == 1 ) {
    $logger->debug( "Host Record Found for " . $host_ref->[0]->hostname );
    $self->{host}->{$host} = $host_ref->[0];
    return $host_ref->[0];
  }
  elsif ( scalar @$host_ref > 1 ) {
    die "Found more then one record for host: $host";
  }
  else {
    $logger->error("No Record for $host found");
  }
  return undef;
}

=item B<getCTI($host)>

Public Method. Returns Support Group CTI

=cut

sub getCTI() {
  my ( $self, $host ) = @_;
  my $host_rec = $self->getHostRecord($host);
  if ( !$host_rec ) {
    die "No Host Record Found, while determining Support CTI";
  }
  my $support_group = $host_rec->support_group->cti;
  return $support_group;
}

=item B<getSupportEmail($host)>


=cut

sub getSupportEmail($host) {
  my ( $self, $host ) = @_;
  my $host_rec = $self->getHostRecord($host);
  if ( !$host_rec ) {
    die "No Host Record Found, while determining Support Email";
  }
  my $support_email = $host_rec->support_group->email;
  return $support_email;
}

=item B<setStatusDisable($host,$user_hash_ref)>

Public method to set status flag to disable. When flag is set to disable, user does not
get populated in /etc/passwd on the target host.
Requires hash ref as arg {username => 'scpham',uidnum => 12345}.

=cut

sub setStatusToDisable() {
  my ( $self, $host, $userargs ) = @_;
  my $passwd_entry = $self->getHostPasswdEntry(
    $host,
    {
      username => $userargs->{username},
      uidnum   => $userargs->{uidnum}
    }
  );
  $passwd_entry->status('DISABLED');
  $passwd_entry->update();
}

=item B<deleteUserFromHost($host,{username => 'scpham',uidnum => 12345})

Public method to delete passwd entry on target host for specified user.
Returns 0 when nothing is deleted. Returns 1 when delete is successfull.

=cut

sub deleteUserFromHost() {
  my ( $self, $host, $userargs ) = @_;
  die "Missing Arg:" if !$host or !scalar keys %$userargs;
  my $logger       = $self->{logger};
  my $passwd_entry = $self->getHostPasswdEntry(
    $host,
    {
      username => $userargs->{username},
      uidnum   => $userargs->{uidnum}
    }
  );
  
  if ( !$passwd_entry ) {
    
    $logger->info( "No Entry Found to Delete: "
        . $userargs->{username}
        . " not on "
        . $host );
    return 0;
  }
  
  $logger->info( "Deleted "
      . $passwd_entry->username->username
      . " from "
      . $passwd_entry->hostname->hostname );

  my @groups_rows =
    EAMS_Group_Mapping->search(
    { hostname => $passwd_entry->hostname->id, username => $passwd_entry->username->id }
    );
  foreach my $g (@groups_rows) {
    $logger->debug( "Removing "
        . $g->username->username
        . " from group "
        . $g->groupname->groupname . " on "
        . $passwd_entry->hostname->hostname );
    $g->delete;
  }
  $passwd_entry->delete;
  return 1;
}

=item B<getHostEntryByUsername($host,$username)>

Public Method to retrieve host password entry by username only

=cut

sub getHostEntryByUsername(){
  my($self, $host, $username ) = @_;
  my $logger = $self->{logger};
  my $host_record = $self->getHostRecord($host);
  if( ! $host_record ){
    $logger->info("Host Record not found in EAMS [$host]");
    return undef;
  }
  my @records = EAMS_User_Mapping->search( {hostname => $host_record->id} );
  foreach my $row ( @records ){
    if( $row->username->username eq $username ){
      $logger->debug("Host Record Found for User: " . $row->username->username . " on host " . $host);
      return $row;
    }
  }
  $logger->info("Did not find user " . $username . " on host " . $host);
  return undef;
}
  

=item B<getHostPasswdEntry($host, {username => 'scpham',uidnum => 12345})>

Public Method to retrieve passwd entry on target host.
Returns row object.

=cut

sub getHostPasswdEntry() {
  my ( $self, $host, $userargs ) = @_;
  my $logger   = $self->{logger};
  my $host_obj = $self->getHostRecord($host);

  my ( $user_obj, $found_status ) = 0;
  if ( exists $userargs->{uidnum} ) {
    $user_obj = $self->getUserRecord($userargs);
    if ($user_obj) {
      $logger->debug( "Getting Passwd Entry for "
          . $user_obj->username . " on "
          . $host_obj->hostname );
      my $temp_ref = $self->getRec(
        'EAMS_User_Mapping',
        {
          hostname => $host_obj->id,
          username => $user_obj->id
        }
      );
      if ( scalar @$temp_ref ) {
        return $temp_ref->[0];
      }
      else {
        $logger->debug("Calling getHostEntryByUsername from getHostPasswdEntry");
        my $row = $self->getHostEntryByUsername($host,$userargs->{username});
        $logger->debug("Done Calling getHostEntryByUsername");
        return $row;
      }
    }
    else {
      $logger->debug("User " . $userargs->{username} . " not found on " . $host);
      return undef;
    }

  }
  else {
    my $row = $self->getHostEntryByUsername($host, $userargs->{username});
    if(!$row){
      $logger->info("User " . $userargs->{username} . " not found on " . $host);
    }
    return $row;
  }
}

=item B<getUserRecord({username => 'scpham', uidnum => 12345});

Public method for retrieving user record from EAMS_Users.
Returns row object.

=cut

sub getUserRecord() {
  my ( $self, $userargs ) = @_;
  my $logger   = $self->{logger};
  my $user_key = $userargs->{username} . ':' . $userargs->{uidnum};
  if ( exists $self->{user}->{$user_key} ) {
    #$logger->info( "Found User in CACHE: " . $userargs->{username} );
    return $self->{user}->{$user_key};
  }
  my $temp_ref = $self->getRec(
    'EAMS_Users',
    {
      username => $userargs->{username},
      uidnum   => $userargs->{uidnum}
    }
  );
  if ( scalar @$temp_ref ) {
    $logger->debug( "User Record Found:" . $temp_ref->[0]->username );
    $self->{user}->{$user_key} = $temp_ref->[0];
    return $temp_ref->[0];
  }
  else {
    return undef;
  }
}

=item B<getHostType($type)>

Public method to retrieve 'type' record from EAMS_Host_Type.
types are 'host','cec'.
Returns row object.

=cut

sub getHostType() {
  my ( $self, $type ) = @_;
  my $logger = $self->{logger};
  my $temp_ref = $self->getRec( 'EAMS_Host_Type', { type => $type } );
  if ( scalar @$temp_ref ) {
   # $logger->debug( "Host Type Found:" . $temp_ref->[0]->type );
    return $temp_ref->[0];
  }
}

=item B<loadJobToEAMS($host_obj,$jobid,$taskid,$func,$userargs)>

Public Method, loads job to EAMS - EAMS_Job_Queue

=cut

sub loadJobToEAMS() {
  my ( $self, $username, $host_obj, $jobid, $taskid, $func, $userargs ) = @_;
  my $logger = $self->{logger};

  #&dumpDebug("addJob\n",$userargs);
  my $ref = {
    hostname => $host_obj->id,
    jobid    => $jobid,
    taskid   => $taskid,
    action   => $func,
    status   => 'QUEUED',
    userargs => "$userargs",
    username => $username
  };
  my $result = $self->create( 'EAMS_Job_Queue', $ref );
  if ( defined $result ) {
    $logger->debug( "Added new EAMS JobID ["
        . $result->id . ']> '
        . $func . ' -- '
        . $result->userargs );
  }
  else {
    $logger->error("Failed to Add Job");
  }
}

=item B<getEAMSJobs()>

Public Method. This method retrieves all jobs from EAMS_Job_Queue with a status of 'QUEUED'

=cut

sub getEAMSJobs() {
  my ($self) = @_;
  my $logger = $self->{logger};
  my @jobs_ar = EAMS_Job_Queue->search( status => 'QUEUED', { order_by => 'id ASC' } );
  if ( scalar @jobs_ar ) {
    &dumpDebug( "EAMS Jobs\n", \@jobs_ar );
    return \@jobs_ar;
  }
  else {
    $logger->debug("No Jobs to Process in EAMS");
  }
  return;
}

=item B<getAllRecs($table)>

Method retrieves all rows in specified table
Returns array ref containing objects(row)

=cut

sub getAllRecs() {
  my ( $self, $table ) = @_;
  die "No Table Specified\n" if !defined $table;
  my @recs = $table->retrieve_all();
  my $logger = $self->{logger};
  $logger->debug((caller(1))[3] . " calling " . (caller(0))[3]);
 # &dumpDebug( "Table: $table\n", \@recs );
  return \@recs;
}

=item B<getSysAccts()>

Method retrieves all system accounts in EAMS_System_Accounts Table
Returns hash ref containing list of user names

=cut

sub getSysAccts() {
  my ($self) = @_;
  my $logger = $self->{logger};
  $logger->debug("Retrieving System Accounts");
  my %hash;
  my @rows = EAMS_System_Accounts->search_distinct_sysaccts();
  foreach my $r (@rows) {
    $hash{ $r->username }++;
  }
  return \%hash;
}

=item B<getGroupnames()>

Public method. Retrieves groupnames from group name table in EAMS
returns array ref

=cut

sub getGroupnames() {
  my ($self) = @_;
  my (%hash);
  my $sysaccts_ref = $self->getSysAccts();
  my @rows         = EAMS_Groups->search_distinct_groupnames();
  &dumpDebug( "getGroupnames\n", \@rows );
  foreach my $r (@rows) {
    next if exists $sysaccts_ref->{ $r->groupname };
    $hash{ $r->groupname }++;
  }
  my @ar = sort keys %hash;
  return \@ar;
}

=item B<getHostPasswdFile($host)>

Method retrieves entries from EAMS_User_Mapping Table.
It then formats the entries to be used to dist the passwd file
Returns array ref

=cut

sub getHostPasswdFile() {
  my ( $self, $host ) = @_;
  my $logger = $self->{logger};
  $logger->debug("Retrieving Host Records: $host");

  #my $aref = $self->getRec( 'EAMS_Hosts', { hostname => $host } );
  my $sysacctsref = $self->getSysAccts();
  my ( @results, @top, @bottom, %sysaccts_hash );

  #foreach my $host (@$aref) {
  #my $passwd = $self->getRec( 'EAMS_User_Mapping', { hostname => $host->id } );
  my @passwds = EAMS_User_Mapping->search_passwd_entries($host);
  foreach my $p (@passwds) {
    my @array = ();
    push ( @array, $p->username );
    push ( @array, $p->{hash} );
    push ( @array, $p->{uidnum} );
    push ( @array, $p->{primarygid} );
    push ( @array, $p->{gecos} );
    push ( @array, $p->{home} );
    push ( @array, $p->{shell} );
    push ( @array, $p->{status} );
    push ( @array, $p->{hostname} );
    my $epoch;

    if ( exists $p->{modifydate} ) {
      $epoch = $self->convertEpoch( $p->{modifydate} );
    }
    elsif ( exists $p->{createddate} ) {
      $epoch = $self->convertEpoch( $p->{createddate} );
    }
    push ( @array, $epoch );
    my $temp_str = join ( ':', @array );

    if ( exists $sysacctsref->{ $p->{username} } ) {
      $sysaccts_hash{ $p->{uidnum} } = $temp_str;
    }
    else {
      push ( @bottom, $temp_str );
    }
  }

  my @tmp_ids = sort { $a <=> $b } keys %sysaccts_hash;
  my $sorted_ids = $self->reorderArray( \@tmp_ids );
  foreach my $num (@$sorted_ids) {
    push ( @top, $sysaccts_hash{$num} );
  }
  push ( @results, @top );
  push ( @results, @bottom );
  die "No Password Records found for $host" if !scalar @results;
  return \@results;
}

sub buildPasswdFile() {
  my ( $self, $host ) = @_;
  my @passwd_entries = EAMS_User_Mapping->search_passwd_entries($host);
  foreach my $p (@passwd_entries) {
    print $p->username . ':' . $p->{uidnum}, "\n";

  }
}

=item B<convertEpoch($date)>

Date format in any format Date::Manip can handle.
Returns epoch time in days from Jan 1 1970

=cut

sub convertEpoch() {
  my ( $self, $date ) = @_;
  my $logger = $self->{logger};
  $date = $date . '-00:00:00';
  my @array = split ( /-/, $date );
  $date = &ParseDate( \@array );
  my $epoch = &UnixDate( $date, "%s" );

  #my $rounded = int( $epoch / 86400 ) + 1;
  my $rounded = int( $epoch / 86400 );

  #  $logger->debug("Converted $date to epoch in days: $rounded");
  return $rounded;
}

=item B<updateAcct($rowobj,$col_href)>

Public method for updating rows
requires hash ref.

=cut

sub updateAcct() {
  my ( $self, $rowobj, $col_href ) = @_;
  die "row object or column hash ref missing\n"
    if ( !$rowobj or ref($col_href) ne 'HASH' );
  foreach my $column ( keys %$col_href ) {
    $rowobj->$column( $col_href->{$column} );
  }
  $rowobj->update();
}

=item B<changeShell($host,{username => 'scpham',uid => 12345,newshell => '/bin/ksh'})>

Public Method to change user shell. method sets status flag to CHANGESHELL.

=cut

sub changeShell() {
  my ( $self, $host, $userargs ) = @_;
  my $logger   = $self->{logger};
  my $newshell = $userargs->{newshell};
  delete $userargs->{CASE};
  delete $userargs->{newshell};
  delete $userargs->{TYPE};
  $userargs->{uidnum} = $userargs->{uid};
  delete $userargs->{uid};
  delete $userargs->{shell};
  my $passwd_entry = $self->getHostPasswdEntry( $host, $userargs );
  $passwd_entry->shell($newshell);
  $passwd_entry->status('CHANGESHELL');
  $passwd_entry->update();
}

=item B<changeUsername({oldusername => 'userfoo', uid => 1234, newusername => 'newfoo'})>

Changes user name on all hosts

=cut

sub changeUsername() {
  my ( $self, $userargs ) = @_;
  my $logger      = $self->{logger};
  my $newusername = $userargs->{newusername};
  $userargs->{uidnum}   = $userargs->{uid};
  $userargs->{username} = $userargs->{oldusername};
  delete $userargs->{uid};
  delete $userargs->{oldusername};
  delete $userargs->{newusername};
  $logger->info( "Changing Username:" . $userargs->{username} . " to $newusername" );

  my $user_rec = $self->getUserRecord($userargs);

  #my @hosts    = $user_rec->hosts;
  #foreach my $passwd_host (@hosts) {
  #  $passwd_host->username($newusername);
  #  $passwd_host->update();
  #}
  $user_rec->username($newusername);
  $user_rec->update();
}

=item B<changeUserHome($host,{username => 'userfoo', uid => '1234', newhomedir => '/apps/newfoodir', TYPE => 'GENERIC'})>

Public method to change a generic account home directory.

=cut

sub changeUserHome() {
  my ( $self, $host, $userargs ) = @_;
  my $logger = $self->{logger};
  delete $userargs->{host} if exists $userargs->{host};
  if ( exists $userargs->{TYPE} and $userargs->{TYPE} ne "GENERIC" ) {
    die "Called changeUserHome but TYPE is not GENERIC\n";
  }
  elsif ( exists $userargs->{TYPE} ) {
    delete $userargs->{TYPE};
  }
  my $newhomedir;
  if ( exists $userargs->{newhomedir} ) {
    $newhomedir = $userargs->{newhomedir};
    delete $userargs->{newhomedir};
  }
  else {
    die "Called changeUserHome without newhomedir specified\n";
  }
  my $passwd_entry = $self->getHostPasswdEntry( $host, $userargs );
  logger->info( "Changing Home Dir for "
      . $passwd_entry->username->username . " to "
      . $passwd_entry->home );
  $passwd_entry->home($newhomedir);
  $passwd_entry->status('CHANGEHOME');
  $passwd_entry->update();
}

=item B<lockUser($host,{username => 'foo', uid => '123'})>

Public method to lock a users account on specified host.

=cut

sub lockUser() {
  my ( $self, $host, $userargs ) = @_;
  if( exists $userargs->{uid} ){
    $userargs->{uidnum} = $userargs->{uid};
    delete $userargs->{uid};
  }
  if( exists $userargs->{host} ){
    delete $userargs->{host};
  }
  
  my $logger       = $self->{logger};
  my $passwd_entry = $self->getHostPasswdEntry( $host, $userargs );
  my $temp_time    = &ParseDate("today");
  my $date         = &UnixDate( $temp_time, "%m-%d-%Y" );
  $logger->info("Locking [" . $userargs->{username} . "] on host [" . "$host]");
  $passwd_entry->hash( 'LOCKED ' . $date );
  $passwd_entry->update();
}

=item B<unlockUser($host, {username => 'foo', uid => '123'})>

Public method for unlocking user account on specified host.

=cut

sub unlockUser() {
  my ( $self, $host, $userargs ) = @_;
  my $cec = $self->{cec};
  if ( !exists $userargs->{uidnum} ) {
    $userargs->{uidnum} = $userargs->{uid};
    delete $userargs->{uid};
  }
  delete $userargs->{host};
  my $logger = $self->{logger};
  my $passwd_entry = $self->getHostPasswdEntry( $host, $userargs );
  $passwd_entry->hash( $cec->getPassword( $userargs->{username} ) );
  $passwd_entry->update();
}

=item B<addUserToGroup($host,{username => 'foo', uid => '123', unixgroup => 'dba'})>

Public method to add user to group on specified host.

=cut

sub addUserToGroup() {
  my ( $self, $host, $userargs ) = @_;
  my $group = $userargs->{unixgroup};
  if ( !exists $userargs->{uidnum} ) {
    $userargs->{uidnum} = $userargs->{uid};
    delete $userargs->{uid};
  }
  delete $userargs->{unixgroup};
  my $logger   = $self->{logger};
  my $host_rec = $self->getHostRecord($host);
  my @groups   = $host_rec->groups;
  my $group_rec;
  my $passwd_entry = $self->getHostPasswdEntry( $host, $userargs );
  if ( !$passwd_entry ) {
    return "User Not Found on Host";
  }
  if ( $passwd_entry->hash =~ /LOCK|TERM/ ) {
    return "Account is Currently Locked";
  }
  foreach my $g (@groups) {
    if ( $g->groupname->groupname eq $group and $g->username eq "" ) {
      my $result = $self->find_or_add(
        'EAMS_Group_Mapping',
        {
          hostname  => $host_rec->id,
          username  => $passwd_entry->username->id,
          groupname => $g->groupname->id
        }
      );
      $logger->info( "Added "
          . $passwd_entry->username->username
          . " to group "
          . $result->groupname->groupname . " on "
          . $host_rec->hostname
          . " with record id: "
          . $result->id );
    }
  }
  return 0;
}

=item B<removeUserFromGroup($host,{username => 'foo', uid => '1234', unixgroup => 'dba'})>

Public method to remove user from group on specified hosts.

=cut

sub removeUserFromGroup() {
  my ( $self, $host, $userargs ) = @_;
  if ( exists $userargs->{uid} ) {
    $userargs->{uidnum} = $userargs->{uid};
    delete $userargs->{uid};
  }
  delete $userargs->{host};
  my $logger = $self->{logger};
  my $group  = $userargs->{unixgroup};
  delete $userargs->{unixgroup};
  my $host_rec     = $self->getHostRecord($host);
  my $user_rec     = $self->getUserRecord($userargs);
  my $passwd_entry = $self->getHostPasswdEntry( $host, $userargs );

  if ( !$passwd_entry ) {
    return "User Account not found on host";
  }
  my @groups = $host_rec->groups;
  my %seen;
  foreach my $g (@groups) {
    if (  $g->groupname->groupname eq $group
      and $g->username == $user_rec->id
      and $g->hostname == $host_rec->id )
    {
      $logger->info( "Removing "
          . $g->username->username
          . " from group "
          . $g->groupname->groupname . " on "
          . $g->hostname->hostname );
      $g->delete;
    }
  }
  return 0;
}

=item B<addGroupToHost($host,{unixgroup => 'groupfoo'})>

Public method to add group to host.

=cut

sub addGroupToHost() {
  my ( $self, $host, $args ) = @_;
  my $logger   = $self->{logger};
  my $db       = $self->{db};
  my $host_rec = $self->getHostRecord($host);
  my @groups   = $host_rec->groups;
  foreach my $grp (@groups) {
    if ( $grp->groupname->groupname eq $args->{unixgroup} ) {
      $logger->info( "Group Already Exists: " . $args->{unixgroup} . " on host " . $host );
      return;
    }
  }
  my $group_rec = $self->getGroupRecord( $args->{unixgroup} );
  if ( !$group_rec ) {
    $logger->info( "Group Not Found" . $args->{unixgroup} );
    return;
  }
  my $result = $self->create(
    'EAMS_Group_Mapping',
    {
      groupname => $group_rec->id,
      hostname  => $host_rec->id
    }
  );
  $logger->info( "Added Group " . $group_rec->groupname . " to " . $host_rec->hostname );

}

=item B<deleteGroupFromHost($host,{unixgroup => 'groupfoo'})>

Public method to delete group from specified host.

=cut

sub deleteGroupFromHost() {
  my ( $self, $host, $args ) = @_;
  my $logger    = $self->{logger};
  my $host_rec  = $self->getHostRecord($host);
  my $group_rec = $self->getGroupRecord( $args->{unixgroup} );
  my $result    = $self->getRec(
    'EAMS_Group_Mapping',
    {
      groupname => $group_rec->id,
      hostname  => $host_rec->id
    }
  );
  $logger->info( "Group Found to Delete " . $args->{unixgroup} );
  foreach (@$result) {
    $logger->info( "Deleting Record ID: " . $_->id );
    $_->delete;
  }
}

=item B<setDefaultGroup($host,{username => 'foo', uid => '134', newunixgroup => 'newfoogroup', oldunixgroup => 'oldfoogroup'})>

Public method to set default primary group on specified host.

=cut

sub setDefaultGroup() {
  my ( $self, $host, $args ) = @_;
  if ( exists $args->{uid} ) {
    $args->{uidnum} = $args->{uid};
    delete $args->{uid};
  }
  delete $args->{host};

  my $logger   = $self->{logger};
  my $oldgroup = $args->{oldunixgroup};
  delete $args->{oldunixgroup};

  my $newgroup = $args->{newunixgroup};
  delete $args->{newunixgroup};
  delete $args->{unixgroup};

  my $passwd_entry = $self->getHostPasswdEntry( $host, $args );
  if ( !$passwd_entry ) {
    $logger->info( "No Passwd Entry Found on $host: "
        . $args->{username}
        . " Can't set default group" );
    return;
  }
  my $host_rec = $self->getHostRecord($host);
  my @groups   = $host_rec->groups;
  my ( $group_rec, %gids );
  foreach my $g (@groups) {
    $gids{ $g->groupname->gidnum }++;
    if ( $g->groupname->groupname eq $newgroup ) {
      $group_rec = $g;
      last;
    }
  }
  if ( !$group_rec ) {
    $logger->info( "No Group Found on host $host. " . $passwd_entry->username->username );
    $logger->info("Will try to add group");
    $group_rec = $self->getGroupRecord($newgroup);
    if ( !$group_rec ) {
      $logger->info("Group not found in EAMS");
      return;
    }
    else {
      $logger->info( "Group Found: " . $newgroup );
      my $result = $self->find_or_add(
        'EAMS_Group_Mapping',
        {
          groupname => $group_rec->id,
          hostname  => $host_rec->id
        }
      );
      $logger->info( "Added Group: "
          . $newgroup . " to "
          . $host_rec->hostname
          . " with row id "
          . $result->id );
      $passwd_entry->primarygid( $group_rec->gidnum );
      $passwd_entry->update();
      return $passwd_entry;
    }
  }
  else {
    $logger->info( "Found Group: " . $group_rec->groupname->groupname );
    $passwd_entry->primarygid( $group_rec->groupname->gidnum );
    $passwd_entry->update();
    return $passwd_entry;
  }
}

=item B<getGroupRecord($group)>

Public method to retrieve group data, if group not found it will try to create one starting at gid 1000.
It will insert into EAMS_Preferred_Groups, then into EAMS_Groups.

=cut

sub getGroupRecord() {
  my ( $self, $group ) = @_;
  my $logger        = $self->{logger};
  my $temp_ref      = $self->getRec( 'EAMS_Preferred_Groups', { groupname => $group } );
  my $preferred_ref = $temp_ref->[0];
  if ( !$preferred_ref ) {
    $logger->info("Preferred Group '$group' not found, trying Reg group table");
    my $temp_ref = $self->getRec( 'EAMS_Groups', { groupname => $group } );
    if ( !scalar @$temp_ref ) {
      $logger->info("Group '$group' not found in EAMS_Groups table");
      $logger->info("Finding Available GID to use for Group Creation");
      my %used_gids;
      my $gid_cnt = 1000;
      my @temp    = EAMS_Groups->search_distinct_gids();
      push ( @temp, EAMS_Preferred_Groups->search_distinct_gids() );
      dumpDebug("DUMPING TEMP\n",\@temp);
      foreach my $g(@temp) {
        $used_gids{$g->gidnum}++;
      }
      my $gid;
      while (1) {
        if ( !exists $used_gids{$gid_cnt} ) {
          $logger->info("Found Available GID: [$gid_cnt]");
          $gid = $gid_cnt;
          last;
        }
        $gid_cnt++;
      }
      $logger->info( "Creating New Group [" . $group . "] with GID [" . $gid . "]");
      my $p_res = $self->create(
        'EAMS_Preferred_Groups',
        {
          groupname => $group,
          gidnum    => $gid
        }
      );
      $logger->info( "Created new preferred group record: [" . $p_res->id . "]" );
      my $rec = $self->create(
        'EAMS_Groups',
        {
          groupname => $group,
          gidnum    => $gid
        }
      );
      $logger->info( "Created new group "
          . $rec->groupname . " - "
          . $rec->gidnum
          . " with record id "
          . $rec->id );
      return $rec;
    }
    $logger->info( "Found group in reg table: " . $temp_ref->[0]->groupname );
    if( scalar @$temp_ref > 1 ){
      return ($temp_ref->[0], $temp_ref);
    }
    else{
      return $temp_ref->[0];
    }
  }
  else {
    $logger->info( "Found Preferred Group: " . $preferred_ref->groupname );
    my $rec = $self->find_or_add(
      'EAMS_Groups',
      {
        groupname => $preferred_ref->groupname,
        gidnum    => $preferred_ref->gidnum
      }
    );
    return $rec;
  }
}

=item B<CreateAcct($host,\%user)>

Public method for creating accounts.
returns user map table row object.

=cut

sub createAcct() {
  my ( $self, $host, $user_ref ) = @_;
  die "Hostname or User Hash Ref emtpy" if ( !$host or ref($user_ref) ne 'HASH' );
  my $logger = $self->{logger};
  $logger->info("Creating Account $user_ref->{username} on Host: $host");
  my $hostrec = $self->getHostRecord($host);
  $user_ref->{hostname} = $hostrec->id;
  my $host_type;
  if ( $host ne 'cec' ) {
    $host_type = $self->getHostType('host');
  }
  else {
    $host_type = $self->getHostType('cec');
  }
  $user_ref->{type} = $host_type->id;
  if ( !exists $user_ref->{username} or !exists $user_ref->{uidnum} ) {
    die "User hash ref missing username or uid key\n";
  }
  my $user = $self->find_or_add(
    'EAMS_Users',
    {
      username => $user_ref->{username},
      uidnum   => $user_ref->{uidnum}
    }
  );
  $user->type( $user_ref->{TYPE} );
  $user->update;
  delete $user_ref->{TYPE};

  # Reassigning username to the record id of EAMS_Users
  #$user_ref->{username} = $user->id;
  my %arg_ref = %$user_ref;
  $arg_ref{username} = $user->id;
  my $gecos   = $arg_ref{gecos};
  my $homedir = $arg_ref{home};
  
  delete $arg_ref{home};
  delete $arg_ref{gecos};
  delete $arg_ref{uidnum};
  
  #$arg_ref{status} = 'NOTCREATED';
  my $shell = $arg_ref{shell};
  delete $arg_ref{shell};
  &dumpDebug( "DEBUG\n", \%arg_ref );
  my $rec = $self->find_or_add( 'EAMS_User_Mapping', \%arg_ref );
  $rec->status('NOTCREATED');
  $rec->shell($shell);
  $rec->gecos($gecos);
  my $current_home = $rec->home;
  if( $current_home ne $homedir and $homedir ne "" ){
    $logger->error("Account Already exists but current home dir does not match the supplied home dir");
    $logger->error("Username [" . $user_ref->{username} . "] current home [" . $current_home .
                   "] supplied home [" . $homedir . ']');
    $logger->error("Maybe should call changeUserHome?");
  }
  $rec->update;
  
  return $rec;
}

=item B<getHostGroupFile($host)>

Method Retrieves group entries for EAMS_Group_Mapping.
Formats the data into array.
Returns array ref

=cut

sub getHostGroupFile() {
  my ( $self, $host ) = @_;
  my $aref = $self->getRec( 'EAMS_Hosts', { hostname => $host } );
  my ( %group_hash, %users_hash, @results, %group_holder );
  foreach my $host (@$aref) {
    my $group = $self->getRec( 'EAMS_Group_Mapping', { hostname => $host->id } );
    
    foreach my $g (@$group) {
      my $group_key = $g->groupname->groupname . ':' . $g->groupname->gidnum;
      if ( defined $g->username ) {
        $users_hash{ $group_key }{ $g->username->username }++;
      }
      else {
        $group_hash{ $group_key } =
          $g->groupname->groupname . ":" . $g->hash . ":" . $g->groupname->gidnum;
      }
      $group_holder{$g->groupname->gidnum}{$g->groupname->groupname}++;
    }
  }
  my @tmp_ids = sort { $a <=> $b } keys %group_holder;
  my $sorted_ids = $self->reorderArray( \@tmp_ids );
  foreach my $id (@$sorted_ids) {
    foreach my $group(keys %{ $group_holder{$id} }){
      my $g_key = $group . ':' . $id;
      my @users = keys %{ $users_hash{$g_key} };
      my $t;
      if (@users) {
        $t = join ( ',', @users );
      }
      push ( @results, $group_hash{$g_key} . ":" . $t );
    }
  }
  die "No Groups Records found for $host" if !scalar @results;
  return \@results;
}

=item B<reorderArray()>

Public Method. This method re-orders the arrays so the 'system' accounts are
on top of the /etc/passwd file. Not a requirement, but helps with ease of reading.

=cut

sub reorderArray() {
  my ( $self, $aref )   = @_;
  my ( @top,  @bottom ) = ();
  foreach my $id (@$aref) {
    if ( $id < 0 ) {
      push ( @bottom, $id );
    }
    elsif ( $id > 25 ) {
      push ( @bottom, $id );
    }
    else {
      push ( @top, $id );
    }
  }
  push ( @top, @bottom );
  return \@top;
}

=item B<checkHRef($hash_ref)>

Method to verify if the arg is a hash ref.
Dies if it is not a hash ref.

=cut

sub checkHRef() {
  my ( $self, $href ) = @_;
  if ( ref($href) ne 'HASH' ) {
    die "Method Expects a Hash Ref\n";
  }
  else {
    return 0;
  }
}


=item B<getUserRecordsbyUsername($username)>

Method to retrieve user record(s) if more then 1 user exists with the same username, but different uid.
returns undef if none is found.

=cut


sub getUserRecordsByUsername(){
  my $self = shift;
  my $username = shift;
  my $logger = $self->{logger};
  my $records_ref = $self->getRec('EAMS_Users',{username => $username});
  if( scalar @$records_ref == 1 ){
    $logger->info("1 Record found: [$username] with record id [" . $records_ref->[0]->id . "] in EAMS_Users");
    return $records_ref;
  }
  elsif( scalar @$records_ref > 1 ){
    $logger->info("More then 1 record found for $username in EAMS_Users");
    foreach my $rec(@$records_ref){
      $logger->debug("$username has record id [" . $rec->id . "]");
    }
    return $records_ref;
  }
  $logger->info("No User Found for [$username] in EAMS_Users");
  return undef;
}

1;

__END__

=back

=head1 SYNOPSIS

use lib '.';
use AFA::DB;

my $obj = AFA::DB->new();

my $result_ref = $obj->getHostGroupFile('tut');

foreach my $r(@$ref){
   print "$r\n";
}

	
=head1 ABSTRACT

EAMS Account Fullfillment DB Interface

=head1 DESCRIPTION

EAMS AFA DB API


=head1 EXPORT

None by default.

=head1 SEE ALSO

AFA::DBI


=head1 AUTHOR

Module Author: scpham@cisco.com

=head1 COPYRIGHT AND LICENSE

Copyright 2005 by Cisco Systems

=cut

