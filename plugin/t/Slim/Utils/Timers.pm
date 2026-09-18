package Slim::Utils::Timers;

# 最小桩：no-op 定时器（真实环境为 LMS 事件循环定时器）
use strict;
use warnings;

my @fired;

sub setTimer  { my ($c, $t, $cb, @args) = @_; push @fired, { client => $c, at => $t, cb => $cb, args => \@args }; return }
sub killTimers { my ($c, $cb) = @_; @fired = grep { $_->{client} ne $c || ($cb && $_->{cb} ne $cb) } @fired; return }
sub listPending { return @fired }
sub resetForTest { @fired = (); return }

1;
