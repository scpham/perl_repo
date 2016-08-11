package AFA::Config;

=head1 NAME

AFA Configuration Module


=for comment

Config Module for AFA. Centralizes all config variables into a single file

$Id: Config.pm,v 1.3 2006/05/29 20:07:36 scpham Exp $
$Author: scpham $
$Date: 2006/05/29 20:07:36 $
$Revision: 1.3 $

=cut

=head2 Available Methods

=over 12

=cut

use strict;
use lib '..';
use Exporter;
use File::Basename;


BEGIN {
  our @ISA = qw(Exporter);
  our @EXPORT_OK = qw(%afa_config);
  my $config_file = dirname ((caller())[1]) . '/../conf/afa.conf';
  open(CONFIGFILE,"<$config_file") || die "Failed to open config file [$config_file]: $!\n";
  our %afa_config;
  while(<CONFIGFILE>){
    next if $_ !~ /=/;
    chomp;
    s/\s*=\s*/=/;
    my($key,$value) = split(/=/);
    $afa_config{$key} = $value;
  }
  close CONFIGFILE;
}



1;
