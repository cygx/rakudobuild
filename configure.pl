# Copyright 2019 cygx <cygx@cpan.org>
# Distributed under the Boost Software License, Version 1.0

use v5.14;
use warnings;

use subs qw(probe);

if (@ARGV != 2 || (@ARGV == 1 && not $ARGV[0] =~ /^--c[cl]$/)) {
    print <<'DONE';

  USAGE
  
      perl configure.pl --cc <COMPILER>
      perl configure.pl --cl <COMPILER>

    use --cc if your compiler is POSIX-like
    use --cl if your compiler is MSVC-like
    
DONE
    exit @ARGV == 1 && $ARGV[0] eq '--help' ? 0 : 1;
}

my (undef, $cc) = @ARGV;
my %tools = (cpp => \&cpp, cc => \&cc);

probe 'cpp.kernel';
probe 'cpp.distro';
probe 'cc.ptrsize';

sub capture_tail {
    open my $proc, '-|', @_;
    my $line;
    while (<$proc>) {
        $line = $_ if /\S/;
    }

    close $proc;
    die unless $? == 0;

    $line =~ s/^\s+|\s+$//g;
    $line;
}

sub cpp {
    my $key = shift;
    capture_tail $cc, '-E', "probes/$key.c";
}

sub cc {
    my $key = shift;
    system $cc, '-oTEMP.probe.exe', "probes/$key.c";
    die unless $? == 0;
    capture_tail './TEMP.probe.exe';
}

sub probe {
    my $key = shift;
    say "probing $key...";
    my ($tool) = $key =~ /^(\w+)/;
    printf "  %s\n\n", $tools{$tool}->($key);
}
