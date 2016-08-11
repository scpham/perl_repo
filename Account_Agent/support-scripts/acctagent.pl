#!/usr/cisco/bin/perl
use lib '/apps/afa_tools';
use AFA::AcctAgent;
use Getopt::Long;
my $host;
GetOptions('h|host=s' => \$host);
my $obj = AFA::AcctAgent->new();
my $hms = $obj->{hms};
$obj->deliverFiles($host);
