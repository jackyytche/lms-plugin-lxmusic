#!/usr/bin/perl
# album-search-test.pl — 专辑搜索（0.11.112）的回归
#
# 钉死三块（实现 = 歌单搜索 0.11.78 泵的复刻 + 专辑详情整张切片）：
#   ① 取数计划 + 虚拟列表几何：首次一次"全平台探测"（学 total 与顺序），此后按 [平台,页] 补页；
#     虚拟列表 = 平台优先拼接；上界 = min(上游 total, PER*MAXPAGES)；末页不足/取失败 ⇒ 上界收敛。
#   ② 条目渲染 _alItems 的行契约：💿 前缀、meta 拼接、passthrough(albumdetail)、
#     playlist => lxm://a/<src>/<id>（整单播放）、头部 head b64（name/img/author/count）。
#   ③ 详情窗口切片契约在 shim 侧整张返回的前提下成立（本套件只测纯函数；上下游形状由
#     tmp/album_shim_probe.py 真网验证，装机后由 UI 验收）。
#
# 用法：perl plugin/t/album-search-test.pl
use strict;
use warnings;
use utf8;   # 字面量按字符串解析：_u() 返回的是字符旗标串，字节串正则匹配不上（11首 现场踩过）

use FindBin;
use File::Spec;

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
	require Plugins::LxMusic::Plugin;
}

my $state_of  = \&Plugins::LxMusic::Plugin::_al_search_state;
my $store_of  = \&Plugins::LxMusic::Plugin::_al_search_store;
my $geom_of   = \&Plugins::LxMusic::Plugin::_al_search_geom;
my $miss_of   = \&Plugins::LxMusic::Plugin::_al_search_missing;
my $feed_of   = \&Plugins::LxMusic::Plugin::_al_search_feed;
my $items_of  = \&Plugins::LxMusic::Plugin::_alItems;

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

sub new_state {
	return { at => time(), query => 'q', pages => {}, fail => {}, total => {},
		order => [], slots => {}, failed => 0 };
}

# _al_search_store 吃的是 {ok,data} 响应壳 —— 与 pl-search-page-test 的 store() 同款包装
sub store {
	my ($st, $src, $page, $groups, $fail) = @_;
	my @g = grep { $_ } @$groups;
	my $res = $fail ? undef : { ok => 1, data => \@g };
	return $store_of->($st, $src, $page, $res);
}

sub need_str {
	my ($need) = @_;
	return join(' ', map { $_->[0] . '/' . $_->[1] } @$need);
}

# ---- ① 取数计划：未探测 ⇒ 全平台探测一次 ----
{
	my $st = new_state();
	check('未探测 ⇒ 探测计划 [* , 1]', need_str($miss_of->($st, 0, 50)) eq '*/1',
		need_str($miss_of->($st, 0, 50)));
}

# ---- ① 探测轮：顺序 + 上界 + 首页即铺满窗口 ----
{
	my $st = new_state();
	store($st, '*', 1, [
		{ source => 'kg', list => [ map { { id => "kg$_", name => "n$_" } } 1 .. 30 ], total => 500 },
		{ source => 'tx', list => [ map { { id => "tx$_", name => "n$_" } } 1 .. 30 ], total => 40 },
		{ source => 'wy', list => [ map { { id => "wy$_", name => "n$_" } } 1 .. 30 ], total => 592 },
	]);
	check('探测后顺序 = 返回顺序', join(',', @{ $st->{order} }) eq 'kg,tx,wy');
	my ($geom, $total) = $geom_of->($st);
	check('kg 上界 min(500, 150)=150', $geom->[0][2] == 150, "got " . $geom->[0][2]);
	check('tx 上界 min(40, 150)=40',  $geom->[1][2] == 40,  "got " . $geom->[1][2]);
	check('wy 上界 min(592, 150)=150', $geom->[2][2] == 150, "got " . $geom->[2][2]);
	check('虚拟列表总行数 = 340', $total == 340, "got $total");
	# ⚠️ PER=30 < LMS 窗口 50 ⇒ 一个窗口天然跨 2 个上游页（与歌单搜索 PER=50 不同）。
	# 首窗 [0,50)：kg 需 p1+p2、tx 需 p1、wy 不涉及；p1 们探测时已存 ⇒ 只缺 kg/2
	check('首窗 50 只缺 kg/2（一窗跨两页）', need_str($miss_of->($st, 0, 50)) eq 'kg/2',
		need_str($miss_of->($st, 0, 50)));
	# 窗口 [40,90)：kg local 40..90 ⇒ 第 2、3 两页（p1 已存不重打）
	my $need = $miss_of->($st, 40, 50);
	check('idx=40 ⇒ kg 第 2+3 页', need_str($need) eq 'kg/2 kg/3', need_str($need));
}

# ---- ① 末页不足一页 ⇒ 上界收敛 ----
{
	my $st = new_state();
	store($st, '*', 1, [ { source => 'kg', list => [ map { { id => "kg$_" } } 1 .. 12 ], total => 99 } ]);
	my ($geom) = $geom_of->($st);
	check('末页 12(<30) ⇒ 上界收敛为 12', $geom->[0][2] == 12, "got " . $geom->[0][2]);
}

# ---- ① 取失败 ⇒ 标记失败、上界收敛、不再重试 ----
{
	my $st = new_state();
	store($st, 'kg', 2, [], 1);
	check('kg/2 失败 ⇒ failed 计数', ($st->{failed} || 0) == 1);
	check('kg/2 不再进计划', need_str($miss_of->($st, 30, 30)) !~ m{kg/2},
		need_str($miss_of->($st, 30, 30)));
}

# ---- ①Ⓐ 活性护栏（0.11.113 冻机事故回归）：ok-但-空 页 ⇒ 必须按失败处理 ----
# 0.11.112 现场实证：单平台页返回 ok 但 data=[] 时（上游整批失败/页号超界），该页既没
# 存页也没标失败 ⇒ missing 永远重发同一页 ⇒ 泵死循环 → qjs fork 堆积 → 整机冻死。
{
	my $st = new_state();
	store($st, '*', 1, [ { source => 'kg', list => [ map { { id => "kg$_" } } 1 .. 30 ], total => 500 } ]);
	check('护栏前置：kg slots=150', $st->{slots}{kg} == 150, "got " . $st->{slots}{kg});
	store($st, 'kg', 2, []);   # ok 但空（store 包装里 groups=[] ⇒ data=[]）
	check('ok-但-空 ⇒ 标失败', ($st->{fail}{'kg|2'} || 0) == 1);
	check('ok-但-空 ⇒ 上界收敛 30', $st->{slots}{kg} == 30, "got " . $st->{slots}{kg});
	check('kg/2 不再进计划', need_str($miss_of->($st, 0, 50)) !~ m{kg/2},
		need_str($miss_of->($st, 0, 50)));
	# 探测轮整体空：只置 probed、不炸
	my $st2 = new_state();
	store($st2, '*', 1, []);
	check('探测轮全空 ⇒ probed 置位', ($st2->{probed} || 0) == 1);
	# ⚠️ 冻机根因回归（0.11.114）：探测轮**失败**（res=undef）也必须置 probed——
	# 0.11.113 的失败分支提前 return 跳过置位 ⇒ missing 永远重发 ['*',1] ⇒ 死循环冻机
	my $st3 = new_state();
	store($st3, '*', 1, [], 1);
	check('探测轮失败 ⇒ probed 置位（冻机根治）', ($st3->{probed} || 0) == 1);
	check('探测轮失败 ⇒ 不再进计划', scalar @{ $miss_of->($st3, 0, 50) } == 0,
		need_str($miss_of->($st3, 0, 50)));
}

# ---- ② feed：平台优先拼接 + 翻页契约 ----
{
	my $st = new_state();
	my @kg1 = map { { id => "k$_", name => "kg-n$_", singer => 's', count => 3, year => '2020', cover => '' } } 1 .. 30;
	my @tx1 = map { { id => "t$_", name => "tx-n$_", singer => 's', count => 0, year => '', cover => '' } } 1 .. 30;
	store($st, '*', 1, [
		{ source => 'kg', list => \@kg1, total => 60 },
		{ source => 'tx', list => \@tx1, total => 60 },
	]);
	store($st, 'kg', 2, [ { source => 'kg', list => [
		map { { id => "K$_", name => "kg-n2-$_", singer => 's', count => 3, year => '2020', cover => '' } } 1 .. 30 ] } ]);
	my $feed = $feed_of->($st, 20, 30);
	my @names = map { $_->{name} } @{ $feed->{items} };
	check('feed offset=20', ($feed->{offset} || 0) == 20);
	check('feed total=120', ($feed->{total} || 0) == 120, "got " . ($feed->{total} || 0));
	check('拼接边界：idx20=kg#21', $names[0] =~ /kg-n21/, $names[0]);
	check('拼接边界：idx29=kg#30 / idx30=kg2#1', $names[9] =~ /kg-n30/ && $names[10] =~ /kg-n2-1/,
		"$names[9] | $names[10]");
}

# ---- ② 空结果 / 全失败的文案 ----
{
	my $st = new_state();
	store($st, '*', 1, []);   # 全空
	my $feed = $feed_of->($st, 0, 50);
	check('空结果 ⇒ 无专辑结果 文案', $feed->{items}[0]{name} =~ /无专辑结果/, $feed->{items}[0]{name});
	my $st2 = new_state();
	store($st2, '*', 1, [], 1);
	my $feed2 = $feed_of->($st2, 0, 50);
	check('全失败 ⇒ 失败文案', $feed2->{items}[0]{name} =~ /失败/, $feed2->{items}[0]{name});
}

# ---- ③ _alItems 行契约 ----
{
	my @rows = (
		{ id => '960399', name => '魔杰座', singer => '周杰伦', cover => '', count => 11, year => '2008-10-15' },
		{ name => '缺id行' },                                       # ⇒ 跳过（无 id 键）
		{ id => '',       name => '空id行' },                       # ⇒ 跳过
		{ id => '0041WVfh2vtlJE', name => '太阳之子', singer => '周杰伦',
		  cover => 'http://y.gtimg.cn/music/photo_new/T002R180x180M0000041WVfh2vtlJE_1.jpg',
		  count => 13, year => '2026-03-25' },
	);
	my $items = $items_of->('kg', \@rows, 10);
	check('渲染 2 行（跳过缺 id）', scalar @$items == 2, "got " . scalar @$items);
	my ($a) = @$items;
	check('💿 前缀', $a->{name} =~ /^\x{1f4bf}/ || $a->{name} =~ /💿/, substr($a->{name}, 0, 4));
	check('meta 含 首数/歌手/年份', $a->{name} =~ /11首/ && $a->{name} =~ /周杰伦/ && $a->{name} =~ /2008-10-15/,
		$a->{name});
	check('passthrough = albumdetail/src/id/head', $a->{passthrough}[0] eq 'albumdetail'
		&& $a->{passthrough}[1] eq 'kg' && $a->{passthrough}[2] eq '960399'
		&& length($a->{passthrough}[3]) > 0);
	check('playlist = lxm://a/kg/960399', ($a->{playlist} || '') eq 'lxm://a/kg/960399',
		($a->{playlist} || '<none>'));
	# head b64 解码回原字段
	require Plugins::LxMusic::Helper;
	my $dec = eval {
		my $hj = Plugins::LxMusic::Plugin::decode_base64url($a->{passthrough}[3]);
		JSON::XS->new->utf8->decode($hj);
	};
	check('head b64 可解码且含 name/count', $dec && $dec->{name} eq '魔杰座' && $dec->{count} == 11,
		$@ || 'n/a');
	# tx 行：封面走缩略+代理（stub Prefs coverProxy=1；gtimg 是非 mg 主机 ⇒ 代理）
	my ($b) = grep { $_->{passthrough}[2] eq '0041WVfh2vtlJE' } @$items;
	check('tx 行 image 存在且已过缩略参数/代理', $b && $b->{image}
		&& $b->{image} =~ m{^http}, ($b && $b->{image}) || '<none>');
	# 无封面的行不该带 image 键
	check('无封面行无 image 键', !exists $a->{image});
	# 0.11.115 行内原生按钮契约：type=playlist（达菲 gencontrol 的 ▶/＋/♡ 钥匙）
	check('行 type=playlist（原生按钮钥匙）', ($a->{type} || '') eq 'playlist', ($a->{type} || '<none>'));
	check('收藏名 = 干净专辑名（无💿/meta）', ($a->{favorites_title} || '') eq '魔杰座',
		($a->{favorites_title} || '<none>'));
	check('收藏 URL = lxm://a/...（♡ 的钥匙）', ($a->{favorites_url} || '') eq 'lxm://a/kg/960399',
		($a->{favorites_url} || '<none>'));
}

# ---- ③ tx 的 albummid 形 id（含大小写/下划线）可进 lxm://a 正则 ----
{
	my $items = $items_of->('tx', [ { id => '0041WVfh2vtlJE', name => 'x', cover => '' } ], 5);
	check('tx mid 形 id 得到 playlist 链接', ($items->[0]{playlist} || '') eq 'lxm://a/tx/0041WVfh2vtlJE',
		($items->[0]{playlist} || '<none>'));
}

# ---- ④ Helper 侧白名单成对（0.11.113 设备实证教训）----
# shim 的 SDK_ACTIONS 与 Helper.pm 的 **Perl 侧白名单**是两道独立的门：0.11.113 只加了
# shim 侧，探测轮在 Helper 掉进 else 分支回 "source missing" ⇒ 五平台全灭。
{
	my $h = File::Spec->catfile($FindBin::Bin, '..', 'LxMusic', 'Helper.pm');
	open my $fh, '<', $h or die "open Helper.pm: $!";
	local $/; my $src = <$fh>; close $fh;
	check('Helper Perl 白名单含 albumsearch+albumtracks', $src =~ /albumsearch[' ]+[:|][^;]*albumtracks/ || $src =~ /albumsearch.*albumtracks/s);
	check('Helper 常驻 worker 名单含 albumsearch+albumtracks',
		$src =~ /qw\([^)]*albumsearch[^)]*albumtracks[^)]*\)/s
		|| $src =~ /qw\([^)]*albumtracks[^)]*albumsearch[^)]*\)/s);
}

print $failed ? "\nFAILED: $failed\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
