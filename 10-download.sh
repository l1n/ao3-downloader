#!/bin/sh
PROCS=1
FORMAT="epub"
SECTION="bookmarks"
while getopts ":u:s:f:p:" opt; do
    case $opt in
        u)
            AO3USER=$OPTARG
            ;;
        f)
            FORMAT=$OPTARG
            ;;
        p)
            PROCS=$OPTARG
            ;;
        s)
            SECTION=$OPTARG
            ;;
        \?)
            echo "Download stuffs from AO3. See 00-readme.txt"
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
            ;;
    esac
done
if [ -z "${AO3USER}" ]; then
    echo "please provide a user";
    exit 1;
fi

echo Downloading initial list of works... && \
curl "https://archiveofourown.org/users/$AO3USER/$SECTION" | \
grep -E ' <a href="/works/[0-9]' -A 4 | \
perl -MURI::Escape -ne '
    BEGIN {
        #Set I/O seperators
        $,="\t";
        $/="--\n";
    };
    @parts = split m{works/(\d*)[^>]*>([^<]*).*//archiveofourown.org/users/([^/]*?)/pseuds/([^"]*)}s;
    @parts[5] = @parts[2];
    @parts[5] =~ s/[^\w _-]+//g;
    @parts[5] = "Work by " . @parts[3] if @parts[5] eq "";
    @parts[5] =~ s/ +/ /g;
    @parts[5] = uri_escape substr @parts[5], 0, 24;
    print @parts[1,2,5,3,4], join("/", "http://archiveofourown.org/downloads", substr(@parts[3], 0, 2), @parts[3,1,5]) . ".'$FORMAT'\n";' | \
cut -f 6 | \
sed '/^\s*$/d' | \
xargs -n 1 -I {} -P $PROCS sh -c "echo Downloading {} && curl -LO {}" && \
echo Done!
