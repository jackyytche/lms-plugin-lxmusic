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
		for my $dir ($build, File::Spec->catdir($root, 'LxMusic')) {
			my $p = File::Spec->catfile($dir, $1);
			next unless -f $p;
			open my $fh, '<', $p or next;
			return $fh;
		}
		return;
	};
	my $helper = File::Spec->catfile($FindBin::Bin, '..', 'LxMusic', 'Helper.pm');
	require $helper;
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

print $failed ? "\n$failed FAILED\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
