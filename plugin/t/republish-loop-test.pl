#!/usr/bin/perl
# republish-loop-test.pl — 0.11.49「补发去自激」回归（2026-09-22 三次崩溃的现场复刻）
# 用法：perl plugin/t/republish-loop-test.pl
#
# 背景（HANDOFF §5.11.118）：整榜入队 300 首后，日志里 `republish ... for 300 queued rows`
# 每 2~3 秒一条、连着十几条，然后 LMS 进程死。旁证：那十几秒里**队列成员一个都没变**。
# 机制：补发写 setRemoteMetadata ⇒ LMS 发 playlist 通知 ⇒ 订阅者又排一次补发 ⇒ 又写 300 行。
#
# 本测试在**不启动 LMS**的前提下验证 0.11.49 的四道闸：
#   A 内容指纹：首轮写满，之后的"通知风暴"一个字节都不再写；
#   B 通知过滤：newmetadata/newsong/open 这类通知**根本不排补发**，只有改队列成员的才排；
#   C 端到端：模拟"每次写入都回声一条通知"的回路 10 轮，写入总数必须为 0；
#   D 自激探测器：强行制造"队列不动却一直在写"，必须在若干轮内进入 60s 隔离。
use strict;
use warnings;

use FindBin;
use File::Spec;

use lib File::Spec->catdir($FindBin::Bin);              # t/ 下的 LMS 存根
use lib File::Spec->catdir($FindBin::Bin, '..');         # 真包（zip 平铺时也在插件的上一级）

BEGIN {
	# ProtocolHandler / Plugin 取**真身**，其余（Helper、LMS 各模块）走 t/ 存根
	my $root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
	unshift @INC, sub {
		my ($self, $file) = @_;
		return unless $file =~ m{^Plugins/LxMusic/(ProtocolHandler|Plugin)\.pm$};
		my $p = File::Spec->catfile($root, 'LxMusic', $1 . '.pm');
		return unless -f $p;
		open my $fh, '<', $p or return;
		return $fh;
	};
	require Plugins::LxMusic::ProtocolHandler;
}

my $PH = 'Plugins::LxMusic::ProtocolHandler';

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

# 假 Request：真代码只用 getRequestString
package FakeReq;
sub new { my ($c, $s) = @_; return bless { s => $s }, $c }
sub getRequestString { return $_[0]->{s} }

package main;

# ---------- 场景：一个播放器 + 300 行 lxm:// 队列 ----------
my @urls = map { "lxm://m/row$_" } 1 .. 300;
@Slim::Player::Playlist::PLAYLIST = @urls;
@Slim::Player::Client::CLIENTS    = (bless {}, 'FakeClient');
for my $u (@urls) {
	$PH->cache_metadata($u, { title => "T-$u", cover => "C-$u", secs => 200, kbps => 320, quality => 'flac' });
}

# ---------- A 内容指纹 ----------
my $n1 = $PH->republish_known_queued();
check('A1 首轮写满 300 行', $n1 == 300 && $Slim::Music::Info::CALLS == 300,
	"n=$n1 calls=$Slim::Music::Info::CALLS");

Slim::Music::Info::resetForTest();
for (1 .. 4) { select undef, undef, undef, 1.05; $PH->republish_known_queued(); }
my $writes = $Slim::Music::Info::CALLS;
check('A2 之后 4 轮"通知风暴"零写入（指纹止血）', $writes == 0, "wrote $writes");

# ---------- B 通知过滤 ----------
my $sub = Slim::Control::Request::lastSubscribe();
check('B0 订阅者已注册', $sub && ref($sub->{cb}) eq 'CODE');
my $cb = $sub->{cb};

Slim::Utils::Timers::resetForTest();
$cb->(FakeReq->new('playlist newmetadata'));
check('B1 playlist newmetadata 不排补发（自激回路的原料）',
	scalar(Slim::Utils::Timers::listPending()) == 0);
$cb->(FakeReq->new('playlist newsong Tank - 千年泪 3'));
check('B2 playlist newsong 不排补发', scalar(Slim::Utils::Timers::listPending()) == 0);
$cb->(FakeReq->new('playlist open http://mcp.example/x.php'));
check('B3 playlist open 不排补发', scalar(Slim::Utils::Timers::listPending()) == 0);
$cb->(FakeReq->new('playlist pause 1'));
check('B4 playlist pause 不排补发', scalar(Slim::Utils::Timers::listPending()) == 0);
$cb->(FakeReq->new('playlist loadtracks add lxm://l/tx/62'));
check('B5 playlist loadtracks 排一次尾部补发（改队列成员）',
	scalar(Slim::Utils::Timers::listPending()) == 1,
	'pending=' . scalar(Slim::Utils::Timers::listPending()));

# ---------- C 端到端：写入回声成通知，10 轮回路必须零写入 ----------
Slim::Utils::Timers::resetForTest();
my $echo_writes = 0;
for my $round (1 .. 10) {
	# 自激回声：每次补发都换来一条 playlist 通知（真机上就是它把 CPU 点着的）
	$cb->(FakeReq->new('playlist newmetadata'));
	Slim::Music::Info::resetForTest();
	# 执行所有被排上的定时器（尾部去抖到点）
	my @pend = Slim::Utils::Timers::listPending();
	$_->{cb}->(@{ $_->{args} }) for @pend;
	$echo_writes += $Slim::Music::Info::CALLS;
	select undef, undef, undef, 1.05;
}
check('C1 10 轮回声回路累计写入 0 行', $echo_writes == 0, "wrote $echo_writes");

# ---------- D 自激探测器 ----------
Slim::Music::Info::resetForTest();
for my $round (1 .. 6) {
	# 强行让指纹失效：每轮改一行内容 ⇒ 队列没变却每轮都在写（这就是自激的特征）
	$PH->cache_metadata($urls[0], { title => "T-round$round", cover => 'C-0', secs => 200, kbps => 320, quality => 'flac' });
	select undef, undef, undef, 1.05;
	$PH->republish_known_queued();
}
my $st = $PH->republish_stats();
check('D1 连续"写了却队列没变" ⇒ 进入 60s 隔离', $st->{quarantine} > time(),
	'quarantine=' . $st->{quarantine} . ' now=' . time());

Slim::Music::Info::resetForTest();
$PH->cache_metadata($urls[1], { title => 'T-forced-after-quarantine', cover => 'C-1', secs => 200, kbps => 320, quality => 'flac' });
select undef, undef, undef, 1.05;
$PH->republish_known_queued();
check('D2 隔离期内即使内容变了也不写', $Slim::Music::Info::CALLS == 0,
	'wrote ' . $Slim::Music::Info::CALLS);

print $failed ? "\nFAILED ($failed)\n" : "\nALL OK\n";
exit($failed ? 1 : 0);
