#!/usr/bin/env perl

use strict;
use Config::General;
use Data::Dumper;
use warnings;
use File::Basename;
use File::Temp qw( tempfile );
use FindBin;
use Getopt::Long;
use IO::File;

sub BEGIN {
    if (exists $ENV{WORKER_DIR} && defined $ENV{WORKER_DIR} &&
            length($ENV{WORKER_DIR}) > 0) {
        unshift(@INC, "$ENV{WORKER_DIR}/lib/perl");
    } else {
        unshift(@INC, "$FindBin::Bin/../lib/perl");
    }
}

use Worker::Utils qw( parse_hdr msg check_file );

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

# command line options
my $out_file = undef;
my $verbose = 0;
my $split_lines = 0;
GetOptions("out=s"       => \$out_file,
	   "verbose"     => \$verbose,
	   "split_lines" => \$split_lines,
           "help"        => \&show_help);
# set verbosity for Worker::Utils
$Worker::Utils::verbose = $verbose;
my $quiet = defined $out_file;

# read config file
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

# try to open the bash file
unless (scalar(@ARGV) >= 1) {
    print STDERR "### error: no file to convert\n";
    print_help();
    exit 1;
}
my $in_file = shift(@ARGV);
my $ih = IO::File->new($in_file, 'r');
unless ($ih) {
    print STDERR "### error: can't open file '$in_file': $!\n";
    print_help();
    exit 1;
}
# open a file that will hold the tasks
my $oh = undef;
if (defined $out_file) {
    $oh = IO::File->new($out_file, 'w');
    unless ($oh) {
	print STDERR "### error: can't open file '$out_file' to write: $!\n";
	exit 2;
    }
} else {
    my $basename = fileparse($in_file);
    ($oh, $out_file) = tempfile("${basename}.XXXXX",
				UNLINK => 0,
				DIR => '.');
    unless ($oh) {
	print STDERR "### error: can't create file: $!\n";
	exit 2;
    }
}

while (my $line = <$ih>) {
    chomp($line);
    if ($split_lines) {
	my @lines = split(/\s*;\s*/, $line);
	print $oh "$_\n" foreach (@lines);
    } else {
	print $oh "$line\n";
    }
    print $oh "$separator\n";
}
$oh->close();
$ih->close();

unless ($quiet) {
    my $name = fileparse($out_file);
    print "$name\n";
}
exit 0;

# ----------------------------------------------------------------------------
# print the script's help stuff
# ----------------------------------------------------------------------------
sub print_help {
    print STDERR <<EOI
### usage: wconvert [-out <file>] [-split_lines] [-help] [-verbose] <bash-file>
#
#   -out <file>  : file to write the output to, if not specified, a random
#                  file name will be generated automatically, and be printed
#                  to standard output
#   -split_lines : split the lines if they contain multiple command separated
#                  by ';'
#   -verbose     : show feedback while processing
#   -help        : print this help message
#   <bash-file>  : bash file to be converted into a task file
#
# Utility to convert a bash file into a Worker task file; each line
# of the bash file is considered to be a task that can be executed
# independently in parallel. 
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
