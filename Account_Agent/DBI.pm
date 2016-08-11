package AFA::DBI;
use strict;
use lib qw(/usr/cisco/packages/dbdoracle/8.1.7);
use AFA::Logger;
use AFA::Config qw(%afa_config);
use base 'Class::DBI::Oracle';
=begin comment

$Id: DBI.pm,v 1.49 2006/06/12 05:18:38 scpham Exp $
$Revision: 1.49 $
$Date: 2006/06/12 05:18:38 $
$Author: scpham $

=end comment

=head1 NAME

EAMS Account Fullfillment DBI API

=cut

delete $ENV{ORACLE_HOME};
$ENV{TNS_ADMIN} = $afa_config{tns_admin};
my $db_user     = $afa_config{eams_db_user};
my $db_pass     = $afa_config{eams_db_pass};
my $eams_sid    = $afa_config{eams_oracle_sid};


__PACKAGE__->set_db( 'Main', "dbi:Oracle:$eams_sid", $db_user, $db_pass,
  { AutoCommit => 1, RaiseError => 1, ShowErrorStatement => 1 } );

sub do_transaction {

  my ( $class, $code, @args ) = @_;
  $class->_invalid_object_method('do_transaction()') if ref($class);

  my @return_values = ();
  local $class->db_Main->{AutoCommit};

  eval {
    local $SIG{__DIE__} = 'DEFAULT';
    @return_values = $code->(@args);
  };
  if ($@) {
    my $error = $@;
    eval {
      local $SIG{__DIE__} = 'DEFAULT';
      $class->dbi_rollback; };
    if ($@) {
      my $rollback_error = $@;
      $class->_croak(
        "Transaction aborted: $error; " . "Rollback failed: $rollback_error\n" );
    }
    else {
      $class->_croak( "Transaction aborted (rollback " . "successful): $error\n" );
    }
    $class->clear_object_index;
    return;
  }
  else {
    $class->dbi_commit;
  }
  return (@return_values);

}
1;

package EAMS_Users;
use base 'AFA::DBI';
EAMS_Users->table('EAMS_USERS_DEV');
EAMS_Users->columns( All => qw/id username uidnum modifydate type createddate/ );
EAMS_Users->has_many( 'hosts',  'EAMS_User_Mapping'  => 'username' );
EAMS_Users->has_many( 'groups', 'EAMS_Group_Mapping' => 'username' );
EAMS_Users->sequence('EAMS_USERS_SEQ_DEV');
1;

package EAMS_Hosts;
use base 'AFA::DBI';
EAMS_Hosts->table('EAMS_HOSTS_DEV');
EAMS_Hosts->columns(
  All => qw/id hostname createddate sox org bu platform shadowfile support_group/ );
EAMS_Hosts->has_many( 'groups',  'EAMS_Group_Mapping' => 'hostname' );
EAMS_Hosts->has_many( 'passwds', 'EAMS_User_Mapping'  => 'hostname' );
EAMS_Hosts->has_many( 'jobs',    'EAMS_Job_Queue'     => 'hostname' );
EAMS_Hosts->has_a( 'support_group' => 'EAMS_Support_Groups' );
EAMS_Hosts->sequence('EAMS_HOSTS_SEQ_DEV');
1;

package EAMS_Host_Type;
use base 'AFA::DBI';
EAMS_Host_Type->table('EAMS_HOST_TYPE_DEV');
EAMS_Host_Type->columns( All => qw/id type/ );
EAMS_Host_Type->sequence('EAMS_HOST_TYPE_SEQ_DEV');
EAMS_Host_Type->has_many( 'host_type', 'EAMS_User_Mapping' => 'type' );
1;

package EAMS_User_Mapping;
use base 'AFA::DBI';
EAMS_User_Mapping->table('EAMS_USER_MAPPING_DEV');
EAMS_User_Mapping->columns(
  All =>
    qw/id username hash gecos primarygid shell home hostname type modifydate createddate status/
);
EAMS_User_Mapping->has_a( 'username' => 'EAMS_Users' );
EAMS_User_Mapping->has_a( 'hostname' => 'EAMS_Hosts' );
EAMS_User_Mapping->has_a( 'type'     => 'EAMS_Host_Type' );
EAMS_User_Mapping->sequence('EAMS_USER_MAPPING_SEQ_DEV');
__PACKAGE__->set_sql( passwd_entries =>
qq{select u.username,a.hash,u.uidnum,a.primarygid,a.gecos,a.home,a.shell,a.status,a.createddate,a.modifydate,h.hostname from eams_hosts_dev h,eams_users_dev u, eams_user_mapping_dev a where u.id = a.username AND h.id = a.hostname AND h.hostname = ?}
);
__PACKAGE__->set_sql( distinct_users =>
qq{select u.username,u.uidnum from eams_users_dev u, eams_user_mapping_dev a, eams_hosts_dev h where a.username = u.id AND a.hostname = h.id AND h.hostname=?}
);

1;

package EAMS_Groups;
use base 'AFA::DBI';
EAMS_Groups->table('EAMS_GROUPS_DEV');
EAMS_Groups->columns( All => qw/id groupname gidnum type/ );
EAMS_Groups->has_many( 'groups', 'EAMS_Group_Mapping' => 'groupname' );
EAMS_Groups->sequence('EAMS_GROUPS_SEQ_DEV');
EAMS_Groups->set_sql(
  distinct_groupnames => qq{ select distinct groupname from EAMS_GROUPS_DEV } );
EAMS_Groups->set_sql( distinct_gids => qq{ select distinct gidnum from EAMS_GROUPS_DEV } );
1;

package EAMS_Group_Mapping;
use base 'AFA::DBI';
EAMS_Group_Mapping->table('EAMS_GROUP_MAPPING_DEV');
EAMS_Group_Mapping->columns( All => qw/id groupname hash username modifydate hostname createddate/ );
EAMS_Group_Mapping->has_a( 'groupname' => 'EAMS_Groups' );
EAMS_Group_Mapping->has_a( 'username'  => 'EAMS_Users' );
EAMS_Group_Mapping->has_a( 'hostname'  => 'EAMS_Hosts' );
EAMS_Group_Mapping->sequence('EAMS_GROUP_MAPPING_SEQ_DEV');
1;

package EAMS_System_Accounts;
use base 'AFA::DBI';
EAMS_System_Accounts->table('EAMS_SYSTEM_ACCOUNTS_DEV');
EAMS_System_Accounts->columns( All => qw/id username/ );
EAMS_System_Accounts->sequence('EAMS_SYSTEM_ACCOUNTS_SEQ_DEV');
EAMS_System_Accounts->set_sql(
  distinct_sysaccts => qq{ select distinct username from EAMS_SYSTEM_ACCOUNTS_DEV } );
1;

package EAMS_Preferred_Groups;
use base 'AFA::DBI';
EAMS_Preferred_Groups->table('EAMS_PREFERRED_GROUPS_DEV');
EAMS_Preferred_Groups->columns( All => qw/id groupname gidnum/ );
EAMS_Preferred_Groups->sequence('EAMS_PREFERRED_GROUPS_SEQ_DEV');
EAMS_Preferred_Groups->set_sql(
  distinct_gids => qq{ select distinct gidnum from EAMS_PREFERRED_GROUPS_DEV } );
1;

package EAMS_Job_Queue;
use base 'AFA::DBI';
EAMS_Job_Queue->table('EAMS_JOB_QUEUE_DEV');
EAMS_Job_Queue->columns(
  All =>
    qw/id jobid hostname userargs taskid status action created completed message returncode username/
);
EAMS_Job_Queue->has_a( 'hostname' => 'EAMS_Hosts' );
EAMS_Job_Queue->sequence('EAMS_JOB_QUEUE_SEQ_DEV');
EAMS_Job_Queue->set_sql( resend => qq{ select * from EAMS_JOB_QUEUE_DEV where status='RESEND' } );
__PACKAGE__->set_sql(
  set_completed => qq{
   UPDATE __TABLE__
      SET completed = SYSDATE
    WHERE __IDENTIFIER__
}
);
1;

package EAMS_CEC;
use base 'AFA::DBI';
EAMS_CEC->table('EAMS_CEC');
EAMS_CEC->columns( All => qw/id username hash expiration_date changed_date status/ );
EAMS_CEC->has_a( 'username' => 'EAMS_Users' );
EAMS_CEC->sequence('EAMS_CEC_SEQ');
1;

package EAMS_Support_Groups;
use base 'AFA::DBI';
EAMS_Support_Groups->table('EAMS_SUPPORT_GROUPS_DEV');
EAMS_Support_Groups->columns( All => qw/id group_name cti duty_pager email/ );
EAMS_Support_Groups->has_many( 'hosts', 'EAMS_Hosts' => 'support_group' );
EAMS_Support_Groups->sequence('EAMS_SUPPORT_GROUPS_SEQ_DEV');
1;

__END__

=head1 SYNOPSIS

None
	
=head1 ABSTRACT

EAMS Account Fullfillment DBI using base Class::DBI::Oracle.
This is a container for all the Class definitions for Class::DBI::Oracle For EAMS.
This also serves as a DB Table relationships.


=head1 DESCRIPTION

EAMS DBI Class/Table Map.

=head1 EXPORT

None by default.

=head1 SEE ALSO

AFA::DB

http:://www.class-dbi.com

=head1 AUTHOR

Module Author: scpham@cisco.com

=head1 COPYRIGHT AND LICENSE

Copyright 2005 by Cisco Systems

=cut
