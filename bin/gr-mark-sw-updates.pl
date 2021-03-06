#!/usr/bin/env perl
use 5.012;
use warnings;

use experimental 'smartmatch';
use Config::Tiny;
use CPAN::DistnameInfo;
use Cwd qw(realpath);
use DB_File;
use File::Find;
use File::Spec::Functions qw(catfile catpath splitpath tmpdir);
use PerlIO::gzip;
use WebService::Google::Reader;

use constant VERBOSE => not $ENV{CRON};

my $creds = Config::Tiny->read("$ENV{HOME}/.inoreader")
    or die Config::Tiny->errstr;
my $username = $creds->{_}{username} // die 'Missing username';
my $password = $creds->{_}{password} // die 'Missing password';

my $dir  = catpath((splitpath(realpath __FILE__))[ 0, 1 ]);
my $file = catfile($dir, '.unwanted-modules.bdb');
my $db   = tie my %db, DB_File => $file;

my $reader = WebService::Google::Reader->new(
    host     => 'www.inoreader.com',
    username => $username,
    password => $password,
    https    => 1,
);

my $conf = read_conf();
my $feed = $reader->tag(Modules =>
    count      => 500,
    exclude    => { state => 'read' },
    order      => 'asc',
    VERBOSE ? () : ( start_time => $db{_last_time} ),
);
die $reader->error unless $feed;

my (%unread, @unwanted_entries);

FEED:
for my $entry ($feed->entries) {
    my $source  = substr $entry->source->get_attr('gr:stream-id'), 5;
    my $conf    = $conf->{$source}
        or warn "Unexpected feed: $source\n" and next;
    my $lang    = $conf->{lang} // next;
    my $title   = $entry->title;
    my $name    = $conf->{name}($entry)
        or warn "Couldn't extract name from $title\n" and next;
    my $summary = $entry->summary // '';
    my $desc    = $entry->content // '';
       $desc  &&= $desc->body;

    if ($name ~~ %{$unread{$lang}}) {
        push @unwanted_entries, delete $unread{$lang}{$name};
        say "$lang - $name - discarding in favor of newer unread entry"
            if VERBOSE;
    }
    $unread{$lang}{$name} = $entry;

    my $listed;
    for my $b (@{$conf->{blacklist} || []}) {
        if ('CODE' eq ref $b) {
            next unless $b->($entry);
        }
        else {
            next unless [$name, $title, $summary, $desc] ~~ $b;
        }
        $listed = 1;
        push @unwanted_entries, $entry;
        VERBOSE && say "$lang - $name - blacklisted";
        last;
    }
    next if $listed;

    for my $w (@{$conf->{whitelist} || []}) {
        next if not $name ~~ $w;
        $listed = 1;
        VERBOSE && say "$lang - $name - whitelisted";
        last;
    }
    next if $listed;

    if ("$lang|$name" ~~ %db and $title ne $db{"$lang|$name"}) {
        push @unwanted_entries, $entry;
        VERBOSE && say "$lang - $name - unwanted because seen";
    }
    else {
        $db{"$lang|$name"} = $title;
    }
}

sleep 0.25;
goto FEED if $reader->more($feed);

$reader->mark_read_entry(\@unwanted_entries) or die $reader->error;

$db{_last_time} = time;

exit;


sub read_conf {
    return {
        'http://search.cpan.org/uploads.rdf' => do {
            my ($dist, $test_perl_dist_installed);
            {
                lang => 'perl',
                name => sub {
                    $dist = CPAN::DistnameInfo->new($_[0]->title . '.tgz');
                    $dist->dist;
                },
                whitelist => [
                    sub {
                        $test_perl_dist_installed //= is_perl_dist_installed();
                        'released' eq $dist->maturity
                            and $_[0] ~~ $test_perl_dist_installed;
                    },
                ],
                blacklist => [
                    sub {
                        return 1 if $dist->dist =~ m[
                            ^ (?:acme | dist-zilla | mojo[^-]* | task-belike) -
                        ]ix;
                        # Prolific purveyors of piffleware.
                        return 1 if $_[0]->link->href =~ m[
                            /~ (?: manwar | perlook | reneeb | rsavage
                                    | szabgab | sharyanto | tobyink | zoffix
                               )
                        ]x;
                    },
                    sub { 'released' ne $dist->maturity },
                ],
            }
        },

        'http://pypi.python.org/pypi?:action=rss' => {
            lang => 'python',
            name => sub {
                my ($name) = $_[0]->link->href =~ m[
                    ^http://pypi\.python\.org/pypi/([^/]+)
                ]x;
                return $name;
            },
            blacklist => [
                qr/ (?:\b|_) (?:django | flask | plone | zope) (?:\b|_) /ix,
                qr/ ^nknu /ix,  # spammer
                sub {
                    my $s = $_[0]->summary;
                    return 1 unless $s;
                    return 1 if 'unknown' eq lc $s;
                    return 1 if $s =~ /\b [nt]est /ix;
                    return 1 if $s =~ /\b print /ix
                        and $s =~ /\b (?: list | array ) /ix;
                },
            ],
        },

        'http://feeds.feedburner.com/gemcutter-latest' => {
            lang => 'ruby',
            name => sub {
                my ($name) = $_[0]->link->href =~ m[
                    ^http://rubygems\.org/gems/([^?/]+)
                ]x;
                return $name;
            },
            blacklist => [
                qr/ (?:\b|_) (?:
                    rails | sinatra | active\W?record
                ) (?:\b|_) /ix,
            ],
        },

        'http://hackage.haskell.org/packages/archive/recent.rss' => {
            lang => 'haskell',
            name => sub { ($_[0]->title =~ m[^\s*(\S+)])[0] },
        },

        'http://feed43.com/vim-scripts.xml' => {
            lang => 'vimscripts',
            name => sub {
                my ($title, $name) = $_[0]->title =~ m[^\s*((.*?)\s+\S+) --];
                $_[0]->title($title);
                return $name;
            },
        },

        'http://registry.npmjs.org/-/rss?descending=true&limit=50' => {
            lang => 'node',
            name => sub { $_[0]->title =~ m[ (.*) \@ ]x; $1 },
            blacklist => [ sub { not $_[0]->summary } ],
        },

        # These feeds only contain new packages, so no filtering is needed.
        map({ $_ => {} } qw(
            http://dirk.eddelbuettel.com/cranberries/cran/new/index.rss
            http://feed43.com/golang_libraries.xml
            http://feed43.com/golang_bindings.xml
        )),
    };
}


# Return a sub that checks if the given Perl dist is installed.
sub is_perl_dist_installed {
    # Find the list of installed modules.
    my (%modules, %prune);
    for my $top (reverse sort @INC) {
        next if '.' eq $top;
        my $len = length $top;
        find {
            wanted => sub {
                if ($File::Find::dir ~~ %prune) {
                    $File::Find::prune = 1;
                    return;
                }
                return unless '.pm' eq substr $_, -3, 3, '';
                return unless -f _;
                substr $_, 0, 1 + $len, '';
                s{[\\/]}{::}g;
                $modules{$_} = undef;
            },
            no_chdir => 1
        }, $top;
        $prune{$top} = undef;
    }

    # Fetch the file that maps packages to distributions.
    my $file = '02packages.details.txt.gz';
    my $url = "http://search.cpan.org/CPAN/modules/$file";
    $file = catfile(tmpdir, $file);
    if (not -r $file or 1 < -M _) {
        my $ua = $reader->ua->clone;
        $ua->default_header(accept_encoding => undef);
        my $res = $ua->mirror($url, $file);
        die "Failed to mirror $file; " if $res->is_error;
    }
    open my $fh, '<:gzip', $file or die "$file: $!";

    # Skip header.
    while (<$fh>) { last when "\n" }

    # Determine the installed distributions, given the installed modules.
    my %dists;
    while (my $line = <$fh>) {
        my ($package, $version, $dist) = split /\s+/, $line;
        next unless $package ~~ %modules;
        my $info = CPAN::DistnameInfo->new($dist)->dist;
        next unless $info;
        $dists{$info} = undef;
    }
    close $fh;

    sub { $_[0] ~~ %dists; }
};
