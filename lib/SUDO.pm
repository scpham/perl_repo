package SUDO;

=begin comment

$Id: SUDO.pm,v 1.14 2008/05/15 15:24:58 scpham Exp $
$Revision: 1.14 $
$Date: 2008/05/15 15:24:58 $
$Author: scpham $

=end

=head1 NAME

SUDO parser module.

=for comment

Perl Interface to sudo.

=head2 Available Methods

=over 12

=cut

use strict;
use warnings;
use Data::Dumper;

our $VERSION = sprintf("%d.%03d", q$Revision: 1.14 $ =~ /: (\d+)\.(\d+)/);

sub new() {
  my $class = shift;
  my $self = {
    Parsed_file => 0,
    Char_Marker => 120,

    # Aliases Counters for Positions tracker references
    Runas_Alias_Cnt => 0,
    User_Alias_Cnt  => 0,
    Host_Alias_Cnt  => 0,
    Cmnd_Alias_Cnt  => 0,

    # Aliases Position tracker references
    Runas_Alias_POS => {},
    User_Alias_POS  => {},
    Host_Alias_POS  => {},
    Cmnd_Alias_POS  => {},

    # Aliases Hash References
    Runas_Alias => {},
    User_Alias  => {},
    Host_Alias  => {},
    Cmnd_Alias  => {},

    # Definitions in Sudoers
    Definitions => [],

    # Mappings for each type of alias
    User_Mapping           => {},
    User_Host_Mapping      => {},
    Host_User_Mapping      => {},
    Cmnd_User_Host_Mapping => {},
    Generic_User_Mapping   => {},
    Definition_Mapping     => {},
    Singleton_Mapping      => {},
    User_Alias_Generic_Host_Mapping => {},

    # Cleaned out sudoers file stuffed into array ref. All '\n','\' and spaces are cleaned up.
    sudoers_aref => []
             };
  bless($self, $class);

  #$self->_Tie_Hashes();
  return $self;
}

=item B<CloneUserAccess($srcuser,$user)>

Method to clone a users access.

=cut

sub CloneUserAccess() {
  my ($self, $srcuser, $user) = @_;
  my $user_alias    = $self->{User_Alias};
  my $user_map      = $self->{User_Mapping};
  my $singleton_map = $self->{Singleton_Mapping};
  my @aliases       = keys %{ $user_map->{$srcuser} };
  foreach my $alias (@aliases) {
    $user_alias->{$alias}{$user}++;
  }
  my @singles = ();
  @singles = keys %{ $singleton_map->{$srcuser} };
  foreach my $host (@singles) {
    $singleton_map->{$user}{$host} = $singleton_map->{$srcuser}{$host};
  }
  if (!scalar @aliases and !scalar @singles) {
    print STDERR "Can't clone user access - User Not Found:[$srcuser]\n";
  }
}

=item B<AddHostToHostAlias($host_alias,$hostname)>

Method to add a host to a Host_Alias

=cut

sub AddHostToHostAlias() {
  my ($self, $ha_name, $hostname) = @_;
  my $host_alias = $self->{Host_Alias};
  if (exists $host_alias->{$ha_name}) {
    $host_alias->{$ha_name}{$hostname}++;
  }
  else {
    print STDERR "Can't add host to Host_Alias - Alias Not Found:[$ha_name]\n";
  }
}

=item B<AddUserToUserAlias($user_alias,$username)>

Method to add a user to a User_Alias

=cut

sub AddUserToUserAlias() {
  my ($self, $ua_name, $username) = @_;
  if (!$ua_name or !$username) {
    die "AddUserToUserAlias Missing args: User_Alias[$ua_name] Username[$username]\n";
  }
  my $user_alias = $self->{User_Alias};
  if (exists $user_alias->{$ua_name}) {
    $user_alias->{$ua_name}{$username}++;
  }
  else {
    print STDERR "Can't add user to User_Alias - Alias Not Found:[$ua_name]\n";
  }
}

=item B<DeleteUser($user)>

Method to delete a user. Deletes users from Singleton_Mapping and User_Alias Refs.

=cut

sub DeleteUser() {
  my ($self, $user) = @_;
  my @aliases       = keys %{ $self->{User_Mapping}->{$user} };
  my $singleton_map = $self->{Singleton_Mapping};
  my $user_alias    = $self->{User_Alias};
  foreach my $alias (@aliases) {
    delete $user_alias->{$alias}{$user};
  }
  delete $singleton_map->{$user};
}

=item B<DeleteHost($host)>

Method to delete host. Deletes from Singleton_Mapping and Host_Alias refs.

=cut

sub DeleteHost() {
  my ($self, $host) = @_;
  my $host_alias    = $self->{Host_Alias};
  my $singleton_map = $self->{Singleton_Mapping};
  foreach my $alias (keys %$host_alias) {
    delete $host_alias->{$alias}{$host};
  }
  foreach my $user (keys %$singleton_map) {
    delete $singleton_map->{$user}{$host};
  }
}

=item B<CreateNewAliases($alias_name,\@users,\@hosts,\@cmds)>

Method to create User_Alias,Host_Alias, and Cmnd_Alias. This will also add the definition of the new aliases.

=cut

sub CreateNewAliases() {
  my ($self, $name, $users_aref, $hosts_aref, $cmd_aref) = @_;
  my $ua_name = $self->_Create_Alias('User', $name, $users_aref);
  my $ha_name = $self->_Create_Alias('Host', $name, $hosts_aref);
  my $ca_name = $self->_Create_Alias('Cmnd', $name, $cmd_aref);
  my $definition_map = $self->{Definition_Mapping};
  push(@{ $definition_map->{$ua_name}{$ha_name} }, $ca_name);
}

=item B<ParseFile($filename)>

Method to parse sudoers file

=cut

sub ParseFile() {
  my ($self, $filename) = @_;
  $self->_GenSudoersArray($filename);
  my $sudoers_aref     = $self->{sudoers_aref};
  my $definitions_aref = $self->{Definitions};
  my $definition_seen  = {};
  foreach my $line (@$sudoers_aref) {
    next if $line =~ /^Defaults/;

    #print $line . "\n";
    if ($line =~ /Runas_Alias|User_Alias|Host_Alias|Cmnd_Alias/) {
      $self->_Build_Alias_Ref($line);
    }
    else {
      if (!exists $definition_seen->{$line}) {
        $definition_seen->{$line}++;
        push(@$definitions_aref, $line);
      }
    }
  }
  $self->{Parsed_file} = 1;
  $self->_Process_Definitions();
}

=item B<GetAliasListByUser($username)>

Accessor method for getting list of user aliases a user is in.

=cut

sub GetAliasListByUser() {
  my ($self, $username) = @_;
  my $ref = $self->{User_Mapping};
  return keys %{ $ref->{$username} };
}

=item B<GetUserAliasLists()>

Accessor Method for User_Alias. Returns array lists of all User_Alias names.

=cut

sub GetUserAliasLists() {
  my $self = shift;
  return keys %{ $self->{User_Alias} };
}

=item B<GetHostAliasLists()>

Accessor method for Host_Alias. Returns array lists of all Host_Alias

=cut

sub GetHostAliasLists() {
  my $self = shift;
  return keys %{ $self->{Host_Alias} };
}

=item B<GetCmndAliasLists()>

Accessor method for Cmnd_Alias. Returns array lists of all Cmnd_Alias.

=cut

sub GetCmndAliasLists() {
  my $self = shift;
  return keys %{ $self->{Cmnd_Alias} };
}

=item B<GetRunasAliasLists()>

Accessor method for Runas_Alias. Returns array lists of all Runas_Alias.

=cut

sub GetRunasAliasLists() {
  my $self = shift;
  return keys %{ $self->{Runas_Alias} };
}

=item B<GetDefinitionsLists()>

Access method for definitions. Returns lists of definitions.

=cut

sub GetDefinitionsLists() {
  my $self = shift;
  return @{ $self->{Definitions} };
}

=item B<GetUserAliasUsers($alias_name)>

Method to get list of users of a specified User_Alias. Returns array.

=cut

sub GetUserAliasUsers() {
  my ($self, $user_alias) = @_;
  return sort $self->_Get_Alias_Values($user_alias, 'User');
}

=item B<GetHostAliasHosts($alias_name)>

Method to get a list of hosts associated with a certain Host_Alias.

=cut

sub GetHostAliasHosts() {
  my ($self, $host_alias) = @_;
  return sort $self->_Get_Alias_Values($host_alias, 'Host');
}

=item B<GetCmndAliasCmds($alias_name)>

Method to get list of cmds associated with a Cmnd_Alias.

=cut

sub GetCmndAliasCmds() {
  my ($self, $cmnd_alias) = @_;
  return sort $self->_Get_Alias_Values($cmnd_alias, 'Cmnd');
}

=item B<GetGenericHostUsers($generic,$host,1)>

Access method to determine which users have access to a generic on specific host.
Specify 1 or true to include All users with the definition of ALL=ALL (System Admins,  application support)

=cut

sub GetGenericHostUsers() {
  my ($self, $generic, $host, $include_admin) = @_;
  my $ref = $self->{Generic_User_Mapping};
  if (!exists $ref->{$generic}) {
    return ();
  }
  my @results = ();
  if(defined $include_admin && $include_admin){
    push(@results, split(',', $ref->{'ALL'}{$host})) if exists $ref->{'ALL'}{$host};
    push(@results, split(',', $ref->{'root'}{$host})) if exists $ref->{'root'}{$host};
    push(@results, split(',', $ref->{'root'}{'ALL'})) if exists $ref->{'root'}{'ALL'};
  }
  if (exists $ref->{$generic}{'ALL'}) {
    @results = split(',', $ref->{$generic}{'ALL'});
  }
  if (exists $ref->{$generic}{$host}) {
    push(@results, split(',', $ref->{$generic}{$host}));
  }
  my @excludes = ();
  if (exists $ref->{$generic}{"!$host"}) {
    @excludes = split(',', $self->{Generic_User_Mapping}->{$generic}{"!$host"});
  }
  my $results_hash = {};
  foreach my $r (@results) {
    $results_hash->{$r}++;
  }
  foreach my $x (@excludes) {
    delete $results_hash->{$x} if exists $results_hash->{$x};
  }
  return sort keys %$results_hash;
}

=item B<GetAllUsers()>

Method returns all users that can su to any generic account.

=cut

sub GetAllUsers() {
  my ($self)      = @_;
  my $generic_map = $self->{Generic_User_Mapping};
  my %results     = ();
  foreach my $generic (keys %{$generic_map}) {
    foreach my $host (keys %{ $generic_map->{$generic} }) {
      foreach my $key (split(',', $generic_map->{$generic}{$host})) {
        $results{$key}++;

      }
    }
  }
  return keys %results;
}

=item B<WriteSudoersFile()>

Method to output the sudoers changes.

=cut

sub WriteSudoersFile() {
  my ($self, $outfile) = @_;
  my $default    = 'Defaults editor=/usr/local/bin/viwrapper,timestamp_timeout=480,syslog=local2';
  my @file_array = ();
  push(@file_array, $default);
  my $position_count   = 1;
  my %position_tracker = ();
  my @alias_name_array = qw/Runas User Host Cmnd/;
  foreach my $type (@alias_name_array) {
    my $alias_type  = $type . '_Alias';
    my $alias_ref   = $self->{$alias_type};
    my @alias_order = $self->_Get_Alias_Order($type);
    foreach my $alias (@alias_order) {
      my $alias_string = $alias_type . " $alias=";
      my @alias_values = sort keys %{ $alias_ref->{$alias} };
      if ((length(join(',', @alias_values)) + length($alias_string)) <= $self->{Char_Marker}) {
        my $joined_string = join(',', @alias_values);
        push(@file_array, $alias_string . $joined_string);
      }
      else {
        $self->_Build_String(\@file_array, \@alias_values, $alias_string);
      }
    }
  }
  $self->_WriteDefinitions(\@file_array, 'Definition');
  $self->_WriteDefinitions(\@file_array, 'Singleton');

  $self->_WriteFile(\@file_array, $outfile);

}

=head2 Private Methods

=item B<_Create_Alias($type,$aliasname,\@values)>

Method to create alias based on type. Returns the alias name.

=cut

sub _Create_Alias() {
  my ($self, $type, $name, $values_aref) = @_;
  my $alias_type = $type . '_Alias';
  my $alias_name;
  if ($type eq 'User') {
    $alias_name = $name . '_USR';
  }
  elsif ($type eq 'Host') {
    $alias_name = $name . '_HOSTS';
  }
  elsif ($type eq 'Cmnd') {
    $alias_name = $name . '_CMD';
  }
  else {

    # Runas_Alias
    $alias_name = $name;
  }
  my $alias_ref = $self->{$alias_type};
  foreach my $v (@$values_aref) {
    $alias_ref->{$alias_name}{$v}++;
  }
  return $alias_name;
}

=item B<_WriteFile()>

Method to write @file_array to a file.

=cut

sub _WriteFile() {
  my ($self, $file_array, $osudoers_file) = @_;
  if (!scalar @$file_array) {
    die "Can't Write sudoers file. File Array is empty\n";
  }
  if (!$osudoers_file) {
    die "Need to specify what file to create for sudoers file\n";
  }
  print "\nCreating new sudoers file: $osudoers_file\n";
  open(SUDOERS, ">$osudoers_file") || die "Can't write sudoers file: $osudoers_file\n";
  print SUDOERS join("\n", @$file_array), "\n";
  close SUDOERS;
}

=item B<_Reorder_Alias($alias_type)>

Method is to sort and create the order or aliases. This is required because their are dependencies when using nested aliases

=cut

sub _Reorder_Alias() {
  my ($self, $alias_type) = @_;
  my $alias_pos_ref     = $self->{ $alias_type . '_Alias_POS' };
  my $alias_ref         = $self->{ $alias_type . '_Alias' };
  my %assigned_position = ();
  my $position_counter  = 0;
  foreach my $alias_name (sort { $a cmp $b } keys %$alias_ref) {
    $assigned_position{$alias_name} = $position_counter++;
  }

# Do at least 1 pass. If a dependency is found, it will do another pass, until it resolves all dependencies, and no
# more dependency is found. For each dependency it finds, it adds another pass.
  my $passes = 1;
  while ($passes--) {
    foreach my $alias (sort keys %assigned_position) {
      my $high_marker = 0;
      my $alias_holder;
      my @values = ();
      if ($alias_type ne 'Cmnd') {
        @values = keys %{ $alias_ref->{$alias} };
      }
      else {
        my @temp_container = keys %{ $alias_ref->{$alias} };
        foreach my $cmd (@temp_container) {
          if ($cmd =~ /\(/) {
            my ($first, $command) = split(/\)/, $cmd);
            $command =~ s/\!//;
            $command =~ s/^\s+?//;
            $command =~ s/\s+?$//;
            push(@values, $command);
          }
          else {
            push(@values, $cmd);
          }
        }
      }
      foreach my $v (@values) {
        $v =~ s/\!//;
        if (exists $alias_ref->{$v}) {
          if ($assigned_position{$alias} < $assigned_position{$v}) {
            if ($high_marker < $assigned_position{$v}) {
              $high_marker  = $assigned_position{$v};
              $alias_holder = $v;
              $passes++;
            }
          }
        }
      }
      if ($high_marker) {
        my $temp = $assigned_position{$alias_holder};
        $assigned_position{$alias_holder} = $assigned_position{$alias};
        $assigned_position{$alias}        = $temp;
      }
    }
  }
  while (my ($k, $v) = each %assigned_position) {
    $alias_pos_ref->{$k} = $v;
  }
}

=item B<_WriteDefinitions>

Method is used to handle the Singleton_Mapping and the Definition_Mapping. This help build the @file_array with the
definitions part of sudoers.

=cut

sub _WriteDefinitions() {
  my ($self, $file_array, $name) = @_;
  my $type = $name . '_Mapping';
  my $map  = $self->{$type};
  foreach my $user_alias (sort keys %$map) {
    foreach my $host_alias (sort keys %{ $map->{$user_alias} }) {
      my $first_piece = $user_alias . " $host_alias=";
      my @values      = @{ $map->{$user_alias}{$host_alias} };

      my $joined_tmp = join(',', @values);
      @values = ();
      @values = $self->_split_comma($joined_tmp);
      if ((length(join(',', @values)) + length($first_piece)) <= $self->{Char_Marker}) {
        my $joined_string = join(',', @values);
        push(@$file_array, $first_piece . $joined_string);
      }
      else {
        $self->_Build_String($file_array, \@values, $first_piece);
      }
    }
  }
}

=item B<_Build_String(\@file_array,\@alias_values,$string_padding)>

Method is to build out the strings for sudoers syntax. Continus strings with the '\'

=cut

sub _Build_String() {
  my ($self, $file_array, $values_aref, $string) = @_;
  my @value_container = ();
  my $char_cnt        = length($string);
  my $padding         = length($string) - 1;
  my $element_tracker = 0;
  my $first_pass      = 0;
  foreach my $a_val (@$values_aref) {
    $element_tracker++;
    $char_cnt += length($a_val);
    push(@value_container, $a_val);
    if ($char_cnt >= $self->{Char_Marker}) {
      my $joined_string = join(',', @value_container);
      $char_cnt = $padding;
      if ($first_pass == 0) {
        if ($element_tracker == @$values_aref) {
          push(@$file_array, $string . $joined_string);
        }
        else {
          push(@$file_array, $string . $joined_string . " \\");
        }
        $first_pass = 1;
      }
      else {
        if ($element_tracker == @$values_aref) {
          push(@$file_array, ' ' x $padding . ',' . $joined_string);
        }
        else {
          push(@$file_array, ' ' x $padding . ',' . $joined_string . " \\");
        }
      }
      @value_container = ();
    }
  }
  if (scalar @value_container) {
    my $joined_string = join(',', @value_container);
    if ($first_pass == 0) {
      push(@$file_array, $string . $joined_string);
    }
    else {
      push(@$file_array, ' ' x $padding . ',' . $joined_string);
    }
  }
}

=item B<_Get_Alias_Order($alias_type)>

Method to get the alias output order.

=cut

sub _Get_Alias_Order() {
  my ($self, $type) = @_;
  my $alias_type_pos = $type . '_Alias_POS';

  #$self->_Check_Alias_Order($type) if $type ne 'Cmnd';
  $self->_Reorder_Alias($type);
  my @order_value        = sort { $a <=> $b } values %{ $self->{$alias_type_pos} };
  my @return_alias_names = ();
  my $alias_pos_ref      = $self->{$alias_type_pos};
  foreach my $num (@order_value) {
    foreach my $alias_name (keys %{$alias_pos_ref}) {
      if ($alias_pos_ref->{$alias_name} == $num) {
        push(@return_alias_names, $alias_name);
        last;
      }
    }
  }
  return @return_alias_names;
}

=item B<_Process_Definitions()>

Method to process definition hash. This is called inside of ParseFile()

Main purpose is to build the mapping hash tables

=cut

sub _Process_Definitions() {
  my $self          = shift;
  my $def_array_ref = $self->{Definitions};

  my $user_host_map = $self->{User_Host_Mapping};
  my $host_user_map = $self->{Host_User_Mapping};

  #my $cmd_map_href    = $self->{Cmnd_User_Host_Mapping};
  my $generic_map     = $self->{Generic_User_Mapping};
  my $definition_href = $self->{Definition_Mapping};

  my $singleton_map  = $self->{Singleton_Mapping};
  my $user_alias_ref = $self->{User_Alias};
  my $user_alias_generic_host = $self->{User_Alias_Generic_Host_Mapping};
  print "\nBuilding Dictionaries\n";
  foreach my $line (@$def_array_ref) {

    # Split the line into 2 pieces. Split by '='
    my ($temp1, $command_column) = split(/=/, $line);

    # Split the first piece into user and host columns
    my ($user_column, $host_column) = split(/\s+/, $temp1);

    my @user_aliases = split(/,/, $user_column);
    my @host_aliases = split(/,/, $host_column);

    my $users = $self->_Process_User_Host_Column($user_column, 'User');
    my $hosts = $self->_Process_User_Host_Column($host_column, 'Host');
    my $commands = $self->_Process_Command_Column($command_column);
    # These arrays will be used to keep track of Real user Aliases vs Singletons.
    my @user_aliases_generic_host = ();
    my @singletons_generic_host = ();
    foreach my $user_alias (@user_aliases) {
      foreach my $host_alias (@host_aliases) {
        if (!exists $user_alias_ref->{$user_alias}) {
          push(@singletons_generic_host,'Singleton');
          #push(@{ $singleton_map->{$user_alias}{$host_alias} }, \@commands);
          push(@{ $singleton_map->{$user_alias}{$host_alias} }, $command_column);
        }
        else {
          push(@user_aliases_generic_host,$user_alias);
          #push(@{ $definition_href->{$user_alias}{$host_alias} }, \@commands);
          push(@{ $definition_href->{$user_alias}{$host_alias} }, $command_column);
        }
      }
    }
    foreach my $user (@$users) {
      foreach my $host (@$hosts) {

       # Push the @commands into array stack. This is needed due to memory limitations.
       # The process was taking over 1g of memory for the BSH sudoers file to create hashes for each
       # command
        push(@{ $user_host_map->{$user}{$host} }, \@$commands);
        push(@{ $host_user_map->{$host}{$user} }, \@$commands);
      }
    }
    foreach my $host (@$hosts) {
      foreach my $cmd (@$commands) {
        if ($cmd eq 'ALL' or $cmd eq '(ALL) ALL' or $cmd eq '(ALL)ALL') {
          if (exists $generic_map->{'root'}{$host}) {
            $generic_map->{'root'}{$host} =
              join(',', split(',', $generic_map->{'root'}{$host}), @$users);
              $user_alias_generic_host->{'root'}{$host} = join(',',@user_aliases_generic_host,@singletons_generic_host);
          }
          else {
            $generic_map->{'root'}{$host} = join(',', @$users);
            $user_alias_generic_host->{'root'}{$host} = join(',',@user_aliases_generic_host,@singletons_generic_host);
          }

          #push(@{$generic_map->{'root'}{$host}},$user);
          #$generic_map->{'root'}{$host}{$user}++;
          if (exists $generic_map->{'ALL'}{$host}) {
            $generic_map->{'ALL'}{$host} =
              join(',', split(',', $generic_map->{'ALL'}{$host}), @$users);
              $user_alias_generic_host->{'ALL'}{$host} = join(',',@user_aliases_generic_host,@singletons_generic_host);
          }
          else {
            $generic_map->{'ALL'}{$host} = join(',', @$users);
            $user_alias_generic_host->{'ALL'}{$host} = join(',',@user_aliases_generic_host,@singletons_generic_host);
          }

          #push(@{$generic_map->{'ALL'}{$host}},$user);
          next;
        }
        elsif (($cmd =~ /\/su / and $cmd !~ /^\!/ and $cmd !~ /\(/)) {

          my $generic = $self->_Parse_Generic($cmd);
          if (exists $generic_map->{$generic}{$host}) {
            $generic_map->{$generic}{$host} =
              join(',', split(',', $generic_map->{$generic}{$host}), @$users);
              $user_alias_generic_host->{$generic}{$host} = join(',',@user_aliases_generic_host,@singletons_generic_host);
          }
          else {
            $generic_map->{$generic}{$host} = join(',', @$users);
            $user_alias_generic_host->{$generic}{$host} = join(',',@user_aliases_generic_host,@singletons_generic_host);
          }

          #push(@{$generic_map->{$generic}{$host}},$user);
        }
        else {
          next;
        }
      }
    }
  }
}

=item B<_Parse_Generic($string)>

Method parses a string and returns just the account name. String has to be in the form of /bin/su -

=cut

sub _Parse_Generic() {
  my ($self, $instring) = @_;
  my $string = (split(/\//, $instring))[-1];
  $string =~ s/\s+/ /g;
  $string =~ s/\s+?$//g;
  $string =~ s/^\s+?//;
  $string =~ s/su -/su/;
  if ($string eq 'su') {
    return 'root';
  }
  return (split(/\s+/, $string))[-1];
}

=item B<_Process_User_Host_Columns($string,$type)>

Method to process user or host columns only. The Command column requires much more indepth logic.
I found it cleaner to have this method seperate from the process command column method.

=cut

sub _Process_User_Host_Column() {
  my ($self, $instring, $type) = @_;
  my $alias_type = $type . '_Alias';
  my $alias_ref  = $self->{$alias_type};
  my (@return_array, @lists) = ();
  my $user_map = $self->{User_Mapping};
  @lists = split(/,/, $instring);
  foreach my $alias_name (@lists) {
    my $exclude = 0;

    if ($alias_name =~ /^\!/) {
      $exclude = 1;

      $alias_name =~ s/^\!//;
      $alias_name =~ s/^\s+?//;
      $alias_name =~ s/\s+?$//;
    }
    if (exists $alias_ref->{$alias_name}) {
      my @temp_results = $self->_Get_Alias_Values($alias_name, $type);
      if ($exclude) {
        foreach my $result (@temp_results) {
          push(@return_array, '!' . $result);
        }
      }
      else {
        push(@return_array, @temp_results);
      }
      if ($type eq 'User') {
        foreach my $r (@temp_results) {
          $user_map->{$r}{$alias_name}++;
        }
      }
    }
    else {
      if ($exclude) {
        push(@return_array, '!' . $alias_name);
      }
      else {
        push(@return_array, $alias_name);
      }
    }
  }
  if (scalar @return_array) {
    return \@return_array;
  }
  else {
    return undef;
  }
}

=item B<_Process_Command_Column>

Method to process command column. Returns array lists.

=cut

sub _Process_Command_Column() {
  my ($self, $instring) = @_;
  my @command_lists = $self->_split_comma($instring);
  my @return_lists  = ();
  my $runas_ref     = $self->{Runas_Alias};
  my $cmd_ref       = $self->{Cmnd_Alias};
  foreach my $cmd (@command_lists) {
    if ($cmd =~ /\(/) {
      my ($runas_name, $cmd_name) = split(/\)/, $cmd);
      $runas_name =~ s/\s+?$//;
      $runas_name =~ s/\(//;
      $runas_name =~ s/^\s+?//;

      $cmd_name =~ s/^\s+?//;
      $cmd_name =~ s/\s+?$//;

      # Process Runas
      my @runas_lists = split(/,/, $runas_name);
      my @runas_container = ();
      foreach my $runas (@runas_lists) {
        if (exists $runas_ref->{$runas}) {
          my @runas_temp = $self->_Get_Alias_Values($runas, 'Runas');
          foreach my $r (@runas_temp) {
            push(@runas_container, $r);
          }
        }
        else {
          push(@runas_container, $runas);
        }
      }

      # Process Commands
      my $exclude       = 0;
      my @cmd_container = ();
      if ($cmd_name =~ /\!/) {
        $exclude = 1;
        $cmd_name =~ s/\!//;
        $cmd_name =~ s/^\s+//;
      }
      if (exists $cmd_ref->{$cmd_name}) {
        my @cmd_temp = $self->_Get_Alias_Values($cmd_name, 'Cmnd');
        foreach my $c (@cmd_temp) {
          if ($exclude) {
            push(@cmd_container, '!' . $c);
          }
          else {
            push(@cmd_container, $c);
          }
        }
      }
      else {
        if ($exclude) {
          push(@cmd_container, '!' . $cmd_name);
        }
        else {
          push(@cmd_container, $cmd_name);
        }
      }

      # End processing Commands
      # Put everything back together
      my $runas_string = join(',', @runas_container);
      foreach my $cmd_val (@cmd_container) {
        push(@return_lists, '(' . $runas_string . ') ' . $cmd_val);
      }
    }
    else {
      my $exclude = 0;
      if ($cmd =~ /\!/) {
        $exclude = 1;
        $cmd =~ s/\!//;
        $cmd =~ s/^\s+?//;
        $cmd =~ s/\s+?$//;
      }
      if (exists $cmd_ref->{$cmd}) {
        my @cmd_temp = $self->_Get_Alias_Values($cmd, 'Cmnd');
        foreach my $c (@cmd_temp) {
          if ($exclude) {
            push(@return_lists, '!' . $c);
          }
          else {
            push(@return_lists, $c);
          }
        }
      }
      else {
        if ($exclude) {
          push(@return_lists, '!' . $cmd);
        }
        else {
          push(@return_lists, $cmd);
        }
      }
    }
  }

  # Return what we gathered
  if (scalar @return_lists) {
    return \@return_lists;
  }
  else {
    return undef;
  }
}

=item B<_Get_Alias_Values($name,$type)>

Method to pull alias values.
Example: _Get_Alias_Values('IOPS_SA','User');

=cut

sub _Get_Alias_Values() {
  my ($self, $name, $type) = @_;
  if ($self->{Parsed_file} == 0) {
    $self->ParseFile('sudoers');
  }
  my @final_values = ();
  my $alias_type   = $type . '_Alias';
  my $alias_ref    = $self->{$alias_type};

  if (!exists $alias_ref->{$name}) {
    print STDERR "Alias [$name] does not exists for type [$alias_type]\n";
    return undef;
  }
  foreach my $v (keys %{ $alias_ref->{$name} }) {
    my $exclude = 0;
    if ($v =~ /^\!/) {
      $exclude = 1;
      $v =~ s/\!//;
    }
    if (!exists $alias_ref->{$v}) {
      if ($exclude) {
        $v = '!' . $v;
      }
      push(@final_values, $v);
    }
    else {
      my @results_array = $self->_Get_Alias_Values($v, $type);
      if ($exclude) {
        foreach my $result (@results_array) {
          push(@final_values, '!' . $result);
        }
      }
      else {
        push(@final_values, @results_array);
      }
    }
  }
  my %dupes = ();
  foreach (@final_values) {
    $dupes{$_}++;
  }
  if (keys %dupes) {
    return keys %dupes;
  }
  else {
    return undef;
  }
}

=item B<_GenSudoersArray($filename)>

Generate sudoers array. Clean all entries of '\' and '\n'. Remove any unwanted spaces in the file as well.
Stuffs data in $self->{sudoers_aref}

=cut

sub _GenSudoersArray() {
  my ($self, $filename) = @_;
  chomp $filename;
  open(IPUT, "<$filename") || die "Can't open sudoers file for parsing: $!";
  my ($hold, @sudoers);
  while (<IPUT>) {
    chomp;
    next if /^#/;
    next if (/^\s+$/);
    next if (/^\n$/);
    $hold .= $_;
    $hold =~ s/\\(|\s+)$//;
    if (/\\(|\s+)$/) { next; }
    $hold =~ s/\s*?#.*$//;
    $hold =~ s/\s+/ /g;
    $hold =~ s/\s+(,)/$1/g;
    $hold =~ s/(,)\s+/$1/g;
    $hold =~ s/(\()\s+?/$1/g;
    $hold =~ s/\s+?(\))/$1/g;
    $hold =~ s/\s+?$//;
    next if $hold eq "";
    push(@sudoers, $hold);
    $hold = "";
  }
  close IPUT;
  $self->{sudoers_aref} = \@sudoers;
}

=item B<_split_comma($string)>

_split_comma($string) will split by comma, and ignore commas within ()..

=cut

sub _split_comma() {
  my ($self, $string) = @_;
  my @temp_array = split(/,/, $string);
  my (@array, @string_holder, $string_tracker, $temp);
  foreach my $element (@temp_array) {
    if ($element =~ /^\(|^\s+?\(/ and $element !~ /\)/ and !$string_tracker) {
      push(@string_holder, $element);
      $string_tracker = 1;
    }
    elsif ($string_tracker and $element =~ /\)/) {
      push(@string_holder, $element);
      $temp = join(',', @string_holder);
      push(@array, $temp);
      $temp           = "";
      @string_holder  = ();
      $string_tracker = 0;
    }
    elsif ($string_tracker) {
      push(@string_holder, $element);
    }
    else {
      push(@array, $element);
    }
  }
  return @array;
}

=item B<_Build_Alias_Ref($string)>

$string represents the alias string in sudo.
Example: User_Alias FOO_USERS=foo1,foo2

Builds alias hash references for lookups

=cut

sub _Build_Alias_Ref() {
  my ($self,        $string)       = @_;
  my ($temp_string, $alias_values) = split(/=/, $string);
  my ($alias_type,  $alias_name)   = split(/\s+/, $temp_string);

  # Variables to keep track of Alias Positions.
  my $alias_type_cnt = $alias_type . "_Cnt";
  my $alias_type_POS = $alias_type . "_POS";
  my $alias_pos_ref  = $self->{$alias_type_POS};
  if (!exists $alias_pos_ref->{$alias_name}) {
    $alias_pos_ref->{$alias_name} = $self->{$alias_type_cnt}++;
  }
  else {
    print STDERR "Alias Position Already Defined [$alias_name]\n";
    die "First Alias Found at Position:" . $alias_pos_ref->{$alias_name} . "\n";
  }
  my @values_array = ();
  if ($alias_type eq 'Cmnd_Alias') {
    @values_array = $self->_split_comma($alias_values);
  }
  else {
    @values_array = split(/,/, $alias_values);
  }
  my $h_ref = $self->{$alias_type};
  foreach my $val (@values_array) {

    $h_ref->{$alias_name}{$val}++;
  }
}

=item B<_Tie_Hashes()>

Use this method to set your hashes to be cached to disk. Depending on the size of the sudoers file,
the memory requirement might be too much, so this method was designed to store the hash data on disk.

=cut

sub _Tie_Hashes() {
  my $self = shift;

  # Declare modules that are required by MLDBM.
  use Fcntl;
  use Storable;
  use MLDBM qw(GDBM_File Storable);

  my @mapping_lists = qw/User_Host Host_User Cmnd_User_Host Generic_User/;
  mkdir('sudoers_cache', 0700);
  foreach my $map_name (@mapping_lists) {
    my $map_hash_name = $map_name . '_Mapping';
    my $map_hash      = $self->{$map_hash_name};
    tie %$map_hash, 'MLDBM', 'sudoers_cache/' . $map_hash_name, O_TRUNC | O_CREAT | O_RDWR, 0640
      or die "$!\n";
  }
}

=item B<GetUserForCommand($command)>

=cut

sub GetUsersForCommand(){
  my($self,$cmd) = @_;
  my $user_host_map = $self->{User_Host_Mapping};
  my $results = {};
  foreach my $user(keys %$user_host_map ){
    foreach my $host( keys %{ $user_host_map->{$user} }){
      my $c_aref = $user_host_map->{$user}{$host};
      foreach my $aref(@$c_aref){
        foreach my $c(@$aref){
          if($c =~ m#^$cmd#){
            $results->{$c}{$user}{$host}++;
          }
        }
      }
    }
  }
  return $results;
}

1;

__END__



=back

=head1 SYNOPSIS

 use SUDO;

 my $sudo = SUDO->new();
 $sudo->ParseFile('sudo');
 $sudo->CloneUserAccess("bob","billy");
 $sudo->AddHostToHostAlias("IOPS_HOSTS","jester");
 my @users_aliases = $sudo->GetUserAliasLists();
 $sudo->WriteSudoersFile("new.sudoers");

=head1 ABSTRACT

 SUDO Perl Interface

=head1 DESCRIPTION

 SUDO is a perl interface to the sudoers file.

=head1 EXPORT

 None by default.

=head1 SEE ALSO

 man sudoers

=head1 AUTHOR

 Module Author: scpham@cisco.com

=head1 COPYRIGHT AND LICENSE

 Copyright 2007 by Cisco Systems

=cut
