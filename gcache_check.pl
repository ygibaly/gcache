#!/usr/intel/pkgs/perl/5.14.1-threads/bin/perl
#===============================================================================
#
#         FILE: gcache_check.pl
#
#        USAGE: ./gcache_check.pl  
#
#  DESCRIPTION: 
#
#      OPTIONS: ---
# REQUIREMENTS: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Cyril Kleczewski (), cyril.kleczewski@intel.com
# ORGANIZATION: 
#      VERSION: 1.0
#      CREATED: 06/14/19 13:25:34
#     REVISION: ---
#===============================================================================

use strict;
use warnings;
use File::Find ;
use File::Find::Rule ;
use File::Temp  qw/ tempfile /;
use File::Path;
use File::Spec;
use List::Util qw(min max);
use List::MoreUtils qw(uniq);
use Cwd;
use Getopt::Long;
use Data::Dumper;
use threads;
use lib "$ENV{RTL_PROJ_BIN}/perllib";
use ToolConfig;

#for cmdline and stuff
#use ScopedVars;

our @ignore_output_patterns;
our $ignore_pattern_command;


# STAGE CONFIG
our @inputs;
our @inputs_exclude;
our @outputs;
our @outputs_exclude;
our @outputs_exclude_check;
our @tools;
our %inputs_per_dut;
our @inputs_files_files;
our @extra_candidates;
our $disable_local_cache;
our $load_all_dutconfig_from_dut_list;

my $num_args = $#ARGV + 1;
if ($num_args != 1) {
    print "\nUsage: gcache_check.pl <path_to_gcache_enabled_run>\n";
    exit 1;
}

our $uncached_model=$ENV{MODEL_ROOT};
our $cached_model=$ARGV[0];

my $exit_status = 0;
# Ignoring model_root
my $model_root_copy = $uncached_model;
$model_root_copy =~ s/^\/p//;
$model_root_copy =~ s/^\/nfs\/[^\/]+\/proj\///;
my $real_model_root = Cwd::realpath($uncached_model);
chomp $real_model_root;
my $ignore_uncached_model_root_command = "-e 's#\\(/p\\|/nfs/\\([^/]\\)\\+/proj\\)/$model_root_copy##g' -e 's#$real_model_root##g'";
#my_print("ignore_uncached = $ignore_uncached_model_root_command");
$model_root_copy = $cached_model;
$model_root_copy =~ s/^\/p//;
$model_root_copy =~ s/^\/nfs\/[^\/]+\/proj\///;
$real_model_root = Cwd::realpath($cached_model);
chomp $real_model_root;
my $ignore_cached_model_root_command = "-e 's#\\(/p\\|/nfs/\\([^/]\\)\\+/proj\\)/$model_root_copy##g' -e 's#$real_model_root##g'";
#my_print("ignore_cached = $ignore_cached_model_root_command");


if (!-d $cached_model) {
    print "\n Gcache Enabled Run: $cached_model doesn't exist\n";
    exit 2;
}

my $fullpath = File::Spec->rel2abs($0);
my $ProgramDir  = &dirname($fullpath);
do "$ProgramDir/global.cfg" if -e "$ProgramDir/global.cfg";

my $proj_cfg = ToolConfig::ToolConfig_get_tool_var("gcache","project_cfg");
my $config_file_dir = ToolConfig::ToolConfig_get_tool_var("gcache","config_file_dir");
my $model_global_config = $config_file_dir."global.cfg";

my @data = `ls -ltr $cached_model/target/cache_data/*/*gcache_passed | sed -e 's#.*cache_data/##' -e 's/_gcache_passed//' | tr "/" " "`;
chomp @data;
for (@data) {
    my ($dut ,$stage) = split(" ",$_);
    my_print("checking $dut $stage\n");
    $ENV{DUT} = $dut;
    if ($proj_cfg && -e $proj_cfg) {
        #my_print("Doing $proj_cfg");
        do $proj_cfg;
    }
    if ($model_global_config && -e $model_global_config) {
        #my_print("Doing $model_global_config");
        do $model_global_config;
    }

    my $stage_config = $config_file_dir.$stage.".cfg";
    #my_print("Doing $stage_config");
    do $stage_config;

    my $ignore_patterns_command = "";
    if (@ignore_output_patterns) {
        $ignore_patterns_command = "-e " .  join(" -e " , map {"'${_}d'"} @ignore_output_patterns);
    }

    my @parent_output_content = map {s/remote_content://r} grep {/^remote_content:/} @outputs;
    @outputs = grep {!/:/} @outputs;
    if (@parent_output_content) {
        my @parent_output;
        for my $file (@parent_output_content) {
            push(@outputs, &extract_files($uncached_model,$file));
        }
    }
    push(@outputs_exclude_check, @outputs_exclude);
    my @output_files = find_files($uncached_model,\@outputs,\@outputs_exclude_check); 
    for my $output_file (@output_files) {
        #my_print("Comparing $output_file\n");
        my $sha1 = `cat $uncached_model/$output_file | sed $ignore_uncached_model_root_command $ignore_patterns_command |  /usr/bin/sha1sum`; chomp $sha1;
        my $sha2 = `cat $cached_model/$output_file | sed $ignore_cached_model_root_command $ignore_patterns_command |  /usr/bin/sha1sum`; chomp $sha2;
        #my_print("uncached $sha1, cached $sha2\n");
        if ($sha1 ne $sha2) {
            my_print("$uncached_model/$output_file and $cached_model/$output_file are different !");
            my $dirname = `dirname $uncached_model/target/gcache/uncache/$output_file`; chomp $dirname; `mkdir -p $dirname`;
            $dirname = `dirname $uncached_model/target/gcache/cache/$output_file`; chomp $dirname; `mkdir -p $dirname`;
            `cat $uncached_model/$output_file | sed $ignore_uncached_model_root_command $ignore_patterns_command  > $uncached_model/target/gcache/uncache/$output_file`;
            `cat $cached_model/$output_file | sed $ignore_cached_model_root_command $ignore_patterns_command > $uncached_model/target/gcache/cache/$output_file`;
            $exit_status = 3;
        }
    }
}


exit $exit_status;


#inputs - 
#   model root
#   an array of paths
#   an array of paths to exclude
#
#outputs -
#   an array of all the files and directories under model_root/paths which aren't exluded
#

sub find_files {
  my $model_root = shift;
  my $rp_model_root = Cwd::realpath($model_root);
  my $paths = shift;
  my @expanded_paths;
  for (@$paths) {
    push(@expanded_paths,glob("$model_root/$_"));
  }
  my $exclude_paths = shift;
  my @output;
  for my $path (@expanded_paths) {
    next if $path ~~ @$exclude_paths;
    my $full_path = $path; #"$model_root/$path";
    my @files;
    if (-l $full_path) {
        @files = ("$full_path");
        my $rp_target = Cwd::abs_path($full_path);
        if ($rp_target =~ /$rp_model_root/) {
            push (@files, File::Find::Rule->in( "$rp_target" ));
        }
    }
    elsif (-d $full_path) {
      my $rule = File::Find::Rule->extras({ follow_skip => 2 });
      $rule->maxdepth(10000);
      @files =  $rule->in( "$full_path/" );
      #@files = File::Find::find({ follow => 1 }, $full_path);
      #@files =  File::Find::Rule->in( $full_path );
    }
    else {
      @files = glob("$full_path");
    }
    push (@output,@files);

  }
  my $model_name = $model_root;
  $model_name =~ s/\/$//;
  $model_name =~ s/.*\///;
  $_ =~ s/$model_root\/// for( @output );
  $_ =~ s/.*$model_name// for( @output );
  $_ =~ s/.*integrate_bundle[0-9]*// for (@output); #hack
  $_ =~ s/\/\//\// for( @output );
  $_ =~ s/\/$// for( @output );
  for (@output) {
    if (-d "$model_root/$_") {
        $_ .= "/";
    }
  }
  my @clean_output;
  for my $f (@output) {
    my $add = 1;
    for my $e (@$exclude_paths) {
        if ($f =~ /$e/) {
            $add = 0;
        }
    }
    push (@clean_output, $f) if ($add and ! -d "$model_root/$f");
  }
  return @clean_output;
}

sub extract_files {
    my $model_root = shift;
    my $file = shift;
    my @inputs;
    #this file can be expended:
    my @files = glob("$model_root/$file");
    for my $f (@files) {
    if (! -e $f) {
        my_print( "content input file $f doesn't exist - ignoring\n");
        next;
    }
    my @tmp_inputs = `cat $f | grep -v "^#" |sed 's/\$MODEL_ROOT//'`;
    chomp @tmp_inputs;
    push (@inputs,@tmp_inputs);
    }
    ##sanitize the inputs
    &sanitize($model_root,\@inputs);
    return @inputs;
}

sub sanitize {
    my $model_root = shift;
    my $files = shift;
  my $model_root_copy = $model_root;
  $model_root_copy =~ s/^\/p//;
  $model_root_copy =~ s/^\/nfs\/[^\/]+\/proj\///;
  my $real_model_root = Cwd::realpath($model_root);
  s#(/p|/nfs/[^/]+/proj/)$model_root_copy/##g for (@$files);
  s#$real_model_root/##g for (@$files);
  s# ##g for (@$files);
}

sub my_print {
    my $str = shift;
    my @broken_str = split("\n", $str);
    print "GCACHE: $_\n" for @broken_str;
    return;
}

