use v5.14;
use warnings;

my $MTIME = mtime('build.conf');

our $fh;
our $dh;

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

my sub with_dir {
    my ($dir, $sub) = @_;
    opendir local $dh, $dir or die "$dir: $!";
    $sub->();
    close $dh;
}

my sub each_file {
    my ($sub) = @_;
    sub {
        while (readdir $dh) {
            local $_ = $_;
            $sub->();
        }
    };
}

my %config;
sub to_uint {
    local $_ = shift;
    die "`$_´ cannot be converted to uint" if /\D/;
    0 + $_;
}

my sub conf {
    my ($key) = @_;
    $config{$key} // die "missing config key `$key´"
}

my sub confopt  { $config{$_[0]} // '' }
my sub confflag { $config{$_[0]} ? 1 : 0 }

my sub conf_u    { to_uint &conf }
my sub confopt_u { to_uint &confopt }

my sub conflist {
    my @list;
    for (@config{@_}) {
        push @list, ref($_) eq 'ARRAY' ? @$_ : $_
            if defined;
    }
    @list;
}

with_file 'build.conf', sub {
    while (<$fh>) {
        s/^\s+|\s+$//g;
        next if length == 0 || /^#/;

        my ($key, $value) = split /\s+/, $_, 2;
        if ($key =~ s/\[\]$//) {
            push @{$config{$key}}, $value;
        }
        else {
            $config{$key} = $value;
        }
    }
};

my %moarconfig = (
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

our $quiet = $ENV{QUIET} ? 1 : 0;
our $async = 0;
our $batchsize = $ENV{SYNC} ? 0 : confopt_u 'make.async.degree';
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
my %help;
my @help;

sub note {
    unshift @_, $dryrun || !$async ? () : '@aync';
    say join ' ', @_ unless $quiet;
}

sub min {
    my $min = shift;
    for (@_) { $min = $_ if $_ < $min }
    $min;
}

sub mtime {
    (stat shift)[9];
}

sub needs_rebuild {
    my ($dest, $mtime) = @_;
    !-f $dest || mtime($dest) < $mtime;
}

sub files {
    my ($base, @globs) = @_;

    my @files;
    for (@globs) {
        push @files, glob("$base/$_");
    }

    @files;
}

sub reext {
    my ($old, $new, @names) = @_;
    s/\Q$old\E$/$new/ for @names;
    @names;
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

sub inc { map { conf('build.cc.flags.include') . $_ } @_ }
sub cc_co {
    conflist(qw(build.cc build.cc.flags.compile)),
    confflag('build.debug')
            ? conflist('build.cc.flags.debug')
            : conflist('build.cc.flags.nodebug'),
    @_,
    conf('build.cc.flags.out');
}

sub help {
    my ($key, $value) = @_;
    push @help, $key;
    $help{$key} = $value;
}

sub sources {
    my $node = shift;
    my $root = conf("$node.root");
    my $base = "$root/".conf("$node.src.base");
    files $base, conflist("$node.src");
}

sub objects {
    my ($node, $out, @sources) = @_;
    my $root = conf("$node.root");
    my $base = "$root/".conf("$node.src.base");
    map { s/^$base/$out/r }
        reext '.c', conf('build.suffix.obj'), @sources;
}

my sub includes {
    my $node = shift;
    my $root = conf("$node.root");
    map { "$root/$_" } conflist("$node.include");
}

sub mkparents {
    my %dirs;
    for (@_) {
        local $_ = $_;
        $dirs{$_} = undef while s/[\\\/][^\\\/]*$//;
    }
    mkdir for sort keys %dirs;
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

            if (needs_rebuild $dest) {
                batch @cmd, $dest, $src;
                $compiled = 1;
            }
        }

        done_batching;
    };
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

target 'clobber' => sub {
    for_repos sub {
        my ($dir) = @_;
        run 'git', '-C', $dir, 'clean', '-xdf';
    };
};

target 'pull' => sub {
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

target 'build-libuv' => build 'moar.3rdparty.libuv', 'libuv-static';

target 'build' => sub {
    dispatch
        confflag('moar.3rdparty.libuv.build') ? 'build-libuv' : ();
};

target 'moar-config' => sub {
    for my $file (qw(config.h config.c)) {
        my $src = conf('moar.root')."/build/$file.in";
        my $dest = conf('moar.root')."/src/gen/$file";
        gen $dest, $src, \%moarconfig
            if needs_rebuild $dest, min mtime($src), $MTIME;
    }
};

#dispatch @ARGV ? @ARGV : 'build';

package oo {
    sub slots {
        no strict 'refs';
        my $pkg = caller;
        for my $slot (@_) {
            *{"${pkg}::${slot}"} = sub : lvalue { shift->{$slot} };
        }
    }
}

package Builder {
    BEGIN { oo::slots qw(name include build) }

    my sub toggle {
        map { /^no-/ ? s/^no-//r : "no-$_"; } @_;
    }

    sub dirwalk {
        my ($dir, $sub) = @_;
        with_dir $dir, each_file sub {
            return if /^\./;
            my $file = "$dir/$_";
            if (-f $file) {
                local $_ = $file;
                $sub->();
            }
            elsif (-d $file) { dirwalk($file, $sub) }
        };
    }

    sub new {
        my (undef, $name, $node, @flags) = @_;

        my %builds;
        @builds{conflist "$node.builds"} = ();
        @builds{map { "no-$_" } keys %builds} = ();

        my %current;
        @current{conflist "$node.builds.default"} = ();

        @flags = grep { exists $builds{$_} } @flags;
        delete @current{toggle @flags};
        @current{@flags} = ();

        bless {
            name => $name,
            build => [ sort keys %current ],
            include => [ includes $node ],
        };
    }

    sub id {
        my $self = shift;
        join '-', $self->name, grep { !/^no-/ } @{$self->build};
    }

    sub headers {
        my @headers;
        for (@{shift->include}) {
            dirwalk $_, sub {
                push @headers, $_ if /\.h$/;
            };
        }
        @headers;
    }
}

say for Builder->new('libuv', 'moar.3rdparty.libuv')->headers;
