#!/usr/bin/perl
# pl-search-page-test.pl — 歌单搜索分页（0.11.78+）的回归
#
# 背景（2026-09-24 与 PC 版 2.12.6 实测对照）：同一关键词 PC 能翻 19 页共 963 行，
# 插件只有 33 行，且那 33 行**全部落在 PC 第 1 页里**。根因是三重自限：
#   ① 每平台只要 8 条 ② 累计 40 条就截断 ③ 从不传 page。
#
# 本测试钉死新实现的**取数计划 + 虚拟列表几何**（分页正确性的全部基础）：
#   · 首次只发一次"全平台探测"（学 total 与平台顺序），此后按 [平台,页] 精确补页
#   · 页宽 = LMS 窗口（50）⇒ **首页由那一次探测就铺满**（这是首屏 11.4s → 3.9s 的关键）
#   · 虚拟列表 = 平台优先拼接（kg 全部 → tx 全部 → …），上界 = min(上游 total, PER*MAXPAGES)
#   · 末页不足一页 / 某页取失败 ⇒ **上界收敛**（宁可少列，也不能让 LMS 补出点进去出错的空行）
#
# ⚠️ 本测试从模块读 `_pl_search_params()`，所以调页宽/页数上限不会让用例失效。
#
# 用法：perl plugin/t/pl-search-page-test.pl
use strict;
use warnings;

use FindBin;
use File::Spec;

use lib File::Spec->catdir($FindBin::Bin);   # plugin/t 里放着 Slim::* / JSON::XS 的桩

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
	require Plugins::LxMusic::Plugin;
}

# 这几个 helper 在模块里是**函数式**调用的（不带 $class 形参）——测试也照函数式取码引用，
# 别写成 `$P->_pl_search_geom(...)`（那会把类名塞进第一个实参，正是 0.11.76 coverThumbSize 的坑）
my $store_of  = \&Plugins::LxMusic::Plugin::_pl_search_store;
my $geom_of   = \&Plugins::LxMusic::Plugin::_pl_search_geom;
my $miss_of   = \&Plugins::LxMusic::Plugin::_pl_search_missing;
my $feed_of   = \&Plugins::LxMusic::Plugin::_pl_search_feed;
my $params_of = \&Plugins::LxMusic::Plugin::_pl_search_params;

my ($PER, $MAXPAGES) = $params_of->();
my $CAP = $PER * $MAXPAGES;

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

# 造第 page 页的假数据：条数 = 该页真实会有的条数（末页可能不满）
sub fake_group {
	my ($src, $total, $page) = @_;
	my $start = ($page - 1) * $PER;
	my $n = $total - $start;
	$n = $PER if $n > $PER;
	$n = 0 if $n < 0;
	my @list = map {
		{ id => 'id_' . ($start + $_), name => "$src-p$page-" . ($start + $_), author => 'a', total => 10, img => "http://x/$src.jpg" }
	} (1 .. $n);
	return undef unless @list;
	return { source => $src, list => \@list, total => $total };
}

sub store {
	my ($st, $src, $page, $groups, $fail) = @_;
	my @g = grep { $_ } @$groups;
	my $res = $fail ? undef : { ok => 1, data => \@g };
	return $store_of->($st, $src, $page, $res);
}

sub new_state {
	return { at => time(), query => 'q', pages => {}, fail => {}, total => {},
		order => [], slots => {}, failed => 0 };
}

sub need_str {
	my ($need) = @_;
	return join(' ', map { $_->[0] . '/' . $_->[1] } @$need);
}

sub names_of {
	my ($feed) = @_;
	return map { $_->{name} } @{ $feed->{items} || [] };
}

# 本用例的"上游真相"：各平台 total（都要能被 clamp 验证到）
my %TOTAL = (kg => 120, tx => 75, wy => 10, mg => 1, kw => 58);

# ---------- 1. 空状态：先发一次"全平台探测" ----------
{
	my $st = new_state();
	my $need = $miss_of->($st, 0, 50);
	check('空状态只发一次全平台探测', need_str($need) eq '*/1', need_str($need));
}

# ---------- 2. 探测轮之后的几何（平台优先拼接 + 末页收敛）----------
my $st = new_state();
store($st, '*', 1, [ map { fake_group($_, $TOTAL{$_}, 1) } qw(kg tx wy mg kw) ]);
{
	my ($geom, $total) = $geom_of->($st);
	my @g = map { [ $_->[0], $_->[1], $_->[2] ] } @$geom;
	check('平台顺序 = kg,tx,wy,mg,kw', join(',', map { $_->[0] } @$geom) eq 'kg,tx,wy,mg,kw',
		join(',', map { $_->[0] } @$geom));
	check("几何 kg: base0 slots", $g[0][1] == 0 && $g[0][2] == 120, "$g[0][1]/$g[0][2]");
	check("几何 tx: base120 slots75", $g[1][1] == 120 && $g[1][2] == 75, "$g[1][1]/$g[1][2]");
	check("几何 wy: base195 slots10（末页收敛）", $g[2][1] == 195 && $g[2][2] == 10, "$g[2][1]/$g[2][2]");
	check("几何 mg: base205 slots1（末页收敛）", $g[3][1] == 205 && $g[3][2] == 1, "$g[3][1]/$g[3][2]");
	check("几何 kw: base206 slots58", $g[4][1] == 206 && $g[4][2] == 58, "$g[4][1]/$g[4][2]");
	check('total = 各平台 slots 之和 (264)', $total == 264, $total);
}

# ---------- 3. 页宽 = LMS 窗口 ⇒ 首页不需要补页（首屏只花一次往返）----------
{
	my $need = $miss_of->($st, 0, 50);
	check('窗口[0,50) 由探测页直接覆盖 ⇒ 不补页', need_str($need) eq '', need_str($need));

	$need = $miss_of->($st, 50, 50);
	check('窗口[50,50) 只需补 kg 第 2 页', need_str($need) eq 'kg/2', need_str($need));

	$need = $miss_of->($st, 120, 20);
	check('窗口[120,20) 命中已缓存页 ⇒ 不取', need_str($need) eq '', need_str($need));

	$need = $miss_of->($st, 206, 50);
	check('窗口[206,50) 命中 kw 第 1 页 ⇒ 不取', need_str($need) eq '', need_str($need));
}

# ---------- 4. 补页后：窗口切片跨平台且铺满 ----------
{
	store($st, 'kg', 2, [ fake_group('kg', 120, 2) ]);
	my $feed = $feed_of->($st, 50, 50);
	my @n = names_of($feed);
	check('补页后窗口铺满 50 行', scalar(@n) == 50, scalar(@n));
	check('第 1 行来自 kg 第 2 页', index($n[0] // '', 'kg-p2-51 ') >= 0, $n[0]);
	check('第 50 行来自 kg 第 2 页末尾', index($n[49] // '', 'kg-p2-100 ') >= 0, $n[49]);

	# kg 给到第 3 页只剩 20 条（120-100）⇒ 上界必须收敛到正好 120
	store($st, 'kg', 3, [ fake_group('kg', 120, 3) ]);
	my ($geom, $total) = $geom_of->($st);
	check('末页不足 ⇒ kg slots 恰好 120', $geom->[0][2] == 120, $geom->[0][2]);
	check('total 仍为 264', $total == 264, $total);

	# 跨平台：窗口落在 kg 尾部（110..119）时，应自动接上 tx 的头几行
	my $feed2 = $feed_of->($st, 110, 15);
	my @n2 = names_of($feed2);
	check('跨平台窗口铺满 15 行', scalar(@n2) == 15, scalar(@n2));
	check('第 1 行来自 kg 第 3 页', index($n2[0] // '', 'kg-p3-111 ') >= 0, $n2[0]);
	check('第 11 行跨到 tx 第 1 页', index($n2[10] // '', 'tx-p1-1 ') >= 0, $n2[10]);
}

# ---------- 5. 失败页 ⇒ 该平台上界收敛，且不再重试 ----------
{
	my $st3 = new_state();
	store($st3, '*', 1, [ fake_group('kg', 120, 1), fake_group('tx', 75, 1) ]);
	store($st3, 'tx', 2, [], 1);
	my ($geom) = $geom_of->($st3);
	check('失败页 2 ⇒ tx 上界收到 50', $geom->[1][2] == 50, $geom->[1][2]);
	check('kg 不受影响', $geom->[0][2] == 120, $geom->[0][2]);
	my $need = $miss_of->($st3, 120, 50);
	check('失败页不再重试', need_str($need) eq '', need_str($need));
}

# ---------- 6. 全空 ⇒ 给"无歌单结果"（而不是空列表）----------
{
	my $st4 = new_state();
	store($st4, '*', 1, []);
	my $feed = $feed_of->($st4, 0, 50);
	check('无结果时给一行 text 提示', ref $feed->{items} eq 'ARRAY' && @{ $feed->{items} } == 1
		&& $feed->{items}[0]{type} eq 'text', $feed->{items}[0]{type} // '?');
}

print "\n(PER=$PER MAXPAGES=$MAXPAGES CAP=$CAP)\n";
print($failed ? "FAILED ($failed)\n" : "ALL OK\n");
exit($failed ? 1 : 0);
