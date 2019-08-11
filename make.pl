use v5.14;
use warnings;

use subs qw(
    conf confopt confflag conf_u confopt_u conflist
    mtime min to_uint note files mkparents reext
    with_file each_line with_dir each_file dirwalk for_repos
    enqueue batch run spawn spurt gen
    includes headers sources objects
    toggle buildspec inc cc_co
    dispatch help target
);

our $CONFFILE;
our $MTIME;
our %CONF;
our %MOARCONF;
our @REPOS;

our $fh;
our $dh;

our $quiet;
our $async;
our $batchsize;
our $dryrun;

my %targets;
my %help;
my @help;
my @queue;

INIT {
    $CONFFILE = 'build.conf';
    $MTIME = mtime $CONFFILE;

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

    $quiet = $ENV{QUIET} ? 1 : 0;
    $async = 0;
    $batchsize = $ENV{SYNC} ? 0 : confopt_u 'make.async.degree';
    $dryrun = $ENV{DRY_RUN} ? 1 : 0;
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

sub min {
    my $min = shift;
    for (@_) { $min = $_ if $_ < $min }
    $min;
}

sub to_uint {
    local $_ = shift;
    die "`$_´ cannot be converted to uint" if /\D/;
    length ? 0 + $_ : 0;
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
    my $name = shift;

    note 'spurt', $name;
    return if $dryrun;

    open my $fh, '>', $name or die $!;

    syswrite $fh, $_ or die $!
        for @_;

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

    spurt $dest, @lines;
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

sub toggle {
    map { /^no-/ ? s/^no-//r : "no-$_"; } @_;
}

sub buildspec {
    my ($node, @flags) = @_;

    my %builds;
    @builds{::conflist "$node.builds"} = ();
    @builds{map { "no-$_" } keys %builds} = ();

    my %spec;
    @spec{::conflist "$node.builds.default"} = ();

    @flags = grep { exists $builds{$_} } @flags;
    delete @spec{toggle @flags};
    @spec{@flags} = ();

    sort keys %spec;
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

help 'clobber'
    => "git clean all repositories";

help 'build'
    => "build everything [DEFAULT]";

help 'build-libuv'
    => "build libuv as static library";

help 'DRY_RUN'
    => "merely log instead of execute commands";

help 'QUIET'
    => 'suppress logging output';

help 'SYNC'
    => "fully synchronous build";

target '--help' => sub {
    say "\n  Abandon all hope, ye who enter here.";
    say "\nTARGETS\n";
    say "  $_\n    ", ($help{$_} // ''), "\n"
        for grep { exists $targets{$_} } @help;
    say "\nENVIRONMENT FLAGS\n";
    say "  $_\n    ", ($help{$_} // ''), "\n"
        for grep { /DRY_RUN|QUIET|SYNC/ } @help;
};

target '--license' => sub {
    print <<'END_LICENSE';
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
};

target 'clobber' => sub {
    for_repos sub {
        my ($dir) = @_;
        run 'git', '-C', $dir, 'clean', '-xdf';
    };
};

target 'pull' => sub {
    my @jflag = conflist('git.jflag');

    for_repos sub {
        my ($dir, $url) = @_;

        enqueue -e $dir
            ? ('git', '-C', $dir, 'pull', '--depth=1',
                '--recurse-submodules', @jflag)
            : ('git', 'clone', '--depth=1',
                '--recurse-submodules', @jflag, $url, $dir);
    };

    batch;
};

target 'build-libuv' => sub {
    my $node = 'moar.3rdparty.libuv';
    my @spec = buildspec $node, @_;

    my @cflags;
    push @cflags, conflist("$node.build.$_.cc.flags") for @spec;
    push @cflags, inc includes $node;

    my @cmd = cc_co @cflags;
    say join ' ', @cmd;

};

dispatch @ARGV;

__END__
sub needs_rebuild {
    my ($dest, $mtime) = @_;
    !-f $dest || mtime($dest) < $mtime;
}

sub build {
    my ($node, $id) = @_;
    sub {
        my @cmd = cc_co inc(includes $node);
        my @sources = sources $node;
        my @objects = objects $node, "build.$id", @sources;
        mkparents @objects unless $dryrun;

        my $compiled = 0;
        for (my $i = 0; $i < @sources; ++$i) {
            my $src = $sources[$i];
            my $dest = $objects[$i];

            if (needs_rebuild $dest, min mtime($src), $MTIME) {
                enqueue @cmd, $dest, $src;
                $compiled = 1;
            }
        }

        batch;
    };
}


target 'build' => sub {
    dispatch
        confflag('moar.3rdparty.libuv.global') ? () : 'build-libuv';
};

target 'moar-config' => sub {
    for my $file (qw(config.h config.c)) {
        my $src = conf('moar.root')."/build/$file.in";
        my $dest = conf('moar.root')."/src/gen/$file";
        gen $dest, $src, \%moarconfig
            if needs_rebuild $dest, min mtime($src), $MTIME;
    }
};

package oo {
    sub public {
        no strict 'refs';
        my $pkg = caller;
        for my $slot (@_) {
            *{"${pkg}::${slot}"} = sub : lvalue { shift->{$slot} };
        }
    }
}

package Builder {
    BEGIN { oo::public qw(name build) }

    sub new {
        my (undef, $name, $node, @flags) = @_;

        my %builds;
        @builds{::conflist "$node.builds"} = ();
        @builds{map { "no-$_" } keys %builds} = ();

        my %current;
        @current{::conflist "$node.builds.default"} = ();

        @flags = grep { exists $builds{$_} } @flags;
        delete @current{toggle @flags};
        @current{@flags} = ();

        bless {
            node => $node,
            name => $name,
            build => [ sort keys %current ],
        };
    }

    sub id {
        my $self = shift;
        join '-', $self->name, grep { !/^no-/ } @{$self->build};
    }

    sub includes { ::includes shift->{node} }
    sub headers { ::headers shift->{node} }
    sub sources { ::sources shift->{node} }

    sub objects {
        my ($self, $prefix) = @_;
        my $node = $self->{node};
        my $id = $self->id;
        ::objects $node, "$prefix$id", ::sources $node;
    }
}

#say for Builder->new('libuv', 'moar.3rdparty.libuv')->objects('build.');
