#!/usr/bin/perl

use strict;
use warnings;
use threads;

use Getopt::Long;
use Pod::Usage;
use File::Fetch;
use URI::Escape;
use Thread::Queue;
use Thread::Semaphore;

$File::Fetch::BLACKLIST = [qw|lwp|]; #Breaks the archive for an unknown reason

my $uid       = undef;
my $processes = 1;
my $format    = "epub";
my $directory = ".";
my $section   = "bookmarks";
my $help      = 0;

GetOptions (
    'u|uid=s'         => \$uid,
    'p|processes:+'   => \$processes,
    'f|format=s'      => \$format,
    'd|directory=s'   => \$directory,
    's|section=s'     => \$section,
    'h|help'         => \$help,
) and $uid or die pod2usage(-exitval => 0, -verbose => 2);

print "Started:\r\nUID => ", $uid, "\r\nThreads => ", $processes, "\r\nSection => ", $section, "\r\n";

print "Starting download threads...";
my $mutex = Thread::Semaphore->new();
STDOUT->autoflush();
my $queue = Thread::Queue->new();
threads->create(\&worker) for 1 .. $processes;
print "Done!\r\n";

print "Downloading list of works...";
my $sectionContents;
my $uri = 'http://archiveofourown.org/users/'.$uid.'/'.$section;
do {
    my $fetchy;
    my $fetcher = File::Fetch->new(uri => $uri);
    my $where = $fetcher->fetch(to => \$fetchy);
    die 'Error in retrieving ', $section, ' for ', $uid, ' from ', $fetcher->uri, ': ', $fetcher->error(0) if $fetcher->error();
    undef $fetcher;
    $sectionContents .= $fetchy;
    $fetchy =~ /rel="next" href="([^"]+)"/;
    $uri = 'http://archiveofourown.org'.($1?$1:'');
} while ($uri && $uri ne 'http://archiveofourown.org');
print "Done!\r\n";

my @lines = split /\r|\n/, $sectionContents;
undef $sectionContents;
my $workCount = 0;
while (defined(my $line = shift @lines)) {
    if ($line =~ m{<a href="/works/[0-9]+"}) {
        $workCount++;
        shift @lines;
        shift @lines;
        shift @lines;
        $line .= shift @lines;
        my @parts = $line =~ m{works/(\d*)[^>]*>([^<]*).*//archiveofourown.org/users/([^/]*?)/pseuds/([^"]*)}s;
        $parts[5] = $parts[1];
        $parts[5] =~ s/[^\w _-]+//g;
        $parts[5] = "Work by " . $parts[2] if $parts[5] eq "";
        $parts[5] =~ s/ +/ /g;
        $parts[5] = uri_escape substr $parts[5], 0, 24;
        $queue->enqueue([$parts[1], join('/', 'http://archiveofourown.org/downloads', substr($parts[3], 0, 2), @parts[3,0,5]) . '.' . $format]);
    }
}
undef @lines;
$queue->end;

$_->join() foreach threads->list;
print 'Fetched ', $workCount, " works.\r\n";

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
