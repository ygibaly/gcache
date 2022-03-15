#!/usr/intel/bin/perl
use Data::Dumper;
use Storable;
use Getopt::Long;
use Term::ANSIColor ;


my %opt;
GetOptions(\%opt,'d|debug', 'store=s','model_root=s','no_print');
#enabled/disabled
#pass/fail
#why fail?
#which log to look at (timestamp?) last

#stage, DUT, enabled , pass/fail, stage runtime (total wtime from logs?), cache time, gcache log 
## report: post_turnin => save? storable file? -> miss on which files? user/cnladmin? 



my $model_root = $opt{model_root};
$model_root = $ENV{MODEL_ROOT} unless ($model_root);
$model_root = $ENV{GK_MODELROOT} unless ($model_root);
unless ($model_root) {
die "no model root provided and MODEL_ROOT is not defined";
}
print "running on $model_root\n";
die "$model_root doesn't exist or isn't a directory\n" unless (-d $model_root);

%stagesi_per_dut;
%stages;

@data = `ls -ltr $model_root/target/cache_data/*/*gcache | sed -e 's#.*cache_data/##' -e 's/_gcache//' | tr "/" " "`;
chomp @data;
for (@data) {
my ($dut ,$stage) = split(" ",$_);
$stages_per_dut{$dut}{$stage}{status} = "miss";
$stages{$stage} = 1;
}

@data = `ls -ltr $model_root/target/cache_data/*/*gcache_passed | sed -e 's#.*cache_data/##' -e 's/_gcache_passed//' | tr "/" " "`;
chomp @data;
for (@data) {
my ($dut ,$stage) = split(" ",$_);
$stages_per_dut{$dut}{$stage}{status} = "hit";
}


@cfg_files = `ls $model_root/core/common/cfg/gcache_cfg/ | sed 's/\.cfg//'`;
chomp @cfg_files;
%cfg_exists;
for (@cfg_files) {
$cfg_exists{$_} = 1;
unless ($stages{$_}) {
	#print "cfg file $_.cfg might be redundent\n";
}
}

#no config file?
for my $dut (keys %stages_per_dut) {
	for my $stage (keys %{$stages_per_dut{$dut}}) {
		unless ($cfg_exists{$stage}) {
			$stages_per_dut{$dut}{$stage}{status} = "no config file!\n";
		}	
	}
} 
%stage_run_time;
for my $dut (keys %stages_per_dut) {
	for my $stage (keys %{$stages_per_dut{$dut}}) {
		my @logfiles = glob("$model_root/target/{$dut,common}/log/*.$stage.log $model_root/target/$dut/cte/*/log/*$stage*log");
		my @gcache_log = glob("$model_root/target/cache_data/$dut/$stage*log");
if ($opt{debug}) {
		print "log files for stage $dut.$stage\n" ;
		print "$_\n" for @logfiles ;
}
		next unless @logfiles;
		chomp($stages_per_dut{$dut}{$stage}{run_time} = `cat $logfiles[0] | grep "\\-I\\-:Run time" | awk '{print \$3}'`);
		$stages_per_dut{$dut}{$stage}{run_time} =~ s/(.*\...).*/$1/;
		$stages_per_dut{$dut}{$stage}{gcache_log} = $gcache_log[0]; 
		$stages_per_dut{$dut}{$stage}{gcache_log} =~ s/$model_root\/*//; 
		$stages_per_dut{$dut}{$stage}{stage_log} = $logfiles[0]; 
		chomp($stages_per_dut{$dut}{$stage}{gcache_time} = `cat $logfiles[0] | grep "GCACHE TIME" | awk '{print \$NF}'`); 
	}
} 



@flowspec_data = `zgrep -l "gcache_enable            => 0" $model_root/target/flow_data/*/* | sed -e 's/^[^\\.]*\\.//' -e 's/\\.pm\\.gz//' -e 's/\\..*\\./ /'`;
chomp @flowspec_data;
for (@flowspec_data) {
my ($dut ,$stage) = split(" ",$_);
$stages_per_dut{$dut}{$stage}{status} = "disabled from flowspec";
}

#@flowspec_data = `zgrep -l "gcache_enable            => 1" $model_root/target/flow_data/*/* | sed -e 's/^[^\.]*\.//' -e 's/\.pm\.gz//' -e 's/\..*\./ /'`;
#chomp @flowspec_data;
#for (@flowspec_data) {
#my ($dut ,$stage) = split(" ",$_);
#next unless ($dut);
#$stages_per_dut{$dut}{$stage} = "enabled from flowspec";
#}

if ($ENV{TURNIN_ID}) {
	$stages_per_dut{turnin_id} = $ENV{TURNIN_ID};
}
if ($ENV{BUNDLE_ID}) {
	$stages_per_dut{bundle_id} = $ENV{BUNDLE_ID};
}

	
print  Dumper(\%stages_per_dut) if ($opt{debug});
store \%stages_per_dut, "$opt{store}" if ($opt{store});
exit 0 if ($opt{no_print});
print color('bold');
printf("%-20s%-10s%-10s%-10s%-15s%-50s\n","stage","dut","status","run time","gcache time","gcache log");
print color('reset');
for my $dut (keys %stages_per_dut) {
	for my $stage (keys %{$stages_per_dut{$dut}}) {
		printf("%-20s%-10s",$stage,$dut);
		my $status = $stages_per_dut{$dut}{$stage}{status};
		if ($status  =~ /hit/) {
			print color('green');
		}
		if ($status =~ /miss/) {
			print color('red');
		}
		if ($status =~ /disabled/) {
			print color('yellow');
		}

		printf("%-10s",$stages_per_dut{$dut}{$stage}{status});
		print color('reset');
		printf("%-10s%-15s%-50s\n",$stages_per_dut{$dut}{$stage}{run_time},$stages_per_dut{$dut}{$stage}{gcache_time},$stages_per_dut{$dut}{$stage}{gcache_log});
	}
}
exit 0;




#per stage analysis



chdir $model_root;
my %tag_to_commit;

@res = `git log --no-walk --tags --pretty="%H %D" | sed 's# .*tag: # #' `;
chomp @res;
for (@res) {
my ($commit,$tag) = split(" ",$_);
$tag_to_commit{$tag} = $commit;
}
#
#bundle_id -> turnin_id : mysql --defaults-file=$GK_CONFIG_DIR/db_reader_credentials.cnf -r -B -N -e "select bundle.id,turnin.id from turnin,bundle where cluster='core' and stepping='lnc-a0' and turnin.status in ('accepted','released')  and turnin.area_deleted_attempts='0' and bundle_id=bundle.id"
#git files changed from commit -> git diff --name-only fd5725bb486adf05d2c7ea3fa0eb039ba8b32c4b



#just one stage for now

my @mismatches = `grep mismatch $model_root/target/cache_data/exe/ironchef_exe_gcache_*.log | sed -e 's/.* in file //' -e 's/in model //' -e 's/(.*//' `;

print @mismatches;
chomp @mismatches;
for (@mismatches) {
my ($file,$model) = split(" ",$_);
print "$file\n";
$file =~ s/$model//;
$file =~ s/^\/+//;
print "$file -> $model\n";
(my $short_model = $model) =~ s/.*\///;
#was this file changed between this model and my model?
print "$short_model\n";
print "$tag_to_commit{$short_model}\n";




}


