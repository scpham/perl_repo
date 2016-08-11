package AFA::CLI;

use strict;
use POSIX ":sys_wait_h";
use lib '.';
use CEC;
use AFA::DBI;
use AFA::DB;
use AFA::Logger;
use AFA::ServerLoader;
use AFA::AcctAgent;
use AFA::Config qw( %afa_config );

sub REAPER {
        my $child;
        # If a second child dies while in the signal handler caused by the
        # first death, we won't get another signal. So must loop here else
        # we will leave the unreaped child as a zombie. And the next time
        # two children die we get another zombie. And so on.
        while (($child = waitpid(-1,WNOHANG)) > 0) {
        }
        $SIG{CHLD} = \&REAPER;
    }
$SIG{CHLD} = \&REAPER;

=begin

$Id: CLI.pm,v 1.17 2007/01/26 15:05:10 scpham Exp $
$Revision: 1.17 $
$Author: scpham $
$Date: 2007/01/26 15:05:10 $

=cut

=head2 Available Methods

=over 12

=cut


sub new() {
  my $class = shift;
  my $self  = {};
  bless( $self, $class );
  $self->_init();
  return $self;
}

sub _init() {
  my $self = shift;
  $self->{logger} = get_logger("AFA::CLI");
  $self->{max_push_proc} = $afa_config{max_push_proc};
  $self->{max_server_load} = $afa_config{max_server_load};
  $self->{cec}    = CEC->new();
  $self->{db}     = AFA::DB->new();
  $self->{servers} = {};
  $self->{logger}->debug("Init AFA::CLI");
}

=item B<lockUser($username,$hostname)>

Method to Lock out user, omit hostname and will lock user on all hosts

=cut

sub lockUser() {
  my ( $self, $username, $hostname ) = @_;
  my $db = $self->{db};
  my $server_ref = $self->{servers};
  my $host_record;
  if ($hostname) {
    $host_record = $db->getHostRecord($hostname);
  }
  my $logger = $self->{logger};
  $logger->debug("Getting System Accounts List");
  my $sys_h_ref = $db->getSysAccts();
  if ( exists $sys_h_ref->{$username} ) {
    $logger->error("Account Specified is a System Account [$username]");
    $logger->error("Can't lock system accounts");
    return 1;
  }
  my $records = $db->getUserHostEntries($username,$hostname);
  foreach my $record(@$records){
    $db->lockUser(
          $record->hostname->hostname,
          {
           username => $record->username->username,
           uid      => $record->username->uidnum
          });
  }
}

=item B<unlockUser($username,$hostname)>

Method to unLock User, omit host and it will unlock user on all hosts

=cut

sub unlockUser() {
  my ( $self, $username, $hostname ) = @_;
  my $logger = $self->{logger};
  my $db     = $self->{db};
  my $cec    = $self->{cec};
  my $server_ref = $self->{servers};
  my $records = $db->getUserHostEntries($username,$hostname);
  foreach my $user (@$records){
    $server_ref->{$user->hostname->hostname}++;
    $logger->info( "Unlocking [$username] on host [" . $user->hostname->hostname . "]" );
    print "Unlocking [$username] on host [" . $user->hostname->hostname . "]\n";
    $user->hash( $cec->getPassword($username) );
    $user->update;
  }
}

=item B<changeShell($username,$shell,$hostname)>

Method to change a users shell. Omit hostname and will change shell on all hosts.

=cut

sub changeShell() {
  my ( $self, $username, $shell, $hostname  ) = @_;
  my $logger = $self->{logger};
  my $db     = $self->{db};
  my $server_ref = $self->{servers};
  my $records = $db->getUserHostEntries($username,$hostname);
  foreach my $record(@$records){
    $server_ref->{$record->hostname->hostname}++;
    $logger->info("Changing shell for [$username] to [$shell] on host ["
                  . $record->hostname->hostname . "]");
    $record->shell($shell);
    $record->status('CHANGE');
    $record->update;
  }
}

=item B<changeHome()>

Method to change a users home directory

=cut

sub changeHome() {
  my ( $self, $username, $homedir, $hostname ) = @_;
  my $logger = $self->{logger};
  my $db     = $self->{db};
  my $server_ref = $self->{servers};
  my $records = $db->getUserHostEntries($username,$hostname);
  foreach my $record(@$records){
    $server_ref->{$record->hostname->hostname}++;
    $logger->info(
      "Changing homedir in EAMS for [$username] on host [" .
       $record->hostname->hostname . "] home [$homedir]");
    $record->home($homedir);
    $record->status('CHANGE');
    $record->update;
  }
}

=item B<showHostPasswdEntries()>

Method to display password entries for a single hosts

=cut

sub showHostPasswdEntries() {
  my ( $self, $hostname ) = @_;
  if ( $hostname eq undef ) {
    print "No host name specified\n";
    exit 1;
  }
  print "Password entries for host [$hostname]\n";
  print "username:pwhash:uid:primary gid:gecos:home:shell:account status:last password change\n\n";
  my $logger          = $self->{logger};
  my $db              = $self->{db};
  my $passwd_file_ref = $db->getHostPasswdFile($hostname);
  foreach my $entry (@$passwd_file_ref) {
    print "$entry\n";
  }
}

=item B<changeUsername($username,$newusername,$hostname)>

Method to change a username

=cut

sub changeUsername(){
  my ( $self, $username, $newusername, $hostname ) = @_;
  my $db = $self->{db};
  my $logger = $self->{logger};
  my $records = $db->getUserHostEntries($username,$hostname);
  if(! scalar @$records){
    $logger->error("No records found for [$username] on host [$hostname]");
    print STDERR "No records found for [$username] on host [$hostname]\n";
    return undef;
  }
  foreach my $user(@$records){
    $self->{servers}->{$user->hostname->hostname}++;
    $logger->info("Changing username from [$username] to [$newusername] on host ["
                  . $user->hostname->hostname
                  . "]");
    print "Changing username from [$username] to [$newusername] on host ["
                  . $user->hostname->hostname
                  . "]\n";
    my $new_user_record = $db->find_or_add('EAMS_Users',{username => $newusername,
                                                         uidnum   => $user->username->uidnum});
    $user->username($new_user_record->id);
    $user->update;
  }
}

=item B<changeUserUID($username,$uid,$hostname)>

Method to change a users uid.

=cut

sub changeUserUID(){
  my($self,$username,$uid,$hostname)=@_;
  my $db = $self->{db};
  my $logger = $self->{logger};
  my $records = $db->getUserHostEntries($username,$hostname);
  if (! scalar @$records){
    $logger->error("Failed to find [$username] on host [$hostname]");
    print STDERR "Failed to find [$username] on host [$hostname]\n";
    return undef;
  }
  foreach my $user(@$records){
    $self->{servers}->{$user->hostname->hostname}++;
    $self->{servers}->{$user->hostname->hostname}++;
    $logger->info("Changing UID for [$username] from ["
                  . $user->username->uidnum . " to [$uid] on host ["
                  . $user->hostname->hostname . "]");
    print "Changing UID for [$username] from ["
          . $user->username->uidnum . "] to [$uid] on host ["
                  . $user->hostname->hostname . "]\n";
    my $new_record = $db->find_or_add('EAMS_Users',{username => $username,
                                                    uidnum   => $uid});
    $user->username($new_record->id);
    $user->update;
  }
}

=item B<changeUserGID($username,$group,$hostname)>

Method to change a primary group for a user on a single host

=cut

sub changeUserGID(){
  my( $self, $username, $group, $hostname ) = @_;
  my $db = $self->{db};
  my $logger = $self->{logger};
  if(! $hostname){
    $logger->("Missing Hostname");
    print STDERR "No hostname specified\n";
    return undef;
  }
  else{
    my $records = $db->getUserHostEntries($username,$hostname);
    if(! scalar @$records){
      $logger->error("No records found for [$username] on host [$hostname]");
      print STDERR "No records found for [$username] on host [$hostname]\n";
      return undef;
    }
    my $host_record = $db->getHostRecord($hostname);
    if(!$host_record){
      $logger->error("Host Record not found for [$hostname]");
      print STDERR "Host Record not found for [$hostname]\n";
      return undef;
    }
    my $groups_records = $db->getRec('EAMS_Group_Mapping',{hostname => $host_record->id});
    my %group_container;
    foreach my $g(@$groups_records){
      if($g->groupname->groupname eq $group and $g->username eq ""){
        $group_container{$g->groupname->gidnum} = $g;
      }
    }
    my $pgid;
    if(keys %group_container > 1){
      $logger->debug("Found more then 1 gid for group [$group]");
      print "Found more then 1 gid for group [$group]\n";
      my %groups_holder;
      PRIMARYGIDQ:
      print "\nWhich GID would you like to use?\n";
      foreach my $g(values %group_container){
        print $g->groupname->gidnum,"\n";
      }
      print "---------------\n";
      print "Enter Q to exit\n";
      print "Enter GID: ";
      my $answer = <STDIN>;
      chomp $answer;
      if($answer =~ /\bq\b|\bQ\b/){
        exit 0;
      }
      if(! exists $group_container{$answer}){
        goto PRIMARYGIDQ;
      }
      else{
        $pgid = $group_container{$answer}->groupname->gidnum;
      }
    }
    elsif(keys %group_container == 1){
      foreach my $g(values %group_container){
        $pgid = $g->groupname->gidnum;
        last;
      }
    }
    else{
      $logger->error("No Group record found for group [$group]: Failed to change primary gid");
      print STDERR "No Group record found for group [$group]: Faield to change primary gid\n";
      return undef;
    }
    foreach my $user(@$records){
      $self->{servers}->{$user->hostname->hostname}++;
      $logger->info("Changing user [$username] gid from ["
                    . $user->primarygid
                    . "] to ["
                    . $pgid . "] on host ["
                    . $user->hostname->hostname
                    . "]");
      print "Changing user [$username] gid from ["
                    . $user->primarygid
                    . "] to ["
                    . $pgid . "] on host ["
                    . $user->hostname->hostname
                    . "]\n";
      $user->primarygid($pgid);
      $user->update;
    }
  }
}

=item B<showGroupEntries($hostname)>

Method to show group entries for a single hosts

=cut

sub showGroupEntries() {
  my ( $self, $hostname ) = @_;
  my $logger     = $self->{logger};
  my $db         = $self->{db};
  my $groups_ref = $db->getHostGroupFile($hostname);
  print "Group File for host [$hostname]\n";
  foreach my $entry (@$groups_ref) {
    print "$entry\n";
  }
}

=item B<showUsersHostLists($hostname)>

Method to show hosts that a user has an account on

=cut

sub showUserHostLists() {
  my ( $self, $username ) = @_;
  my $logger     = $self->{logger};
  my $db         = $self->{db};
  my $user_ref   = $db->getUserRecordsByUsername($username);
  my @user_hosts = ();
  foreach my $rec (@$user_ref) {
    push ( @user_hosts, $rec->hosts );
  }
  print "User [$username] Host List\n";
  print "Hostname\n";
  print "--------\n";
  foreach my $g (@user_hosts) {
    print $g->hostname->hostname . "\n";
  }
  print "\n";
}

=item B<showUsersGroupMemberships($username,$hostname)>

Functions to show a users group memberships on a single host

=cut

sub showUsersGroupMemberships() {
  my ( $self, $username, $hostname ) = @_;
  my $logger        = $self->{logger};
  my $db            = $self->{db};
  my $user_entry    = $db->getHostEntryByUsername( $hostname, $username );
  my $group_records = $db->getRec(
    'EAMS_Group_Mapping',
    {
      hostname => $user_entry->hostname->id,
      username => $user_entry->username->id
    }
  );
  if ( !scalar @$group_records ) {
    $logger->info("No Group Records found for [$username] on host [$hostname]");
  }
  else {
    print "Listing Group Memberships for [$username] on host [$hostname]\n";
    print "Groupname:GID\n\n";
    foreach my $g (@$group_records) {
      print $g->groupname->groupname . ":" . $g->groupname->gidnum . "\n";
    }
  }
}

=item B<addUserToGroup($username,$group,$hostname)>

Method to add a user to a group on a single host.

=cut

sub addUserToGroup() {
  my ( $self, $username,  $group,$hostname ) = @_;
  my $logger     = $self->{logger};
  my $db         = $self->{db};
  my $server_ref = $self->{servers};
  my $user_entry = $db->getHostEntryByUsername( $hostname, $username );
  if(! $user_entry){
    $logger->error("Could not find [$username] on host [$hostname]");
    print "Could not find [$username] on host [$hostname]\n";
    return undef;
  }
  my $group_recs =
    $db->getRec( 'EAMS_Group_Mapping', { hostname => $user_entry->hostname->id } );
  my @group_container;
  foreach my $g (@$group_recs) {
    if ( $g->groupname->groupname eq $group and $g->username eq "" ) {
      push ( @group_container, $g );
    }
  }
  if ( !scalar @group_container ) {
    $logger->error("Group [$group] not found on host [$hostname]");
    print "Group [$group] not found. Please add the group to host [$hostname]\n";
  }
  else {
    if ( scalar @group_container > 1 ) {
      $logger->info("Found more then 1 group with the same group name");
      $logger->info("Will add user to all groups with the same name");
      print "Found more then 1 group with the same group name\n";
      print "Will add user to all groups with the same name\n";
    }
    foreach my $group_r (@group_container) {
      my $rec = $db->find_or_add(
        'EAMS_Group_Mapping',
        {
          groupname => $group_r->groupname->id,
          hostname  => $user_entry->hostname->id,
          username  => $user_entry->username->id
        }
      );
      $logger->info( "Added [$username] to group [$group] gid ["
          . $group_r->groupname->gidnum
          . "] on host [$hostname]" );
      print "Sucessfully Added [$username] to group [$group] on host [$hostname]\n";
      $server_ref->{$user_entry->hostname->hostname}++;
    }
  }
}

=item B<removeUserFromGroup($username,$group,$hostname)>

Method to remove user from a group on a single host.

=cut

sub removeUserFromGroup() {
  my ( $self, $username, $group, $hostname ) = @_;
  my $logger          = $self->{logger};
  my $db              = $self->{db};
  my $user_entry      = $db->getHostEntryByUsername( $hostname, $username );
  my $user_groups_rec = $db->getRec(
    'EAMS_Group_Mapping',
    {
      hostname => $user_entry->hostname->id,
      username => $user_entry->username->id
    }
  );
  my $seen;
  foreach my $g_rec (@$user_groups_rec) {
    if ( $g_rec->groupname->groupname eq $group ) {
      $seen++;
      $logger->info( "Deleted [$username] from group [$group] gid ["
          . $g_rec->groupname->gidnum
          . "] on host [$hostname]" );
      print "Removed [$username] from group [$group] gid ["
        . $g_rec->groupname->gidnum
        . "] on host [$hostname]\n";
      $g_rec->delete;
    }
  }
  if ( !$seen ) {
    $logger->info(
"Failed to remove [$username] from group [$group] on host [$hostname]: No Record Found"
    );
    print
"Failed to remove [$username] from group [$group] on host [$hostname]: No Record Found\n";
    return undef;
  }
  $self->{servers}->{$hostname}++;

}

=item B<setUserHash($username, $hash, $hostname)>

Methods to set a users password hash. Omitting hostname will operate on all hosts.

=cut

sub setUserHash() {
  my ( $self, $username, $hash, $hostname ) = @_;
  my $logger = $self->{logger};
  my $db     = $self->{db};
  my $server_ref = $self->{servers};
  if ( !$hash ) {
    print "Hash Value Not Specified\n";
    exit 1;
  }
  my $records = $db->getUserHostEntries($username,$hostname);
  if(! scalar @$records > 0){
    $logger->error("No Records found for [$username] on host [$hostname]");
    print STDERR "No Records found for [$username] on host [$hostname]\n";
    return undef;
  }
  foreach my $user(@$records){
    $server_ref->{$user->hostname->hostname}++;
    $logger->info("Changing password hash for [$username] from ["
                  . $user->hash . "] to ["
                  . $hash . "] on host ["
                  . $user->hostname->hostname . "]");
    print "Changing password hash for [$username] from ["
                  . $user->hash . "] to ["
                  . $hash . "] on host ["
                  . $user->hostname->hostname . "]\n";
    $user->hash($hash);
    $user->update;
  }
}

=item B<addGroupToHost($group,$gid,$hostname)>

Method to add group to host. If gid is omitted it will list available gids associated with $group for use.

=cut

sub addGroupToHost() {
  my ( $self ,$group,$gid,$hostname ) = @_;
  my $logger = $self->{logger};
  my $db     = $self->{db};
  $self->{servers}->{$hostname}++;
  my ( $group_record, $group_recs );
  if ($gid) {
    $group_record = $db->getRec(
      'EAMS_Groups',
      {
        groupname => $group,
        gidnum    => $gid
      }
    );
    if ( scalar @$group_record > 0 ) {
      $logger->info("Group [$group] gid [$gid] found");
      $group_record = $group_record->[0];
    }
    else {
      $logger->info(
        "Group [$group] gid [$gid] not found, querying EAMS_Groups by groupname only");
      $group_recs = $db->getRec( 'EAMS_Groups', { groupname => $group } );
      if ( scalar @$group_recs > 0 ) {
        $logger->info(
          "Found [" . scalar @$group_recs . "] record(s) for group [$group]" );
        print "Found [" . scalar @$group_recs . "] record(s) for group [$group]\n";
        Q1:
        print "\nWould you like to use one of these other gid(s) instead? Y/[N]: ";
        my $answer = <STDIN>;
        chomp $answer;
        my %gids;
        if ( $answer =~ /\by\b|\bY\b/ ) {
        LISTGIDS1:
          print "\nListing available gids for group [$group]\n";
          print "Enter Q to exit\n";
          print "GIDs\n";
          print "----\n";
          foreach my $g (@$group_recs) {
            print $g->gidnum . "\n";
            $gids{ $g->gidnum } = $g;
          }
          print "Enter GID: ";
          my $gid_answer = <STDIN>;
          chomp $gid_answer;
          if ( !exists $gids{$gid_answer} ) {
            goto LISTGIDS1;
          }
          $group_record = $gids{$gid_answer};
        }
        elsif ( $answer =~ /\bn\b|\bN\b/ ) {
          $logger->info("Creating group [$group] with gid [$gid]\n");
          print "Creating group [$group] with gid [$gid]\n";
          $group_record = $db->find_or_add(
            'EAMS_Groups',
            {
              groupname => $group,
              gidnum    => $gid
            }
          );
        }
        else {
          goto Q1;
        }
      }
      else {
        $logger->info("Creating group [$group] with gid [$gid]\n");
        print "Creating group [$group] with gid [$gid]\n";
        $group_record = $db->find_or_add(
          'EAMS_Group',
          {
            groupname => $group,
            gidnum    => $gid
          }
        );
      }
    }
  }
  else {
    ( $group_record, $group_recs ) = $db->getGroupRecord($group);
    if ( ref($group_recs) eq 'ARRAY' ) {
      if ( scalar @$group_recs > 1 ) {
        $logger->debug( "["
            . scalar @$group_recs
            . "] group(s) was found for group [$group] in EAMS_Groups table" );
        LISTGIDS2:
        print "\nListing available gids for group [$group]\n";
        print "Enter Q to exit\n";
        print "GIDs\n";
        print "----\n";
        my %gid;
        foreach my $g_rec (@$group_recs) {
          print $g_rec->gidnum . "\n";
          $gid{ $g_rec->gidnum } = $g_rec;
        }
        print "Enter GID: ";
        my $answer = <STDIN>;
        chomp $answer;
        if ( $answer =~ /\bq\b|\bQ\b/ ) {
          exit 1;
        }
        if ( !exists $gid{$answer} ) {
          goto LISTGIDS2;
        }
        $group_record = $gid{$answer};
      }
    }
  }
  my $host_record = $db->getHostRecord($hostname);
  if ( $host_record eq undef ) {
    $logger->error("Host Record Not Found [$hostname]");
    print "Host Record Not Found [$hostname]\n";
    return undef;
  }
  my $host_group_entry = $db->find_or_add(
    'EAMS_Group_Mapping',
    {
      groupname => $group_record->id,
      hostname  => $host_record->id,
      username  => undef
    }
  );
  $logger->info( "Successfully created group ["
      . $group_record->groupname
      . "] gid ["
      . $group_record->gidnum
      . "] on host ["
      . $host_record->hostname
      . "] with record id ["
      . $host_group_entry->id
      . "]" );
  print "Successfully created group ["
    . $group_record->groupname
    . "] gid ["
    . $group_record->gidnum
    . "] on host ["
    . $host_record->hostname
    . "] with record id ["
    . $host_group_entry->id . "]\n";
}

=item B<removeGroupFromHost($group,$hostname)>

Method to remove group from host. If more then 1 group is found, it will prompt you for the one you want to remove.
If there are users associated with the group, it will prompt you.

=cut

sub removeGroupFromHost() {
  my ( $self, $group, $hostname ) = @_;
  my $logger      = $self->{logger};
  my $db          = $self->{db};
  
  my $host_record = $db->getHostRecord($hostname);
  if(! $host_record){
    $logger->error("Host Record not found for host [$hostname]");
    print STDERR "Can't remove group [$group] from host [$hostname]: Host Record Not Found\n";
    return undef;
  }
  my $group_recs  = $db->getRec( 'EAMS_Groups', { groupname => $group } );
  my @groups_on_host;
  my $group_find_status;
  foreach my $g_rec (@$group_recs) {
    my $recs = $db->getRec(
      'EAMS_Group_Mapping',
      {
        hostname  => $host_record->id,
        groupname => $g_rec->id
      }
    );

    if ( scalar @$recs > 0 ) {
      $group_find_status = 1;
      push ( @groups_on_host, $recs );
    }
  }
  if ( !$group_find_status ) {
    $logger->error("No Group [$group] found on host [$hostname]");
    print "No Group [$group] found on host [$hostname]\n";
    return undef;
  }
  my ( %group_2_remove, %users, $global_answer, $global_group_rec );
  if ( scalar @groups_on_host > 1 ) {
    $logger->info( "["
        . scalar @groups_on_host
        . "] groups found on host [$hostname] with the same groupname [$group]" );
    print "["
      . scalar @groups_on_host
      . "] groups found on host [$hostname] with the same groupname [$group]\n";
    print "Which Group/GID combination would you like to remove?\n";

    foreach my $gref (@groups_on_host) {
      foreach my $g (@$gref) {
        my $group_key = $g->groupname->groupname . ':' . $g->groupname->gidnum;
        if ( $g->groupname->groupname eq $group and $g->username eq "" ) {
          $group_2_remove{$group_key} = $g;
        }
        else {
          $users{$group_key}{ $g->username }++;
        }
      }
    }
    LISTGIDS3:
    foreach my $g ( keys %group_2_remove ) {
      my ( $gname, $gid ) = split ( ':', $g );
      print "$gid\n";
    }
    print "Enter Q to exit\n";
    print "Enter GID you would like to remove: ";
    my $answer = <STDIN>;
    chomp $answer;
    $global_answer = $group . ':' . $answer;
    if ( !exists $group_2_remove{$global_answer} and $global_answer !~ /\bq\b|\bQ\b/ ) {
      goto LISTGIDS3;
    }
    elsif ( $answer =~ /\bq\b|\bQ\b/ ) {
      exit 1;
    }
  }
  else {
    my $a_ref     = $groups_on_host[0];
    my $group_key = $group . ':' . $a_ref->[0]->groupname->gidnum;
    $global_answer = $group_key;
    foreach my $g (@$a_ref) {
      if ( $g->groupname->groupname eq $group and $g->username eq "" ) {
        $group_2_remove{$group_key} = $g;
      }
      else {
        $users{$group_key}{$group_key}++;
      }
    }
  }
  my @user_count = keys %{ $users{$global_answer} };
  $global_group_rec = $group_2_remove{$global_answer};
  if ( scalar @user_count > 0 ) {
    print "There are users associated with this group [$group] gid ["
      . $global_group_rec->groupname->gidnum . "]\n";
    print "Do you want to still remove this group? Y/[N]: ";
    my $answer = <STDIN>;
    chomp $answer;
    if ( $answer =~ /\by\b|\bY\b/ ) {
      my $recs_2_delete = $db->getRec(
        'EAMS_Group_Mapping',
        {
          hostname  => $host_record->id,
          groupname => $global_group_rec->groupname->id
        }
      );
      my $core_group;
      foreach my $group_record (@$recs_2_delete) {
        if ( $group_record->username ne "" ) {
          my $user_recs = $db->getRec( 'EAMS_Users', { id => $group_record->username } );
          print "Removing ["
            . $user_recs->[0]->username
            . "] from group [$group] on host [$hostname]\n";
          $group_record->delete;
        }
        else {
          $core_group = $group_record;
        }
      }
      $self->{servers}->{$hostname}++;
      $logger->info( "Removing group [$group] gid ["
          . $core_group->groupname->gidnum
          . "] from host [$hostname] with record id ["
          . $core_group->id
          . "]" );
      print "Removing group [$group] from host [$hostname]\n";
      $core_group->delete;
    }
  }
  else {
    $self->{servers}->{$hostname}++;
    $logger->info( "Removing group [$group] gid ["
        . $global_group_rec->groupname->gidnum
        . "] from host [$hostname] with record id ["
        . $global_group_rec->id
        . "]" );
    print "Removing group [$group] gid ["
      . $global_group_rec->groupname->gidnum
      . "] from host [$hostname] with record id ["
      . $global_group_rec->id . "]\n";
    $global_group_rec->delete;
  }

}

=item B<syncUserPasswordFromCEC($username,$hostname)>

Method to sync a users password with CEC. Omit hostname and it will sync with all host user has accounts on.

=cut

sub syncUserPasswordFromCEC {
  my ( $self, $username, $hostname ) = @_;
  my $logger = $self->{logger};
  my $db     = $self->{db};
  my $cec    = $self->{cec};
  my $server_ref = $self->{servers};
  my $return_status = 0;
  my $records = $db->getUserHostEntries($username,$hostname);
  foreach my $user (@$records) {
    $server_ref->{$user->hostname->hostname}++;
    $logger->info( "Syncing User [$username] Password on host ["
        . $user->hostname->hostname
        . "] with CEC" );
    print "Syncing User [$username] Password on host ["
      . $user->hostname->hostname
      . "] with CEC\n";
    $user->hash( $cec->getPassword($username) );
    $user->update;
  }
  return $return_status;
}

=item B<setUserPassword($username,$password,$hostname)>

Method to set a users password. It will call generateHash to create the password hash.
Omit hostname and will change password on all hosts user has accounts on.

=cut

sub setUserPassword() {
  my ( $self, $username, $password, $hostname ) = @_;
  my $db     = $self->{db};
  my $logger = $self->{logger};
  my $server_ref = $self->{servers};
  my $encrypted_password;
  my $return_status = 0;
  if ( !$password ) {
    $logger->info("Password not specified");
    print "You must specify a password\n";
    exit 1;
  }
  else {
    if(! exists $self->{encrypted_hash} ){
      $encrypted_password = $self->generateHash($password);
      $self->{encrypted_hash} = $encrypted_password;
    }
    else{
      $encrypted_password = $self->{encrypted_hash};
    }
  }
  my $records = $db->getUserHostEntries($username,$hostname);
  foreach my $user (@$records) {
    $server_ref->{$user->hostname->hostname}++;
    $logger->info( "Setting password for [$username] on host ["
        . $user->hostname->hostname
        . "] password hash ["
        . "$encrypted_password]" );
    print "Setting password for [$username] on host ["
      . $user->hostname->hostname
      . "] password hash [$encrypted_password]\n";
    $user->hash($encrypted_password);
    $user->update;
    $return_status = 1;
  }
  return $return_status;
}


=item B<changeUserGecos($username,$gecos,$hostname)>

Method to change a users geco field. omit hostname will operate on all servers.

=cut


sub changeUserGecos(){
  my( $self, $username, $gecos, $hostname ) = @_;
  my $db = $self->{db};
  my $logger = $self->{logger};
  if( ! $gecos){
    $logger->error("Gecos variable not specified");
    print STD "Gecos not specified\n";
    exit 1;
  }
  my $records = $db->getUserHostEntries($username,$hostname);
  if( ! scalar @$records ){
    $logger->error("No Records found for [$username] on host [$hostname]");
    print STDERR "No Records found for [$username] on host [$hostname]\n";
  }
  foreach my $user(@$records){
    $self->{servers}->{$user->hostname->hostname}++;
    $logger->info("Changing gecos field from ["
                  . $user->gecos ."] to ["
                  . $gecos . "] for [$username] on host ["
                  . $user->hostname->hostname . "]");
    print "Changing gecos field from ["
                  . $user->gecos ."] to ["
                  . $gecos . "] for [$username] on host ["
                  . $user->hostname->hostname . "]\n";
    $user->gecos($gecos);
    $user->update;
  }
}
  

=item B<generateHash($password)>

Method to generate hash for UNIX/Linux passwords.

=cut

sub generateHash() {
  my ( $self, $password ) = @_;
  my @salt_chars = ( 'a' .. 'z', 'A' .. 'Z', '0' .. '9' );
  srand( time ^ $$ ^ unpack "%L*", `ps axww | gzip` );
  my $salt = $salt_chars[ rand(63) ] . $salt_chars[ rand(63) ];
  return crypt( $password, $salt );
}

=item B<addHostToEAMS(\@hostnames)>

Method to add a host to EAMS. This must be done before any jobs will be processed for this host.

=cut

sub addHostToEAMS() {
  my ( $self, $hostnames ) = @_;
  my $logger = $self->{logger};
  my $max_proc = $self->{max_server_load};
  if(! $max_proc){
    $max_proc = 5;
  }
  AHFORK:
  my $pid = fork();
  if($pid){
    $logger->debug("Forking ServerLoader process for ["
                   . scalar @$hostnames . "] host(s) PID [$pid]");
    print "Forking ServerLoader process for ["
                   . scalar @$hostnames . "] host(s) PID [$pid]\n";
  }
  elsif(defined $pid){
    my $process_count;
    foreach my $host(@$hostnames){
      my $pid = fork();
      if($pid){
        $process_count++;
        $logger->debug("Forking PID[$pid] for Server Loading process for host [$host]");
        print "Forking PID[$pid] for Server Loading process for host [$host]\n";
        while( $process_count > 0 and $process_count >= $max_proc ){
          if(waitpid(-1,&WNOHANG)>0){
            $process_count--;
          }
        }
      }
      elsif(defined $pid){
          my $dbh = AFA::DBI->db_Main;
          $dbh->disconnect;
          my $server_loader = AFA::ServerLoader->new();
          $server_loader->{over_ride} = 1;
          $server_loader->getHostData($host);
          $server_loader->genData();
          $server_loader->loadRecs();
          exit 0;
      }
      else{
        $logger->error("Failed to fork process for ServerLoader for [$host]: Retrying..");
        print "Failed to fork process for ServerLoader for [$host]: Retrying..\n";
        redo;
      }
    }
  }
  else{
    goto AHFORK;
  }
}

=item B<listHosts()>

Method to list hosts that are in EAMS

=cut

sub listHosts(){
  my($self) = @_;
  my @records = EAMS_Hosts->retrieve_all;
  print "Listing hosts that are in EAMS\n";
  my($hostname,$platform);
  # Set max lines per page.
  $= = '10000000';
  format STDOUT_TOP=
Hostname              Platform
==============================
.
  format STDOUT=
@<<<<<<<<<<<<<        @<<<<<<<<<<<<<<<
  $hostname,$platform
.
  
  foreach my $record(@records){
    $hostname = $record->hostname;
    $platform = $record->platform;
    write;
  }
  print "==============================\n";
}

=item B<removeHostFromEAMS($hostname)>

Method to delete all records associated with a host. This will remove the host completely from EAMS.

=cut

sub removeHostFromEAMS(){
  my( $self, $hostname ) = @_;
  my $db = $self->{db};
  my $logger = $self->{logger};
  my $host_record = $db->getHostRecord($hostname);
  if(!$host_record){
    print STDERR "No Record Found for Host [$hostname]\n";
    exit 1;
  }
  my @users = $host_record->passwds();
  my @groups = $host_record->groups;
  $logger->info("Removing User Entries for host [$hostname]");
  print "Removing User Entries for host [$hostname]\n";
  foreach my $user(@users){
    $logger->info("Removing user [" . $user->username->username 
                  . "] from host [$hostname]");
    print "Removing user ["
          . $user->username->username
          . "] from host [$hostname]\n";
    $user->delete;
  }
  $logger->info("Removing group records from host [$hostname]");
  print "Removing group records from host [$hostname]\n";
  foreach my $group(@groups){
    $logger->info("Removing Group ["
                  . $group->groupname->groupname . "]");
    print "Removing Group Record [" . $group->id . "]\n";
    $group->delete;
  }
  $logger->info("Removing host [$hostname] record [" . $host_record->id ."]");
  print "Removing host [$hostname] record [" . $host_record->id ."]\n";
  $host_record->delete;
}

=item B<pushFiles($hostname)>

Method to update the /etc/passwd,/etc/shadow and /etc/group oh host.
If no hostname supplied. Will try to get hosts list from $self->{servers}

=cut

sub pushFiles() {
  my ( $self, $hostname ) = @_;
  my $logger = $self->{logger};
  my $max_proc = $self->{max_push_proc};
  if(! $max_proc){
    $max_proc = 5;
  }
  my @hostlists;
  if($hostname){
    push(@hostlists,$hostname);
  }
  else{
    @hostlists = keys %{ $self->{servers} };
  }
  $logger->debug("Max PROC value set to [$max_proc] for pushing process");
  my $host_cnt = scalar @hostlists;
  $logger->info("Pushing files to [$host_cnt] host(s)");
  print "Pushing files to [$host_cnt] host(s)\n";
  PPFORK:
  my $pid = fork ();
  if($pid){
    print "Forking PID [$pid] for push file process for [$host_cnt] host(s)\n";
  }
  elsif(defined $pid){
    my $dbh = AFA::DBI->db_Main;
    $dbh->disconnect;
    my $process_count;
    foreach my $host(@hostlists){
      my $pid = fork();
      if($pid){
        $process_count++;
        $logger->debug("Push Server Process for host [$host] PID [$pid]");
        print "\nForking PID [$pid] for host [$host]\n";
        while( $process_count > 0 and $process_count >= $max_proc ){
          if(waitpid(-1,&WNOHANG)>0){
            $process_count--;
          }
        }
      }
      elsif( defined $pid ){
        my $agent = AFA::AcctAgent->new();
        my($results,$errors) = $agent->deliverFiles($host);
        $self->processResults($host,$results,$errors);
        exit 0;
      }
      else{
        $logger->error("Failed to fork for push process for host [$host]");
        print STDERR "Failed to fork for push process for host [$host]\n";
        redo;
      }
    }
    exit 0;
  }
  else{
    $logger->error("Could not fork push file process");
    print "Could not fork push file process\n";
    goto PPFORK;
  }
}

=item B<processResults($results,$errors)>

Method to process change home and change shell results from AFA::AcctAgent for each host.
$results,$errors are array refs recieved from AFA::AcctAgent->deliverFiles($hostname)

=cut

sub processResults(){
  my($self,$host,$results,$errors) = @_;
  my $db = $self->{db};
  my $logger = $self->{logger};
  if(! $host){
    $logger->error("Hostname was not specified");
    print STDERR "Hostname was not specified\n";
    exit 1;
  }
  foreach my $line(@$results){
    my($msg_type,$action,$remainder) = split(/:/,$line);
    next if $msg_type ne 'alert';
    my($username,$uid,$type,$status_msg,$msg) = split(/\|/,$remainder);
    my $user_record = $db->getHostPasswdEntry($host,{username => $username, uidnum => $uid});
    if($action eq 'changehome' and $type eq 'home'){
      if($status_msg =~ /Failed/){ 
        $logger->error("Failed to change home for [$username] on host [$host]: $msg");
        print STDERR "Failed to change home for [$username] on host [$host]: $msg\n";
        print STDERR "Please Fix this issue before attempting changing home for this user\n";
        $user_record->status('ACTIVE');
        $user_record->update;
      }
      elsif($status_msg eq 'already exists' or $status_msg eq 'Success'){
        $logger->info("Successfully created home directory for [$username] on host [$host]");
        print "Successfully created home directory for [$username] on host [$host]\n";
        $user_record->status('ACTIVE');
        $user_record->update;
      }
    }
    elsif($action eq 'changeshell' and $type eq 'shell'){
      if($status_msg eq 'Requested Shell Not Found'){
        $logger->error("Requested shell not found for [$username] on host [$host]. Setting shell to [$msg]");
        print STDERR "Requested shell not found for [$username] on host [$host]. Setting shell to [$msg]\n";
        $user_record->shell($msg);
        $user_record->status('ACTIVE');
        $user_record->update;
      }
      elsif($status_msg eq 'Success'){
        $logger->info("Successfully changed shell for [$username] on host [$host] shell [$msg]");
        print "Successfully changed shell for [$username] on host [$host] shell [$msg]\n";
        $user_record->shell($msg);
        $user_record->status('ACTIVE');
        $user_record->update;
      }
    }
  }
}

=item B<offlineHost($hostname)>

=cut

sub offlineHost() {
  my ( $self, $hostname ) = @_;
}

=item B<onlineHost($hostname)>

=cut

sub onlineHost() {

}

=item B<checkAnswer()>

=cut

sub checkAnswer() {
  my $self   = shift;
  my $logger = $self->{logger};
  my $answer = undef;
  while ( $answer ne "Y" or $answer ne "y" or $answer ne "n" or $answer ne "N" ) {
    print "Are you sure you want to continue? Y/N: ";
    my $answer = <STDIN>;
    if ( $answer =~ /quit|q/i ) {
      $logger->debug("User Answered with a quit");
      exit 0;
    }
    else {
      if ( $answer eq "Y" or $answer eq "y" ) {
        return 1;
      }
      elsif ( $answer eq "N" or $answer eq "n" ) {
        return 0;
      }
      else {
        system('clear');
      }
    }
  }
}

1;

__END__

=back

=head1 ABSTRACT

 EAMS CLI

=head1 DESCRIPTION

 EAMS CLI was built to manage the accounts inside of EAMS


=head1 EXPORT

 None by default.


=head1 AUTHOR

 Module Author: scpham@cisco.com

=head1 COPYRIGHT AND LICENSE

 Copyright 2005 by Cisco Systems

=cut



