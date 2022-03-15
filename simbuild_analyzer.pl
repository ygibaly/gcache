#!/usr/intel/bin/perl 
#===============================================================================
#
#         FILE: strace_reader.pl
#
#        USAGE: ./strace_reader.pl  
#
#  DESCRIPTION: 
#
#      OPTIONS: ---
# REQUIREMENTS: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Yossef Gibaly (), yossef.gibaly@intel.com
# ORGANIZATION: 
#      VERSION: 1.0
#      CREATED: 12/31/19 10:57:49
#     REVISION: ---
#===============================================================================

use strict;
use warnings;

my $simbuild = join(" ", @ARGV);
if ($simbuild !~ /-sched\s+local/) {
    $simbuild.= " -sched local";
}
print "$simbuild\n";


my $strace_output_file = "/tmp/strace_output_$$";
`strace -s 999 -f -o $strace_output_file -e trace=file $simbuild`;



open my $LINES, $strace_output_file or die "Could not open $strace_output_file: $!";

my $model_root = `realpath $ENV{MODEL_ROOT}`;
chomp $model_root;

my @inputs;
my @outputs;
my %seen;

while( my $line = <$LINES>)  {  
  next unless ($line =~ /open\(/);
  $line =~ /.*open\("(.*)"/;
  my $file = $1;
  next if ($seen{$file});
  $seen{$file} = 1;
  next if (-d $file);


  my $path = `realpath $file`;
  chomp $path;
  next unless ($path =~ /$model_root/);
  if ($line =~ /O_WRONLY/ || $line =~ /RDWR/) {
    push(@outputs, $file);
  }
  elsif ($line =~ /O_RDONLY/) {
    push(@inputs, $file);
  }
}


print "INPUTS:\n";
print join("\n",@inputs);
print "\n";
print "OUTPUTS:\n";
print join("\n",@outputs);
print "\n";
