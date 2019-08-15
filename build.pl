# Copyright 2019 cygx <cygx@cpan.org>
# Distributed under the Boost Software License, Version 1.0

use v5.14;
use warnings;

use Digest::SHA1 qw(sha1_base64);
use Time::HiRes qw(stat);

my $LICENSE = <<'END_LICENSE';
Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
END_LICENSE

my $VERSION = '0.01';

use subs qw(
    conf confopt confflag conf_u confopt_u conflist
    mtime touch min max to_uint note files mkparents reext rotor chomped
    with_file each_line with_dir each_file dirwalk for_repos
    enqueue batch run spawn spurt gen
    includes headers sources objects cache ccdigest
    toggle buildspec buildargs inc cc_co ar_rcs
    compile nolib linkit build
    dispatch help target
);

my $CONFFILE = 'CONFIG.status';
my $CONFTIME = mtime $CONFFILE;

my %CONF;
my %MOARCONF;
my @REPOS;

my @FLAGS  = qw(QUIET SYNC DRY_RUN FORCE_BUILD LOG_CALLS);
my $FLAGRX = qr/QUIET|SYNC|DRY_RUN|FORCE_BUILD|LOG_CALLS/;

our $fh;
our $dh;

our $quiet;
our $async;
our $batchsize;
our $dryrun;
our $force;

my %targets;
my %help;
my @help;
my @queue;

with_file $CONFFILE, sub {
    while (<$fh>) {
        s/^\s+|\s+$//g;
        next if length == 0 || /^#/;

        my ($key, $value) = split /\s+/, $_, 2;
        if ($key =~ s/\[\]$//) {
            push @{$CONF{$key}}, $value;
        }
        else {
            $CONF{$key} = $value;
        }
    }
};

%MOARCONF = (
    be  => confflag('arch.endian.big'),
    static_inline => conf('lang.c.specifier.static_inline'),
    version => conf('moar.version'),
    versionmajor => conf('moar.version.major'),
    versionminor => conf('moar.version.minor'),
    versionpatch => conf('moar.version.patch'),
    noreturnspecifier => confopt('lang.c.specifier.noreturn'),
    noreturnattribute => confopt('lanc.c.attribute.noreturn'),
    formatattribute => confopt('lang.c.attribute.format'),
    dllimport => confopt('lang.c.specifier.dll.import'),
    dllexport => confopt('lang.c.specifier.dll.export'),
    dlllocal => confopt('lang.c.attribute.dll.local'),
    has_pthread_yield => confflag('lib.c.pthread.yield'),
    has_fn_malloc_trim => confflag('lib.c.std.malloc_trim'),
    can_unaligned_int32 => confflag('lang.c.feature.unaligned.i32'),
    can_unaligned_int64 => confflag('lang.c.feature.unaligned.i64'),
    can_unaligned_num32 => confflag('lang.c.feature.unaligned.f32'),
    can_unaligned_num64 => confflag('lang.c.feature.unaligned.f64'),
    ptr_size => conf_u('arch.pointer.size'),
    havebooltype => confflag('lang.c.feature.bool'),
    booltype => conf('lang.c.type.bool'),
    translate_newline_output => confflag('os.io.translate_newlines'),
    jit_arch => conf('moar.jit.arch'),
    jit_platform => conf('moar.jit.platform'),
    vectorizerspecifier => confopt('lang.c.pragma.vectorize_loop'),
    expect_likely => confopt('lang.c.builtin.expect.likely'),
    expect_unlikely => confopt('lang.c.builtin.expect.unlikely'),
    expect_condition => confopt('lang.c.builtin.expect'),
    backendconfig => '/* FIXME */',
);

{
    my @repos = conflist('git.repos');
    while (@repos) {
        my $dir = shift @repos;
        my $url = shift @repos;
        push @REPOS, [ $dir, $url ];
    }
}

{
    my %flags;
    @flags{@FLAGS} = @ENV{@FLAGS};

    my @argflags = grep {  /^(?:$FLAGRX)=/ } @ARGV;
           @ARGV = grep { !/^(?:$FLAGRX)=/ } @ARGV;

    @flags{map { s/=.*$//r } @argflags} = map { s/^.*?=//r } @argflags;

    $quiet = $flags{QUIET} ? 1 : 0;
    $async = 0;
    $batchsize = $flags{SYNC} ? 0 : confopt_u('script.async.degree');
    $dryrun = $flags{DRY_RUN} ? 1 : 0;
    $force = $flags{FORCE_BUILD} ? 1 : 0;
}

sub conf {
    my ($key) = @_;
    $CONF{$key} // die "missing config key `$key´"
}

sub confopt  { $CONF{$_[0]} // '' }
sub confflag { $CONF{$_[0]} ? 1 : 0 }

sub conf_u    { to_uint &conf }
sub confopt_u { to_uint &confopt }

sub conflist {
    my @list;
    for (@CONF{@_}) {
        push @list, ref($_) eq 'ARRAY' ? @$_ : $_
            if defined;
    }
    @list;
}

sub mtime { (stat shift)[9] }
sub touch { utime undef, undef, shift }

sub min {
    my $min = shift;
    for (@_) { $min = $_ if $_ < $min }
    $min;
}

sub max {
    my $max = shift;
    for (@_) { $max = $_ if $_ > $max }
    $max;
}

sub to_uint {
    local $_ = shift;
    die "`$_´ cannot be converted to uint" if /\D/;
    length() ? 0 + $_ : 0;
}

sub note {
    unshift @_, $dryrun || !$async ? () : '@aync';
    say join ' ', @_ unless $quiet;
}

sub files {
    my ($base, @globs) = @_;

    my @files;
    for (@globs) {
        push @files, glob("$base/$_");
    }

    @files;
}

sub mkparents {
    my %dirs;
    for (@_) {
        local $_ = $_;
        $dirs{$_} = undef while s/[\\\/][^\\\/]*$//;
    }
    mkdir for sort keys %dirs;
}

sub reext {
    my ($old, $new, @names) = @_;
    s/\Q$old\E$/$new/ for @names;
    @names;
}

sub rotor {
    my ($n, $sub) = @_;
    my @stack;
    sub {
        push @stack, $_;
        if (@stack == $n) {
            $sub->(@stack);
            @stack = ();
        }
    };
}

sub chomped {
    my ($sub) = @_;
    sub {
        chomp;
        $sub->();
    };
}

sub with_file {
    my ($file, $sub) = @_;
    open local $fh, $file or die "$file: $!";
    $sub->();
    close $fh;
}

sub each_line {
    my ($sub) = @_;
    sub {
        while (<$fh>) {
            local $_ = $_;
            $sub->();
        }
    };
}

sub with_dir {
    my ($dir, $sub) = @_;
    opendir local $dh, $dir or die "$dir: $!";
    $sub->();
    close $dh;
}

sub each_file {
    my ($sub) = @_;
    sub {
        while (readdir $dh) {
            local $_ = $_;
            $sub->();
        }
    };
}

sub dirwalk {
    my ($dir, $sub) = @_;

    my @subdirs;
    with_dir $dir, each_file sub {
        return if /^\./;
        my $file = "$dir/$_";
        if (-f $file) {
            local $_ = $file;
            $sub->();
        }
        elsif (-d $file) { push @subdirs, $file }
    };

    dirwalk($_, $sub) for @subdirs;
}

sub for_repos {
    for my $repo (@REPOS) {
        $_->(@$repo) for @_;
    }
}

sub enqueue {
    push @queue, \@_;
}

# TODO: error handling!
sub batch {
    return unless @queue;

    if ($batchsize < 2 || $dryrun) {
        run @$_ for @queue;
        @queue = ();
        return;
    }

    my %procs;
    my %cmds;

    LOOP: while (1) {
        while (scalar(keys %procs) < $batchsize) {
            my $cmd = shift @queue;
            my $pid = spawn @$cmd;
            die $! unless $pid > 0;
            $procs{$pid} = undef;
            $cmds{$pid} = $cmd;
            last LOOP unless scalar(@queue);
        }

        my $pid = wait;
        die if !exists $procs{$pid} || $? != 0;
        delete $procs{$pid};
        delete $cmds{$pid};
    }

    while ((my $pid = wait) >= 0) {
        die if !exists $procs{$pid} || $? != 0;
        delete $procs{$pid};
        delete $cmds{$pid};
    }

    die if scalar(keys %procs);
}

sub run {
    my ($cmd) = @_;
    note @_;
    return 1 if $dryrun;

    system(@_) == 0
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

sub spurt {
    my $file = shift;
    open my $fh, '>', $file or die $!;
    syswrite $fh, $_ or die $! for @_;
    close $fh;
}

sub gen {
    my ($dest, $src, $hash) = @_;

    my @lines;
    with_file $src, each_line sub {
        while (/@(\w+)@/) {
            my $key = $1;
            die "unknown key `$key´"
                unless exists $hash->{$key};

            my $value = $hash->{$key};
            s/@\Q$key\E@/$value/g;
        }

        push @lines, $_;
    };

    note '# GENERATING `$dest´ from `$src´';
    spurt $dest, @lines unless $dryrun;
}

sub includes {
    my $node = shift;
    my $root = conf("$node.root");
    map { "$root/$_" } conflist("$node.include");
}

sub headers {
    my @headers;
    for (includes shift) {
        dirwalk $_, sub {
            push @headers, $_ if /\.h$/;
        };
    }
    @headers;
}

sub sources {
    my $node = shift;
    my $root = conf("$node.root");
    my $base = "$root/".conf("$node.src.base");
    files $base, conflist("$node.src");
}

sub objects {
    my ($node, $prefix, @sources) = @_;
    my $root = conf("$node.root");
    my $base = "$root/".conf("$node.src.base");
    map { s/^$base/$prefix/r }
        reext '.c', conf('build.suffix.obj'), @sources;
}

sub cache {
    my ($file) = @_;
    return unless -f $file;

    my %cache;
    with_file $file, each_line chomped rotor 3, sub {
        my ($dest, @info) = @_;
        $cache{$dest} = \@info;
    };

    %cache;
}

sub ccdigest {
    die if $_[ 1] ne conf('build.cc.flags.compile')
        || $_[-3] ne conf('build.cc.flags.out');

    splice @_, 1, 1, conf('build.cc.flags.preprocess');
    splice @_, -3, 2;

    my $cmd = join ' ', map { '"' . s/"/\\"/rg . '"' } @_;
    my $out = `$cmd`;
    die unless $? == 0;
    sha1_base64 $out;
}

sub toggle {
    map { /^no-/ ? s/^no-//r : "no-$_"; } @_;
}

sub buildspec {
    my ($node, @flags) = @_;

    my %builds;
    @builds{conflist "$node.builds"} = ();
    @builds{map { "no-$_" } keys %builds} = ();

    my %spec;
    @spec{conflist "$node.builds.default"} = ();

    @flags = grep { exists $builds{$_} } @flags;
    delete @spec{toggle @flags};
    @spec{@flags} = ();

    sort keys %spec;
}

sub buildargs {
    my ($node, @flags) = @_;
    my ($name) = $node =~ /(\w+)$/;
    my @spec = buildspec @_;
    my $id = join '-', $name, grep { !/^no-/ } @spec;
    $node, $name, $id, @spec;
}

sub inc { map { conf('build.cc.flags.include') . $_ } @_ }

sub cc_co {
    conflist(qw(build.cc build.cc.flags.compile)),
    confflag('build.debug')
            ? conflist('build.cc.flags.debug')
            : conflist('build.cc.flags.nodebug'),
    @_,
    conf('build.cc.flags.out');
}

sub ar_rcs {
    conf('build.ar'), conflist('build.ar.flags.rcs'), @_;
}

sub compile {
    my ($node, $name, $id, @spec) = @_;
    my $cachefile = "CACHE.$id";

    note "# COMPILING `$id´";

    my @cflags;
    push @cflags, conflist("$node.build.$_.cc.flags") for @spec;
    push @cflags, inc includes $node;

    my @cc_co = cc_co @cflags;
    my @ar_rcs = ar_rcs;

    my @sources = sources $node;
    my @objects = objects $node, "BUILD.$id", @sources;
    mkparents @objects unless $dryrun;

    my @headers = headers $node;
    my $hdrtime = max map { mtime $_ } @headers;

    my %cache = cache $cachefile
        unless $dryrun;

    for (my $i = 0; $i < @objects; ++$i) {
        my $obj = $objects[$i];
        my $src = $sources[$i];
        my @cmd = (@cc_co, $obj, $src);

        my ($exists, $objtime);
        next if !$force
             && ($exists = -f $obj)
             && ($objtime = mtime($obj)) > $CONFTIME
             && $objtime > $hdrtime
             && $objtime > mtime($src);

        unless ($dryrun) {
            my $cmd = join "\0", @cmd;
            my $digest = ccdigest @cmd;
            if (!$force
                && $exists
                && exists $cache{$obj}
                && $cache{$obj}->[0] eq $cmd
                && $cache{$obj}->[1] eq $digest) {
                touch $obj;
                next;
            }

            $cache{$obj} = [ $cmd, $digest ];
        }

        enqueue @cmd;
    }

    my $compiling = @queue > 0;

    unlink $cachefile
        unless $dryrun;

    batch;

    spurt $cachefile,
        map { map { "$_\n" } $_, @{$cache{$_}} } sort keys %cache
            unless $dryrun;

    $compiling;
}

sub nolib {
    my ($node, $name, $id, @spec) = @_;
    not -f "BUILD.$id/$name.a";
}

sub linkit {
    my ($node, $name, $id, @spec) = @_;
    say join ' ', ar_rcs("BUILD.$id/$name.a", '?');
}

sub build {
    my $node = shift;
    sub {
        @_ = buildargs $node, @_;
        (&compile or &nolib) and &linkit;
    }
}

sub dispatch {
    my ($target, @args) = @_;
    $target //= 'build';
    die "unknown target `$target´"
        unless exists $targets{$target};

    $targets{$target}->(@args);
}

sub help {
    my ($key, $value) = @_;
    push @help, $key;
    $help{$key} = $value;
}

sub target {
    my ($name, $action) = @_;
    $targets{$name} = $action;
}

help 'pull'
    => "update existing git repositories and create missing ones";

help 'build'
    => "build everything [DEFAULT TARGET]";

help 'build-libuv'
    => "build bundled copy of libuv as static library";

help 'clobber'
    => "git clean all repositories";

help 'DRY_RUN'
    => "merely log instead of execute commands";

help 'QUIET'
    => 'suppress logging output';

help 'SYNC'
    => "fully synchronous build";

help 'FORCE_BUILD'
    => "always rebuild";

target '--help' => sub {
    say "\n  Abandon all hope, ye who enter here.";

    say "\nUSAGE\n",
        "\n  perl build.pl <TARGET> [<ARGS>]",
        "\n  perl build.pl [--version] [--license] [--help]",
        "\n";

    say "\nTARGETS\n";
    say "  $_\n    ", ($help{$_} // ''), "\n"
        for grep { exists $targets{$_} && !/^--/ } @help;

    say "\nENVIRONMENT VARIABLES\n";
    say "  $_=1\n    ", ($help{$_} // ''), "\n"
        for grep { /^(?:$FLAGRX)$/ } @help;
};

target '--version' => sub { say $VERSION };

target '--license' => sub { print $LICENSE };

target 'clobber' => sub {
    for_repos sub {
        my ($dir) = @_;
        run 'git', '-C', $dir, 'clean', '-xdf';
    };
};

target 'pull' => sub {
    my @jflag = conflist('git.flags.jobs');

    for_repos sub {
        my ($dir, $url) = @_;

        enqueue -e $dir
            ? ('git', '-C', $dir, 'pull', '--recurse-submodules', @jflag)
            : ('git', 'clone', '--depth=1',
                '--recurse-submodules', @jflag, $url, $dir);
    };

    batch;
};

target 'build' => sub {
    say 'TODO';
};

target 'build-libuv' => build 'moar.3rdparty.libuv';;

target 'build-libtommath' => build 'moar.3rdparty.libtommath';

dispatch @ARGV;

__END__
target 'build' => sub {
    dispatch
        confflag('moar.3rdparty.libuv.global') ? () : 'build-libuv';
};

target 'moar-config' => sub {
    for my $file (qw(config.h config.c)) {
        my $src = conf('moar.root')."/build/$file.in";
        my $dest = conf('moar.root')."/src/gen/$file";
        gen $dest, $src, \%moarconfig
            if needs_rebuild $dest, min mtime($src), $CONFTIME;
    }
};
