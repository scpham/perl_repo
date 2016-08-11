package AFA::Logger;
use strict;
use Data::Dumper;
use Log::Log4perl qw(get_logger :levels);
use AFA::Epage;
use AFA::Config qw(%afa_config);
use Exporter;
our @ISA    = qw(Exporter Log::Log4perl);
our @EXPORT = qw(get_logger dumpDebug);

$Data::Dumper::Purity = 1;
$Data::Dumper::Terse  = 0;    # don't output names where feasible
$Data::Dumper::Indent = 1;
my $dumpdata = 1;

my $logger_config = $afa_config{logger_config};
my $epage_user    = $afa_config{epage_user};

if ( !Log::Log4perl->initialized() ) {
  umask 0077;
  Log::Log4perl->init_once($logger_config);
  my $logger = get_logger("");
  $logger->debug('Logger Initialized');
}

$SIG{__DIE__} = sub {
  # Set to Ignore after the first die call. This prevents double and triple die messages.
  $SIG{__DIE__} = 'IGNORE';
  $Log::Log4perl::caller_depth++;
  my $logger = get_logger("");
  $logger->fatal(@_);
  $Log::Log4perl::caller_depth--;
  my $epage = AFA::Epage->new();
  $epage->sendPage($epage_user,\@_);
  #die @_;
};

sub dumpDebug($$) {
  my ( $string, $ref ) = @_;
  return if $afa_config{dumpdebug} == 0 || $afa_config{dumpdebug} eq 'false';
  my $logger = get_logger("");
  if ( $logger->is_debug() ) {
    $Log::Log4perl::caller_depth++;
    $logger->debug(
      $string,
      {
        filter => \&Dumper,
        value  => $ref
      }
    );
    $Log::Log4perl::caller_depth--;
  }
}

1;
