package AFA::ServerLoader;
use Data::Dumper;
use lib '..';
use AFA::Logger;
use AFA::DBI;
use AFA::HMS;
use AFA::Config qw(%afa_config);
use AFA::DB;
use strict;

=for

$Id: ServerLoader.pm,v 1.21 2006/08/15 21:53:25 scpham Exp $
$Revision: 1.21 $
$Date: 2006/08/15 21:53:25 $
$Author: scpham $

=cut

=item B<new()>

New Method Obviously

=cut

sub new {
  my $class = shift;
  my $self  = {
    hms      => undef,
    logger   => get_logger('AFA::ServerLoader'),
    script   => './server_data_gather.pl',
    db       => undef,
    data     => undef,
    hostname => undef,
    status   => undef,
    host     => {},
    passwd   => {},
    groups   => {}
  };
  
  bless( $self, $class );
  $self->_init();
  return $self;
}

=item B<_init()>

Private init() method

=cut

sub _init() {
  my $self = shift;
  $self->{hms} = AFA::HMS->new();
  $self->{db}  = AFA::DB->new();
  $self->{logger}->debug('Init AFA::ServerLoader');
}

=item B<getHostData($host,$script)>

Retrieve Host Data Using HMS. This needs to be ran first before genData method.

=cut

sub getHostData() {
  my ( $self, $host ) = @_;
  my $script = $self->{script};
  $self->{hostname} = $host;
  my $hmsobj = $self->{hms};
  $hmsobj->RunScript( $host, $script );
  ( $self->{data}, $self->{error} ) = $hmsobj->GetResults();
  $self->genData();
}

=item B<genData()>

Generate and filters the data into arrays/hash

=cut

sub genData() {
  my ($self) = @_;
  my $aref = $self->{data};
  my ( %host, %passwd, %groups );
  my ( $load_pass, $load_group, $res_status ) = 0;
  foreach my $line (@$aref) {
    chomp $line;
    if ( $line =~ /HOSTNAME/ ) {
      $res_status++;
      $host{hostname} = ( split ( /:/, $line ) )[-1];
      next;
    }
    if ( $line =~ /OSTYPE/ ) {
      $host{platform} = ( split ( /:/, $line ) )[-1];
      next;
    }
    if ( $line =~ /SHADOWFILE/ ) {
      $host{shadowfile} = ( split ( /:/, $line ) )[-1];
      next;
    }
    if ( $line =~ /PASSWD/ ) {
      $load_pass = 1;
      next;
    }
    if ( $line =~ /GROUPFILE/ ) {
      $load_pass  = 0;
      $load_group = 1;
      next;
    }
    if ($load_pass) {
      $passwd{$line}++;
      next;
    }
    if ($load_group) {
      $groups{$line}++;
      next;
    }
  }
  if ( $res_status == 0 ) {
    print "No Results for host: " . $self->{hostname} . "\n";
  }

  $self->{status} = $res_status;
  $self->{host}   = \%host;
  $self->{passwd} = \%passwd;
  $self->{groups} = \%groups;
}

=item B<loadRecs()>

Load Records Method, this loads the /etc/passwd,/etc/shadow and /etc/group into
EAMS

=cut

sub loadRecs() {
  my ($self) = @_;
  my $hostref   = $self->{host};
  my $passwdref = $self->{passwd};
  my $groupsref = $self->{groups};
  my $db        = $self->{db};
  my $logger    = $self->{logger};
  die "No records to load for host: " . $self->{hostname} . "\n" if $self->{status} == 0;
  my $host = $db->find_or_add( 'EAMS_Hosts', $hostref );
  my $htype = $db->find_or_add( 'EAMS_Host_Type', { type => 'host' } );
  my %users_hash;

  foreach my $pline ( keys %$passwdref ) {
    chomp $pline;
    my ( $username, $phash, $uid, $gid, $gecos, $home, $shell ) = split ( /:/, $pline );

    #my $usertype = $self->getType($username);
    my $usertype = 'unknown';
    my $uhashref = {
      username => $username,
      uidnum   => $uid,
    };
    $logger->info("Adding user to EAMS_Users table [$username]");
    my $user = $db->find_or_add( 'EAMS_Users', $uhashref );
    $users_hash{$username} = $user->id;

    if ( $phash eq "" ) {
      $phash = 'NP';
    }
    my $umapref = {
      username   => $user->id,
      hash       => $phash,
      gecos      => $gecos,
      primarygid => $gid,
      shell      => $shell,
      home       => $home,
      hostname   => $host->id,
      type       => $htype->id,
    };
   
    if ( !$gecos ) {
      delete $umapref->{gecos};
    }

    # Over Ride flag, This flag should be used when the data is already loaded, and
    # you want to sync the passwd hashes on the server to the DB.
    if ( exists $self->{over_ride} ) {
      delete $umapref->{hash};
    }
    $logger->debug("Adding user [$username] to host ["
                   . $host->hostname . "]\n"
                   . Dumper($umapref));
    my $umaprow = $db->find_or_add( 'EAMS_User_Mapping', $umapref );
    if ( exists $self->{over_ride} ) {
      if ( defined $phash ) {
        $umaprow->hash($phash);
        $umaprow->update();
      }
    }
    if ( $umaprow->status eq "" ) {
      $umaprow->status('ACTIVE');
      $umaprow->update;
    }
  }
  foreach my $gline ( keys %$groupsref ) {
    chomp $gline;
    my ( $groupname, $ghash, $gid, $remainder ) = split ( /:/, $gline );
    my @users = split ( /,/, $remainder );
    my $gref = {
      groupname => $groupname,
      gidnum    => $gid
    };
    $logger->info("Adding group [$groupname] to EAMS_Groups");
    my $group = $db->find_or_add( 'EAMS_Groups', $gref );
    my $gmapref = {
      groupname => $group->id,
      hostname  => $host->id
    };
    $logger->info("Adding group [$groupname] to host ["
                   . $host->hostname . "]");
    my $gmaprow = $db->find_or_add( 'EAMS_Group_Mapping', $gmapref );
    if ( defined $ghash ) {
      $gmaprow->hash($ghash);
      $gmaprow->update();
    }
    foreach my $u (@users) {
      chomp $u;
      my $gmapref = {
        groupname => $group->id,
        username  => $users_hash{$u},
        hostname  => $host->id
      };
      $logger->info("Adding user [$u] to group [$groupname] on host [" .
                     $host->hostname . "]");
      my $gmaprow = $db->find_or_add( 'EAMS_Group_Mapping', $gmapref );
      if ( defined $ghash ) {
        $gmaprow->hash($ghash);
        $gmaprow->update();
      }
    }
  }
}

1;
