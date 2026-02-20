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
$File::Fetch::WARN      = 0;            # We can handle the errors

# Initialize default values for configurable sections of the program
my $uid       = undef;                  # Required (can't make base URL without it)
my $procs     = 1;                      # Number of worker threads
my $format    = "epub";                 # Extension of downloaded works
my $directory = ".";                    # Directory to drop downloads in
my $section   = "bookmarks";            # Section of user's profile to get
my $help      = 0;                      # Flag to print help and quit out
my $retries   = 30;                     # Number of times to retry downloads
my $comments  = 0;                      # Flag to download comments

GetOptions (
    'uid=s'         => \$uid,
    'processes:+'   => \$procs,
    'format=s'      => \$format,
    'directory=s'   => \$directory,
    'section=s'     => \$section,
    'help'          => \$help,
    'comments'      => \$comments,
)
    and (
       $uid                             # $uid is mandatory
    && $procs > 0                       # Can't have less than one download thread
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
my $uri = 'https://archiveofourown.org/users/'.$uid.'/'.$section;
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
    $uri = 'https://archiveofourown.org'.($1?$1:'');
} while ($uri && $uri ne 'https://archiveofourown.org');
print "Done!\r\n";

# Queue the work links found (feedback is from the threads)
# Split on newlines
my @lines = split /$/m, $sectionContents;
undef $sectionContents;                 # Garbage collect the string section
my $workCount = 0;                      # A counter for works queued for download
my @work_meta;                          # Metadata for comment downloading
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
        my @parts = $line =~ m{works/(\d*)[^>]*>([^<]*).*/users/([^/]*?)/pseuds/([^"]*)}s;
        $parts[5] = $parts[1];
        $parts[5] =~ s/[^\w _-]+//g;
        $parts[5] = "Work by " . $parts[2] if $parts[5] eq "";
        $parts[5] =~ s/ +/ /g;
        my $safe_title = $parts[5];
        $parts[5] = uri_escape substr $parts[5], 0, 24;
        # Queue the download for the current work URL
        $queue->enqueue([$parts[1], join('/', 'https://archiveofourown.org/downloads', @parts[0,5]) . '.' . $format]);
        push @work_meta, [$parts[0], $safe_title, $parts[1]] if $comments;
    }
}
undef @lines;                           # Garbage collect the lines
$queue->end;

$_->join() foreach threads->list;
print 'Fetched ', $workCount, " works.\r\n";

# Download comments for each work if requested
if ($comments && @work_meta) {
    print "Downloading comments...\r\n";
    my $comment_works = 0;
    for my $meta (@work_meta) {
        my ($work_id, $safe_title, $title) = @$meta;
        print "  Fetching comments for: $title...";
        my @all_comments = fetch_all_comments($work_id);
        if (@all_comments) {
            write_comments_file($directory, $safe_title, $title, $work_id, @all_comments);
            print " ", scalar @all_comments, " comments saved.\r\n";
            $comment_works++;
        } else {
            print " no comments found.\r\n";
        }
    }
    print "Saved comments for $comment_works works.\r\n";
}

# Worker thread subroutine (download url to a file in a directory)
sub worker {
    while (my $t = $queue->dequeue) {
        $mutex->down();
        print 'Fetching ', @$t[0], ' ';
        my $fetcher;
        my $tries = 0;
        do {
            $fetcher = File::Fetch->new(uri => @$t[1]);
            $fetcher->fetch(to => $directory);
            print "." if ($fetcher->error); # Show a retry bar
            $tries++;
        } while ($tries < $retries && $fetcher->error);
        if ($tries == $retries) {
            print 'Failed to fetch ', @$t[1], " :(\r\n";
        } else {
            print "... Done!\r\n";
        }
        $mutex->up();
    }
}

# Fetch all comments for a work, handling pagination
sub fetch_all_comments {
    my ($work_id) = @_;
    my @all_comments;
    my $url = "https://archiveofourown.org/works/$work_id?show_comments=true&view_adult=true";

    while ($url) {
        my $html = "";
        my $fetcher;
        my $tries = 0;
        do {
            $fetcher = File::Fetch->new(uri => $url);
            $fetcher->fetch(to => \$html);
            print "." if ($fetcher->error);
            $tries++;
        } while ($tries < $retries && $fetcher->error);

        if ($tries == $retries) {
            warn "Failed to fetch comments page: $url\n";
            last;
        }

        push @all_comments, parse_comments($html);

        # Check for next page of comments
        if ($html =~ m{rel="next" href="([^"]*show_comments[^"]*)"}) {
            my $next = $1;
            $next =~ s/&amp;/&/g;
            $url = "https://archiveofourown.org" . $next;
        } else {
            $url = undef;
        }
    }

    return @all_comments;
}

# Parse comments from a single page of HTML
sub parse_comments {
    my ($html) = @_;
    my @comments;

    # Find the comments section
    my $comments_start = index($html, '<ol class="thread">');
    return @comments if $comments_start == -1;

    my $section = substr($html, $comments_start);

    # Find all comment positions first
    my @positions;
    while ($section =~ m{<li\s[^>]*id="comment_(\d+)"[^>]*>}g) {
        push @positions, { id => $1, start => $-[0], after_tag => pos($section) };
    }

    for my $i (0 .. $#positions) {
        my $p = $positions[$i];
        my $chunk_end = $i < $#positions ? $positions[$i+1]{start} : length($section);
        my $chunk = substr($section, $p->{after_tag}, $chunk_end - $p->{after_tag});

        # Calculate depth from thread nesting before this comment
        my $before = substr($section, 0, $p->{start});
        my $opens = () = $before =~ m{<ol\s+class="thread">}g;
        my $closes = () = $before =~ m{</ol>}g;
        my $depth = $opens - $closes - 1;
        $depth = 0 if $depth < 0;

        # Extract author
        my $author = "Anonymous";
        if ($chunk =~ m{<h4[^>]*class="heading byline"[^>]*>(.*?)</h4>}s) {
            my $byline = $1;
            if ($byline =~ m{<a[^>]*href="/users/[^"]*"[^>]*>([^<]*)</a>}) {
                $author = $1;
            } else {
                my $cleaned = strip_html($byline);
                $author = $cleaned if $cleaned !~ /^\s*$/;
            }
        }

        # Extract date
        my $date = "";
        if ($chunk =~ m{<span[^>]*class="posted datetime"[^>]*>.*?<abbr[^>]*>([^<]*)</abbr>}s) {
            $date = $1;
        }

        # Extract body
        my $body = "";
        if ($chunk =~ m{<blockquote[^>]*class="userstuff"[^>]*>(.*?)</blockquote>}s) {
            $body = strip_html($1);
        }

        push @comments, {
            author => $author,
            date   => $date,
            depth  => $depth,
            body   => $body,
        };
    }

    return @comments;
}

# Strip HTML tags and decode common entities
sub strip_html {
    my ($text) = @_;
    $text =~ s{<br\s*/?>}{\n}gi;
    $text =~ s{<p[^>]*>}{\n}gi;
    $text =~ s{</p>}{}gi;
    $text =~ s{<[^>]+>}{}g;
    $text =~ s/&amp;/&/g;
    $text =~ s/&lt;/</g;
    $text =~ s/&gt;/>/g;
    $text =~ s/&quot;/"/g;
    $text =~ s/&#39;/'/g;
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    return $text;
}

# Write comments to a text file
sub write_comments_file {
    my ($dir, $safe_title, $title, $work_id, @comments) = @_;
    my $filename = "$dir/${safe_title}_comments.txt";

    open(my $fh, '>', $filename) or do {
        warn "Could not write to $filename: $!\n";
        return;
    };

    print $fh "Comments for: $title\n";
    print $fh "https://archiveofourown.org/works/$work_id\n";
    print $fh "=" x 40, "\n\n";

    for my $i (0 .. $#comments) {
        my $c = $comments[$i];
        my $indent = "  " x $c->{depth};

        print $fh "$indent$c->{author}";
        print $fh " ($c->{date})" if $c->{date};
        print $fh "\n";

        my $body_indent = $indent . "  ";
        for my $line (split /\n/, $c->{body}) {
            print $fh "$body_indent$line\n";
        }
        print $fh "\n";

        # Add separator before next top-level comment
        if ($i < $#comments && $comments[$i+1]{depth} == 0) {
            print $fh "---\n\n";
        }
    }

    print $fh "Total: ", scalar @comments, " comments\n";
    close $fh;
}

__END__

=head1 NAME

AO3 Downloader

=head1 SYNOPSIS

ao3-download --uid UID [options]

=head1 OPTIONS

=over 12

=item B<--uid>

User ID on AO3. [required]

=item B<--processes>

Processes to run at once.

=item B<--format>

Format to download works in. Valid values are epub (default), mobi, pdf, and html.

=item B<--directory>

Where to download files (default current directory).

=item B<--section>

Section to download. Valid values are bookmarks (default), and works. (Collections and Serieses are not supported at this time).

=item B<--comments>

Also download reader comments for each work, saved as plain text files alongside the work downloads.

=back

=head1 DESCRIPTION

B<This program> will download the works found for a section of a given user page. Optionally, it can also download reader comments for each work.

=cut
