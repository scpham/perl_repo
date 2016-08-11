package AFA::Epage;
use strict;
use Data::Dumper;
use MIME::QuotedPrint;
use HTML::Entities;
use Mail::Sendmail;
use lib '..';
use AFA::Config qw(%afa_config);

# Need to do this, since this module is loaded in AFA::Logger
use Log::Log4perl qw(get_logger :levels);


sub new(){
  my $class = shift;
  my $self = {logger    => get_logger('AFA::Epage')};
  bless($self,$class);
  return $self;
}

sub sendPage(){
  my( $self, $epage_user, $message) = @_;
  my $logger = $self->{logger};
  my $boundary = "====" . time() . "====";
  my $pid = $$;
  my $epage_user = $afa_config{epage_user};
  my $caller = (caller(3))[3];
  my $line = (caller(1))[2];
  my %mail     = (
      from           => 'EAMS UUA Admin <eams-uua-admin@cisco.com>',
      subject        => "AFA Fatal Exception [$caller] PID [$pid]",
      to             => $epage_user,
      'content-type' => "multipart/alternative; boundary=\"$boundary\"",
      smtp           => 'rtp-core-1.cisco.com'
  );
  
  my $message_body = join("\n",@$message);
  $message_body = $caller . " -- Fatal Exception At Line: $line\n\n\n\n" . $message_body;
  my $plainformat = encode_qp $message_body;

  $boundary = '--' . $boundary;
  $mail{body} = <<MESSAGE_BODY;
$boundary
Content-Type: text/plain; charset="ios-8859-1"
Content-Transfer-Encoding: quoted-printable

$plainformat

$boundary
MESSAGE_BODY

  sendmail(%mail) || $logger->error("$Mail::Sendmail::error");
  $logger->info("Fatal Error Recieved.. Sending page to " . $epage_user );
  $logger->info("Paging message contains:\n" . join("\n",@$message));
}


1;