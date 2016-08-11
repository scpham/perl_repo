package AFA::AcctAgent;
use strict;
use Fcntl qw(:DEFAULT :flock);
use lib '..';
use AFA::Logger;
use AFA::Config qw(%afa_config);
use AFA::DB;
use AFA::HMS;

=for

$Id: AcctAgent.pm,v 1.42 2006/08/16 04:57:24 scpham Exp $
$Author: scpham $
$Date: 2006/08/16 04:57:24 $
$Revision: 1.42 $

=cut

sub new {
  my $class = shift;
  my $self  = {
    ignorelocal => $afa_config{ignore_local},
    lockdir   => $afa_config{acct_agent_lockdir},
    workdir   => $afa_config{acct_agent_workdir},
    locktimer => 300,
    logger    => get_logger('AFA::AcctAgent'),
    db        => undef,
    hms       => undef,
    code      => undef
  };
  bless( $self, $class );
  $self->_init();
  return $self;
}

sub _init() {
  my ($self) = @_;
  $self->{logger}->debug("Init AFA::AcctAgent");
  $self->{db}  = AFA::DB->new();
  $self->{hms} = AFA::HMS->new();
  my $logger   = $self->{logger};
  my $lockdir = $self->{lockdir};
  my $workdir = $self->{workdir};
  if ( !-e $lockdir ) {
    if ( !mkdir $lockdir, 0700 ) {
      die "Failed to create lock directory " . $lockdir . ": $!\n";
    }
    else {
      $logger->info("Created Lock Directory " . $lockdir);
    }
  }
  if( ! -e $workdir ){
    if( !mkdir $workdir,0700 ){
      die "Failed to create work directory " . $workdir . ": $!\n";
    }
    else{
      $logger->info("Created Work Directory " . $workdir);
    }
  }
  $self->_loadAgentCode();
}

sub createLock() {
  my ( $self, $host ) = @_;
  die "No lockfile specified: $host\n" if !$host;
  my $fh;
  my $lockfile = $self->{lockdir} .  '/' . $host . '.lock';
  sysopen( $fh, $lockfile, O_WRONLY | O_CREAT, 0600 )
    or die "Can't open file: $lockfile: $!";
  eval {
    local $SIG{ALRM} = sub { die "Timed Out Acquiring Lock: $lockfile"; };
    alarm( $self->{locktimer} );
    flock( $fh, LOCK_EX ) or die "Can't Aquire Lock On File: " . $lockfile . ":$!\n";
    alarm(0);
  };
  if ( $@ =~ /Timed Out Acquiring Lock/ ) {
    die "Timed Out Acquiring Lock: $lockfile for $host";
  }
  $self->{$host} = $fh;
}

sub deliverFiles() {
  my ( $self, $host ) = @_;
  die "No host specified for pushFiles() method\n" if !defined $host;
  $self->createLock($host);
  my $logger    = $self->{logger};
  my $hmsobj    = $self->{hms};
  my $db        = $self->{db};
  my $workdir   = $self->{workdir};
  my $ignore_local;
  if( $self->{ignorelocal} ne "" ){
    $ignore_local = 'my $IGNORE_LOCAL=' . $self->{ignorelocal};
  }
  else{
    $ignore_local = 'my $IGNORE_LOCAL="0"';
  }
  my $passwdref = $db->getHostPasswdFile($host);
  my $groupref  = $db->getHostGroupFile($host);
  my $code      = $self->_makeArrayStr( 'passwd', $passwdref ) . "\n\n";
  $code .= $self->_makeArrayStr( 'group', $groupref );
  $code .= 'my $MKDIR_HOMEDIRS="0";';
  $code .= "$ignore_local;";
  $code .= $self->{code};
  $self->{code} = $code;
  open( DUMP, ">$workdir/$host.aagent.pl" );
  print DUMP $self->{code} . "\n";
  close DUMP;
  eval {
    local $SIG{__DIE__} = 'DEFAULT';
    local $SIG{ALRM} = sub { die "Host Timed Out" };
    alarm(30);
    $hmsobj->RunScript( $host, \$self->{code} );
    $self->_loadAgentCode();
    alarm(0);
  };
  if($@ =~ /Host Timed Out/){
    $logger->debug("Killing SSH PID: " . $hmsobj->{pid} . " due to host time out: $host");
    kill 'INT', $hmsobj->{pid};
    sleep(2);
    kill 'KILL',$hmsobj->{pid};
    $self->_loadAgentCode();
    return ([0],["Host Timed Out"]);
  }
  elsif($@){
    $logger->debug("Killing SSH PID: " . $hmsobj->{pid} . " due to host time out: $host");
    kill 'INT', $hmsobj->{pid};
    sleep(2);
    kill 'KILL', $hmsobj->{pid};
    $self->_loadAgentCode();
    return([0],["Host Error -- $@"]);
  }

  my ( $resref, $errref, $sshdebug  ) = $hmsobj->GetResults();

  foreach my $line (@$resref) {
    $logger->debug("$host:$line");
  }
  if ( scalar @$errref ) {
    print "EVAL ERROR:\n";
    foreach (@$errref) {
      $logger->error($host . ':' . $_);
    }
  }
  close $self->{$host};
  return ( $resref, $errref );
}

sub _makeArrayStr() {
  my ( $self, $aname, $aref ) = @_;
  my $str   = 'my @' . $aname . '= (' . "\n";
  my $elems = $self->_makeArray($aref);
  $str .= $elems;
  $str .= ');';
  return $str;
}

sub _makeArray() {
  my ( $self, $aref ) = @_;
  my $astr;
  foreach (@$aref) {
    $astr .= "'$_',\n";
  }
  $astr =~ s/\,$//;
  return $astr;
}

sub _loadAgentCode() {
  my ($self) = @_;
  $self->{code} = << 'EOK';
'
use strict;
use File::Copy;
use Sys::Hostname;
use Fcntl qw(:DEFAULT :flock);

if( ! scalar @passwd or ! scalar @group ){
  &message('debug',"passwd or group array empty");
  die "Passwd or Group File Empty!";
}
elsif( scalar @passwd < 5 ){
  &message('debug',"Password File seems to be corrupt");
  &message('debug',"Dumping Password Contents");
  &message('debug',join("\n",@passwd));
  die "Corrupt Password File";
}
elsif( scalar @group < 5 ){
  &message('debug',"Group File seems to be corrupt");
  &message('debug',"Dumping Group File Contents");
  &message('debug',join("\n",@group));
  die "Corrupt Group File";
}

my $current_hostname = hostname;
$current_hostname =~ s/\.cisco\.com$//;

my $shadow_file = '/etc/shadow';
my $passwd_file = '/etc/passwd';
my $group_file  = '/etc/group';

my $shadow_tmp  = '/etc/.shadow_tmp';
my $passwd_tmp  = '/etc/.passwd_tmp';
my $group_tmp   = '/etc/.group_tmp';

my $LOCKFILE    = '/var/tmp/.hms.afa.lock';

my %files = ( $shadow_tmp => 1,
              $passwd_tmp => 1,
              $group_tmp  => 1,
              $LOCKFILE   => 1
            );


my $os = $^O;
my %mkdir_users;
my @avail_shells;
my $backupdir = '/var/tmp/eams_backup_files/';

my $isshadow = 0;
if(-e $shadow_file){
  $isshadow = 1;
}

sub cleanup(){
  &message('debug',"cleanup()");
  foreach my $file(keys %files){
    if( (! $isshadow and $file eq $shadow_tmp) ){
      next;
    }
    if(defined fileno $files{$file}){
      &message('debug',"Closing file ($file)");
      close $files{$file} or die "Failed to close $file: $!\n";
    }
    if(-e $file){
      &message('debug',"Removing tmp file ($file)");
      unlink $file;
    }
  }
}

sub sig_catcher(){
  my $sig = shift;
  die "Caught $sig, calling die\n";
}

$SIG{__DIE__} = sub {
                    &message('alert','error',"Cleanup Called Via Died: Something went wrong");
                    &message('alert','error',"Die Called with: @_");
                    &revert;
                    $SIG{__DIE__} = 'IGNORE';
                    };

$SIG{INT} = \&sig_catcher;
$SIG{HUP} = \&sig_catcher;
$SIG{TERM} = \&sig_catcher;
$SIG{STOP} = \&sig_catcher;
$SIG{ABRT} = \&sig_catcher;


&createFiles();

&chkRootUsage();
&backupFiles();
&createPasswdFile();
&createGroupFile();
&Finalize();
&setMode();
&mkhomes();
&cleanup();
exit 0;

sub revert(){
  &message('debug',"revert()");
  &cleanup();
  my $passwd_bk = $backupdir . "passwd.bk";
  my $shadow_bk = $backupdir . "shadow.bk";
  my $group_bk  = $backupdir . "group.bk";
  my %restore_map = (
                      $passwd_bk => $passwd_file,
                      $shadow_bk => $shadow_file,
                      $group_bk  => $group_file
                    );

  while( my ( $src, $dest ) = each %restore_map){
    if(! $isshadow and $src eq $shadow_bk ){
      next;
    }
    if(!copy($src,$dest)){
      &message('alert','email',"Failed to restore file $src to $dest> $!");
    }
    else{
      &message('alert','email',"Restored file $src to $dest");
    }
  }
  &setMode();
}

sub Finalize(){
  local $SIG{INT} = 'IGNORE';
  local $SIG{HUP} = 'IGNORE';
  local $SIG{TERM} = 'IGNORE';
  local $SIG{ABRT} = 'IGNORE';
  local $SIG{STOP} = 'IGNORE';
  my %sys_files = (
                  $passwd_tmp => $passwd_file,
                  $shadow_tmp => $shadow_file,
                  $group_tmp  => $group_file
                  );
  while(my ($src,$dest) = each %sys_files){
    if( ! $isshadow and $src eq $shadow_tmp ){
      next;
    }
    my $size = -s $src;
    if(! $size){
      die "$src file size was zero: $size\n";
    }
    if(!rename($src,$dest)){
      die "Failed to rename $src to $dest: $\n";
    }
    else{
      &message('debug',"Renamed ($src) to ($dest)");
    }
  }
}

sub setMode(){
  my %shadow_mode = (
                hpux    => sub {chmod 0600,'/etc/shadow';},
                solaris => sub {chmod 0400,'/etc/shadow';},
                linux   => sub {chmod 0600,'/etc/shadow';}
                );

  my %files_perm = (
                  hpux    => sub { chown '0','3',$_[0];},
                  solaris => sub { chown '0','0',$_[0];},
                  linux   => sub { chown '0','0',$_[0];}
                  );

  chmod 0644, $passwd_file;
  chmod 0644, $group_file;
  $files_perm{$os}->($passwd_file);
  $files_perm{$os}->($group_file);
  if($isshadow){
    $shadow_mode{$os}->();
    $files_perm{$os}->($shadow_file);
  }
}

sub getShell(){
  my $is_shell = shift;
  my @temp_shells = grep ( !/sbin/, @avail_shells );
  my @shells = grep(/\/$is_shell$/, @temp_shells);
  if( -e $shells[0] ){
    return ('1', $shells[0]);
  }
  return ('0','/bin/ksh');
}
  
sub getHomeDir(){
  my ($username) = shift;
  my @dirs = qw(/users /home);
  foreach my $dir(@dirs){
    if( -e $dir and -d $dir ){
      return "$dir/$username";
    }
  }
}

sub createPasswdFile(){
  my $shadow_handle = $files{$shadow_tmp};
  my $passwd_handle = $files{$passwd_tmp};
  my %shadow_fields = (hpux    => '::::::',
                       solaris => '::::::',
                       linux   => ':0:99999:7:::');

  my %seen;
  my $ret;
  foreach my $line(@passwd){
    my($username,$pwhash,$uid,$gid,$gecos,$home,$shell,$acct_status,$hostname,$lastchng) = split(/:/,$line);
    if($MKDIR_HOMEDIRS && $uid >= 2000){
    
      $acct_status = 'NOTCREATED';
    }
    if( $current_hostname ne $hostname ){
      die "Current hostname: $current_hostname does not match Password File for hostname: $hostname\n";
    }
    next if $acct_status eq 'DISABLED';
    if($acct_status eq 'NOTCREATED'){
      if( ! -e $shell ){
        ($ret,$shell) = &getShell($shell);
      }
      elsif( grep (/^$shell$/, @avail_shells) and $shell !~ /sbin/ ){
        $ret = 1;
      }
      else{
        $ret = 1;
      }
      if($ret){
        &message('alert','create',"$username|$uid|shell|Success|$shell");
      }
      else{
        &message('alert','create',"$username|$uid|shell|Requested Shell Not Found|$shell");
      }
      if(!$home){
        $home = &getHomeDir($username);
      }
      $mkdir_users{$username} = "$uid:$gid:$home:create";
    }
    elsif($acct_status eq 'CHANGESHELL'){
      ($ret,$shell) = &getShell($shell);
      if($ret){
        &message('alert','changeshell',"$username|$uid|shell|Success|$shell");
      }
      else{
        &message('alert','changeshell',"$username|$uid|shell|Requested Shell Not Found|$shell");
      }
    } 
    $seen{$username}++;
    if($acct_status eq 'CHANGEHOME'){
      $mkdir_users{$username} = "$uid:$gid:$home:changehome";
    }
    if($isshadow){
      print $passwd_handle "$username:x:$uid:$gid:$gecos:$home:$shell" . "\n";
      print $shadow_handle "$username:$pwhash:$lastchng" . $shadow_fields{$os} . "\n";
    }
    else{
      print $passwd_handle "$username:$pwhash:$uid:$gid:$gecos:$home:$shell" . "\n";
    }
  }
  my $passwd_diff = &getDiff(\%seen,$passwd_file);
  
  if($isshadow){
    my $shadow_diff = &getDiff(\%seen,$shadow_file);
    foreach my $l(@$shadow_diff){
      &message('alert','email',"Local Entries found (/etc/shadow) $l");
      print $shadow_handle $l , "\n";
    }
  }
  foreach my $l(@$passwd_diff){
    &message('alert','email',"Local Entries found (/etc/passwd) $l");
    print $passwd_handle $l , "\n";
  }
  if( $isshadow ){
    close $shadow_handle or die "Failed to close $shadow_tmp: $!\n";
  }
  close $passwd_handle or die "Failed to close $passwd_tmp: $!\n";
}

sub getDiff(){
  my ($href,$file) = @_;
  open(DIFF,"<",$file) or die "Can't Open file: $file: $!\n";
  my (%cmp_hash,%line);
  while(<DIFF>){
    chomp;
    my $user = (split(/:/))[0];
    $line{$user} = $_;
    $cmp_hash{$user}++;
  }
  close DIFF or die "Can't close file: $file: $!\n";
  my @local_additions;
  foreach my $x(keys %cmp_hash){
    if(!exists $$href{$x} and $x ne ""){
      push(@local_additions,$line{$x});
    }
  }
  if($IGNORE_LOCAL){
    @local_additions=();
  }
  return \@local_additions;
} 

sub createGroupFile(){
  my $group_handle = $files{$group_tmp};
  my (%seen,%group_line);
  foreach my $line(@group){
    my($group,$ghash,$gid,$users) = split(/:/,$line);
    $seen{$group}++;
    $group_line{$group} = $line;
    if(length($line) > 900){
      my @users_array = split(/,/,$users);
      my $char_cnt = 0;
      my @user_container = ();
      foreach my $u( @users_array ){
        if($char_cnt > 800){
          my $u_str = join(',',@user_container);
          print $group_handle "$group:$ghash:$gid:$u_str\n";
          @user_container = ();
          $char_cnt = 0;
        }
        push(@user_container,$u);
        $char_cnt += length($u);
      }
      if(@user_container){
        my $u_str = join(',',@user_container);
        print $group_handle "$group:$ghash:$gid:$u_str\n";
      }
    }
    else{
      print $group_handle "$group:$ghash:$gid:$users\n";
    }
  }
  my $group_diff = &getDiff(\%seen,$group_file);
  foreach my $g(@$group_diff){
    &message('alert','email',"Local Entries Found (/etc/group) $g");
    print $group_handle $g , "\n";
  }
  close $group_handle or die "Can't close file $group_tmp:$!\n";
}

sub mkhomes(){
  opendir(SKEL, '/etc/skel') or die "Can't Open /etc/skel dir:$!";
  my @skel_files = grep !/^\.$|^\.\.$/ ,readdir SKEL;
  close SKEL;
  foreach my $user(keys %mkdir_users){
    my($uid,$gid,$home,$type) = split(/:/,$mkdir_users{$user});
    if(-e $home and ! -d $home){
      &message('alert','case',"$user|$uid|home|Home Directory Creation Failed|$home exists but is not a directory");
      next;
    }
    elsif(-e $home and -d $home){
      my($dir_uid,$dir_gid) = (stat($home))[4,5];
      if($uid ne $dir_uid){
        &message('alert','case',"$user|$uid|home|Home Directory Creation Failed|$home exists, but is not owned by $user");
        next;
      }
      else{
        &message('alert',$type,"$user|$uid|home|already exists|$home");
      }
    }
    else{
      if(!mkdir $home, 0755){
        &message('alert','case',"$user|$uid|home|Home Directory Creation Failed|Failed to create $home ($!)");
        next;
      }
      else{
        chown $uid, $gid, $home;
        &message('alert',$type,"$user|$uid|home|Success|$home");
        foreach my $file(@skel_files){
          my $skelsrc = '/etc/skel/' . $file;
          if(! $home){
            &message('alert','email',"$user|$uid|home|Failed|home not defined");
            next;
          }
          my $dest = $home . "/$file";
          if( ! -e $dest ){
            if(!copy($skelsrc,$dest)){
              &message('alert','case',"$user|$uid|skel|Failed|Failed to copy $dest to $home ($!)");
              next;
            }
            else{
              chown $uid, $gid, $dest;
              &message('alert','notice',"$user|$uid|skel|Success|Copied skel file $skelsrc to $dest");
            }
          }
          else{
            &message('alert','notice',"$user|$uid|skel|warning|File already exists: $dest");
          }
        }
      }
    }
  }
}

sub createFiles(){
  &message('debug',"createFiles()");
  foreach my $file(keys %files){
    if( ! $isshadow and $file eq '/etc/.shadow_tmp' ){
      next;
    }
    &message('debug',"Creating file ( '$file' )");
    my $handle = &createLock($file);
    $files{$file} =  $handle;
  }
  open(SHELLS,"<",'/etc/shells') or die "Can't Open Shells File: $!";
  @avail_shells = <SHELLS>;
  chomp @avail_shells;
  close SHELLS;
}
 
sub createLock(){
  my ($file) = @_;
  &message('debug',"createLock( '$file' )");
  my $fh;
  sysopen($fh,$file,O_WRONLY|O_CREAT,0600) or die "Can't open file: $file: $!";
  flock($fh,LOCK_EX) or die "Can't Aquire Lock On File: " . $file . ":$!\n";
  truncate($fh,0);
  if($file eq '/var/tmp/.hms.afa.lock'){
    print $fh $$ , "\n";
  }
  return $fh;
}

sub chkRootUsage(){
  my %df = ( hpux    => '/usr/bin/df -k /',
             solaris => '/usr/bin/df -k /',
             linux   => '/bin/df -k /'
           );
  my $regex;
  if($os eq 'solaris' or $os eq 'linux'){
    $regex = q{.*? (\d+)\% .*$};
  }
  elsif($os eq 'hpux'){
    $regex = q{.*? (\d+) \% .*$};
  }
  my @output = `$df{$os}`;
  foreach my $line(@output){
    chomp $line;
    if($line =~ s/$regex/$1/g){
      my $usage = $line;
      if($usage > 95){
        die "Full Root Filesystem ($usage%)\n";
      }
    }
  }
}

sub backupFiles(){
  
  if(! -e $backupdir and ! -d $backupdir){
    if(!mkdir($backupdir,0700)){
      die "Failed to make dir $backupdir:$!";
    }
    else{
      &message('debug',"Created $backupdir");
    }
  }
  elsif( ! -d $backupdir and -e $backupdir ){
    die "$backupdir exists, but is not a directory\n";
  }
  my %hash = (
              '/etc/passwd' => $backupdir . "passwd",
              '/etc/shadow' => $backupdir . "shadow",
              '/etc/group'  => $backupdir . "group"
              );

  foreach my $filesrc(keys %hash){
    if( ! $isshadow and $filesrc eq '/etc/shadow' ){
      next;
    }
    &copyFile($filesrc,$hash{$filesrc},'.org');
    &copyFile($filesrc,$hash{$filesrc},'.bk');
  }
}
 
sub copyFile(){
  my ($filesrc,$filedest,$ext) = @_;
  $filedest .= $ext;
  die "Args required: Missing File Src and File Dest args\n" if (! defined $filesrc and ! defined $filedest);
  if(! defined $filedest){
    die "Function requires file destination\n";
  }
  if(-e $filesrc){
    if(-e $filedest and $ext eq '.org'){
      &message('debug',"Original File Already Exist ($filedest)");
      return 0;
    }
    if(!copy($filesrc,$filedest)){
      die "Failed to copy $filesrc to $filedest:$!\n";
    }
    else{
      chown '0','0', $filedest;
      chmod 0600,$filedest;
      &message('debug',"Copied ($filesrc) to ($filedest)");
    }
  }
  return 0;
}

sub message(){
  print join(':',@_) , "\n";
}
'
EOK

  $self->{code} =~ s/^'//;
  $self->{code} =~ s/'$//;
}
1;
