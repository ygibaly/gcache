#!/usr/intel/pkgs/perl/5.14.1-threads/bin/perl
#===============================================================================
#
#         FILE: fast_cache.pl
#
#        USAGE: ./fast_cache.pl  
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
#      CREATED: 03/14/19 10:15:59
#     REVISION: ---
#===============================================================================


use strict;
use warnings;
use File::Find ;
use File::Find::Rule ;
use File::Temp  qw/ tempfile /;
use File::Path;
use File::Spec;
use File::Compare;
use List::Util qw(min max);
use List::MoreUtils qw(uniq);
use Cwd;
use Getopt::Long;
use Data::Dumper;
use threads;
use lib "$ENV{RTL_PROJ_BIN}/perllib";
use ToolConfig;

#my $flowbee_path = &ToolConfig::ToolConfig_get_tool_path("rtltools/flowbee");
#unshift @INC , $flowbee_path; #same as use lib, but at runtime                                                                                        
use Storable qw(store retrieve freeze thaw dclone);


#for DutConfig
use vars qw(%DutConfig);


BEGIN {
  my $flowbee_path = &ToolConfig::ToolConfig_get_tool_path("rtltools/flowbee");
  unshift @INC , $flowbee_path; #same as use lib, but at runtime                                                                                        
}

#for cmdline and stuff
use ScopedVars;

# GLOBAL CONFIG
our $max_candidates;
our $max_candidate_age;
our @ignore_patterns;
our @disabled_stages;



# STAGE CONFIG
our @inputs;
our @inputs_exclude;
our @outputs;
our @outputs_exclude;
our @tools;
our %inputs_per_dut;
our @inputs_files_files;
our @extra_candidates;
our $disable_local_cache;
our $load_all_dutconfig_from_dut_list;
our $dont_sort_inputs;


if ((defined ($ENV{GK_DISABLE_GCACHE}) && $ENV{GK_DISABLE_GCACHE}) || (defined ($ENV{DISABLE_GCACHE}) && $ENV{DISABLE_GCACHE}) || (defined $ENV{GK_EVENT} && $ENV{GK_EVENT} =~ /release/) ) {
    my_print( "DISABLE_GCACHE is set - not runnig gcache\n");
    exit 1;
}


my $sttime = time;

my $fullpath = File::Spec->rel2abs($0);

my $ProgramDir  = &dirname($fullpath);
do "$ProgramDir/global.cfg" if -e "$ProgramDir/global.cfg";

my $proj_cfg = ToolConfig::ToolConfig_get_tool_var("gcache","project_cfg");
if ($proj_cfg && -e $proj_cfg) {
	do $proj_cfg;
}
my $model_global_config = ToolConfig::ToolConfig_get_tool_var("gcache","config_file_dir")."global.cfg";
if ($model_global_config && -e $model_global_config) {
	do $model_global_config;
}


my %opt;
GetOptions(\%opt,'cfg=s');
die "--cfg <cfg_file> is required" unless ($opt{cfg});
die "Can't read config file: $opt{cfg}\n" unless ( -e $opt{cfg});
do "$opt{cfg}";


print "dont sort inputs -> $dont_sort_inputs\n";
my @skip_stages = ToolConfig::ToolConfig_get_tool_var("gcache","force_disable_stages");
push (@skip_stages, @disabled_stages) unless ($ENV{GCACHE_IGNORE_DISABLED});

my $stage_name = $opt{cfg};
$stage_name =~ s/\.cfg$//;
$stage_name =~ s/^.*\///;
if ($stage_name ~~ @skip_stages || $stage_name =~ /intf|tr_report_tlm/  ) {
    my_print( "stage $stage_name is disabled from running gcache (configured from cfg)\n");
    exit 1;
}

my $original_model_root = $ENV{MODEL_ROOT};

my $model_root = $ENV{MODEL_ROOT}; 
$model_root =~ s#^/p#/nfs/site/proj#;
$model_root =~ s#^/nfs/^[/]+/proj#/nfs/site/proj#;

my_print( "running caching script for model $model_root\n");

die "no DUT set, can't run without DUT\n" unless ($ENV{DUT});

if ($inputs_per_dut{$ENV{DUT}}) {
    push (@inputs, @{$inputs_per_dut{$ENV{DUT}}});
}

my @content_inputs = map {s/content://r} grep {/^content:/} @inputs;

my @git_inputs = map {s/git://r} grep {/^git:/} @inputs;


my @parent_content = map {s/remote_content://r} grep {/^remote_content:/} @inputs;
my $dont_run_local_cache = 0;
for (@parent_content) {
    unless (-e "$model_root/$_") {
        $dont_run_local_cache = 1;
    }
}

my @dutconfig_keys = map {s/dutconfig://r} grep {/^dutconfig:/} @inputs;
my @duts_list = ($ENV{DUT});

if ($load_all_dutconfig_from_dut_list) {
  my @cfg_files = glob("$model_root/core/*/cfg/$ENV{DUT}.cfg");
  my $cfg_file = $cfg_files[0];
  my_print( "$cfg_file\n");
  unless (-e $cfg_file) {
    my_print( "didnt find file $model_root/core/*/cfg/$ENV{DUT}.cfg\n");
  }
  if (-e $cfg_file) {
    require $cfg_file;
    DutConfig->import;
    @duts_list = @{$DutConfig{duts_list}};

  }
}

@inputs = grep {!/:/} @inputs;


my_print( join("\n",@content_inputs));
my_print( "\n");

for my $file (@content_inputs) {
    push (@inputs,&extract_files($model_root,$file));
}


for (@git_inputs) {
	my @tmp = `cd $ENV{MODEL_ROOT} ; $ENV{RTL_PROJ_BIN}/git ls-files "$_"`;
	my_print(@tmp);
	chomp @tmp;
	push(@inputs , @tmp);
}






my @input_files = find_files($model_root, \@inputs, \@inputs_exclude);


my_print( "#################################\n\n");
my_print( join("\n",@input_files));
my_print( "\n");
my_print( "#################################\n\n");

my @local_output_files = find_files($model_root,\@outputs,\@outputs_exclude); 
################################################################################
# Local caching part
#
# Steps:
#   1. Make sure the stage ran (tasks.pl)
#   2. Make sure all outputs exist
#   3. Make sure all outputs where modified after last input was modified
################################################################################


if ( ! $disable_local_cache and (-e "$ENV{MODEL_ROOT}/target/cache_data/$ENV{DUT}/$stage_name" || -e "$ENV{MODEL_ROOT}/target/cache_data/$ENV{DUT}/${stage_name}_gcache_passed") and ! $dont_run_local_cache ) { #stage ran, and finished successfully at that time
    my @local_cache_input_files = @input_files;
    push (@local_output_files, @parent_content);
    #parent_content
    if (-e "$ENV{MODEL_ROOT}/target/cache_data/$ENV{DUT}/$stage_name") {
        my_print( "stage already ran successfully, checking for changes in input files\n");
    }
    elsif (-e "$ENV{MODEL_ROOT}/target/cache_data/$ENV{DUT}/${stage_name}_gcache_passed") {
        my_print( "stage already had a cache hit, checking for changes in input files\n");
        if (@tools) {
	    my @tmp =  glob("$model_root/$ENV{CFGDIR}/*ToolData.pm");
            s/$model_root\/// for @tmp;
            push (@local_cache_input_files, @tmp);
        }
    }
    my $last_input_modified = min ( map {-M "$model_root/$_"} @local_cache_input_files );
    my $last_input_modified_minutes = $last_input_modified*24*60;
    my_print( "last input was midified $last_input_modified_minutes minutes ago\n");

   @local_output_files = grep {! -d "$model_root/$_"} @local_output_files; 
    my $first_output_modified = max ( map {-M "$model_root/$_"} @local_output_files );
    my $first_output_modified_minutes = $first_output_modified*24*60;
    my_print( "first output was midified $first_output_modified_minutes minutes ago\n");
    if ($last_input_modified > $first_output_modified) {
        my_print( "no changes in input files, no need to run stage\n");
        exit 0;
    }
    else {
        my_print( "changes in input files, will look for matches in other models\n");
    }
}


################################################################################
#   basic idea
#   look at all the inputs - use md5
#   look at all the tools and the paths
#   compare to release/TI
#   copy output
#   remap output
################################################################################

my_print( "looking for matching models\n");


my @candidates = get_candidates($ENV{cluster_is},$ENV{STEPPING});
die "Didn't find any Candidates for cache\n" unless (@candidates);


#for dynamic inputs here we get the actual inputs from the Candidates
my %input_per_candidate;
my @extra_inputs;

if (@parent_content) {
#extract files...
		for my $model (@candidates) {
				my @tmp_input;
				# if configuration havn't changed we can use the stored data as the input files data
				my $parent_config_file = $opt{cfg};
				$parent_config_file =~ s/$model_root/$model/;

				my @parent_input;
				for my $file (@parent_content) {
								push(@parent_input, &extract_files($model,$file));
				}
				@tmp_input = find_files($model, \@parent_input, \@inputs_exclude);
				@{$input_per_candidate{$model}} = @tmp_input;
				push (@{$input_per_candidate{$model}},@input_files); #adding the non parent-specific inputs
				push (@extra_inputs,@tmp_input);
		}
}

push (@input_files,@extra_inputs);
@input_files = uniq (@input_files);

#my_print( "INPUT FILES:\n");
#my_print( join("\n",@input_files));
#my_print( "\n");
#my_print( "INPUT FILES END\n");



#my_print( join("\n",@input_files));
my $reference = get_cache_data_for_model($model_root,1);

mkpath "$model_root/target/cache_data/$ENV{DUT}/";
#store($reference,"$model_root/target/cache_data/$ENV{DUT}/${stage_name}_gcache");

my_print( "got cache data for local model - $model_root\n");

my %threads;
my %matches;

$threads{$_} = threads->create(\&get_cache_data_for_model, $_) for @candidates;
$matches{$_} = $threads{$_}->join() for @candidates;
my $selected_model = undef;
my_print( "Matching models:\n");
for (@candidates) {
    if ($matches{$_}) {
        my_print( "$_\n");
        $selected_model = $_ unless $selected_model; # take the first one that matches
    }
}
my $ttime = time - $sttime;
my_print( "looking for matches took $ttime seconds\n");
my $inputs_file_handler;
my @final_inputs;
if ( ! @parent_content || ($selected_model && $input_per_candidate{$selected_model})) {
	open ($inputs_file_handler,'>',"$model_root/target/cache_data/$ENV{DUT}/${stage_name}_input_files");
	@final_inputs = @input_files;
	@final_inputs = @{$input_per_candidate{$selected_model}} if ( @parent_content);
	print $inputs_file_handler join("\n",@final_inputs);
	close ($inputs_file_handler);
}

die "Didn't find any matches for cache, running the stage\n" unless ($selected_model);

######
$selected_model = Cwd::abs_path($selected_model);

#dynamic outputs
my @parent_output_content = map {s/remote_content://r} grep {/^remote_content:/} @outputs;

@outputs = grep {!/:/} @outputs;


if (@parent_output_content) {
        my @parent_output;
        for my $file (@parent_output_content) {
            push(@outputs, &extract_files($selected_model,$file));
        }
}



my @output_files = find_files($selected_model,\@outputs,\@outputs_exclude); 

exit 0 unless (@output_files); # if no output for some reason we are done

my $output_fh;
my $output_file_name = "$model_root/target/cache_data/$ENV{DUT}/${stage_name}_output_files";
open ($output_fh , '>' ,$output_file_name);
print $output_fh  join("\n",@output_files);

#faster way to rsync

my $split_output_files = "/tmp/output_split_$$";
`/usr/bin/split $output_file_name -l 3000 $split_output_files`;
my $rsync_cmd = "ls $split_output_files* | xargs -P 40 -n 1 -Ixxx /usr/intel/bin/rsync -p --chmod=u+w --links --files-from=xxx $selected_model $model_root";

my_print( "running rsync command: $rsync_cmd");
`$rsync_cmd`;
die "Syncing from model $selected_model failed\n" if ($?);

#copy_outputs($output_files_list_XXXXX);

remap_output($selected_model,$model_root,$output_file_name);
my_print( "Caching script passed\n");

exit 0;



sub get_cache_data_for_model {
  my $model_root = shift;
  my $store = shift; #should we return the result or just use it as referernce?
  my %result;
  my $ret_data;
  unless ($store) {
     $ret_data = Storable::retrieve("$model_root/target/cache_data/$ENV{DUT}/${stage_name}_gcache");
  }


  #DutConfig part
  if (@dutconfig_keys) {
    my_print( "in dutconfig\n");
    for my $dut (@duts_list) {
        my_print( "looking for $model_root/core/*/cfg/$dut.cfg\n");
    my @cfg_files = glob("$model_root/core/*/cfg/$dut.cfg");
    my $cfg_file = $cfg_files[0];
    my_print( "$cfg_file\n");
    unless (-e $cfg_file) {
        my_print( "didnt find file $model_root/core/*/cfg/$dut.cfg\n");
    }
    if (-e $cfg_file) {
        $ENV{MODEL_ROOT} = $model_root;
    # If this dut has a config file, then use it.
      require $cfg_file;
      DutConfig->import;
      for my $key (@dutconfig_keys) {
          my $value = Dumper($DutConfig{$key}); 
          my_print( "DUTCONFIG $model_root $dut $key $value\n");
          if ($store) {
              $result{DutConfig}{$dut}{$key} = $value;
          }
          else {
          my_print( "DutConfig mismatch in model $model_root\nlocal DutConfig->{$dut}->{$key}:\n$reference->{DutConfig}->{$dut}->{$key}\nreference DutConfig:\n$value\n") unless ($reference->{DutConfig}->{$dut}->{$key} eq $value);
          return 0 unless ($reference->{DutConfig}->{$dut}->{$key} eq $value);
          }
        }
    }
    $ENV{MODEL_ROOT} = $original_model_root;
  }
  }


#for dynamic inputs 
  my @current_input_files = @input_files;
  if ($input_per_candidate{$model_root}) {
    my_print( "dynamic inputs for model $model_root\n");
    @current_input_files = uniq(@{$input_per_candidate{$model_root}});
    my_print( join("\n",@current_input_files));
    my_print( "\n");
    my_print( "end dynamic inputs\n");
  }


  # Ignoring model_root
  my $model_root_copy = $model_root;
  $model_root_copy =~ s/^\/p//;
  $model_root_copy =~ s/^\/nfs\/[^\/]+\/proj\///;
  my $real_model_root = Cwd::realpath($model_root);
  chomp $real_model_root;
  my $ignore_model_root_command = "-e 's#\\(/p\\|/nfs/\\([^/]\\)\\+/proj\\)/$model_root_copy##g' -e 's#$real_model_root##g'";
  my $ignore_patterns_command = "";
  if (@ignore_patterns) {
   $ignore_patterns_command = "-e " .  join(" -e " , map {"'${_}d'"} @ignore_patterns); 
  }
#tools
    for my $tool (@tools) {
      my $tool_info_hash;
      if ($ret_data->{tool}{$tool}) {
        $tool_info_hash = $ret_data->{tool}{$tool};
      }
      else {
        $tool_info_hash = `export MODEL_ROOT=$model_root ; ToolConfig.pl show_tool_info $tool | sed  $ignore_model_root_command  | /usr/bin/sha1sum`;
        chomp $tool_info_hash;
        $tool_info_hash =~ s/ .*//;
      }
        if ($store) {
            $result{tool}{$tool} = $tool_info_hash;
       }
       else {
            my_print( "tool mismatch in model $model_root Tool: $tool hash: $tool_info_hash Local tool hash: $reference->{tool}{$tool}\n")  unless ($reference->{tool}{$tool} eq $tool_info_hash); #...
            return 0  unless ($reference->{tool}{$tool} eq $tool_info_hash); #...
       }
    }


  my_print( "$model_root\n");
    for my $f (@current_input_files) {
      my $file = $model_root . "/" . $f;
      next if (-d $file);
      #my_print( "$file not exist\n") if (! -e $file);
      my $hash;
      if ($ret_data->{$f}) {
        $hash = $ret_data->{$f};
      }
      else {
      unless ( -e $file) {
        $hash = -1;
      }
      else {
	my $sort_part = $dont_sort_inputs ? "" : "| sort";
      my $sh1 = `cat $file | sed $ignore_model_root_command $ignore_patterns_command $sort_part |  /usr/bin/sha1sum`;
      chomp $sh1;
        $sh1 =~ s/$model_root\///;
        ($hash,undef) = split(/\s+/,$sh1);
      }
      }
        if ($store) {
            $result{$f} = $hash;
        }
        else {
            my_print( "mismatch in file $file in model $model_root ($reference->{$f} vs $hash) \n") unless ($reference->{$f} eq "$hash");
            return 0 unless ($reference->{$f} eq "$hash");
        }
    }


    #cmdline part:
    my_print( "stage is $stage_name\n");
    my_print( "looking for $model_root/target/flow_data/*$ENV{DUT}*/*$stage_name*gz\n");
    my $scopes_file = ( sort {-M $a <=> -M $b} glob("$model_root/target/flow_data/*$ENV{DUT}*/*$stage_name*gz") )[0];
    if ($scopes_file) {
    my_print( "scopes file: $scopes_file\n");
    my @lines = `zcat $scopes_file`;

    my $str = join ("", @lines);

    my $scopes  = eval $str;
    if ($?) {
        my_print( $@);
    }
    my_print( join("\n", @{$scopes->{opts_ref}})); #check the sorting mechanism of simbuild
    my $cmdline = join(" ", @{$scopes->{opts_ref}});
    if ($store) {
        $result{cmdline} = $cmdline;
    }
    else {
        my_print( "cmdline mismatch in model $model_root\nlocal cmdline:\n$reference->{cmdline}\nreference cmdline:\n$cmdline\n") unless ($reference->{cmdline} eq $cmdline);
      #  return 0 unless ($reference->{cmdline} eq $cmdline);
    }
    }
    else { #scopes file not exist 
        my_print( "couldn't find scope file $model_root/target/flow_data/*$ENV{DUT}*/*$stage_name*gz - can't get stage cmdline\n");
    }

    #my $end = time;
    return \%result if $store;
    return 1;
}


#get all models to be searched, first releases then TI's, from newest to oldest

sub get_candidates {
    my_print( "Candidates for cache:\n");
    my $cluster = shift;
    my $stepping = shift;
    my @releases = `mysql --defaults-file=$ENV{GK_CONFIG_DIR}/db_reader_credentials.cnf -r -B -N -e "select distinct symlink_path from releases where cluster='$ENV{cluster_is}' and branch='$ENV{branch_is}' and stepping='$ENV{STEPPING}'    and status='released'"`; #glob("$ENV{RTLMODELS}/$cluster/*$stepping*"); #TODO - this is ugly and doesn't fit core
    chomp @releases;
    @releases = grep {-e $_ && -M $_ < $max_candidate_age} @releases;
	@releases = reverse(@releases);
	#limit to 5 releases
	splice (@releases,5);

    my @turnins;
    if (defined $ENV{GK_BUNDLE_ID} ) {
        my $query = "select distinct bundle.symlink_path from turnin,bundle where cluster='$ENV{cluster_is}' and stepping='$ENV{STEPPING}' and branch='$ENV{branch_is}' and (turnin.status in ('accepted','released','integrating')  OR (bundle.status='build_failed' AND turnin.stage='integrate'))   and turnin.area_deleted_attempts='0' and bundle_id=bundle.id";
        $query .= " and bundle.merge_start_time < (select merge_start_time from bundle where id='$ENV{GK_BUNDLE_ID}')";
        @turnins = `mysql --defaults-file=$ENV{GK_CONFIG_DIR}/db_reader_credentials.cnf -r -B -N -e "$query"`; }
    else {
        @turnins = `mysql --defaults-file=$ENV{GK_CONFIG_DIR}/db_reader_credentials.cnf -r -B -N -e "select distinct bundle.symlink_path from turnin,bundle where cluster='$ENV{cluster_is}' and stepping='$ENV{STEPPING}' and branch='$ENV{branch_is}' and turnin.status in ('accepted','released')  and turnin.area_deleted_attempts='0' and bundle_id=bundle.id"`;
    }
    chomp @turnins;
    @turnins  = reverse @turnins;
    @turnins = grep {-e $_ && -M $_ < $max_candidate_age && !/latest/} @turnins;


    my @tmp_candidates =  (@extra_candidates,@releases,@turnins);
    my @candidates_final;
    for (@tmp_candidates) {
       if (-e "$_/target/cache_data/$ENV{DUT}/$stage_name" || 
        -e  "$_/target/cache_data/$ENV{DUT}/${stage_name}_gcache_passed"  
            ) {
        push (@candidates_final , $_);
       }
       else {
        my_print( "candidate $_ doesn't appear to pass the stage $stage_name - skipping\n");
       }
    }
my_print (scalar(@candidates_final) . " candidates, max is $max_candidates\n");
    splice (@candidates_final, $max_candidates) if ($max_candidates < scalar(@candidates_final));
	my_print(join("\n",@candidates_final));
	my_print("\n");
    return @candidates_final;
}

#inputs - 
#   model root
#   an array of paths
#   an array of paths to exclude
#
#outputs -
#   an array of all the files and directories under model_root/paths which arn't exluded
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
    push (@clean_output, $f) if ($add and (! -d "$model_root/$f" || &is_dir_empty("$model_root/$f")));
  }
  return @clean_output;
}


sub is_dir_empty {
    return -1 if not -e $_[0];   # does not exist
    return -2 if not -d $_[0];   # in not a directory
    return 1 if -l $_[0];   # in not a directory
    opendir my $dir, $_[0] or    # likely a permissions issue
        print "Can't opendir '".$_[0]."', because: $!\n";
    readdir $dir;
    readdir $dir;
    return 0 if( readdir $dir ); # 3rd times a charm
    return 1;
}

sub remap_output {
    my $old_model_root = shift;
    my $new_model_root = shift;
    my $file_list = shift; # a file containing all the output files
    my $part_old_model_root = $old_model_root;
    $part_old_model_root =~ s/^\/p//;
    $part_old_model_root =~ s/^\/nfs\/[^\/]+\/proj\///;
    my $rp_old_model_root = Cwd::realpath($old_model_root);
    
    #first fix links
    my_print( "fixing links\n");
    my @files = `cat $file_list`;
    chomp @files;
    my_print( "files are " . join("\n",@files));
    my @links = grep {-l "$new_model_root/$_"} @files;
    for my $link (@links) {
        $link = "$new_model_root/$link";
        my_print( "working on $link\n");
        my $target = readlink ($link);
        my $rp_target = Cwd::realpath($target);
        if ($rp_target =~ /$rp_old_model_root/) {
            #fix the link
            my_print( "fixing link to $target\n");
            unlink($link);
            $target =~ s#(/p|/nfs/([^/])+/proj)/$part_old_model_root#$new_model_root#g;
            my_print( "should point to $target\n");
            symlink($target,$link);
        }

    }


    #three options - model can start with either /p /nfs/site/proj /nfs/(iil|fm...)/proj
    #we want to remap all of them TODO can i know for sure only one of them will appear in the outputs?
   
    #GIBALY - do i need realpath here as well?
    my_print( "running: cat $file_list | sed 's#^\\/##' |  egrep -v '\\.so\$' xargs -P 40 -n 1 sed -i -e 's#\\(/p\\|/nfs/\\([^/]\\)\\+/proj\\)/$part_old_model_root#$new_model_root#g' -e 's#$rp_old_model_root#$new_model_root#");

    `cd $new_model_root ; cat $file_list | sed 's#^\\/##' | egrep -v '\\.so\$' | /usr/bin/xargs -P 40 -n 1 /usr/bin/sed -i -e 's#\\(/p\\|/nfs/\\([^/]\\)\\+/proj\\)/$part_old_model_root#$new_model_root#g' -e 's#$rp_old_model_root#$new_model_root#g'`;
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

