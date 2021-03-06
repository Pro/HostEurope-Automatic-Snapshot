﻿#!/bin/perl
$| = 1; # Disable output caching

use utf8;
use strict;
use warnings;
use File::Basename;
use Cwd 'abs_path';
use Getopt::Long;
use Term::ANSIColor;
use XML::Simple;
use WWW::Mechanize;
use HTTP::Request::Common qw(POST);
use HTML::TreeBuilder;
use URI::Escape;

use Time::Local;

use Data::Dumper;

my $windows = $^O =~ /Win32/i;
if($windows == 1){
require Win32::Console::ANSI;
	import Win32::Console::ANSI;
	require Win32::File;
	import Win32::File;
}

my $version = '0.1';
our $mypath = abs_path(File::Basename::dirname(__FILE__));
our $verbosity = 3; # 0 = quiet, 1 = normal, 2 = verbose, 3 = debug
my $config_file = $mypath."/config.xml";
my $pid_file = $mypath."/.he_snapshot.pid";

my $server_url = "https://kis.hosteurope.de";
my $admin_url = "/administration/";
my $backup_url = "/administration/vps/admin.php?menu=3&mode=backup&vps_id=";
my $backup_new_url = "/administration/vps/admin.php?menu=3&mode=backup&submode=new_backup2&vps_id=";
my $backup_renew_url = "/administration/vps/admin.php?menu=3&mode=backup&submode=Erneuern&vps_id=";
my $backup_delete_url = "/administration/vps/admin.php?menu=3&mode=backup&submode=Loeschen&vps_id=";

require $mypath.'/utils.pl';

# Process command line flags
our %options = ();
processCommandLine();

# Ensure monogamy
my $otherPid = pidBegin($pid_file, $options{"override"});
if($otherPid != 0){
  printfvc(1, "Another instance of $0 is running (process ID $otherPid). Giving up!\n(Use --override to terminate the other process)", 'red');
  exit();
}

# Read config XML
our $config = XMLin($config_file, ForceArray => ['vps']);

# Initialise HTTP client
my	$mech = WWW::Mechanize->new();
	
if (KisLogin() != 1)
{
	pidFinish($pid_file);
	exit();
}

#Logged in. Now iterate through each VPS

foreach my $vps_item (@{$config->{"vps"}}){
	VPSSnapshot($vps_item);
}

pidFinish($pid_file);
exit();

sub VPSSnapshot
{
	my $vps = shift;
	my $vps_id = $vps->{"vps_id"};
	
	printfv(3, "Elaborate VPS: $vps_id ...");
	
	my $snap_div = SnapshotInfo($vps_id);
	if (!defined($snap_div))
	{
		return;
	}
		
	my(%snap_status) = &SnapshotStatus($snap_div, $vps_id);
	
	if ($snap_status{"status"} != 0)
	{
		printfvc(1, "Not creating snapshot because current status is: " . $snap_status{"text"}, 'red');
		return;
	}
		
	my $snap_remain = SnapshotRemain($snap_div, $vps_id);
	
	my $renew_id = undef;
		
	if ($snap_remain <= $vps->{"min_available"})
	{
		my(@snap_list) = SnapshotList($snap_div);
		$renew_id = DeleteSnapshot($snap_div, $vps_id, $vps->{"deletion_stategy"}, @snap_list);
	}
	
	CreateSnapshot($vps_id, $vps->{"snapshot_description"},$renew_id);
}

sub SnapshotInfo
{
	my $vps_id = shift;
	my $res = $mech->get($server_url.$backup_url.$vps_id);
	if ($res->is_success) {
		my $string = $res->decoded_content();
		#SaveHtmlResponse($res,"creating.html");
		#my $string = LoadHtmlResponse("creating.html");
		return GetSnapshotInfoDiv($string);
	} else {
		printfvc(1, "Couldn't get snapshot info for VPS $vps_id. Server returned: " . $res->as_string, 'red');
		return undef;
	}
}

sub GetSnapshotInfoDiv
{
	my $string = shift;
	my $tree = HTML::TreeBuilder->new; # empty tree
	$tree->parse($string);
	my $root = $tree->elementify();

	#only div around snapshot has this style
	my $snapshot_div = $root->find_by_attribute("style","border: 1px solid #999;padding:10px;");
	if (!defined($snapshot_div))
	{
		printfvc(1, "Snapshot info not found. Maybe page HTML code has changed. Try to update your script.", 'red');
		return undef;
	}
	return $snapshot_div;
}

sub SnapshotStatus
{

	my $snap_div = shift;
	my $vps_id = shift;
	my %ret = eval {
	
		my $table = $snap_div->address(".0");
		
		if ($table->tag() ne "table")
		{
			return ("status"=>"0",
				"text" => "");
		}
		my $status_cell = $table->address(".1.0");
		my $status_text = $status_cell->address(".0");
		my $descr = $status_text->address(".0");
		#Zur Zeit ist eine Aufgabe geplant. Startzeit: 23.02.2012 20:51:00, Typ: Backup anlegen
		
		my $progress = $status_text->address(".2");
		#Aktueller Status: Zu 3% fertiggestellt.
		
		if ($descr->as_text() =~ m/Zur Zeit ist eine Aufgabe geplant.*Typ: (.*)/)
		{
			if ($1 eq "Backup anlegen")
			{
				my $percentage = 0;
				if (defined($progress) && $progress ne " " && $progress->as_text() =~ m/Aktueller Status: Zu (\d+)% fertiggestellt/)
				{
					$percentage = $1;
				}
				return ("status"=>"1", #Creating backup
						"text" => "Creating backup. Progress: $percentage%",
						"percentage" => $percentage,
						);
			}
		} elsif ($descr->as_text() =~ m/Es wurde ein neues Backup geplant\. Wenn Sie die Ansicht aktualisieren, sehen Sie den aktuellen Status\./)
		{
			return ("status"=>"2", #Backup planned
					"text" => "Backup planned",
					);
		}
		
		return ("status"=>"-1",
				"text" => $status_text->as_text());
	};
	if ($@){
		printfvc(1, "Snapshot status not found. Maybe page HTML code has changed. Try to update your script.", 'red');
		return ("status"=>"-1",
				"text" => "No status found");
    } else {
		return %ret;
	}
}

sub SnapshotRemain
{
	my $snap_div = shift;
	my $vps_id = shift;
	my $ret = eval {
		my $p_tag = $snap_div->look_down(
			'_tag', 'p',
			sub {
				$_[0]->as_text =~ m{.*möglichen Snapshot Backup gefunden.*}
			}
		);
		
		my $current = $p_tag->address(".1")->as_text(); #first child
		my $max = $p_tag->address(".3")->as_text(); #third child
		printfv(3, "[$vps_id] Used: " . $current . ", Available: " . $max);
		return $max - $current;
	};
	if ($@){
		printfvc(1, "Snapshot count not found. Maybe page HTML code has changed. Try to update your script.", 'red');
		return undef;
    } else {
		return $ret;
	}
}

sub SnapshotList
{
	my $snap_div = shift;
	my @ret = eval {
		my $table_tag = $snap_div->look_down(
			'_tag', 'table',
			'border', '0',
			'cellpadding', '0',
			'cellspacing', '0',
		)->look_down(
			'_tag', 'tbody',
			);
		my $rowAddr = 0;
		
		my @ret = ();
		while (defined($table_tag->address(".$rowAddr")))
		{
		
			if ($table_tag->address(".$rowAddr") eq " ")
			{
				last;
			}
			
			my %list_entry = ();
			my $row = $table_tag->address(".$rowAddr");
			
			
			my $time_size = $row->address(".0")->as_text(); #31.01.2012 um 10:43 Uhr Größe: 46.65 GiB
			my ($s_day, $s_mon, $s_year, $s_hour, $s_min, $s_size, $s_unit) = $time_size =~ m/(\d{2})\.(\d{2})\.(\d{4}) um (\d{2}):(\d{2}) Uhr Größe: ([\d.]+) (T|G|M|K)iB/;
			
			$list_entry{"time"}=timelocal(0, $s_min, $s_hour, $s_day, $s_mon-1, $s_year-2000);
			$list_entry{"size"}=$s_size;#Will kontain size in KiB
			if ($s_unit eq "T")
			{
				$list_entry{"size"} *= 1024*1024*1024;
			} elsif ($s_unit eq "G")
			{
				$list_entry{"size"} *= 1024*1024;
			} elsif ($s_unit eq "M")
			{
				$list_entry{"size"} *= 1024;
			}
						
			$list_entry{"name"} = $row->address(".1")->as_text(); #Name as text
			
			my $type = $row->address(".2")->look_down(
				'_tag', 'option',
				sub {
					$_[0]->attr('selected')
				}
			);
			if (defined($type))
			{
				$list_entry{"type"} = $type->as_text();
			} else {
				$list_entry{"type"} = $row->address(".2")->as_text();
			} #Snapshot Backup (1/2)
			
			if (defined($row->address(".3")) && $row->address(".3") ne ' ')
			{
				$list_entry{"backup_id"} = $row->address(".3")->look_down(
					'_tag', 'input',
					sub {
						$_[0]->attr('name') eq "backup[id]"
					}
				)->attr('value'); #ad33d381-1d67-6c4b-a120-302c183c0259/20120131094340
			}
			
			push(@ret,\%list_entry);			
			$rowAddr += 1;
		}
		return @ret;
	};
	if ($@){
		printfvc(1, "Snapshot List couln't be parsed. Maybe page HTML code has changed. Try to update your script.", 'red');
		return undef;
    } else {
		return @ret;
	}
}

sub DeleteSnapshot
{
	my $snap_div = shift;
	my $vps_id = shift;
	my $deletion_strategy = shift;
	my @snap_list = shift;
	
	my $backup_id = undef;
	my $cmp_timestamp = undef;
	my $renew = 0;
	
	foreach my $snap_entry (@snap_list)
	{
		if (!defined($snap_entry->{"backup_id"}))
		{
			printfvc(3, "Deletion: Skipping " . $snap_entry->{"name"} . " because it has no id.");
			next;
		}
		if ($deletion_strategy eq "newest")
		{
			if (!defined($cmp_timestamp) || $snap_entry->{"time"}>$cmp_timestamp)
			{
				$backup_id = $snap_entry->{"backup_id"};
				$cmp_timestamp = $snap_entry->{"time"};
			}
		} elsif ($deletion_strategy eq "oldest")
		{
			if (!defined($cmp_timestamp) || $snap_entry->{"time"}<$cmp_timestamp)
			{
				$backup_id = $snap_entry->{"backup_id"};
				$cmp_timestamp = $snap_entry->{"time"};
			}
		} else {
			if ($snap_entry->{"name"} eq $deletion_strategy)
			{
				$backup_id = $snap_entry->{"backup_id"};
				$renew = 1;
				last;
			}
		}
	}
	
	if (!defined($backup_id))
	{
		printfvc(1, "Couldn't delete Snapshot. None found for deletion strategy: $deletion_strategy", 'red');
		return undef;
	}
	
	if ($renew)
	{
		printfvc(3, "Renewing Snapshot with id: $backup_id",'green');
		return $backup_id;
	}
	printfvc(3, "Deleting Snapshot with id: $backup_id",'green');
	
	my $res = $mech->get($server_url.$backup_delete_url.$vps_id."&backup%5Bid%5D=".$backup_id);
	if ($res->is_success) {
		my $string = $res->decoded_content();
		
		my $snap_div = GetSnapshotInfoDiv($string);	
		if (!defined($snap_div))
		{
			return -1;
		}
		my(%snap_status) = SnapshotStatus($snap_div, $vps_id);
		if ($snap_status{status} != 2)
		{
			printfvc(1, "Couldn't delete snapshot for VPS $vps_id. Status isn't as expected. Current status: " . $snap_status{text}, 'red');
			return -1;
		}
		return 1;
	} else {
		printfvc(1, "Couldn't delete snapshot for VPS $vps_id. Server returned: " . $res->as_string, 'red');
		return -1;
	}
	
	return undef;
}

sub CreateSnapshot
{
	my $vps_id = shift;
	my $snap_name = shift;
	my $renew_id = shift;
	
	my $url = "";
	if (defined($renew_id))
	{
		$url = $server_url.$backup_new_url.$vps_id."&backup%5Bid%5D=".$renew_id;
	}
	else
	{
		$url = $server_url.$backup_new_url.$vps_id."&backup%5Bmessage%5D=".uri_escape($snap_name)."&backup%5Bnew_type%5D=12+weeks";
	}
	
	my $res = $mech->get($url);
	if ($res->is_success) {
		my $string = $res->decoded_content();
		
		my $snap_div = GetSnapshotInfoDiv($string);	
		if (!defined($snap_div))
		{
			return -1;
		}
		my(%snap_status) = SnapshotStatus($snap_div, $vps_id);
		if ($snap_status{status} != 2)
		{
			printfvc(1, "Couldn't create new snapshot for VPS $vps_id. Status isn't as expected. Current status: " . $snap_status{text}, 'red');
			return -1;
		}
		return 1;
	} else {
		printfvc(1, "Couldn't create new snapshot for VPS $vps_id. Server returned: " . $res->as_string, 'red');
		return -1;
	}
}

sub LoadHtmlResponse
{
	my $path = shift;
	open FILE, $path or die "Couldn't open file: $!"; 
	my $string = join("", <FILE>); 
	close FILE;
	return $string;
}

sub SaveHtmlResponse
{
	my $res = shift;
	my $name = shift;
	open(MYOUTFILE, ">$name");
	print MYOUTFILE $res->decoded_content();
	close MYOUTFILE;
}

sub KisLogin
{
	my $req = POST $server_url,
		[ kdnummer => $config->{"account_name"}, passwd => $config->{"account_password"} ];

	# send request
	my $res = $mech->request($req);

	# check the outcome
	if ($res->code == 200) {
		printfvc(3, "Logged in.", 'green');
		return 1;
	} else {
		printfvc(1, "Couldn't login. Server response: " . $res->status_line, 'red');
		return 0;
	}
}


sub processCommandLine
{
  $options{"v"} = 0;
  $options{"q"} = 0;
  $options{"h"} = 0;
  $options{"config"} = "";
  $options{"pid"} = "";
  $options{"no-color"} = 0;
  $options{"override"} = 0;
  
  my @flags = (
    "v|verbose", 
    "q|quiet", 
    "h|help", 
    "config=s", 
    "pid=s",
    "no-color", 
  );
  GetOptions(\%options, @flags);
  $verbosity = 2 if($options{'v'});
  $verbosity = 0 if($options{'q'});
  $config_file = $options{'config'} if($options{'config'} ne "");
  $pid_file = $options{'pid'} if($options{'pid'} ne "");
  $ENV{'ANSI_COLORS_DISABLED'} = 1 if($options{'no-color'});
  printHelp() if($options{'h'});
}

sub printHelp
{
printfvc(0, '
  _    _ ______      _____ _   _          _____   _____ _    _  ____ _______ 
 | |  | |  ____|    / ____| \ | |   /\   |  __ \ / ____| |  | |/ __ \__   __|
 | |__| | |__      | (___ |  \| |  /  \  | |__) | (___ | |__| | |  | | | |   
 |  __  |  __|      \___ \| . ` | / /\ \ |  ___/ \___ \|  __  | |  | | | |   
 | |  | | |____     ____) | |\  |/ ____ \| |     ____) | |  | | |__| | | |   
 |_|  |_|______|   |_____/|_| \_/_/    \_\_|    |_____/|_|  |_|\____/  |_|   

Version %s
', 'blue', $version);
printfvc(1, "Copyright by Stefan Profanter (github.com/Pro)
Feature requests and bugs? Please report to:
    https://github.com/Pro/HostEurope-Automatic-Snapshot/issues", 'cyan');
print("
Automatic Snapshot generation of HostEurope VServer through HostEurope Web Interface.

  Usage: $0 [options]

Options: -v  --verbose          Show more detailed status information
         -q  --quiet            No output whatsoever
         -h  --help             Show this help screen and exit
             --override         Terminate other instances of the script
             --config <file>    Use specific config file (default is config.xml)
             --pid <file>       PID file location (default = ./putiosync.pid)
             --no-color         Disables colored output
");
  exit();
}