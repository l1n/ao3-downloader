#!/usr/bin/perl

use strict;
use warnings;
use threads;

use Getopt::Long;
use File::Fetch;
use URI::Escape;
use Thread::Queue;
use Thread::Semaphore;

$File::Fetch::BLACKLIST = [qw|lwp|]; #Breaks the archive for an unknown reason

my $uid       = undef;
my $processes = 1;
my $format    = "epub";
my $section   = "bookmarks";

GetOptions (
    'u|id=s'         => \$uid,
    'p|rocesses:i'   => \$processes,
    'f|ormat:s'      => \$format,
    's|ection:s'     => \$section
) or die 'Bad arguments to script';

print "Started:\r\nUID => ", $uid, "\r\nThreads => ", $processes, "\r\nSection => ", $section, "\r\n";

print "Starting download threads...";
my $mutex = Thread::Semaphore->new();
STDOUT->autoflush();
my $queue = Thread::Queue->new();
threads->create(\&worker) for 1 .. $processes;
print "Done!\r\n";

print "Downloading list of works...";
my $sectionContents;
my $fetcher = File::Fetch->new(uri => 'http://archiveofourown.org/users/'.$uid.'/'.$section);
my $where = $fetcher->fetch(to => \$_);
die 'Error in retrieving ', $section, ' for ', $uid, ' from ', $fetcher->uri, ': ', $fetcher->error(0) if $fetcher->error();
undef $fetcher;
print "Done!\r\n";

my @lines = split /\r|\n/;
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
        my $fetcher = File::Fetch->new(uri => @$t[1]);
        $fetcher->fetch();
        $fetcher->fetch() if $fetcher->error();
        print "Done!\r\n";
        $mutex->up();
    }
}
