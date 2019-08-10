use v5.12;
use warnings;

sub run {
    my ($cmd, @args) = @_;
    say join ' ', @_;
    system($cmd, @args) == 0
        or die "`$cmd´ returned $?";
}

sub for_repos {
    open my $fh, 'repo.list'
        or die $!;

    while (<$fh>) {
        chomp;
        my ($dir, $url) = split /\s+/, $_, 2;
        $_->($dir, $url) for @_;
    }

    close $fh;
}

sub init {
    for_repos sub {
        my ($dir, $url) = @_;
        run 'git',  'clone', '--depth=1', $url, $dir;
    };
}

sub update {
    for_repos sub {
        my ($dir, $url) = @_;
        run 'git', '-C', $dir, 'pull', '--depth=1';
    };
}

my %targets = (
    init => \&init,
    update => \&update,
);

@ARGV = qw(build)
    unless @ARGV;

for (@ARGV) {
    die "unknown target `$_´"
        unless exists $targets{$_};

    $targets{$_}->();
}
