use v5.14;
use warnings;

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

sub confval  { $config{(shift)} }
sub confflag { $config{(shift)} ? 1 : 0 }
sub confnum  { $config{(shift)} + 0 }
sub conflist {
    my @list;
    for (@config{@_}) {
        push @list, ref($_) eq 'ARRAY' ? @$_ : $_;
    }
    @list;
}

our $quiet = 0;
our $async = 0;
our $batchsize = confnum 'make.batch.size';
our $dryrun = $ENV{DRY_RUN} ? 1 : 0;

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
    unshift @_, $dryrun ? () : $async ? '[ASYNC]' : '[SYNC]';
    say join ' ', @_ unless $quiet;
}

sub mtime {
    (stat shift)[9];
}

sub files {
    my ($root, @globs) = @_;

    my @files;
    for (@globs) {
        push @files, glob("$root/$_");
    }

    @files;
}

sub reext {
    my ($old, $new, @names) = @_;
    s/\Q$old\E$/$new/ for @names;
    @names;
}

sub spurt {
    my ($name, $contents) = @_;
    note 'spurt', $name;
    return if $dryrun;

    open my $fh, '>', $name or die $!;
    syswrite $fh, $contents or die $!;
    close $fh;
}

sub run {
    my ($cmd, @args) = @_;
    note @_;
    return 1 if $dryrun;

    system($cmd, @args) == 0
        or die "`$cmd´ returned $?";
}

sub spawn {
    local $async = 1;
    note @_;
    return 1 if $dryrun;

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

sub await {
    return 1 if $dryrun;

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

my @batch;

sub done_batching {
    my %procs;
    my %cmds;

    for (@batch) {
        my $pid = spawn @$_;
        die $! unless $pid > 0;
        $procs{$pid} = undef;
        $cmds{$pid} = $_;
    }

    await \%procs or die;
    @batch = ();
}

sub batch {
    if ($batchsize < 2) {
        run @_;
        return;
    }

    push @batch, \@_;
    return if @batch < $batchsize;

    done_batching;
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

sub help {
    my ($key, $value) = @_;
    push @help, $key;
    $help{$key} = $value;
}

sub inc { map { confval('build.cc.flags.include') . $_ } @_ }
sub cc_co {
    conflist(qw(build.cc build.cc.flags.compile)),
    confflag('build.debug')
            ? conflist('build.cc.flags.debug')
            : conflist('build.cc.flags.nodebug'),
    @_,
    confval('build.cc.flags.out');
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

sub libuv_root { confval('moar.root') . '/3rdparty/libuv' }
sub libuv_sources { files libuv_root, conflist('moar.3rdparty.libuv.src') }
sub libuv_objects { reext '.c', confval('build.suffix.obj'), libuv_sources }
sub libuv_includes { libuv_root.'/include', libuv_root.'/src' }

target 'build-libuv' => sub {
    my @sources = libuv_sources;
    my @cmd = cc_co inc(libuv_includes);

    my $compiled = 0;
    for my $src (@sources) {
        my $sfx = $config{'build.suffix.obj'};
        my $dest = $src =~ s/\.c$/$sfx/r;

        if (!-f $dest || mtime($dest) < mtime($src)) {
            batch @cmd, $dest, $src;
            $compiled = 1;
        }
    }

    done_batching;
};

target 'clean-libuv' => sub {
    for (grep { -f $_ } libuv_objects) {
        note 'unlink', $_;
        unlink $_ unless $dryrun;
    }
};

gen 'moar/src/gen/config.h', 'moar/build/config.h.in', sub {
    my ($dest, $src) = @_;

};

dispatch @ARGV ? @ARGV : qw(build);
