#!/usr/bin/perl
# worker-lifecycle-test.pl — 常驻 worker 生命周期回归（CBM 审计 F.13，0.11.86）
# 用法：perl plugin/t/worker-lifecycle-test.pl
#
# 背景：`request → _worker_submit → _worker_poll(超时) → _worker_kill
#        → _worker_fail_all('retry:…') → request` 是一个**四元环**（retry 会同步重入
# `request()`）。0.11.54 的"worker kill 雪崩"（mg 一张歌单几乎全无声）就是环失控的现场；
# 0.11.58 又踩出"kill 删错格子 ⇒ 孤儿 worker"。
#
# 本套件钉死环上的**两道不变量**与 kill 的格子归属：
#   ① `$job->{forked}` —— retry 只发生一次；已 fork 过的 job 再进来只能报错，不许无限重试。
#   ② `%WORKER_BAD{key}`（10 分钟）—— 超时后该源改走 fork，环不会再被触发。
#   ③ `_worker_kill` 只删**自己那一格**（`$WORKER{key} == $w`），否则会删掉 retry 期间
#      刚 spawn 出来的新 worker 的登记 ⇒ 新进程成孤儿、同源叠出两个 qjs。
#
# 手法：自己搭一个假 worker（真管道 + 真子进程当 pid），把 `request` 换成记录器，
# 于是可以观察"超时后到底走 fork 还是直接判失败"。不依赖设备、不依赖 qjs。
#
# ⚠️ 两个调用约定（本文件第一版就踩了）：
#   · `_worker_poll` / `_worker_hostile` **不是方法**——`my ($w) = @_` / `my $src = shift`，
#     必须用函数式调用（LMS 的 Timers 也只传一个 client 参数）。写成 `$H->...` 会把类名当参数。
#   · `_worker_fail_all` / `_worker_kill` 是方法（`my ($class, $w, $why) = @_`），两种调用都行。
use strict;
use warnings;

use FindBin;
use File::Spec;
use POSIX ();

use lib File::Spec->catdir($FindBin::Bin);           # t/ —— Slim::* / AnyEvent 存根

BEGIN {
	$ENV{LX_TEST_QUIET_WARN} = 1;                    # 让 CI 回写的回归日志逐字节稳定
	my $root  = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
	my $build = File::Spec->catdir($root, 't_build', 'Plugins', 'LxMusic');
	unshift @INC, sub {
		my ($self, $file) = @_;
		return unless $file =~ m{^Plugins/LxMusic/([^/]+\.pm)$};
		my @cand = grep { -f $_ } map { File::Spec->catfile($_, $1) }
			($build, File::Spec->catdir($root, 'LxMusic'));
		return unless @cand;
		my ($newest) = sort { (stat($b))[9] <=> (stat($a))[9] } @cand;
		open my $fh, '<', $newest or return;
		return $fh;
	};
	my $helper = File::Spec->catfile($FindBin::Bin, '..', 'LxMusic', 'Helper.pm');
	require $helper;
	$INC{'Plugins/LxMusic/Helper.pm'} = $helper;
}

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

my $H = 'Plugins::LxMusic::Helper';
my @dispatched;          # 记录 retry 时的 request() 调用
my $stub_request = sub {
	my ($class, %a) = @_;
	push @dispatched, \%a;
	return 1;
};
{
	no warnings 'redefine';
	no strict 'refs';
	*Plugins::LxMusic::Helper::request = $stub_request;
}

sub job_line {
	my ($id, $src, $action, $info) = @_;
	# 手写 JSON，免得依赖存根 JSON::XS 的编码细节（这里只要求能被 decode 回来）
	return sprintf('{"id":%d,"action":"%s","source":"%s","info":{"id":"%s"}}',
		$id, $action, $src, $info->{id}) . "\n";
}

# 假 worker 工厂：pid/rd/wr 由调用方给（undef = 该用例不关心进程/管道）
sub fake_worker {
	my (%o) = @_;
	return {
		key => $o{key} || '/tmp/lx-src-A.js',
		src => $o{key} || '/tmp/lx-src-A.js',
		pid => $o{pid},
		rd  => $o{rd},
		wr  => $o{wr},
		buf => '', ready => 1, queue => [], jobs => {}, id => 0,
		last => time(), recent => [], info => '', dead => 0,
	};
}

# ---------------------------------------------------------------- §A _worker_fail_all
{
	@dispatched = ();
	my $w = fake_worker(key => 'retry-src');
	my $timeout = 42;
	my @cbs;
	my $mk = sub {
		my $n = shift;
		my $cb = sub { push @cbs, $_[0] };
		return { id => $n, cb => $cb, timeout => $timeout, logs => [],
			line => job_line($n, 'kw', 'musicUrl', { id => 'song' . $n }) };
	};
	my $j1 = $mk->(1);                      # 还没 fork 过 ⇒ 应该被"改走 fork"
	my $j2 = $mk->(2); $j2->{forked} = 1;   # 已经 fork 过 ⇒ 只能报错，不许再 fork
	$w->{jobs}  = { 1 => $j1, 2 => $j2 };
	$w->{queue} = [1, 2];

	my $dead_when_dispatched;
	{
		local $SIG{__WARN__} = sub { };     # 假 worker 不在 %WORKER 里，压掉 undef 比较告警
		no warnings 'redefine';
		*Plugins::LxMusic::Helper::request = sub {
			my ($class, %a) = @_;
			$dead_when_dispatched = $w->{dead};
			push @dispatched, \%a;
			return 1;
		};
		$H->_worker_fail_all($w, 'retry:worker timed out');
	}
	*Plugins::LxMusic::Helper::request = $stub_request;

	check('retry: worker marked dead BEFORE the re-dispatch (no reuse of a dying worker)',
		$dead_when_dispatched ? 1 : 0,
		defined $dead_when_dispatched ? "dead=$dead_when_dispatched" : 'request never called');
	check('retry: exactly one job re-dispatched (fork path)', @dispatched == 1, scalar @dispatched);
	my $d = $dispatched[0] || {};
	check('retry: re-dispatch keeps source key',   ($d->{source}   // '') eq 'retry-src', $d->{source} // '');
	check('retry: re-dispatch keeps sourceId',     ($d->{sourceId} // '') eq 'kw',        $d->{sourceId} // '');
	check('retry: re-dispatch keeps action',       ($d->{action}   // '') eq 'musicUrl',  $d->{action} // '');
	check('retry: re-dispatch keeps timeout',      ($d->{timeout}  // 0)  == $timeout,    $d->{timeout} // 'undef');
	check('retry: re-dispatch keeps info payload',
		(ref $d->{info} eq 'HASH' && ($d->{info}{id} // '') eq 'song1'), ref $d->{info});
	check('retry: re-dispatch keeps the callback', (ref $d->{cb} // '') eq 'CODE');
	check('retry: job flagged forked (one-shot)',  $j1->{forked} ? 1 : 0);
	check('retry: already-forked job is NOT retried again', $j2->{forked} == 1 && @dispatched == 1);
	check('retry: already-forked job got an error callback', @cbs == 1 && !$cbs[0]{ok}, scalar @cbs);
	check('retry: error callback carries why=worker', (($cbs[0] || {})->{why} // '') eq 'worker',
		($cbs[0] || {})->{why} // '');
	check('retry: queued jobs dropped', @{ $w->{queue} } == 0, scalar @{ $w->{queue} });
	check('retry: jobs table drained', scalar(keys %{ $w->{jobs} }) == 0);

	# 幂等：同一个 worker 再 fail 一次不该再派发任何东西
	@dispatched = ();
	{
		local $SIG{__WARN__} = sub { };
		$H->_worker_fail_all($w, 'retry:worker timed out');
	}
	check('retry: second fail_all on the same worker dispatches nothing', @dispatched == 0, scalar @dispatched);
}

# ---------------------------------------------------------------- §B 超时 → fork
{
	my $pid;
	{
		local $SIG{__WARN__} = sub { };
		$pid = fork();
		if (defined $pid && $pid == 0) { sleep 30; POSIX::_exit(0) }
	}
	if (!$pid) {
		print "ok - skip: platform has no fork (timeout->fork case)\n";
	}
	else {
		@dispatched = ();
		my @cbs;
		pipe(my $rd, my $wr) or die "pipe: $!";
		close $wr;                      # 写端关掉 ⇒ sysread 立刻 EOF，poll 不会阻塞
		my $w = fake_worker(pid => $pid, rd => $rd, key => '/tmp/lx-src-B.js');
		my $timedout = {
			id => 7, cb => sub { push @cbs, { %{ $_[0] }, _which => 'timedout' } },
			timeout => 3, logs => [], line => job_line(7, 'kw', 'musicUrl', { id => 'T' }),
			sent => time() - 9, deadline => time() - 6, started => time() - 9,
		};
		my $sibling = {
			id => 8, cb => sub { push @cbs, { %{ $_[0] }, _which => 'sibling' } },
			timeout => 20, logs => [], line => job_line(8, 'kg', 'musicUrl', { id => 'S' }),
			sent => time() - 2, deadline => time() + 18, started => time() - 2,
		};
		$w->{jobs} = { 7 => $timedout, 8 => $sibling };
		Slim::Utils::Timers::resetForTest();

		my $bad_before = Plugins::LxMusic::Helper::_worker_hostile($w->{key}) ? 1 : 0;
		{
			local $SIG{__WARN__} = sub { };
			Plugins::LxMusic::Helper::_worker_poll($w);
		}

		check('timeout: worker was not previously hostile', $bad_before == 0);
		check('timeout: worker marked hostile (later requests take the fork path)',
			Plugins::LxMusic::Helper::_worker_hostile($w->{key}) ? 1 : 0);
		check('timeout: worker marked dead', $w->{dead} ? 1 : 0);
		check('timeout: timed-out job answered exactly once', scalar(@cbs) == 1, scalar @cbs);
		my ($to)  = grep { $_->{_which} eq 'timedout' } @cbs;
		my ($sib) = grep { $_->{_which} eq 'sibling' } @cbs;
		check('timeout: timed-out job gets the explicit timeout error',
			$to && !$to->{ok} && ($to->{why} // '') eq 'timeout', $to ? ($to->{why} // 'undef') : 'no callback');
		check('timeout: timeout message names the budget',
			$to && ($to->{error} // '') =~ /timeout: worker request exceeded/, $to ? ($to->{error} // '') : '');
		check('timeout: sibling in-flight job is NOT failed with worker-stopped (snowball fix)',
			!$sib, $sib ? ($sib->{error} // '') : 'none');
		check('timeout: sibling was re-dispatched via fork',
			@dispatched == 1 && (($dispatched[0]{sourceId} // '') eq 'kg'), scalar @dispatched);
		my @pending = grep { "$_->{client}" eq "$w" } Slim::Utils::Timers::listPending();
		check('timeout: no poll timer left for the recycled worker', scalar(@pending) == 0, scalar @pending);

		{ local $SIG{__WARN__} = sub { }; close $rd if $rd }
		kill 'KILL', $pid if $pid;
		waitpid($pid, POSIX::WNOHANG());
	}
}

# ---------------------------------------------------------------- §C 源码级护栏
# 这两条是"改坏就静默复发"的修复（0.11.58 的孤儿 worker / 0.11.54 的雪崩），
# 行为层不好构造（需要真 spawn + 真 %WORKER），所以直接在源码上钉住写法。
{
	my $src = do {
		local (@ARGV, $/) = (File::Spec->catfile($FindBin::Bin, '..', 'LxMusic', 'Helper.pm'));
		<>
	};
	check('guard: kill deletes only its own slot (not a bare delete)',
		$src =~ /delete \$WORKER\{ \$w->\{key\} \}\s*if\s*\$WORKER\{ \$w->\{key\} \}\s*==\s*\$w;/,
		'guarded delete missing');
	check('guard: timeout branch recycles with retry: prefix',
		$src =~ /_worker_kill\(\$w,\s*'retry:worker timed out'\)/, 'retry prefix missing');
	check('guard: timeout branch stamps WORKER_BAD before recycling',
		$src =~ /\$WORKER_BAD\{ \$w->\{key\} \} = time\(\);/, 'WORKER_BAD stamp missing');
	check('guard: retry marks the worker dead before re-dispatch',
		$src =~ /\$w->\{dead\} = 1 if \$retry;/, 'pre-dead guard missing');
	check('guard: already-forked jobs never re-enter request',
		$src =~ /if \(\$retry && !\$job->\{forked\}\)/, 'forked one-shot guard missing');
}

print $failed ? "\nFAILED: $failed\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
