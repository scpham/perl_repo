#!/usr/bin/perl


use Data::Dumper;
use Getopt::Long;
use lib '/apps/lib';
use SUDO;



my @users = ();
my $file;
GetOptions('u|acct=s{,}' => \@user,
           'f|file=s' => \$file);

my $sudo = SUDO->new();

if( defined $file ){
    $sudo->ParseFile($file);
}




my @accts = ('sysadm','root','shareadm');

my @users = ();
foreach my $user(@accts){
    print STDERR "Processing account $user\n";
    push(@users,$sudo->GetGenericHostUsers($user,'test-host'));
}

print join("\n",@users);

