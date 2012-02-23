use IO::Null;
use Term::ReadKey;

sub printfv
{
  my ($level, $format, @parameters) = @_;
  printfvc($level, $format, $level >= 2 ? 'blue' : '', @parameters);
}

sub printfvc
{
  # Prints a colored line
  my ($level, $format, $color, @parameters) = @_;
  
  return if($level > $verbosity);
  print color $color if($color ne '');
  my $string = sprintf($format, @parameters);
  if($string !~ m/\n/gis){
    ($wchar, $hchar, $wpixels, $hpixels) = GetTerminalSize();
    $string = substr($string, 0, $wchar);
    printf("%-".($wchar-1)."s", $string);
  }else{
    print($string);
  }
  
  print color 'reset';
  print("\n");
}

sub pidBegin
{
  my $pidfile = shift;
  #die $pidfile;
	my $override = shift or 0;
	# Check if another instance of the process is already running
	if(-e $pidfile){
		open PIDFILE, "<".$pidfile;
		my $pid = <PIDFILE>;
		close PIDFILE;
		# Paw the other process to see if it moves
		my $exists = kill 0, $pid;
		return $pid if(!$override and $exists);
		if($override and $exists){
		  # It's alive! Kill it!
			my $res = kill 15, $pid;
			if($res eq 1){
				printfvc(0, "Terminated other instances process!", 'green bold');
			}else{
				printfvc(0, "Could not terminate other instance!", 'red bold');
				return $pid;
			}
		}
	}
	open PIDFILE, ">".$pidfile;
	print PIDFILE $$;
	close PIDFILE;
	return 0;
}

sub pidFinish
{
  my $pidfile = shift;
	unlink $pidfile;
}


1;