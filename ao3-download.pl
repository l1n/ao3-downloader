#!/usr/bin/perl

# Keep it clean
use strict 'subs';
use warnings;

use threads;                            # NOTE We could probably have threading be
                                        # fully disabled if $processes == 0

# All modules are threadsafe and in the standard distribution
use Getopt::Long;
use Pod::Usage;
use File::Fetch;
use URI::Escape;
use Thread::Queue;
use Thread::Semaphore;

# Setup options for modules
Getopt::Long::Configure (
    'auto_abbrev',                      # Allows truncation of options
    'gnu_compat'                        # Allows --opt=BLA syntax and --opt "BLA"
);
$File::Fetch::BLACKLIST = [qw|lwp|];    # Breaks the Archive for an unknown reason

# Initialize default values for configurable sections of the program
my $uid       = undef;                  # Required (can't make base URL without it)
my $procs     = 1;                      # Number of worker threads
my $format    = "epub";                 # Extension of downloaded works
my $directory = ".";                    # Directory to drop downloads in
my $section   = "bookmarks";            # Section of user's profile to get
my $help      = 0;                      # Flag to print help and quit out

GetOptions (
    'uid=s'         => \$uid,
    'processes:+'   => \$procs,
    'format=s'      => \$format,
    'directory=s'   => \$directory,
    'section=s'     => \$section,
    'help'          => \$help,
)
    and (
       $uid                             # $uid is mandatory
    && $processes > 0                   # Can't have less than one download thread
    && $format =~                       # $format must be
        m{^(?:epub|pdf|html|mobi)$}     # epub, pdf, html, or mobi
)
    or die pod2usage(                   # Print documentation and quit if bad opts
        -exitval => $help,              # With return value 0 if $help was not set
        -verbose => 2                   # Print all the sections
    );

# Threading initialization section
print "Starting download threads...";
my $mutex = Thread::Semaphore->new();   # When $mutex is up, then the thread has
STDOUT->autoflush();                    # exclusive STDOUT control
my $queue = Thread::Queue->new();       # Queue feeds URLs to download to workers
threads->create(\&worker)               # Create $procs download threads
    for 1 .. $procs;
print "Done!\r\n";

# Scrape all pages of work links
print "Downloading list of works...";
my $sectionContents;                    # Total section contents aggregator
# Initial URI to scrape
my $uri = 'http://archiveofourown.org/users/'.$uid.'/'.$section;
do {
    my $fetchy = "";                    # Create blank variable to fetch page to
    # Initialize fetcher with $uri as the target
    my $fetcher = File::Fetch->new(uri => $uri);
    my $where   = $fetcher->fetch(to => \$fetchy);
    my $err     = $fetcher->error(0);
    die <<ERROR
Error in retrieving $section for $uid from $uri: $err.
ERROR
    if $err;
    undef $fetcher;                     # Garbage collect the File::Fetch object
    $sectionContents .= $fetchy;

    # Check for next page to scrape and scrape it or quit
    $fetchy =~ /rel="next" href="([^"]+)"/;
    $uri = 'http://archiveofourown.org'.($1?$1:'');
} while ($uri && $uri ne 'http://archiveofourown.org');
print "Done!\r\n";

# Queue the work links found (feedback is from the threads)
# Split on newlines
my @lines = split /$/m, $sectionContents;
undef $sectionContents;                 # Garbage collect the string section
my $workCount = 0;                      # A counter for works queued for download
                                        # TODO make this reflect works actually downloaded somehow
while (defined(my $line = shift @lines)) {
    # If a line with a work link
    if ($line =~ m{<a href="/works/[0-9]+"}) {
        $workCount++;
        # Ignore the next three lines
        shift @lines; shift @lines; shift @lines;
        # The fourth line is important though
        $line .= shift @lines;
        # Split the line into parts
        my @parts = $line =~ m{works/(\d*)[^>]*>([^<]*).*//archiveofourown.org/users/([^/]*?)/pseuds/([^"]*)}s;
        $parts[5] = $parts[1];
        $parts[5] =~ s/[^\w _-]+//g;
        $parts[5] = "Work by " . $parts[2] if $parts[5] eq "";
        $parts[5] =~ s/ +/ /g;
        $parts[5] = uri_escape substr $parts[5], 0, 24;
        # Queue the download for the current work URL
        $queue->enqueue([$parts[1], join('/', 'http://archiveofourown.org/downloads', substr($parts[3], 0, 2), @parts[3,0,5]) . '.' . $format]);
    }
}
undef @lines;                           # Garbage collect the lines
$queue->end;

$_->join() foreach threads->list;
print 'Fetched ', $workCount, " works.\r\n";

# Worker thread subroutine (download url to a file in a directory)
sub worker {
    while (my $t = $queue->dequeue) {
        $mutex->down();
        print "Fetching ",@$t[0],"...";
        my $fetcher;
        my $tries = 0;
        do {
            $fetcher = File::Fetch->new(uri => @$t[1]);
            $fetcher->fetch(to => $directory);
            $tries++;
        } while ($tries < 30 && $fetcher->error());
        if ($tries == 30) {
            print "Failed to fetch @$t[1] :(\r\n";
        } else {
            print "Done!\r\n";
        }
        $mutex->up();
    }
}

__END__

=head1 NAME

AO3 Downloader

=head1 SYNOPSIS

ao3-download -u UID [options]

=head1 OPTIONS

=over 12

=item B<-uid>

User ID on AO3. [required]

=item B<-processes>

Processes to run at once.

=item B<-format>

Format to download works in. Valid values are epub (default), mobi, pdf, and html.

=item B<-directory>

Where to download files (default current directory).

=item B<-section>

Section to download. Valid values are bookmarks (default), and works. (Collections and Serieses are not supported at this time).

=back

=head1 DESCRIPTION

B<This program> will download the works found for a section of a given user page.

=cut
