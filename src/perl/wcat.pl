#!/usr/bin/env perl

use strict;
use warnings;
use Data::Dumper;
use Config::General;
use FindBin;
use Getopt::Long;
use IO::File;
use Set::Scalar;
use Template;

sub BEGIN {
    if (exists $ENV{WORKER_DIR} && defined $ENV{WORKER_DIR} &&
            length($ENV{WORKER_DIR}) > 0) {
        unshift(@INC, "$ENV{WORKER_DIR}/lib/perl");
    } else {
        unshift(@INC, "$FindBin::Bin/../lib/perl");
    }
}

use Worker::CsvProvider;
use Worker::DataProvider;
use Worker::Utils qw( parse_hdr check_file msg quote_options );

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

# configure command line parsing
Getopt::Long::Configure("no_ignore_case", "pass_through",
			"no_auto_abbrev");

# command line variables
my @data_files  = ();
my $pattern     = undef;
my $output_file = undef;
my $skip_first  = 0;
my $keep_blank  = undef;
my $rm_orig     = undef;
my $verbose     = undef;
my $quiet       = undef;

GetOptions(
    "data=s"       => \@data_files,
    "pattern=s"    => \$pattern,
    "output=s"     => \$output_file,
    "skip_first=i" => \$skip_first,
    "keep_blank"   => \$keep_blank,
    "rm_orig"      => \$rm_orig,
    "verbose"      => \$verbose,
    "quiet"        => \$quiet,
    "help"         => \&show_help,
);

# set verbosity for Worker::Utils
$Worker::Utils::verbose = $verbose;

msg("validating options...");
unless (defined $pattern) {
    print STDERR "### error: no pattern given\n";
    exit 2;
}
msg("pattern: '$pattern'");
unless (scalar(@data_files) > 0) {
    print STDERR "### error: no data file is provided\n";
    print_help();
    exit 3;
}
# check that files, if supplied, can be read
msg("checking file existances...");
if (scalar(@data_files) > 0) {
    @data_files = split(/,/, join(',', @data_files));
    check_file($_, "data file") foreach @data_files;
}

# create data providers
msg("creating providers...");
my @providers = ();
# create the appropriate provider
foreach my $data_file (@data_files) {
    eval {
        push(@providers, Worker::CsvProvider->new($data_file));
    };
    if ($@) {
        print STDERR "### error parsing '$data_file': $@";
        exit 4;
    }
    msg("data file provider '$data_file' created");
}

# initialize Template engine
msg("initializing template engine...");
my $tt_config = {ABSOLUTE => 1};
my $engine = Template->new($tt_config);
msg("template engine initialized");

my $provider = Worker::DataProvider->new(@providers);
msg("all providers created");

# get all variable names
my @variables = $provider->get_vars();

my $job_size = 0;

my $file_est = Set::Scalar->new();
my @files_found = ();
while ($provider->has_next()) {
    $job_size++;
    my $vars = $provider->get_next();
    my $file_name = '';
    unless ($engine->process(\$pattern, $vars, \$file_name)) {
        print STDERR "### error: problem with template,\n";
        print STDERR "           ", $engine->error(), "\n";
        exit 5;
    }
    msg("file '$file_name'");
    if (!$file_est->contains($file_name)) {
        $file_est->insert($file_name);
        if (-e $file_name && -r $file_name) {
            push(@files_found, $file_name);
        } else {
            print STDERR "### warning: can't open file '$file_name'\n"
                unless $quiet;
        }
    }
}

my $out_fh = IO::File->new();
my $in_fh = IO::File->new();
unless ($out_fh->open($output_file, 'w')) {
    print STDERR "### error: can't open '$output_file' for writing: $!\n";
    exit 6;
}
msg("output file '$output_file' opened");
my $eol_printed = 1;
for my $file_name (@files_found) {
    unless ($in_fh->open($file_name, 'r')) {
        print STDERR "### error: can't open '$file_name' for reading: $!\n";
        $out_fh->close();
        exit 7;
    }
    msg("processing file '$file_name'");
    $out_fh->print("$/") unless $eol_printed;
    for (my $i = 0; $i < $skip_first; $i++) {
        $in_fh->getline();
    }
    while (my $line = $in_fh->getline()) {
        if (!$in_fh->eof) {
            $out_fh->print($line);
        } elsif ($line =~ /\S/) {
            $out_fh->print($line);
        } elsif ($keep_blank) {
            $out_fh->print($line);
        }
        $eol_printed = chomp($line);
    }
    $in_fh->close();
    msg("file '$file_name' processed");
    if ($rm_orig) {
        unless (unlink($file_name) == 0) {
            print "### warming: file '$file_name' could not be deleted\n"
                unless $quiet;
        }
    }
}
$out_fh->close();
msg("output file '$output_file' closed");

exit 0;

# ------------------------------------------------------------------
# shows help and exits
# ----------------------------------------------------------------------------
sub show_help {
    print_help();
    exit 0;
}

# ----------------------------------------------------------------------------
# print the script's help stuff
# ----------------------------------------------------------------------------
sub print_help {
    print STDERR <<EOI
### usage: wcat  -pattern <pat> -data <files> -output <file>  \\
#                [-skip_first <num>] [-keep_blank] [-rm_orig] \\
#                [-verbose] [-quiet] [-help]
#
#   -pattern <pat>        : pattern for the files to concatenate, based on
#                           the values in the data files provided; suppose
#                           that a data file has columns 'alpha' and 'beta',
#                           used to generate files with names, e.g.,
#                           'result-15-13.txt', where 15 is a value of 'alpha'
#                           and 12 is a value of 'beta', than the relevant
#                           pattern would be 'result-[%alpha%]-[%beta%].txt'
#   -data <data-files>    : comma-separated list of data files (default CSV
#                           files) used to provide the data for the work
#                           items, note that these must be the same file(s)
#                           used for the wsub command
#   -output <file>        : name of the output file that will contain the
#                           concatenated data
#   -skip_first <num>     : number of lines to skip at the start of each file,
#                           e.g., to skip over headers; defaults to 0
#   -keep_blank           : if files have trailing new lines, these are
#                           suppressed by default; specify this option to
#                           keep them; note that this may introduce blank
#                           lines in the output file
#   -rm_orig              : remove the files, ones they have been concatenated
#                           to the output file; use with caution since this
#                           can not be undone
#   -verbose              : feedback information is written to standard error
#   -quiet                : don't show warnings
#   -help                 : print this help message
EOI
}

