package Slim::Utils::Timers;

# 最小桩：no-op 定时器（真实环境为 LMS 事件循环定时器）
use strict;
use warnings;

my @fired;

sub setTimer  { my ($c, $t, $cb, @args) = @_; push @fired, { client => $c, at => $t, cb => $cb, args => \@args }; return }
sub killTimers { my ($c, $cb) = @_; @fired = grep { $_->{client} ne $c || ($cb && $_->{cb} ne $cb) } @fired; return }
sub listPending { return @fired }
sub resetForTest { @fired = (); return }

# 测试用（0.11.58 新增）：立即执行所有**已到期**的定时器回调——真实环境由 LMS 事件循环驱动。
# 只增不改：既有用例不受影响。
sub fireDue {
	my $now = time();
	my @due = grep { $_->{at} <= $now } @fired;
	@fired = grep { $_->{at} > $now } @fired;
	$_->{cb}->(@{ $_->{args} }) for @due;
	return scalar @due;
}

1;
