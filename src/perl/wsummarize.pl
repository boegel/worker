#!/usr/bin/env perl

use strict;
use warnings;
use Config::General;
use Data::Dumper;
use FindBin;
use Getopt::Long;

sub BEGIN {
    if (exists $ENV{WORKER_DIR} && defined $ENV{WORKER_DIR} &&
            length($ENV{WORKER_DIR}) > 0) {
        unshift(@INC, "$ENV{WORKER_DIR}/lib/perl");
    } else {
        unshift(@INC, "$FindBin::Bin/../lib/perl");
    }
}

use Worker::LogParser;
use Worker::TaskfileParser;
use Worker::ExecutedTasksFilter;
use Worker::Utils qw( parse_hdr check_file compute_file_extension msg );

# directory containing the Worker software
my $worker_dir = undef;
if (exists $ENV{WORKER_DIR} && defined $ENV{WORKER_DIR} &&
        length($ENV{WORKER_DIR}) > 0) {
    $worker_dir = "$ENV{WORKER_DIR}";
} else {
    $worker_dir = "$FindBin::Bin/..";
}
$worker_dir .= '/' unless length($worker_dir) == 0 || $worker_dir =~ m|/$|;
check_file($worker_dir, 'worker directory', 1, 1);

my $config_file = "${worker_dir}/conf/worker.conf";
check_file($config_file, 'configuration file', 1);
msg("reading config file '$config_file'...");
my $config = Config::General->new($config_file);
my %conf = $config->getall();
msg("config file read");
msg(Dumper(\%conf) . "\n");

# determine task separator
my $worker_hdr = "${worker_dir}$conf{worker_hdr}";  # worker header file
my $separator = parse_hdr($worker_hdr);

# get the templates for the log and task file
my $default_log = $conf{default_log};    # templ. log name
my $default_sh  = $conf{default_sh};     # templ. batch name

# command line options
my $is_long = 0;
my $verbose = undef;
my $should_redo = 0;
my $show_tasks = 0;

GetOptions("long"      => \$is_long,
	   "retry"     => \$should_redo,
	   "verbose"   => \$verbose,
	   "showtasks" => \$show_tasks,
           "help"      => \&show_help);

# set verbosity for Worker::Utils
$Worker::Utils::verbose = $verbose;

my $log_ext = compute_file_extension($default_log);
my $batch_ext = compute_file_extension($default_sh);

my $log_file = $ARGV[0];
check_file($log_file, "log file");

my $task_file = compute_task_file($log_file, $log_ext, $batch_ext);
check_file($task_file, "task file");

my $task_parser = Worker::TaskfileParser->new($separator);
$task_parser->parse($task_file);
my $nr_tasks = $task_parser->nr_tasks();

my $log_parser = Worker::LogParser->new();
$log_parser->parse($log_file);
my $nr_completed = $log_parser->nr_completed();
my $nr_failed = $log_parser->nr_failed();
my $nr_done = $nr_completed + $nr_failed;

printf("%d of %d executed tasks succesfully completed\n",
       $nr_completed, $nr_done);
printf("%d of %d executed tasks failed\n",
       $nr_failed, $nr_done);
printf("%.2f %% of the tasks executed\n", 100*$nr_done/$nr_tasks);
if ($is_long && $log_parser->has_failed()) {
    print "failed task IDs:\n", join(", ", $log_parser->failed()), "\n";
}
if ($is_long) {
    my $executed_filter = Worker::ExecutedTasksFilter->new();
    $executed_filter->set_redo_failed($should_redo);
    $executed_filter->filter([$task_parser->tasks()],
			     [$log_parser->completed()],
			     [$log_parser->failed()]);
    print "task IDs to do:\n", join(", ", $executed_filter->task_ids()), "\n";
    if ($show_tasks && $executed_filter->nr_tasks > 0) {
	print "task file:\n\n";
	print join("$separator\n", $executed_filter->tasks()), "$separator\n";
    }
}

# ----------------------------------------------------------------------------
# compute the name of a task file out of that of the given log file name
# ----------------------------------------------------------------------------
sub compute_task_file {
    my ($log_file, $log_ext, $batch_ext) = @_;
    $batch_ext = ".$batch_ext";
    $log_file =~ s/\.$log_ext([^.]*)$/$batch_ext.$1/e;
    return $log_file;
}

# ----------------------------------------------------------------------------
# print the script's help stuff
# ----------------------------------------------------------------------------
sub print_help {
    print STDERR <<EOI
### usage: wsummarize [-help] [-long] [-retry] [-verbose] <log-file>
#
#   -long      : show IDs of failed tasks
#   -retry     : in combination with -long, the list of task IDs
#                to be done includes failed tasks
#   -verbose   : show feedback while processing
#   -help      : print this help message
#   <log-file> : worker log files to parse
#
# Utility to summarize a worker log file: it displays the number of
# succesfully completed and failed tasks, and shows the latter's task
# ID when '-long' is specified.
EOI
}
# ------------------------------------------------------------------
# shows help and exits
# ----------------------------------------------------------------------------
sub show_help {
    print_help();
    exit 0;
}
# ----------------------------------------------------------------------------
