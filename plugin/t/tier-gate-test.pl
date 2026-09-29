#!/usr/bin/perl
# tier-gate-test.pl — 「交付档位闸」回归（0.11.98，方案 a）
# 用法：perl plugin/t/tier-gate-test.pl
#
# 背景（用户 2026-09-29 现场）：「请求 flac24bit，播出来却是 mp3 128kbps」。
# 根因：候选按**档位为外层**排（flac24bit → flac → 320k → 128k），但旧代码把
#   "拿到一个可播 URL" 当成 "这一档满足了"（$finish 里唯一质量闸是 `$kbps < 64`），
#   于是任一源在 flac24bit 档回了"可播的 128k mp3"，就在第 1 档 $done=1 交付
#   ⇒ **阶梯永远走不到 flac 那一层**（而那一层本来有源能给真无损）。
#
# 修法：用真实交付物反推档位（ProtocolHandler::_actualTier），低于「请求档位在阶梯上的
#   次一档」就拒绝该次交付、放行给下一个候选。
#
# 本套件钉死：
#   · flac24bit 请求拿到 128k mp3 ⇒ **拒绝**，并继续走到 flac 档交付真无损；
#   · flac24bit 请求拿到 flac(16bit) ⇒ **接受**（阶梯本来就允许降一档）；
#   · 320k 请求拿到 128k mp3 ⇒ **接受**（次一档就是 128k，不该更严）；
#   · flac 请求拿到 320k ⇒ **接受**（在阶梯内降一档）；
#   · 请求档已是阶梯末档（128k）⇒ 不设地板，任何可播都接受；
#   · 非梯档交付（如 ogg/wav）⇒ 不参与比较，一律放行（不误伤）；
#   · 拒绝**不会**卡住并行窗口（被拒候选必须结算并补位）。
use strict;
use warnings;

use FindBin;
use File::Spec;
use File::Temp ();

use lib File::Spec->catdir($FindBin::Bin);

BEGIN {
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
	require Plugins::LxMusic::ProtocolHandler;
}

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

# ---------- 桩：request / probeUrl / Sources ----------
my (@launched, %cb, %path, @got);
my %deliver_of;      # 源 id => 该源这次"交付"的 URL（由 probeUrl 按后缀推档位）

{
	no warnings 'redefine';
	no strict 'refs';
	*Plugins::LxMusic::Helper::request = sub {
		my ($class, %a) = @_;
		my ($id) = grep { $path{$_} eq $a{source} } keys %path;
		push @launched, { id => $id, info => $a{info} };
		$cb{$id} = $a{cb};
		return 1;
	};
	# probeUrl 按 URL 里的档位标记给出"真实交付"的魔数/长度/位深，用来驱动 _actualTier。
	# ⚠️ URL **必须带真实音频后缀**（.mp3/.flac/.ogg）：shim 的 `preferStreamable` 会把
	#    "无后缀的脚本中转链"当成不友好候选**先挂起**（不当场校验）⇒ $finish 根本不会被调用。
	#    第一版把后缀当档位标记用（`A.mp3-128`），于是全被挂起、测试假失败。
	#    现在档位放在**路径段**里（`/mp3-128/A.mp3`），后缀仍是真后缀。
	*Plugins::LxMusic::Helper::probeUrl = sub {
		my ($class, $url, $pcb) = @_;
		my $secs = 267;
		my %m = (
			'mp3-128' => { magic => 'mp3',  len => int(128 * 1000 / 8 * $secs) },
			'mp3-320' => { magic => 'mp3',  len => int(320 * 1000 / 8 * $secs) },
			'flac-16' => { magic => 'flac', len => int(1000 * 1000 / 8 * $secs), bits => 16 },
			'flac-24' => { magic => 'flac', len => int(1800 * 1000 / 8 * $secs), bits => 24 },
			'ogg'     => { magic => 'ogg',  len => int(171 * 1000 / 8 * $secs) },
		);
		my ($key) = grep { $url =~ m{/\Q$_\E/} } keys %m;
		my $d = $m{$key} || { magic => 'mp3', len => 0 };
		$pcb->({ ok => 1, status => 206, magic => $d->{magic}, length => $d->{len},
			bits => ($d->{bits} || 0), samplerate => 44100, channels => 2 });
	};
	*Plugins::LxMusic::Sources::enabled = sub {
		return [ { id => 'A', name => 'srcA' }, { id => 'B', name => 'srcB' } ];
	};
	*Plugins::LxMusic::Sources::pathFor = sub { my ($class, $id) = @_; return $path{$id} };
}

# ⚠️ 候选的 `pathFor` 必须是**真实存在的文件**，否则派发器会把候选当 "file missing"
# 丢掉、根本不 launch（第一版用了 '/tmp/srcA.js'，在 Windows 上不存在 ⇒ 全部候选被丢，
# 测试假失败）。这里建真文件。
my $tmpdir = File::Temp->newdir();
my $srcA = File::Spec->catfile("$tmpdir", 'srcA.js');
my $srcB = File::Spec->catfile("$tmpdir", 'srcB.js');
for my $f ($srcA, $srcB) {
	open my $fh, '>', $f or die "cannot write $f: $!";
	print $fh "// stub\n";
	close $fh;
}

%path = (A => $srcA, B => $srcB);
my $track = { songmid => '76381', name => '老人与海', singer => '海鸣威、吴琼',
	interval => '04:27', source => 'mg',
	types => [ { type => '128k' }, { type => '320k' }, { type => 'flac' }, { type => 'flac24bit' } ] };

# 跑一次 resolve；$deliver 指定各源"交付"什么。
# ⚠️ 必须**迭代**驱动：候选可能在"上一个被拒"之后才被派发出来（阶梯往下走）。
#    只 fire 一轮会漏掉后来启动的候选 ⇒ 假失败（第一版就这么错的）。
sub run {
	my (%opt) = @_;
	@launched = (); %cb = (); @got = ();
	Plugins::LxMusic::Helper::_breaker_reset();
	Plugins::LxMusic::Helper::_score_reset();
	Slim::Utils::Timers::resetForTest();
	Plugins::LxMusic::Helper->resolveTrack(
		music => $track, src => 'mg', type => $opt{want},
		cb    => sub { push @got, $_[0] },
	);
	return unless $opt{deliver};
	# 反复扫描：新出现的候选就交付（按 $opt{deliver} 指定的后缀），直到没有新回调
	my %fired;
	for my $round (1 .. 12) {
		last if @got;                       # 已交付（成功）就停
		my @todo = grep { !$fired{$_} } keys %cb;
		last unless @todo;
		for my $id (@todo) {
			$fired{$id} = 1;
			my $u = $opt{deliver}{$id} or next;
			# 档位标记放进路径段，后缀保持**真音频后缀**（见 probeUrl 的说明）
			my $ext = $u =~ /ogg/ ? 'ogg' : ($u =~ /flac/ ? 'flac' : 'mp3');
			$cb{$id}->({ ok => 1, data => "http://cdn.example/$u/$id.$ext", why => 'worker' });
		}
	}
}

# ---------- 1. flac24bit 请求拿到 128k mp3 ⇒ 必须被拒，并继续派发 ----------
{
	%path = (A => $srcA);                    # 只留一个源：A 唯一能交付的就是 128k mp3
	run(want => 'flac24bit', deliver => { A => 'mp3-128' });
	check('1a flac24bit + 128k mp3: 该次交付被拒（未交付）', @got == 0,
		'got=' . scalar(@got));
	# 被拒后必须继续派发（窗口没被卡死）：应看到 flac 档的候选被启动
	my @tiers = map { $_->{info}{type} } @launched;
	check('1b 拒绝后继续派发到下一档（flac）', (grep { $_ eq 'flac' } @tiers),
		'tiers=' . join(',', @tiers));
	%path = (A => $srcA, B => $srcB);
}

# ---------- 1c. 同一场景让 B 在 flac 档交付真无损 ⇒ 应当交付 flac ----------
{
	run(want => 'flac24bit', deliver => { A => 'mp3-128', B => 'flac-16' });
	check('1c 交付的是 flac 而不是 128k mp3',
		@got == 1 && $got[0]{ok} && $got[0]{url} =~ m{/flac-16/},
		@got ? $got[0]{url} : 'none');
	check('1d 交付档位(flac) 高于被拒的 128k', @got && $got[0]{url} !~ m{/mp3-128/},
		@got ? $got[0]{url} : 'none');
}

# ---------- 2. flac24bit 请求拿到 flac(16bit) ⇒ 接受（阶梯允许降一档） ----------
{
	run(want => 'flac24bit', deliver => { A => 'flac-16' });
	check('2a flac24bit + flac16bit: 接受', @got == 1 && $got[0]{ok},
		'got=' . scalar(@got));
	check('2b 交付就是那个 flac', @got && $got[0]{url} =~ m{/flac-16/},
		@got ? $got[0]{url} : 'none');
}

# ---------- 3. 320k 请求拿到 128k mp3 ⇒ 接受（次一档就是 128k） ----------
{
	run(want => '320k', deliver => { A => 'mp3-128' });
	check('3  320k + 128k mp3: 接受（不该更严）', @got == 1 && $got[0]{ok},
		'got=' . scalar(@got));
}

# ---------- 4. flac 请求拿到 320k ⇒ 接受（阶梯内降一档） ----------
{
	run(want => 'flac', deliver => { A => 'mp3-320' });
	check('4  flac + 320k: 接受', @got == 1 && $got[0]{ok}, 'got=' . scalar(@got));
}

# ---------- 5. 128k 请求（阶梯末档）⇒ 不设地板，任何可播都接受 ----------
{
	run(want => '128k', deliver => { A => 'mp3-128' });
	check('5a 128k 请求 + 128k 交付: 接受', @got == 1 && $got[0]{ok}, 'got=' . scalar(@got));
}

# ---------- 6. 非梯档交付（ogg）⇒ 不参与比较，放行 ----------
{
	%path = (A => $srcA);                    # 只留一个源，避免第二个候选干扰
	run(want => 'flac24bit', deliver => { A => 'ogg' });
	check('6  flac24bit + ogg: 非梯档放行（不误伤 OGG 源）', @got == 1 && $got[0]{ok},
		'got=' . scalar(@got));
	%path = (A => $srcA, B => $srcB);
}

# ---------- 7. tier_rank 基本正确性 ----------
{
	my $PH = 'Plugins::LxMusic::ProtocolHandler';
	# ⚠️ tier_rank 是**函数**（取 $_[0]），tierRank 是**方法**（取 $_[1]）——别混用
	check('7a 128k < 320k < flac < flac24bit',
		Plugins::LxMusic::ProtocolHandler::tier_rank('128k')
			< Plugins::LxMusic::ProtocolHandler::tier_rank('320k')
		&& Plugins::LxMusic::ProtocolHandler::tier_rank('320k')
			< Plugins::LxMusic::ProtocolHandler::tier_rank('flac')
		&& Plugins::LxMusic::ProtocolHandler::tier_rank('flac')
			< Plugins::LxMusic::ProtocolHandler::tier_rank('flac24bit'));
	check('7b 非梯档无排名',
		!defined Plugins::LxMusic::ProtocolHandler::tier_rank('OGG')
		&& !defined Plugins::LxMusic::ProtocolHandler::tier_rank('WAV'));
	check('7c 方法形式与函数形式一致',
		$PH->tierRank('flac')
			== Plugins::LxMusic::ProtocolHandler::tier_rank('flac'));
}

print $failed ? "\nFAILED ($failed)\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
