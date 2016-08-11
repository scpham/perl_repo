package ForkIT;


=for comment

  $Id: ForkIT.pm,v 1.1 2007/12/03 01:45:33 scpham Exp $
  $Author: scpham $
  $Revision: 1.1 $
  $Date: 2007/12/03 01:45:33 $

=cut


use strict;
use warnings;
use Data::Dumper;
use IO::Handle;
use Log::Log4perl qw(get_logger);
use POSIX ":sys_wait_h";


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

=item B<forkit(\@stack, $max_proc, $callback, $options)>

  Accepts:
    \@stack   = Stack of items to fork. I.E. Hostnames, Usernames
    $max_proc =  Max number of fork items at any given time
    $callback = Function to fork. The function will call called as $callback->($item, $options); $items are from the stack
    $options  = options to pass to callback function

=cut

sub forkit() {
  my ( $self, $stack, $max_proc, $forkit_cb, $options ) = @_;
  my $logger = $self->{logger};
  if(! $max_proc){
    $max_proc = 5;
  }
  $logger->debug("Max PROC value set to [$max_proc] for forkit process");
  my $stack_cnt = scalar @$stack;
  $logger->info("[$stack_cnt] stack items(s)");
  print "[$stack_cnt] stack items(s)\n";
  PPFORK:
  my $pid = fork ();
  if($pid){
    print "Forking PID [$pid] process for stack count [$stack_cnt]\n";
  }
  elsif(defined $pid){
    my $process_count;
    foreach my $item(@$stack){
      my $pid = fork();
      if($pid){
        $process_count++;
        $logger->debug("Process for stackID[$item] PID [$pid]");
        print "\nForking PID [$pid] for stack item [$item]\n";
        while( $process_count > 0 and $process_count >= $max_proc ){
          if(waitpid(-1,&WNOHANG)>0){
            $process_count--;
          }
        }
      }
      elsif( defined $pid ){
        $forkit_cb->($item,$options);
        exit 0;
      }
      else{
        $logger->error("Failed to fork for stack item [$item]");
        print STDERR "Failed to fork for stack item [$item]\n";
        redo;
      }
    }
    exit 0;
  }
  else{
    $logger->error("Could not fork process");
    print "Could not fork process\n";
    goto PPFORK;
  }
}



=for comment

  $Log: ForkIT.pm,v $
  Revision 1.1  2007/12/03 01:45:33  scpham
  Forking code to fork a function.


=cut



1;
