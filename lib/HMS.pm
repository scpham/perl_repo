package HMS;
use strict;


require "flush.pl";
use IPC::Open3;
use IO::Select;
use IO::Handle;
use Logger;
use Config qw(%config);

use vars qw($VERSION);

$VERSION = '1.00';

=begin comment

$Id: HMS.pm,v 1.1 2007/01/22 18:20:24 scpham Exp $
$Revision: 1.1 $
$Date: 2007/01/22 18:20:24 $
$Author: scpham $

=end

=head1 NAME

EAMS Host Management System (HMS) Module

=for comment

EAMS HMS module, is built from hms_cli.
This module contains the base function of hms_cli which
is the current mechanism to run scripts on a remote host
without the need to have the script stored locally.

=head2 Available Methods

=over 12

=item B<new()>

method returns HMS obj.
Contains struct definition

=cut

sub new() {
  my $class = shift;
  my $self  = {
    'timeout'    => $config{hms_timeout},
    'logger'     => get_logger('HMS'),
    'verbose'    => undef,
    'writer'     => 1,
    'reader'     => 1,
    'error'      => 1,
    'pid'        => undef,
    '_script'    => undef,
    '_bootstrap' => undef,
    '_sshargs'   => undef,
    '_errors'    => [],
    '_results'   => [],
    '_sshdebug'  => []
  };
  bless( $self, $class );
  $self->_init();
  return $self;
}

=item B<_init()>

Private method that is called when new method is called.
This method also loads the bootstrap code for excution on the remote host

=cut

sub _init() {
  my $self = shift;
  $self->{logger}->debug('Init HMS');
  $self->_BootStrap();
}

=item B<_BootStrap()>

Private Method. Method creates the bootstrap code within the struct under _bootstrap key

=cut

sub _BootStrap() {
  my $self = shift;

  # Bootstrap code. Very small to avoid potential issues.
  $self->{_bootstrap} = << 'EOK';
'
$server=<STDIN>;
eval "$server";
if($@){
 die $@;
}
exit 0;
'
EOK

  # Code to Load the Perl Server
  $self->{_server} = << 'EOK';
use IPC::Open3;
require "flush.pl";
$SIG{ALRM} = sub { die "BootLoader Script Timed Out" };
my $data=<STDIN>;
my ($timeout,$script_type,$data) = split(/SCRIPT_TYPE--SCRIPT_TYPE--SCRIPT_TYPE/,$data);
my $python_filename = "/var/tmp/.$$-pyt-hms-$$-tmp$$";
print "BEGIN SCRIPT\n";
if($script_type =~ /perl/){
  eval {
    alarm($timeout);
    eval "$data";
    if($@){
      die $@;
    }
    alarm(0);
  };
}
else{
   $data =~ s/hms~hms~hms~hms/\n/g;
   my $script = $data;
   if($script_type !~ /python/){
      $script = "$script\n" . "exit $?;" . "\n";
   }
   eval {
      alarm($timeout);
      if ( $script_type =~ /python/ ){
         open (FH, ">>$python_filename") or $return = 1;
         die if $return;
         print FH $script;
         close FH;
         my @args = qw(/usr/bin/python);
         $pid = open3( \*WR, \*RD, \*RD, @args, $python_filename );
      }
      else{
	 $pid = open3( \*WR, \*RD, \*RD, $script_type);
	 print WR $script;
	 &flush(\*WR);
      }
      while(<RD>){
         print;
      }
      unlink $python_filename;
      alarm(0);
      close WR;
      close RD;
      waitpid( $pid, 0 );
   };
}
print "END SCRIPT\n";
if($@ =~ /BootLoader Script Timed Out/){
   if($script_type =~ /python/){
      unlink($python_filename);
   }
   print "BootLoader Script Timed Out\n";
   alarm(0);
}
elsif($@ =~ /Remote Script Timed Out/){
  print "Remote Script Timed Out";
}
else{
   if($@){
      print "BEGIN EVAL Error\n";
      print "$@\n";
      print "END EVAL Error\n";
   }
}
&flush(\*STDOUT);
&flush(\*STDERR);
exit 0;

EOK
  $self->{_server}    =~ s/\n|\r//g;
  $self->{_bootstrap} =~ s/\n|\r//g;
}

=item B<LoadScript($scriptfile)>

Public method to load scripts for use on the remote host
This method will takes a script file, and dumps it into a string variable.
for Perl scripts, it just removes the new line and any pod or comment blocks.
For shell/python scripts it removes comments, and replaces \n with hmshmshmshms.
On the receiving end, it converts it back to \n.


=cut

sub LoadScript() {
  my $self = shift;
  print "Loading Script\n" if $self->{verbose};
  my $logger = $self->{logger};
  $logger->debug("Loading Agent Script");
  my $file = shift;
  my $script_type;
  if ( -e $file ) {
    open( FILE, "<$file" ) || die "Can't Open Script to Load: $!";
    $self->{_script} = undef if exists $self->{_script};
    my $pod = 0;

    while (<FILE>) {
      if (/^#!\s*(.*)$/) {
        $script_type = $1;
        next;
      }
      $pod = 1, next if /\s*=(pod|head|item|back|over|for|begin)/i;
      $pod = 0, next if /\s*=(cut|end)/i;
      next if $pod;
      next if /^#/;
      if ( /#/ and $_ !~ /\$#/ and $_ !~ /\/.*?#.*?\// and $_ !~ /s#.*#.*#/ ) {
        s/#.*$//g;
      }
      $self->{_script} .= $_;
    }
    close FILE;
  }
  else {
    if ( defined $$file ) {
      $script_type = '/usr/local/bin/perl';
      $self->{_script} = $$file;
    }
    else {
      die "No Script to load or script not found\n";
    }
  }

  if ( $script_type !~ /perl/ ) {
    $self->{_script} =~ s/\n/hms~hms~hms~hms/g;
  }
  else {
    $self->{_script} =~ s/\n|\r//g;
    $self->{_script} =
      'local $SIG{ALRM} = sub { die "Remote Script Timed Out"; };'
      . "alarm($self->{timeout}); "
      . $self->{_script}
      . 'alarm(0);';
  }
  my $delimiter = 'SCRIPT_TYPE--SCRIPT_TYPE--SCRIPT_TYPE';
  $self->{_script} =
    $self->{timeout} . $delimiter . "$script_type" . $delimiter . $self->{_script};

}

=item B<_LoadSSH($hostname)>

Private method that loads the SSH Args
Currently we are still dependant on the ssh binaries
Method takes a hostname as an arg.

=cut

sub _LoadSSH() {
  my $self = shift;
  die "LoadSSH method takes hostname arg\n" if @_ < 1;
  my $host = shift;
  @{ $self->{_sshargs} } = (
    "ssh", "-vvv", '-l', 'root',
    "-o",
    "ChallengeResponseAuthentication=no", "-o",
    "PreferredAuthentications=publickey", "-o",
    "NumberOfPasswordPrompts=0",          "-o",
    "PasswordAuthentication=no",          "-o",
    "PubkeyAuthentication=yes",           "-o",
    "UseRsh=no",                          "-o",
    "RhostsAuthentication=no",            "-o",
    "RhostsRSAAuthentication=no",         "-o",
    "FallBackToRsh=no",                   "-o",
    "StrictHostKeyChecking=no",           "-o",
    "BatchMode=yes",                      $host,
    'PATH=/usr/local/bin:/usr/bin:/bin:\$PATH; export PATH;',
    'perl', "-e",
    "$self->{_bootstrap}"
  );
  print "Running LoadSSH($host)\n" if $self->{verbose};
}

=item B<GetFileHandles()>

Public method. Returns 2 filehandles, WR and RD.
WR = Writer handle
RD = Reader handle

C<my($writer,$reader) = $obj-E<gt>GetFileHandles();>

=cut

sub GetFileHandles() {
  my $self = shift;
  return ( $self->{writer}, $self->{reader}, $self->{error} );
}

=item B<RunScript($hostname,$scriptfile)>

Public method RunScript()
Uses IPC::Open3 to communicate with ssh and the bootstrap code
RunScript Calls LoadScript($file) and LoadServer($host)

=cut

sub RunScript() {
  my $self = shift;
  die "RunScript method requires 2 args: RunScript(\$hostname,\$scriptfile)\n" if @_ < 2;
  my $host = shift;
  my $file = shift;
  my $logger = $self->{logger};
  delete $self->{data};
  delete $self->{sshdebug};
  $logger->debug("Running Agent on host " . $host);
  print "Running RunScript($host,$file)\n" if $self->{verbose};
  $self->LoadScript($file);
  $self->LoadServer($host);
  $self->doIO("$self->{_script}\n");
}

=item B<LoadServer($host)>

Public method loads bootstrap code on the remote host, and prepares PERL for code execution.
LoadServer Calls _LoadSSH($host) to load the ssh command line args

=cut

sub LoadServer() {
  my $self   = shift;
  my $host   = shift;
  my $logger = $self->{logger};
  $self->{sshdebug} = undef;
  if ( !defined $host ) {
    die "LoadServer() method requires hostname arg\n";
  }
  $logger->debug("Loading Server");
  $self->_LoadSSH($host);
  $self->{hostname} = $host;
  $self->{pid} = open3( \*WR, \*RD, \*ERR, @{ $self->{_sshargs} } );
  my $pid = $self->{pid};
  $self->{r}      = IO::Select->new( *RD, *ERR );
  $self->{w}      = IO::Select->new(*WR);
  $self->{writer} = *WR;
  $self->{reader} = *RD;
  $self->{error}  = *ERR;

  # Load the Perl Server code.
  $self->doIO("$self->{_server}\n");
  $self->{sshdebug} =~ s/\r//g;
  if ( $self->checkServerStatus() ) {
    $logger->error( "Could not log in: " . $self->{ssh_error} );
    close $self->{writer};
    close $self->{reader};
    close $self->{error};
  }
  else {
    $logger->debug("Successfully Logged In: [$host]");
  }
}

=item B<checkServerStatus()>

Method to check if login to server was successful

=cut

sub checkServerStatus() {
  my ($self) = @_;
  my @connection_log = split ( /\n/, $self->{sshdebug} );
  if ( grep( /debug1: Authentication succeeded/, @connection_log ) ) {

    return;
  }
  my @search_strings =
    ( 'Name or service not known', 'Permission denied', 'Connection timed out' );
  foreach my $s (@search_strings) {
    if ( grep( /$s/, @connection_log ) ) {
      $self->{ssh_error} = $s;
      push ( @{ $self->{_errors} }, $s );
      return 1;
    }
  }
}

=item B<doIO($script)>

Method to avoid IO blocking calls.

=cut

sub doIO() {
  my ( $self, $script ) = @_;
  my $logger = $self->{logger};
  my $writer = $self->{writer};
  my $reader = $self->{reader};
  my $error  = $self->{error};
  my $r      = $self->{r};
  my $w      = $self->{w};
  my ( $rd_eof, $err_eof ) = 0;

  while ( my ( $rr, $ww ) = IO::Select->select( $r, $w ) ) {
    if ( $ww && @$ww ) {
      #$logger->debug("Writing to INPUT Stream");
      my $cnt = syswrite( $writer, $script );
      substr( $script, 0, $cnt, "" );
      if ( !$cnt ) {
        my $caller = ( caller(1) )[3];

        # See if caller was called from LoadServer method.
        # If it was then we want to return immediately.
        # Since we know the next call will be blocked waiting for script to run
        if ( $caller =~ /LoadServer/ ) {
          return;
        }
        undef $w;
      }
    }
    my $buffer;
    foreach my $in (@$rr) {
      my $cnt = sysread( $in, $buffer, 32768 );

      #print "Buffer: $buffer";

      if ( fileno($in) == fileno($reader) ) {
        #$logger->debug("Reading from OUTPUT Stream");
        $self->{data} .= $buffer;
      }
      elsif ( fileno($in) == fileno($error) ) {
        #$logger->debug("Reading from ERROR Stream");
        $self->{sshdebug} .= $buffer;
      }

      # If you use length to check here, it will cause an infinite loop.
      if ( !$cnt ) {
        if ( fileno($in) == fileno($reader) ) {
          $rd_eof = 1;
        }
        elsif ( fileno($in) == fileno($error) ) {
          $err_eof = 1;
        }

        # We want to avoid closing these handles, we might not be done with them.
        if ( $rd_eof && $err_eof ) {
          last;
        }
      }
    }
    if ( $rd_eof && $err_eof ) {
      last;
    }
  }
  $self->{data}     =~ s/\r//g;
  $self->{sshdebug} =~ s/\r//g;
}

=item B<GetResults()>

Public method returns results array ref
This method will process the data stream when called, and will return 3
array refs. Results,Errors and SSH Debug info.

my($res_ref,$err_ref,$ssh_debug) = $hms-E<gt>GetResults();

=cut

sub GetResults() {
  my $self = shift;
  my ( @results, @errors, @sshdebug ) = ();
  my ( $err_trk, $res_trk ) = 0;
  my $reader = $self->{reader};
  my $writer = $self->{writer};
  my $logger = $self->{logger};
  $logger->debug("Processing Results from host: " . $self->{hostname});
  $self->{_errors}   = [];
  $self->{_results}  = [];
  $self->{_sshdebug} = [];
  my @dat_array = split ( /\n/, $self->{data} );
  $self->{data} = undef;
  my @sshdebug = split ( /\n/, $self->{sshdebug} );

  foreach (@dat_array) {

    #print "STDOUT:$_\n";
    #while (<$reader>) {
    chomp;
    if (/BEGIN EVAL Error/) {
      $err_trk = 1;
      next;
    }
    if (/END EVAL Error/) {
      $err_trk = 0;
      next;
    }
    if (/BEGIN SCRIPT/) {
      $res_trk = 1;
      next;
    }
    if (/END SCRIPT/) {
      $res_trk = 0;
      next;
    }
    if ( $err_trk == 1 || /Script Timed Out/ ) {
      push ( @errors, $_ );
      next;
    }
    if ( $res_trk == 1 ) {
      push ( @results, $_ );
      next;
    }
  }
  waitpid( $self->{pid}, 0 );
  push ( @{ $self->{_sshdebug} }, @sshdebug );
  push ( @{ $self->{_errors} },   @errors );
  push ( @{ $self->{_results} },  @results );
  close $self->{reader};
  close $self->{error};
  close $self->{writer};
  return ( $self->{_results}, $self->{_errors}, $self->{_sshdebug} );
}

sub DESTROY() {
  my $self = shift;
  if ( defined fileno $self->{writer} ) {
    close $self->{writer};
  }
  if ( defined fileno $self->{reader} ) {
    close $self->{reader};
  }
  if ( defined fileno $self->{error} ) {
    close $self->{error};
  }
  waitpid( $self->{pid}, 0 );
}

1;

__END__

=back

=head1 SYNOPSIS

 use HMS;
 my $obj = HMS->new();
 $obj->RunScript('erp-tools',"/path/to/script");
 my ($results_ref, $error_ref, $ssh_debug) = $obj->GetResults();
 foreach (@$a_ref){
    print;
 }
 
   OR
 
 my($writer,$reader) = $obj->GetFileHandles();
 while(<$reader>){
 	print;
 }
 
  OR
 
 use HMS;
 require "flush.pl";
 my $script_file = '/path/to/script_file';
 my $script = $obj->LoadScript($script_file);
 my $obj = HMS->new();
 $obj->LoadServer($hostname);
 my($writer,$reader) = $obj->GetFileHandles();
 print $writer $script , "\n";
 &flush($writer);
 while(<$reader>){
 	print;
 }
 close $writer; close $reader;
 waitpid($obj->{pid},0);

=head1 ABSTRACT

 EAMS Host Management System Module.

=head1 DESCRIPTION

 HMS is a framework for delivering files and script execution on the remote host.
 Currently only script execution works as of 11/14/05


=head1 EXPORT

 None by default.

=head1 SEE ALSO

 hms_cli command line script


=head1 AUTHOR

 Orginal Author(hms_cli): stewrigh@cisco.com
 Module Author: scpham@cisco.com

=head1 COPYRIGHT AND LICENSE

 Copyright 2005 by Cisco Systems

=cut
