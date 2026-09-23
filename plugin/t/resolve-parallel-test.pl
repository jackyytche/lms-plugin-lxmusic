#!/usr/bin/perl
# resolve-parallel-test.pl — Helper::resolveTrack 的"并行候选窗口"回归（0.11.24）
# 用法：perl plugin/t/resolve-parallel-test.pl
#
# 手法：把 Helper->request / probeUrl / Sources 全部换成**不立即回调**的假实现，
# 于是可以观察"在没有任何回调发生之前，派发器到底启动了几个候选"——这正是并行窗口的定义。
# 然后再手工按任意顺序回调，验证：只交付一次、先到者胜、全失败只报一次、中转链兜底。
use strict;
use warnings;

use FindBin;
use File::Spec;
use File::Temp ();
use lib File::Spec->catdir($FindBin::Bin);

BEGIN {
	# zip 平铺结构：Helper.pm 在插件根、包名 Plugins::LxMusic::Helper（同 helper-test.pl 的钩子，
	# 这样 `perl t/resolve-parallel-test.pl` 在 CI 与本地都能独立跑通，不依赖外部 -I）
	my $root  = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
	my $build = File::Spec->catdir($root, 't_build', 'Plugins', 'LxMusic');
	unshift @INC, sub {
		my ($self, $file) = @_;
		return unless $file =~ m{^Plugins/LxMusic/([^/]+\.pm)$};
		# ⚠️ 2026-09-23：t_build 里可能有**过期副本**（本地/CI 早期构建留下的），
		# 无条件优先它会让我们在"测旧代码"（实测踩到：ProtocolHandler 加载到 09-19 的版本，
		# 新方法怎么都不存在）。⇒ 两个候选都在时**取 mtime 更新的那个**。
		my @cand = grep { -f $_ } map { File::Spec->catfile($_, $1) }
			($build, File::Spec->catdir($root, 'LxMusic'));
		return unless @cand;
		my ($newest) = sort { (stat($b))[9] <=> (stat($a))[9] } @cand;
		open my $fh, '<', $newest or return;
		return $fh;
	};
	my $helper = File::Spec->catfile($FindBin::Bin, '..', 'LxMusic', 'Helper.pm');
	require $helper;
	# 0.11.60：告诉 require 这个包已经加载（否则 ProtocolHandler 的 `use Plugins::LxMusic::Helper`
	# 会经钩子**再加载一遍**同名包 ⇒ "Subroutine _src_failed redefined" 噪音）
	$INC{'Plugins/LxMusic/Helper.pm'} = $helper;
}

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

# 两个"源"文件（-f 检查要真存在）
my $tmp = File::Temp->newdir();
my %path = (A => File::Spec->catfile($tmp, 'A.js'), B => File::Spec->catfile($tmp, 'B.js'));
for my $p (values %path) { open my $fh, '>', $p or die $!; print $fh "// stub\n"; close $fh }

# ---- 打桩：记录启动、不回调 ----
my @launched;
my %cb;
{
	no warnings 'redefine';
	no strict 'refs';
	*Plugins::LxMusic::Helper::request = sub {
		my ($class, %a) = @_;
		my ($id) = grep { $path{$_} eq $a{source} } keys %path;
		push @launched, { id => $id, path => $a{source}, info => $a{info},
			priority => $a{priority}, budget => $a{budget} };
		$cb{$id} = $a{cb};
		return 1;
	};
	*Plugins::LxMusic::Helper::probeUrl = sub {
		my ($class, $url, $pcb) = @_;
		$pcb->({ ok => 1, status => 206, magic => 'flac', length => 30_000_000 });
	};
	*Plugins::LxMusic::Sources::enabled = sub {
		return [ { id => 'A', name => 'srcA' }, { id => 'B', name => 'srcB' } ];
	};
	*Plugins::LxMusic::Sources::pathFor = sub { my ($class, $id) = @_; return $path{$id} };
}

my $track = { songmid => '1', name => 'song', singer => 'singer', interval => '04:00',
	types => [ { type => 'flac', size => '30.00 MiB' } ] };

sub new_run {
	@launched = ();
	%cb = ();
	# 0.11.57：每个场景先清"死源熔断"，否则前两个场景的失败会把某些
	# (源×平台×档位) 三元组闸掉，后面的场景根本不会再派候选（这正是熔断的设计行为）。
	Plugins::LxMusic::Helper::_breaker_reset();
	Plugins::LxMusic::Helper::_score_reset();      # 0.11.63：分数也要隔离，否则场景之间互相影响派发顺序
	Slim::Utils::Timers::resetForTest();
	my @got;
	Plugins::LxMusic::Helper->resolveTrack(
		music => $track, src => 'wy', type => 'flac',
		cb    => sub { push @got, $_[0] },
	);
	return \@got;
}

# 0.11.58：带整体预算的场景（定时器桩需要 fireDue 才会触发）
sub new_run_budget {
	my ($secs) = @_;
	@launched = ();
	%cb = ();
	Plugins::LxMusic::Helper::_breaker_reset();
	Slim::Utils::Timers::resetForTest();
	my @got;
	Plugins::LxMusic::Helper->resolveTrack(
		music => $track, src => 'wy', type => 'flac', budget => $secs,
		cb    => sub { push @got, $_[0] },
	);
	return \@got;
}

# ---------- 1. 没有回调前就应启动 2 个候选（并行窗口 = 2） ----------
{
	my $got = new_run();
	check('window: 未回调前已启动 2 个候选', scalar(@launched) == 2,
		'launched=' . scalar(@launched));
	check('window: 两个候选来自不同源', (@launched == 2
		&& $launched[0]{id} ne $launched[1]{id}));

	# 第二个候选先成功（friendly: 带 .flac 后缀）
	$cb{B}->({ ok => 1, data => 'http://cdn.example/b.flac', why => 'worker' });
	check('deliver: 先到者交付', @$got == 1 && $got->[0]{ok} && $got->[0]{url} =~ /b\.flac$/);

	# 之后第一个候选再失败 ⇒ 不得二次交付
	$cb{A}->({ ok => 0, error => 'upstream 500', why => 'worker' });
	check('deliver: 不再二次交付', @$got == 1);
	check('deliver: tries 记下了失败与成功', @{ $got->[0]{tries} } >= 2);
}

# ---------- 2. 全失败：只回调一次，错误里带两个源 ----------
{
	my $got = new_run();
	$cb{A}->({ ok => 0, error => 'a failed', why => 'worker' });
	$cb{B}->({ ok => 0, error => 'b failed', why => 'worker' });
	check('allfail: 只回调一次', @$got == 1);
	check('allfail: ok=0', @$got && !$got->[0]{ok});
	check('allfail: 错误里提到两个源', @$got && $got->[0]{error} =~ /srcA/ && $got->[0]{error} =~ /srcB/,
		@$got ? $got->[0]{error} : '');
}

# ---------- 3. 中转链兜底：两个不友好候选都先"暂缓"，最后才用兜底交付（恰好一次） ----------
{
	my $got = new_run();
	$cb{A}->({ ok => 1, data => 'http://relay.example/kw/kw.php?type=mp3&id=1', why => 'worker' });
	$cb{B}->({ ok => 1, data => 'http://relay.example/kw/kw.php?type=mp3&id=2', why => 'worker' });
	check('deferred: 只交付一次', @$got == 1);
	my @def = grep { $_->{deferred} } @{ $got->[0]{tries} || [] };
	check('deferred: 两个候选都先被标记为暂缓', @def == 2, 'deferred_tries=' . scalar(@def));
	check('deferred: 交付的是中转链（兜底路径）',
		@$got && $got->[0]{ok} && $got->[0]{url} =~ m{relay\.example});
}

# ---------- 4. 能力表裁剪（0.11.58）：源声明不支持该平台 ⇒ 完全不为它生成候选 ----------
{
	# B 源只声明支持 kw；本场景请求平台 wy ⇒ 只有 A 源该被派出
	Plugins::LxMusic::Helper::_caps_reset();
	Plugins::LxMusic::Helper->_caps_note($path{B},
		{ status => 'success', sources => { kw => { name => 'kw', qualitys => ['128k', '320k'] } } });
	my $got = new_run();
	check('caps: 未声明该平台的源不再生成候选（只派 A）',
		@launched == 1 && $launched[0]{id} eq 'A', 'launched=' . join(',', map { $_->{id} } @launched));
	$cb{A}->({ ok => 0, error => 'x', why => 'worker' });
	check('caps: 失败路径仍然只回调一次', @$got == 1);

	# 声明支持的平台照旧派发
	Plugins::LxMusic::Helper::_caps_reset();
	Plugins::LxMusic::Helper->_caps_note($path{B},
		{ status => 'success', sources => { wy => { name => 'wy', qualitys => ['flac'] } } });
	my $got2 = new_run();
	check('caps: 声明支持的平台照旧参与', scalar(@launched) == 2,
		'launched=' . scalar(@launched));

	# 档位裁剪：B 在 wy 上只声明 128k/320k，而请求 flac ⇒ B 不出现在 flac 档
	Plugins::LxMusic::Helper::_caps_reset();
	Plugins::LxMusic::Helper->_caps_note($path{B},
		{ status => 'success', sources => { wy => { name => 'wy', qualitys => ['128k', '320k'] } } });
	my $got3 = new_run();
	my @src_of_launch = map { $_->{id} } @launched;
	check('caps: 档位不支持时该源被裁掉', !grep { $_ eq 'B' } @src_of_launch,
		'launched=' . join(',', @src_of_launch));

	Plugins::LxMusic::Helper::_caps_reset();
}

# ---------- 5. 整体预算（0.11.58）：超预算必须明确失败，不再让调用方无限等 ----------
{
	my $got = new_run_budget(1);     # 1 秒预算，且两个候选都不回调
	check('budget: 预算内没有候选返回 ⇒ 尚未回调', @$got == 0);
	sleep 2;
	Slim::Utils::Timers::fireDue();
	check('budget: 超预算只回调一次', @$got == 1);
	check('budget: 回调标了 timeout 且 ok=0', @$got && !$got->[0]{ok} && $got->[0]{timeout});
	check('budget: 错误信息说明是预算超时', @$got && $got->[0]{error} =~ /budget/,
		@$got ? $got->[0]{error} : '');
}

# ---------- 6. 请求分级（0.11.58）：后台（预热）优先级要一路传到候选请求上 ----------
{
	@launched = ();
	%cb = ();
	Plugins::LxMusic::Helper::_breaker_reset();
	my @got;
	Plugins::LxMusic::Helper->resolveTrack(
		music => $track, src => 'wy', type => 'flac', priority => 'bg',
		cb    => sub { push @got, $_[0] },
	);
	my @prios = map { $_->{priority} } @launched;
	# ⚠️ grep 是列表操作符，会把它后面的一切都吃掉（包括 detail 参数）——所以先算进变量
	my $all_bg = @prios ? (grep { ($_ // '') ne 'bg' } @prios) == 0 : 0;
	check('bg: 预热的 bg 优先级传到了候选请求', @prios == 2 && $all_bg,
		'prios=' . join(',', map { $_ // 'undef' } @prios));
	check('bg: 设备空闲时 _load_busy 为假（不会误丢后台请求）',
		!Plugins::LxMusic::Helper::_load_busy());
	$cb{A}->({ ok => 0, error => 'x', why => 'worker' });
	$cb{B}->({ ok => 0, error => 'y', why => 'worker' });
	check('bg: 照常收尾（只回调一次）', @got == 1);
}

# ---------- 7. 真实档位推导（0.11.60，A0）：位深/码率/上游声明 → 一个标签 ----------
{
	require Plugins::LxMusic::ProtocolHandler;
	my $PH = 'Plugins::LxMusic::ProtocolHandler';
	my @decl_flac   = ({ type => '128k' }, { type => '320k' }, { type => 'flac' });
	my @decl_24     = ({ type => 'flac' }, { type => 'flac24bit' });

	check('tier: flac 且位深 24 -> flac24bit', $PH->_actualTier('flc', 1700, 24) eq 'flac24bit');
	check('tier: flac 且位深 16 -> flac', $PH->_actualTier('flc', 1000, 16) eq 'flac');
	check('tier: flac 无位深 + 1647kbps + 上游只声明 flac -> flac（不再吹成 24bit）',
		$PH->_actualTier('flc', 1647, 0, \@decl_flac) eq 'flac');
	check('tier: flac 无位深 + 1709kbps + 上游含 flac24bit -> flac24bit',
		$PH->_actualTier('flc', 1709, 0, \@decl_24) eq 'flac24bit');
	check('tier: mp3 320kbps -> 320k', $PH->_actualTier('mp3', 320, 0) eq '320k',
		'got=' . ($PH->_actualTier('mp3', 320, 0) // 'undef'));
	check('tier: mp3 256kbps -> 256k', $PH->_actualTier('mp3', 256, 0) eq '256k',
		'got=' . ($PH->_actualTier('mp3', 256, 0) // 'undef'));
	check('tier: mp3 192kbps -> 192k', $PH->_actualTier('mp3', 192, 0) eq '192k',
		'got=' . ($PH->_actualTier('mp3', 192, 0) // 'undef'));
	check('tier: mp3 96kbps -> 128k', $PH->_actualTier('mp3', 96, 0) eq '128k',
		'got=' . ($PH->_actualTier('mp3', 96, 0) // 'undef'));
	check('tier: m4a -> aac', $PH->_actualTier('mp4', 200, 0) eq 'aac',
		'got=' . ($PH->_actualTier('mp4', 200, 0) // 'undef'));
	check('tier: 未知格式原样大写', $PH->_actualTier('ape', 900, 0) eq 'APE',
		'got=' . ($PH->_actualTier('ape', 900, 0) // 'undef'));
	check('label: 192k -> MP3 192kbps', $PH->qualityLabel('192k') eq 'MP3 192kbps');
	check('label: 256k -> MP3 256kbps', $PH->qualityLabel('256k') eq 'MP3 256kbps');
	check('label: 已是人读标签则幂等（不再被 uc 成 FLAC 24BIT）',
		$PH->qualityLabel('FLAC 24bit') eq 'FLAC 24bit');
}

# ---------- 8. 封面缩略改写（0.11.61）：只动实测有尺寸变体的源，其余原样 ----------
{
	my $H = 'Plugins::LxMusic::Helper';
	my $wy = 'https://p2.music.126.net/l0vGEnowGfj6DgFSGojyfQ==/109951168163397768.jpg';
	my $tx = 'https://y.gtimg.cn/music/photo_new/T002R500x500M000002iWKlh2DcjFL.jpg';
	my $kw = 'http://img1.kwcdn.kuwo.cn/star/albumcover/500/s3s94/93/211513640.jpg';
	my $kg = 'https://imge.kugou.com/stdmusic/240/966846.jpg';
	my $mg = 'https://d.musicapp.migu.cn/data/oss/resource/00/42/rf/abc.jpg';

	check('thumb: wy 追加 param=300y300', $H->coverThumb($wy, 300) eq $wy . '?param=300y300',
		$H->coverThumb($wy, 300));
	check('thumb: wy 已有 param 不重复追加',
		$H->coverThumb($wy . '?param=130y130', 300) eq $wy . '?param=130y130',
		$H->coverThumb($wy . '?param=130y130', 300));
	check('thumb: tx R500x500 -> R300x300',
		$H->coverThumb($tx, 300) eq 'https://y.gtimg.cn/music/photo_new/T002R300x300M000002iWKlh2DcjFL.jpg',
		$H->coverThumb($tx, 300));
	check('thumb: kw albumcover/500 -> /300/',
		$H->coverThumb($kw, 300) eq 'http://img1.kwcdn.kuwo.cn/star/albumcover/300/s3s94/93/211513640.jpg',
		$H->coverThumb($kw, 300));
	check('thumb: kg 没有尺寸变体 -> 原样', $H->coverThumb($kg, 300) eq $kg, $H->coverThumb($kg, 300));
	check('thumb: mg 没有尺寸变体 -> 原样', $H->coverThumb($mg, 300) eq $mg, $H->coverThumb($mg, 300));
	check('thumb: size=0 关闭改写 -> 原样', $H->coverThumb($wy, 0) eq $wy, $H->coverThumb($wy, 0));
	# 0.11.62：大图档（队列/正在播放）用 500，且与列表档互不影响
	check('thumb(big): 显式 500 -> param=500y500',
		$H->coverThumb($wy, 500) eq $wy . '?param=500y500', $H->coverThumb($wy, 500));
	check('thumb(big): kind=big 走 coverThumbBig（默认 500）',
		$H->coverThumb($wy, undef, 'big') eq $wy . '?param=500y500',
		$H->coverThumb($wy, undef, 'big'));
	check('thumb: 列表档仍是 300（未被大图档带偏）',
		$H->coverThumb($tx, undef) eq 'https://y.gtimg.cn/music/photo_new/T002R300x300M000002iWKlh2DcjFL.jpg',
		$H->coverThumb($tx, undef));
	check('thumb: 未知域 -> 原样',
		$H->coverThumb('https://example.com/a.jpg', 300) eq 'https://example.com/a.jpg');
}

# ---------- 9. 每（源 × 平台）自适应排序（0.11.63） ----------
{
	my $H = 'Plugins::LxMusic::Helper';

	# 9a) 没有任何数据 ⇒ 保持注册表顺序（稳定排序，绝不因为"没见过"就乱排）
	@launched = ();
	%cb = ();
	$H->_breaker_reset();
	$H->_score_reset();
	Plugins::LxMusic::Helper->resolveTrack(music => $track, src => 'wy', type => 'flac', cb => sub { });
	check('score: 无数据时保持注册表顺序（A 先）',
		@launched == 2 && $launched[0]{id} eq 'A', 'order=' . join(',', map { $_->{id} } @launched));

	# 9b) A 在 wy 上失败过、B 在 wy 上又快又成功 ⇒ B 必须排到前面
	Plugins::LxMusic::Helper::_score_note(Plugins::LxMusic::Helper::_score_key({ id => 'A', name => 'srcA' }, 'wy'), 0, 3000);
	Plugins::LxMusic::Helper::_score_note(Plugins::LxMusic::Helper::_score_key({ id => 'B', name => 'srcB' }, 'wy'), 1, 200);
	@launched = ();
	%cb = ();
	$H->_breaker_reset();
	Plugins::LxMusic::Helper->resolveTrack(music => $track, src => 'wy', type => 'flac', cb => sub { });
	check('score: 按（源×平台）分数重排（B 先）',
		@launched == 2 && $launched[0]{id} eq 'B', 'order=' . join(',', map { $_->{id} } @launched));

	# 9c) 分数是**分平台**的：B 在 kw 上的成功不能影响 wy 的顺序
	$H->_score_reset();
	Plugins::LxMusic::Helper::_score_note(Plugins::LxMusic::Helper::_score_key({ id => 'B', name => 'srcB' }, 'kw'), 1, 100);
	@launched = ();
	%cb = ();
	$H->_breaker_reset();
	Plugins::LxMusic::Helper->resolveTrack(music => $track, src => 'wy', type => 'flac', cb => sub { });
	check('score: 分平台隔离（kw 的数据不影响 wy 顺序）',
		@launched == 2 && $launched[0]{id} eq 'A', 'order=' . join(',', map { $_->{id} } @launched));

	# 9d) 分数表是只读诊断口（设置页/日志可用）
	my $st = $H->score_state;
	check('score: score_state 能读出计数', ref($st) eq 'HASH' && exists $st->{ 'B|kw' }
		&& $st->{ 'B|kw' }{ok} == 1, join(',', sort keys %$st));

	$H->_score_reset();
}

print $failed ? "\n$failed FAILED\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
