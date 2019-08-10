use v5.12;
use warnings;

my %targets;
my %rules;

sub spurt {
    my ($name, $contents) = @_;
    say 'SYNC spurt ', $name;
    open my $fh, '>', $name or die $!;
    syswrite $fh, $contents or die $!;
    close $fh;
}

sub spawn {
    say join ' ', 'ASYNC', @_;
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
    say join ' ', 'SYNC', @_;
    system($cmd, @args) == 0
        or die "`$cmd´ returned $?";
}

sub for_repos {
    open my $fh, 'repo.list'
        or die $!;

    while (<$fh>) {
        chomp;
        my ($url, $dir) = split /\s+/, $_, 2;
        $_->($dir, $url) for @_;
    }

    close $fh;
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
    my $pid;
    delete $procs->{$pid}
        while ($pid = wait) >= 0;

    !%$procs;
}

target '--help' => sub {
    say <<'DONE';
TODO
DONE
};

target init => sub {
    spurt 'repo.list', <<'DONE' unless -f 'repo.list';
https://github.com/MoarVM/MoarVM.git            moar
https://github.com/perl6/nqp.git                nqp
https://github.com/rakudo/rakudo.git            rakudo
https://github.com/MoarVM/libatomic_ops.git     3rdparty/libatomicops
https://github.com/libuv/libuv.git              3rdparty/libuv
https://github.com/MoarVM/dyncall.git           3rdparty/dyncall
https://github.com/MoarVM/dynasm.git            3rdparty/dynasm
https://github.com/MoarVM/libtommath            3rdparty/libtommath
https://github.com/MoarVM/cmp.git               3rdparty/cmp
DONE
};

target pull => sub {
    my %procs;

    for_repos sub {
        my ($dir, $url) = @_;

        my $pid = spawn -e $dir
            ? ('git', '-C', $dir, 'pull', '--depth=1')
            : ('git',  'clone', '--depth=1', $url, $dir);

        die $! if $pid <= 0;
        $procs{$pid} = 1;
    };

    await \%procs or die;
};

gen 'moar/src/gen/config.h', 'moar/build/config.h.in', sub {
    my ($dest, $src) = @_;

};

dispatch @ARGV ? @ARGV : qw(build);
