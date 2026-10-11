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
#   · 0.11.117 同档「质量优先窗口」：同档里"快而低档"的交付先压住，等同档更好的那份；
#     单源（无同档兄弟在飞）立即交付；`qualityHold=0` 回到"先到者交付"（见 18a~18d）。
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
my (@launched, %cb, %path, @got, %cb_info, %enabled_ids, %local_reject, %probe_reject, %timeout_reject,
	%inflight_src, $max_same, %hold_fire);
# ⚠️ 0.11.102：回调**按 (源|档位) 存**，不是按源 —— 并行窗口会把同一个源在不同档**同时**派发出去，
# 旧写法 `%cb{$id}` 会被后一次派发覆盖 ⇒ 只 fire 最后一次那个档的交付，
# "半开重试是否真的发生"就测不出来（判别性用例 10c 第一版就这么假失败）。
my %deliver_of;      # 源 id => 该源这次"交付"的 URL（由 probeUrl 按后缀推档位）

{
	no warnings 'redefine';
	no strict 'refs';
	*Plugins::LxMusic::Helper::request = sub {
		my ($class, %a) = @_;
		my ($id) = grep { $path{$_} eq $a{source} } keys %path;
		my $q = ($a{info} || {})->{type} // '?';
		# 0.11.103：模拟**本机准入闸**的立即拒绝（`_err('source busy (hostile queue full)')`
		# 的形态：ok=0 + why='local'），用来验证"本机原因不得计入熔断/评分"。
		if ($local_reject{"$id|$q"}) {
			return $a{cb}->({ ok => 0, data => undef, why => 'local', logs => [], alerts => [],
				error => 'source busy (hostile queue full)' });
		}
		# 0.11.106：模拟**超时**（源慢，不是坏）——验证"超时不封平台"
		if ($timeout_reject{"$id|$q"}) {
			return $a{cb}->({ ok => 0, data => undef, why => 'worker', logs => [], alerts => [],
				error => 'timeout: worker request exceeded 20s' });
		}
		push @launched, { id => $id, info => $a{info} };
		# 0.11.107：统计**同一源同时在飞**的最大数（必须 ≤1：我们自己的准入闸每源并发 1，
		# 并行派同一源的多个档只会被自己拒成 `local-fault: source busy`）。
		$inflight_src{$id}++;
		$max_same = $inflight_src{$id} if $inflight_src{$id} > $max_same;
		my $orig = $a{cb};
		$cb{"$id|$q"} = sub { $inflight_src{$id}--; $orig->(@_) };
		$cb_info{"$id|$q"} = $a{info};      # 0.11.102：判别"这次交付发生在哪一档"
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
		# 0.11.103：注入"坏链"（能拿到 URL、但探测判死）——用来验证验链失败不封平台。
		# URL 形如 `http://cdn.example/<交付标记>/<源id>.flac` ⇒ 按**源 id**（末段）判。
		my ($rid) = $url =~ m{/([^/]+)\.(?:mp3|flac|ogg)$};
		if ($rid && $probe_reject{$rid}) {
			return $pcb->({ ok => 0, error => 'HTTP 404' });
		}
		my %m = (
			'mp3-128' => { magic => 'mp3',  len => int(128 * 1000 / 8 * $secs) },
			'mp3-320' => { magic => 'mp3',  len => int(320 * 1000 / 8 * $secs) },
			'flac-16' => { magic => 'flac', len => int(1000 * 1000 / 8 * $secs), bits => 16 },
			'flac-24' => { magic => 'flac', len => int(1800 * 1000 / 8 * $secs), bits => 24 },
			# 0.11.100：真 Hi-Res 格（24bit + 96kHz）——`_actualTier` 只有两项都量到才给 hires
			'flac-24-96' => { magic => 'flac', len => int(2900 * 1000 / 8 * $secs), bits => 24, sr => 96000 },
			'ogg'     => { magic => 'ogg',  len => int(171 * 1000 / 8 * $secs) },
		);
		my ($key) = grep { $url =~ m{/\Q$_\E/} } keys %m;
		my $d = $m{$key} || { magic => 'mp3', len => 0 };
		$pcb->({ ok => 1, status => 206, magic => $d->{magic}, length => $d->{len},
			bits => ($d->{bits} || 0), samplerate => ($d->{sr} || 44100), channels => 2 });
	};
	*Plugins::LxMusic::Sources::enabled = sub {
		# ⚠️ 0.11.102：`%path` 只影响 `pathFor`，**不影响"哪些源是启用的"**。旧桩恒返回 A+B，
		# 于是 `%path=(A=>…)` 那种"只留一个源"的写法里 B 仍会作为候选（到派发时才因 file missing 被丢），
		# 结果"某档是否**整档**被熔断"就永远算不出来（10c 第一版据此假失败）。
		my @ids = @{ $enabled_ids{list} || [ 'A', 'B' ] };
		return [ map { { id => $_, name => 'src' . $_ } } @ids ];
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
	# 0.11.102：预先人为熔断若干"源|平台|档位"三元组（每键连记 2 次失败即上闸），
	# 用来验证"整档只因熔断而空 ⇒ 半开重试一次"这条防锁死逻辑。
	for my $k (@{ $opt{pretrip} || [] }) {
		Plugins::LxMusic::Helper::_src_failed($k, $k);
		Plugins::LxMusic::Helper::_src_failed($k, $k);
	}
	# 0.11.111：把刚压上的熔断"老化"若干秒 ⇒ 用来验证"冷却后半开"（否则要真等 90s）
	for my $k (@{ $opt{pretrip} || [] }) {
		Plugins::LxMusic::Helper::_breaker_age($k, $opt{pretrip_age}) if $opt{pretrip_age};
	}
	# 0.11.103：本机准入拒绝注入（`"源|档位" => 1`）
	%local_reject = %{ $opt{local_reject} || {} };
	%timeout_reject = %{ $opt{timeout_reject} || {} };   # 0.11.106：超时注入
	%inflight_src = ();                                  # 0.11.107：同源并发统计
	$max_same = 0;
	%hold_fire = %{ $opt{hold_fire} || {} };             # 0.11.108：压住某些候选不 fire
	Plugins::LxMusic::Helper->resolveTrack(
		music => $track, src => 'mg', type => $opt{want},
		# 0.11.110：抢跑窗口默认关闭（0）；要测它得显式传 `quality_head_start`
		(defined $opt{quality_head_start} ? (qualityHeadStart => $opt{quality_head_start}) : ()),
		# 0.11.117：同档质量优先窗口（生产默认读 pref；测试桩里显式传才可复现）
		(defined $opt{quality_hold} ? (qualityHold => $opt{quality_hold}) : ()),
		cb    => sub { push @got, $_[0] },
	);
	return unless $opt{deliver};
	# 反复扫描：新出现的候选就交付（按 $opt{deliver} 指定的后缀），直到没有新回调。
	# ⚠️ 0.11.102：**必须按派发顺序 fire**，不能用 `keys %cb`（哈希顺序不定）。
	#   并行窗口会把同一个源在多个档同时派出去，谁先 fire 谁就决定交付档位 ⇒
	#   哈希顺序会让"半开重试到底交付在哪一档"变成随机结果（10c 实测时好时坏）。
	my %fired;
	for my $round (1 .. 12) {
		last if @got;                       # 已交付（成功）就停
		my @todo;
		for my $e (@launched) {
			my $k = ($e->{id} // '?') . '|' . (($e->{info} || {})->{type} // '?');
			next if $fired{$k};
			push @todo, [ $k, $e ];
		}
		# 0.11.108：`hold_fire` 让某些候选**先不 fire**（模拟"慢源还在飞"）——
		# 用来验证"更高档在飞时，低档交付被压住"；只剩被压住的候选时才放开。
		my @later = grep { $hold_fire{ $_->[0] } } @todo;
		my @now   = grep { !$hold_fire{ $_->[0] } } @todo;
		@now = @later if !@now;
		last unless @now;
		for my $t (@now) {
			my ($k, $e) = @$t;
			$fired{$k} = 1;
			my ($sid, $tier) = split /\|/, $k, 2;
			# 0.11.102：`deliver_tier{档位}{源}` 优先 —— 用来做"同一源在不同档交付不同东西"的判别性用例
			# （否则 `deliver{A}` 一个值在任何档都命中，掩盖"半开重试到底有没有发生"）。
			my $u = ($opt{deliver_tier} && $opt{deliver_tier}{ $tier // '' }
					&& $opt{deliver_tier}{ $tier // '' }{$sid})
				|| ($opt{deliver} ? $opt{deliver}{$sid} : undef) or next;
			# 档位标记放进路径段，后缀保持**真音频后缀**（见 probeUrl 的说明）
			my $ext = $u =~ /ogg/ ? 'ogg' : ($u =~ /flac/ ? 'flac' : 'mp3');
			$cb{$k}->({ ok => 1, data => "http://cdn.example/$u/$sid.$ext", why => 'worker' });
		}
	}
}

# ---------- 1. flac24bit 请求拿到 128k mp3 ⇒ 高档必须被拒，只在允许的地板档放行 ----------
{
	%path = (A => $srcA);                    # 只留一个源：A 唯一能交付的就是 128k mp3
	run(want => 'flac24bit', deliver => { A => 'mp3-128' });
	# ⚠️ 0.11.102：本用例的口径改了。旧写法断言"完全未交付"，那是**测试桩**的产物
	#   （旧桩按"源"只 fire 一次 ⇒ 被拒后同源的低档候选再也不会交付）。
	#   真实语义（也是设计意图）：高档拒掉这个 128k，**阶梯继续往下**，
	#   到 320k 档时地板是 128k ⇒ 允许放行。所以正确的断言是：
	#   ① 记下了 `tier-too-low`（证明高档真的拒了）；② 交付发生在地板允许的 320k 档。
	my @low = grep { ($_->{why} // '') eq 'tier-too-low' } @{ ($got[0] || {})->{tries} || [] };
	check('1a flac24bit 请求：128k mp3 在高档被拒（tries 记 tier-too-low）',
		@low >= 1, 'tier-too-low=' . scalar(@low));
	check('1b 只在 320k 档放行（交付档位 = 320k，不是 flac24bit/flac）',
		@got == 1 && $got[0]{ok} && (($got[0]{quality} // '') eq '320k'),
		@got ? ($got[0]{quality} // '?') : 'none');
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
# ⚠️ 0.11.117：本用例口径是"**单源**交付降一档 ⇒ 接受"，必须真的只留一个源：
#   桩里由 `%path` 决定"哪些源有文件"（`Sources::enabled` 恒返回 A+B），上一块结尾
#   把 `%path` 恢复成了 (A,B) ⇒ 若不收回，B 就成了**同档在飞**的第二候选，
#   新的"同档质量优先窗口"会（正确地）压住 A 的降档交付 ⇒ 本用例假失败（实测踩到）。
{
	%path = (A => $srcA);
	run(want => 'flac24bit', deliver => { A => 'flac-16' });
	check('2a flac24bit + flac16bit: 接受', @got == 1 && $got[0]{ok},
		'got=' . scalar(@got));
	check('2b 交付就是那个 flac', @got && $got[0]{url} =~ m{/flac-16/},
		@got ? $got[0]{url} : 'none');
	%path = (A => $srcA, B => $srcB);
}

# ---------- 3. 320k 请求拿到 128k mp3 ⇒ 接受（次一档就是 128k） ----------
{
	%path = (A => $srcA);
	run(want => '320k', deliver => { A => 'mp3-128' });
	check('3  320k + 128k mp3: 接受（不该更严）', @got == 1 && $got[0]{ok},
		'got=' . scalar(@got));
	%path = (A => $srcA, B => $srcB);
}

# ---------- 4. flac 请求拿到 320k ⇒ 接受（阶梯内降一档） ----------
{
	%path = (A => $srcA);
	run(want => 'flac', deliver => { A => 'mp3-320' });
	check('4  flac + 320k: 接受', @got == 1 && $got[0]{ok}, 'got=' . scalar(@got));
	%path = (A => $srcA, B => $srcB);
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

# ---------- 8. 阶梯构造（0.11.99：按排名生成；修 `hires` 陷阱） ----------
# 起因：`@QUALITY_LADDER` 里曾没有 `hires` ⇒ 请求 hires 时阶梯塌成 `('hires','128k')`，
# **跳过 flac24bit/flac/320k**。以下断言把"默认档位逐项不回归"钉死。
{
	my $HL = 'Plugins::LxMusic::Helper';
	my $lad = sub {
		my ($want, $track, $decl) = @_;
		return join(',', $HL->qualityLadder($want, $track || {}, $decl));
	};

	check('8a 默认档位 flac24bit 的阶梯与 0.11.98 逐项相同',
		$lad->('flac24bit') eq 'flac24bit,flac,320k,128k', $lad->('flac24bit'));
	check('8a 320k 的阶梯逐项相同',
		$lad->('320k') eq '320k,128k', $lad->('320k'));
	check('8a 128k 的阶梯逐项相同', $lad->('128k') eq '128k', $lad->('128k'));

	# 8b **本次修复的核心**：请求 hires 必须能一路降到 flac24bit/flac/320k/128k
	{
		my @l = $HL->qualityLadder('hires', {}, undef);
		check('8b hires 阶梯含 flac24bit/flac/320k/128k（修前只有 hires,128k）',
			join(',', @l) eq 'hires,flac24bit,flac,320k,128k', join(',', @l));
		my %in = map { $_ => 1 } @l;
		check('8b hires 阶梯确实包含 flac/flac24bit/320k',
			$in{flac24bit} && $in{flac} && $in{'320k'} && $in{'128k'});
	}

	# 8c 表里没有、但是梯档（192k/256k）：先试它本身，再接排名更低者（与旧行为一致）
	check('8c 192k 阶梯 = 192k,128k', $lad->('192k') eq '192k,128k', $lad->('192k'));
	# 8d 非梯档（ape/wav/未知）保持旧行为
	check('8d ape（非梯档）阶梯 = ape,128k', $lad->('ape') eq 'ape,128k', $lad->('ape'));

	# 8e 曲目声明过滤：只声明 flac 的曲目请求 flac24bit ⇒ 只试 flac
	check('8e 曲目只声明 flac ⇒ 阶梯收敛为 flac',
		$lad->('flac24bit', { types => [ { type => 'flac' } ] }) eq 'flac',
		$lad->('flac24bit', { types => [ { type => 'flac' } ] }));

	# 8f **旧的塌陷行为必须消失**：过滤后一个不剩时，回落成未过滤阶梯，而不是 ('128k')
	{
		my @l = $HL->qualityLadder('flac24bit',
			{ types => [ { type => 'nonsense' } ] }, [ 'flac24bit' ]);
		check('8f 过滤后为空不再塌成 128k（回落成完整阶梯）',
			join(',', @l) eq 'flac24bit,flac,320k,128k', join(',', @l));
	}

	# 8g qualityFallback 关掉 ⇒ 只试请求档本身
	{
		# ⚠️ Helper 在编译期就 `my $prefs = preferences('plugin.lxmusic')`（名字带后缀），
		#    测试必须用**同一个名字**取实例，否则设的值被测代码看不到（本用例第一版就栽在这）。
		my $p = Slim::Utils::Prefs::preferences('plugin.lxmusic');
		my $old = $p->get('qualityFallback');
		$p->set('qualityFallback', 0);
		my @l = $HL->qualityLadder('flac24bit', {}, undef);
		check('8g 关掉 qualityFallback ⇒ 只试请求档', join(',', @l) eq 'flac24bit', join(',', @l));
		# 复原（同一份 stub 会被后面的用例读到）
		if (defined $old) { $p->set('qualityFallback', $old) } else { delete $p->{vals}{qualityFallback} }
		my @l2 = $HL->qualityLadder('flac24bit', {}, undef);
		check('8g 复原后阶梯回到完整形态', join(',', @l2) eq 'flac24bit,flac,320k,128k', join(',', @l2));
	}

	# 8h 档位闸地板：hires 的"次一档"必须是 flac24bit（而不是 128k）
	{
		my @l = $HL->qualityLadder('hires', {}, undef);
		check('8h hires 的地板（阶梯次一档）= flac24bit', ($l[1] // '') eq 'flac24bit', $l[1] // 'undef');
	}
}

# ---------- 9. 0.11.100：请求 hires（真 Hi-Res 档）时的阶梯与闸门 ----------
{
	%path = (A => $srcA);

	# 9a 请求 hires、交付 24bit/44.1k ⇒ **接受**（地板 = 阶梯次一档 = flac24bit）
	run(want => 'hires', deliver => { A => 'flac-24' });
	check('9a hires 请求 + 24bit/44.1k ⇒ 接受（地板 flac24bit）', @got == 1 && $got[0]{ok},
		'got=' . scalar(@got));

	# 9b 请求 hires、交付 128k mp3 ⇒ 高档全部拒掉，只在 320k 档（地板 128k）放行
	run(want => 'hires', deliver => { A => 'mp3-128' });
	my @low9 = grep { ($_->{why} // '') eq 'tier-too-low' } @{ ($got[0] || {})->{tries} || [] };
	check('9b hires 请求 + 128k mp3 ⇒ 高档被拒（tier-too-low）', @low9 >= 1,
		'tier-too-low=' . scalar(@low9));
	check('9b2 只在 320k 档放行', @got == 1 && (($got[0]{quality} // '') eq '320k'),
		@got ? ($got[0]{quality} // '?') : 'none');
	my @tiers9 = map { $_->{info}{type} } @launched;
	check('9c 被拒后继续派发（见过 flac24bit 与 flac 两档）',
		(grep { $_ eq 'flac24bit' } @tiers9) && (grep { $_ eq 'flac' } @tiers9),
		'tiers=' . join(',', @tiers9));

	# 9d 请求 hires、交付 96k/24bit ⇒ 接受，且反推档位就是 hires
	run(want => 'hires', deliver => { A => 'flac-24-96' });
	check('9d hires 请求 + 96k/24bit ⇒ 接受', @got == 1 && $got[0]{ok}, 'got=' . scalar(@got));
	my $t9 = Plugins::LxMusic::ProtocolHandler->_actualTier('flc', 2900, 24, $track->{types}, 96000);
	check('9e 该交付反推出的档位 = hires', ($t9 // 'undef') eq 'hires', $t9 // 'undef');

	# 9f 阶梯：曲目声明了 flac24bit ⇒ 请求 hires 时**第一档就是 hires**（不被曲目 types 裁掉）
	my @lad = Plugins::LxMusic::Helper->qualityLadder('hires', $track, undef);
	check('9f 曲目有 flac24bit ⇒ hires 允许参与且排第一',
		($lad[0] // '') eq 'hires' && ($lad[1] // '') eq 'flac24bit', join(',', @lad));

	# 9g 反向（决策 D2）：曲目**只声明 flac**（没有 flac24bit/也没 hires）⇒ 不硬凑 hires
	my @lad2 = Plugins::LxMusic::Helper->qualityLadder('hires',
		{ types => [ { type => '128k' }, { type => '320k' }, { type => 'flac' } ] }, undef);
	check('9g 曲目只声明 flac ⇒ 阶梯不含 hires', !(grep { $_ eq 'hires' } @lad2), join(',', @lad2));

	%path = (A => $srcA, B => $srcB);
}

# ---------- 10. 0.11.102：降档不得变成"平台级锁死"（用户 2026-10-03 现场） ----------
# 现场：mg 榜单>热歌榜，第一首走完整阶梯（8s，tries 里有 flac24bit/flac），**之后每首只剩
# `@320k` 一档**（1s 就返回 128k）。根因 = 交付档位闸把"交付过低"记进熔断，而熔断键是
# `源|平台|档位`、TTL 600s、跨曲目共享 ⇒ 一首歌降档 → 10 分钟内全平台所有曲目的高档消失。
{
	%path = (A => $srcA);
	$enabled_ids{list} = ['A'];      # 只留 A：这样"某档只剩被熔断的源"才是**整档**（见桩注释）
	run(want => 'flac24bit', deliver => { A => 'mp3-128' });
	my $bs = Plugins::LxMusic::Helper::_breaker_state();
	check('10a 交付档过低不触发熔断（bad 为空）', !(scalar keys %{ $bs->{bad} }),
		'bad=' . join(',', keys %{ $bs->{bad} }));
	check('10b 交付档过低不计入失败计数（fail 为空）', !(scalar keys %{ $bs->{fail} }),
		'fail=' . join(',', keys %{ $bs->{fail} }));

	# 10c 就算某档**整档被熔断**，本轮也要半开重试一次（防"一次降档→永远降档"）。
	#     判别点 = **交付发生在哪一档**：半开重试成功 ⇒ 交付档位是 `flac24bit`；
	#     若没半开（旧行为），A 只会在 flac 档被派发 ⇒ 交付档位是 `flac`。
	#     （第一版按 URL 判断，不具判别力：同一个交付串在 flac 档也会命中 `/flac-24/`。）
	run(want => 'flac24bit', deliver => { A => 'flac-24' }, pretrip => ['A|mg|flac24bit']);
	check('10c 整档被熔断时仍半开重试该档（交付档位 = flac24bit）',
		@got == 1 && $got[0]{ok} && (($got[0]{quality} // '') eq 'flac24bit'),
		@got ? ($got[0]{quality} // '?') : 'none');
	my @tiers10 = map { $_->{info}{type} } @launched;
	check('10d 半开重试确实派发了 flac24bit 档',
		(scalar(grep { $_ eq 'flac24bit' } @tiers10)) ? 1 : 0,
		'tiers=' . join(',', @tiers10));
	%path = (A => $srcA, B => $srcB);
	delete $enabled_ids{list};       # 恢复"两个源都在"的默认桩状态
}

# ---------- 11. 0.11.103：**本机原因**（准入拒绝/引擎缺口）不得被当成"源的失败" ----------
# 现场：慢源被 `%WORKER_BAD` 转 fork + 每源并发 1，而并行窗口把同一个源在多个档同时派出去，
# 第 3 个请求必然被"队列满"拒绝 —— 那是**我们自己的闸**，旧代码却记成 `_src_failed`
# ⇒ 连续 2 次就把"只是慢、但可能给无损"的源熔断 600s（玉宁熙从 mg 的 tries 里整段消失，
# 而同一首它在宿主侧独立实测能给 1000.5kbps FLAC）。
{
	%path = (A => $srcA, B => $srcB);
	$enabled_ids{list} = [ 'A', 'B' ];
	run(want => 'flac', deliver => { B => 'flac-16' }, local_reject => { 'A|flac' => 1 });
	my $bs11 = Plugins::LxMusic::Helper::_breaker_state();
	check('11a 本机准入拒绝不触发熔断（bad 为空）', !(scalar keys %{ $bs11->{bad} }),
		'bad=' . join(',', keys %{ $bs11->{bad} }));
	check('11b 本机准入拒绝不计入失败计数（fail 为空）', !(scalar keys %{ $bs11->{fail} }),
		'fail=' . join(',', keys %{ $bs11->{fail} }));
	check('11c 本机拒绝不阻塞阶梯（由 B 交付）',
		@got == 1 && $got[0]{ok} && (($got[0]{quality} // '') eq 'flac'),
		@got ? ($got[0]{quality} // '?') : 'none');
	check('11d tries 里记成 local-fault（可诊断，不伪装成源错）',
		(scalar(grep { ($_->{why} // '') =~ /^local-fault:/ } @{ ($got[0] || {})->{tries} || [] })) ? 1 : 0,
		join(' | ', map { $_->{why} // '?' } @{ ($got[0] || {})->{tries} || [] }));
	%local_reject = ();
	delete $enabled_ids{list};
}

# ---------- 12. 0.11.103：验链失败（坏链）同样不得平台级封禁 ----------
# 现场：玉宁熙给 mg 生成的链**偶发 404**（同一首同一档几分钟后再试就成功），旧代码两次 404
# 就把它在 mg 上封 600s ⇒ 用户看到"整平台全是 128k"。坏链是**按曲目**的事实，
# 而熔断键 `源|平台|档位` 没有曲目维度 ⇒ 不该用它来封平台。
{
	%path = (A => $srcA, B => $srcB);
	$enabled_ids{list} = [ 'A', 'B' ];
	# A 在**每一档**都回坏链（探测 404），B 正常交付 ⇒ 断言 A 不被封、且由 B 交付
	%probe_reject = ('A' => 1);
	run(want => 'flac', deliver => { A => 'flac-16', B => 'flac-16' });
	my $bs12 = Plugins::LxMusic::Helper::_breaker_state();
	check('12a 验链失败不触发熔断（bad 为空）', !(scalar keys %{ $bs12->{bad} }),
		'bad=' . join(',', keys %{ $bs12->{bad} }));
	check('12b 验链失败不计入失败计数（fail 为空）', !(scalar keys %{ $bs12->{fail} }),
		'fail=' . join(',', keys %{ $bs12->{fail} }));
	check('12c tries 里仍能看到 verify: 记录（可诊断）',
		(scalar(grep { ($_->{why} // '') =~ /^verify:/ } @{ ($got[0] || {})->{tries} || [] })) ? 1 : 0,
		join(' | ', map { $_->{why} // '?' } @{ ($got[0] || {})->{tries} || [] }));
	%probe_reject = ();
	delete $enabled_ids{list};
}

# ---------- 13. 0.11.105：tries 里必须带**实际 URL**（诊断盲区） ----------
# 起因：设备 vs 宿主"同一源同一首：宿主 FLAC / 设备 404"这条查不下去，因为工具页的 tries
# 只有"源@档位: why/ms"，没有 URL；只能靠日志（而日志切片又不可靠）。现在必须带 URL。
{
	%path = (A => $srcA, B => $srcB);
	$enabled_ids{list} = [ 'A', 'B' ];
	run(want => 'flac24bit', deliver => { A => 'flac-24' });
	my @urls = map { $_->{url} // '' } @{ ($got[0] || {})->{tries} || [] };
	check('13a 成功交付的 tries 条目带 url（工具页可显示实际拿到的链）',
		(scalar(grep { m{/flac-24/} } @urls)) ? 1 : 0, join(' | ', @urls));
	delete $enabled_ids{list};
}

# ---------- 14. 0.11.106：**超时是"慢"，不是"坏"**，不许封平台 ----------
# 现场（0.11.105 的新诊断照出来的第一件事）：`lx-玉宁熙-Pro@flac24bit: timeout: worker request
# exceeded 14s {resp: code=200 len=90770 …} 13656ms` —— 源已回 200+90KB，只是设备上跑它超过 14s。
# 旧规则两次超时就把它封 600s ⇒ 唯一能给 mg 无损的源消失 ⇒ "整平台全是 128k"。
# 判据：不熔断；仍记 `slow-timeout:`；阶梯继续（由别的源/档位交付）。
{
	%path = (A => $srcA, B => $srcB);
	$enabled_ids{list} = [ 'A', 'B' ];
	run(want => 'flac', deliver => { B => 'flac-16' }, timeout_reject => { 'A|flac' => 1 });
	my $bs14 = Plugins::LxMusic::Helper::_breaker_state();
	check('14a 超时不触发熔断（bad 为空）', !(scalar keys %{ $bs14->{bad} }),
		'bad=' . join(',', keys %{ $bs14->{bad} }));
	check('14b 超时不计入失败计数（fail 为空）', !(scalar keys %{ $bs14->{fail} }),
		'fail=' . join(',', keys %{ $bs14->{fail} }));
	check('14c 超时仍记 slow-timeout（可诊断、不伪装成源坏）',
		(scalar(grep { ($_->{why} // '') =~ /^slow-timeout:/ } @{ ($got[0] || {})->{tries} || [] })) ? 1 : 0,
		join(' | ', map { $_->{why} // '?' } @{ ($got[0] || {})->{tries} || [] }));
	check('14d 超时不阻塞阶梯（由 B 交付）',
		@got == 1 && $got[0]{ok} && (($got[0]{quality} // '') eq 'flac'),
		@got ? ($got[0]{quality} // '?') : 'none');
	%timeout_reject = ();
	delete $enabled_ids{list};
}

# ---------- 15. 0.11.107：同一个源不许同时派多个候选 ----------
# 起因（0.11.106 设备实测）：窗口把同一源在多个档同时派出，而慢源走"每源并发 1"的准入闸
# ⇒ 后到的档被**我们自己的闸**拒成 `local-fault: source busy`（现场：玉宁熙唯一能成功的
# `@flac` 被它自己的 `@flac24bit` 挤掉）。判据：任何时刻同一源在飞数 ≤ 1。
{
	%path = (A => $srcA);
	$enabled_ids{list} = [ 'A' ];        # 只有一个源 ⇒ 它在阶梯里必然有多个候选
	run(want => 'flac24bit', deliver => { A => 'flac-24' });
	check('15a 同源同时只派一个候选（不再自己把自己拒成 busy）', $max_same == 1,
		"max_same=$max_same launched=" . scalar(@launched));
	delete $enabled_ids{list};
}

# ---------- 16. 0.11.108/110：质量优先抢跑（**默认关闭**，可显式开） ----------
# 现场（用户 2026-10-03 "mg 仍旧是 128k mp3"）：慢源还在跑高档时，低档候选已交付 128k 并被接受，
# 慢源的高档结果到了也没人要。0.11.108/109 做过"压住低档 + 3s 抢跑窗口"。
# **0.11.110 起默认关闭**（`qualityHeadStart` 默认 0）：根因最后是**源**（mg 聚合源只给标清），
# 换上自建 `咪咕无损桥` 后它常年最快（设备实测 0.7~1.0s 直接给 FLAC）⇒ 不必等；
# 而"等"的代价实测很实在（4/12 首被拖到 24.5s 预算耗尽而 FAIL）。下面同时钉住两种行为。
{
	%path = (A => $srcA, B => $srcB);
	$enabled_ids{list} = [ 'A', 'B' ];
	my %common = (
		want         => 'flac24bit',
		deliver      => { A => 'mp3-128', B => 'mp3-128' },
		deliver_tier => { flac24bit => { A => 'flac-24' } },
		hold_fire    => { 'A|flac24bit' => 1 },   # A 的高档"慢"：先不 fire
	);
	# 16a/16b：**显式开** 3s 抢跑 ⇒ 低档被压住，最终交付高档
	run(%common, quality_head_start => 3);
	check('16a 开启抢跑时，更高档仍在飞 ⇒ 低档被压住（最终 = flac24bit）',
		@got == 1 && (($got[0]{quality} // '') eq 'flac24bit'),
		@got ? ($got[0]{quality} // '?') : 'none');
	check('16b 只交付一次（压住的那份没有被抢先交付）', @got == 1, scalar(@got));

	# 16c：**把 `qualityHeadStart` 关掉、同时也把 0.11.117/119 的质量窗口关掉**（`quality_hold => 0`）
	# ⇒ 回到"谁先给可播链接谁交付"。
	# ⚠️ 0.11.117 起"低档先到就交付"**不再是默认**（默认 `qualityHold=3` 会压住低档等更好的），
	#   所以本用例必须显式 `quality_hold => 0` 才能测"抢跑这一个开关"的语义（16d 测新默认）。
	run(%common, quality_hold => 0);
	check('16c 抢跑与质量窗口都关掉：低档先到就交付（= 320k），不等待',
		@got == 1 && (($got[0]{quality} // '') eq '320k'),
		@got ? ($got[0]{quality} // '?') : 'none');
	# 16d：0.11.117/119 的新默认 —— 即使抢跑关着，质量窗口也会压住低档
	run(%common, quality_hold => 3);
	check('16d 质量窗口默认开：低档先到也被压住（最终 = flac24bit）',
		@got == 1 && (($got[0]{quality} // '') eq 'flac24bit'),
		@got ? ($got[0]{quality} // '?') : 'none');
	%hold_fire = ();
	delete $enabled_ids{list};
}

# ---------- 17. 0.11.111：熔断的**半开冷却**（防"偶发两次错误 → 整档消失 10 分钟"） ----------
# 现场：本 session 修了五处"按曲目失败被当成平台级失败"的分类（too-low/verify/local/timeout/同源并发），
# 但只要源的报错文案落在分类之外就会复现 —— 0.11.110 实测自建"咪咕无损桥"两次按曲目失败后被封，
# 第 5 首起整段消失。结构性修法：上闸后冷却 90s 就**放一次**（半开），失败刷新时间戳，成功清零。
{
	%path = (A => $srcA, B => $srcB);
	$enabled_ids{list} = [ 'A', 'B' ];
	# ⚠️ 测试桩每次 run() 会先 `_breaker_reset()` ⇒ 手动 `_src_failed` 必须走 `pretrip` 通道
	run(want => 'flac', deliver => { B => 'flac-16' }, pretrip => ['A|mg|flac']);
	# ⚠️ 只看 **flac 档**：A 在 320k/128k 档没被闸，仍应正常参与（这是对的，别误判）
	check('17a 刚上闸时该源在**该档**不生成候选',
		!(scalar grep { ($_->{id} // '') eq 'A' && (($_->{info} || {})->{type} // '') eq 'flac' } @launched),
		'launched=' . join(',', map { ($_->{id} // '?') . '@' . (($_->{info} || {})->{type} // '?') } @launched));
	# 上闸时间往前拨到超过冷却期 ⇒ 应放一次（半开）
	run(want => 'flac', deliver => { B => 'flac-16' }, pretrip => ['A|mg|flac'], pretrip_age => 120);
	check('17b 超过冷却期后放一次（半开，A 在该档重新成为候选）',
		(scalar grep { ($_->{id} // '') eq 'A' && (($_->{info} || {})->{type} // '') eq 'flac' } @launched) ? 1 : 0,
		'launched=' . join(',', map { ($_->{id} // '?') . '@' . (($_->{info} || {})->{type} // '?') } @launched));
	Plugins::LxMusic::Helper::_breaker_reset();
	delete $enabled_ids{list};
}

# ---------- 18. 0.11.117：同档「质量优先窗口」（降档交付先压住，等同档更好的那份） ----------
# 现场（用户 2026-10-11）：「wy 平台只有 320k mp3？」
# 宿主侧 6 首真实 wy 曲目实测：HYWmusic 6/6 给真 FLAC、1010音源 1/6；设备侧对照：把 1010 停掉后
# 同一首立刻变 FLAC 24bit 1612kbps/0.76s ⇒ 源没问题，是"快而低档"的源把"慢而高档"的源饿死：
# 同档候选**并行**派发（先到先得），而交付闸的地板允许 flac→320k ⇒ 先到的 320k 就 $done=1。
# 本闸：手上这份低于**本曲阶梯最高档**、且同档还有候选在飞（或窗口已开）⇒ 先压住最多 $hold 秒。
{
	%path = (A => $srcA, B => $srcB);
	$enabled_ids{list} = [ 'A', 'B' ];
	# 18a：A 在同档（flac）只给 320k mp3、B 给真 flac；B 后到（hold_fire 模拟慢源）⇒ 必须交付 B 的 flac
	Slim::Utils::Timers::resetForTest();
	run(want => 'flac', deliver => { A => 'mp3-320', B => 'flac-16' },
		hold_fire => { 'B|flac' => 1 }, quality_hold => 1);
	check('18a 同档更优者胜：交付的是 B 的真 flac（不是先到的 320k）',
		@got == 1 && $got[0]{ok} && $got[0]{url} =~ m{/flac-16/},
		@got ? ($got[0]{url} // '?') : 'none');
	check('18b 先到的那份 320k 被压住过（窗口武装了定时器 ⇒ 有上限，不是无限等）',
		(scalar grep { ($_->{at} // 0) <= time() + 3 } Slim::Utils::Timers::listPending()) ? 1 : 0,
		'pending=' . scalar(Slim::Utils::Timers::listPending()));
	# 18c：`qualityHold => 0`（用户要"能响优先"）⇒ 回到旧行为：先到的 320k 直接交付
	run(want => 'flac', deliver => { A => 'mp3-320', B => 'flac-16' },
		hold_fire => { 'B|flac' => 1 }, quality_hold => 0);
	check('18c qualityHold=0（关）⇒ 回到"先到者交付"= 320k',
		@got == 1 && $got[0]{ok} && $got[0]{url} =~ m{/mp3-320/},
		@got ? ($got[0]{url} // '?') : 'none');
	# 18d：单源（没有同档兄弟在飞）⇒ 降档交付**立即**发生，零额外等待（不误伤最常见路径）
	%path = (A => $srcA);
	run(want => 'flac', deliver => { A => 'mp3-320' }, quality_hold => 2);
	check('18d 单源降档 ⇒ 立即交付（窗口不开，零开销）',
		@got == 1 && $got[0]{ok} && $got[0]{url} =~ m{/mp3-320/},
		@got ? ($got[0]{url} // '?') : 'none');
	%path = (A => $srcA, B => $srcB);
	delete $enabled_ids{list};
	Slim::Utils::Timers::resetForTest();
}

# ---------- 19. 0.11.119：跨档也要等（"更好档还在飞"必须跨档看） ----------
# 现场（用户 2026-10-11）：「tx 能出 192k 24bit，但一旦解析不出就直接退回 mp3」。
# 设备 tries 实证：mp3 是从 **320k 档**交付的，而能做无损的 1010音源还在 **flac 档**飞；
# 0.11.117 的判据只看"**同一档**有没有兄弟"（$q=320k 只有它自己）⇒ 不压 ⇒ 先到的 mp3 交付。
# 阶梯是"全档位铺开、并行派发"，所以"更好档在飞"要**跨档**看（本用例 A 的 flac 档当场失败、
# 由 320k 档给 mp3，B 的 flac 档慢一步到 ⇒ 必须等 B）。
{
	%path = (A => $srcA, B => $srcB);
	$enabled_ids{list} = [ 'A', 'B' ];
	# ⚠️ 桩的"交付循环"由 `deliver` 是否存在决定（`return unless $opt{deliver}`）⇒
	#   只用 `deliver_tier` 时必须同时给一个（可为空的）`deliver`，否则整个循环不跑（第一版就这么假失败）。
	run(want => 'flac', local_reject => { 'A|flac' => 1 }, deliver => {},
		deliver_tier => { '320k' => { A => 'mp3-320' }, 'flac' => { B => 'flac-16' } },
		hold_fire => { 'B|flac' => 1 }, quality_hold => 1);
	check('19a 低档（320k）交付被压住，最终交付更高档的 flac（跨档等待）',
		@got == 1 && $got[0]{ok} && $got[0]{url} =~ m{/flac-16/},
		@got ? ($got[0]{url} // '?') : 'none');
	# 19b：同样场景但**只有一个源**（没有更高档候选在飞）⇒ 不允许白等，低档立即交付
	%path = (A => $srcA);
	run(want => 'flac', local_reject => { 'A|flac' => 1 }, deliver => {},
		deliver_tier => { '320k' => { A => 'mp3-320' } }, quality_hold => 2);
	check('19b 无更高档候选在飞 ⇒ 立即交付低档（不白等）',
		@got == 1 && $got[0]{ok} && $got[0]{url} =~ m{/mp3-320/},
		@got ? ($got[0]{url} // '?') : 'none');
	%path = (A => $srcA, B => $srcB);
	delete $enabled_ids{list};
	Slim::Utils::Timers::resetForTest();
}

print $failed ? "\nFAILED ($failed)\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
