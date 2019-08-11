use v5.14;
use warnings;

our $quiet = 0;
our $async = 0;

my %config;
{
    open my $fh, 'build.conf'
        or die $!;

    while (<$fh>) {
        s/^\s+|\s+$//g;
        next unless length;

        my ($key, $value) = split /\s+/, $_, 2;
        if ($key =~ s/\[\]$//) {
            push @{$config{$key}}, $value;
        }
        else {
            $config{$key} = $value;
        }
    }

    close $fh;
}

my @repos;
{
    my $i = 0;
    my $reps = $config{'git.repos'};
    while ($i < @$reps) {
        my $dir = $reps->[$i++];
        my $url = $reps->[$i++];
        push @repos, [ $dir, $url ];
    }
}

my %targets;
my %rules;
my %help;
my @help;

sub note {
    unshift @_, $async ? '[ASYNC]' : '[SYNC]';
    say join ' ', @_ unless $quiet;
}

sub conflist {
    my @list;
    for (@config{@_}) {
        push @list, ref($_) eq 'ARRAY' ? @$_ : $_;
    }
    @list;
}

sub confflag {
    !!$config{(shift)}
}

sub confval {
    $config{(shift)};
}

sub mtime {
    (stat shift)[9];
}

sub spurt {
    my ($name, $contents) = @_;
    note 'spurt', $name;
    open my $fh, '>', $name or die $!;
    syswrite $fh, $contents or die $!;
    close $fh;
}

sub spawn {
    local $async = 1;
    note @_;
    if ($^O eq 'MSWin32') {
        system 1, @_;
    }
    else {
        my $pid = fork // return -1;
        return $pid if $pid;
        exec @_;
        die $!;
    }
}

sub run {
    my ($cmd, @args) = @_;
    note @_;
    system($cmd, @args) == 0
        or die "`$cmd´ returned $?";
}

sub for_repos {
    for my $repo (@repos) {
        $_->(@$repo) for @_;
    }
}

sub gen {
    my ($dest, $src, @actions) = @_;
    $rules{$dest} = [ [$src], [@actions] ];
}

sub target {
    my ($name, $action) = @_;
    $targets{$name} = $action;
}

sub dispatch {
    for (@_) {
        die "unknown target `$_´"
            unless exists $targets{$_};

        $targets{$_}->();
    }
}

sub await {
    my $procs = shift;
    my $ok = 1;

    while ((my $pid = wait) >= 0) {

        # expected proc
        if (exists $procs->{$pid}) {
            $procs->{$pid} = $?;
            $ok = 0 if $? != 0;
        }

        # unexpected proc
        else {
            $procs->{(-$pid)} = $?;
            $ok = 0;
        }
    }

    # check all expected procs are done
    if ($ok) {
        for (values %$procs) {
            unless (defined) {
                $ok = 0;
                last;
            }
        }
    }

    $ok;
}

sub help {
    my ($key, $value) = @_;
    push @help, $key;
    $help{$key} = $value;
}

help pull
    => "update git repositories that exist and create those that don't";

help 'build-libuv'
    => "create static libuv library";

target '--help' => sub {
    say "\n  Abandon all hope, ye who enter here.\n\nTARGETS\n";
    say "  $_\n    ", ($help{$_} // ''), "\n"
        for @help;
};

target pull => sub {
    my %procs;

    my @jflag = $config{'git.jflag'} // ();
    for_repos sub {
        my ($dir, $url) = @_;

        my $pid = spawn -e $dir
            ? ('git', '-C', $dir, 'pull', '--depth=1', 
                '--recurse-submodules', @jflag)
            : ('git', 'clone', '--depth=1',
                '--recurse-submodules', @jflag, $url, $dir);

        die $! if $pid <= 0;
        $procs{$pid} = undef;
    };

    await \%procs or die;
};

target 'build-libuv' => sub {
    my $root = confval('moar.root') . '/3rdparty/libuv';

    my @sources;
    for (conflist 'moar.3rdparty.libuv.src') {
        push @sources, glob "$root/src/$_";
    }

    my @cmd = (
        conflist(qw(build.cc build.cc.flags.compile)),
        confval('build.cc.flags.include'), "$root/include",
        confval('build.cc.flags.include'), "$root/src",
        confflag('build.debug')
            ? conflist('build.cc.flags.debug')
            : conflist('build.cc.flags.nodebug'),
        confval('build.cc.flags.out')
    );

    my $compiled = 0;
    for my $src (@sources) {
        my $sfx = $config{'build.suffix.obj'};
        my $dest = $src =~ s/\.c$/$sfx/r;

        if (!-f $dest || mtime($dest) < mtime($src)) {
            run @cmd, $dest, $src;
            $compiled = 1;
        }
    }
};

gen 'moar/src/gen/config.h', 'moar/build/config.h.in', sub {
    my ($dest, $src) = @_;

};

dispatch @ARGV ? @ARGV : qw(build);
