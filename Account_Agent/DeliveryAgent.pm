package AFA::DeliveryAgent;

use lib '..';
use AFA::HMS;

use strict;

sub new {
  my $class = shift;
  my $self  = {};
  bless( $self, $class );
  return $self;
}

1;
