#!/usr/bin/perl
# pl-detail-head-test.pl — 歌单详情页头数据"随链接带下去"的回归（0.11.86，待办 B-5）
# 用法：perl plugin/t/pl-detail-head-test.pl
#
# 背景（实测，`tmp/sdk_endpoint_size.py` + mg A/B）：
#   mg 的歌单详情要打两跳——歌曲页 81KB/约 0.4s，外加一跳 `resource/playlist/v2.0`
#   只有 **2.2KB 却要 886~1354ms**，而且它只提供 name/img/desc/author/play_count，
#   这些**列表行里全都有**。0.11.86 起：列表行把这些随下钻链接带下去（base64），
#   插件据此让 mg 走 lean 路径（只打歌曲页），页头用带下来的数据渲染。
#
# 本套件钉死：
#   · `_plItems` 确实把头部数据（name/img/author/count）编进 passthrough；
#   · 有头部数据时对 mg 发 `lean=1`；没有（旧链接/上游没有名字）时不发（行为不变）；
#   · lean 响应**没有 info** 时，页头仍要有 名字/作者/首数/封面（回退到带下来的数据）；
#   · 上游 info 存在时**上游优先**（带下来的数据不许盖掉权威值）；
#   · 非 mg 平台不传 lean（kg 有自己的默认快路径，kw/tx/wy 无此接口）。
use strict;
use warnings;

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

use MIME::Base64 ();
use Encode ();

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

my $P = 'Plugins::LxMusic::Plugin';

# ---------- 1. _plItems 必须把头部数据编进 passthrough ----------
my $mg_row = {
	source => 'mg', id => '234431051', name => '好想好想',
	author => '小编', total => 111,
	img    => 'https://d.musicapp.migu.cn/data/oss/resource/00/aa/bb/cover.webp',
};
my $items = Plugins::LxMusic::Plugin::_plItems('mg', [ $mg_row ], 30);
check('_plItems 产出一行', @$items == 1, scalar @$items);
my @pt = @{ $items->[0]{passthrough} || [] };
check('passthrough = [songlistdetail, src, id, head]', @pt == 4 && $pt[0] eq 'songlistdetail' && $pt[1] eq 'mg',
	join(',', @pt));
check('行上带整单 playlist 链接（不受影响）',
	(($items->[0]{playlist} // '') eq 'lxm://l/mg/234431051'), $items->[0]{playlist} // 'undef');

my $head = {};
if (@pt == 4) {
	my $j = eval { Plugins::LxMusic::Plugin::decode_base64url($pt[3]) };
	$head = $j ? (eval { JSON::XS->new->utf8->decode($j) } || {}) : {};
}
check('头部数据可解码且带 name',    (($head->{name} // '') eq '好想好想'), $head->{name} // 'undef');
check('头部数据带 author',          (($head->{author} // '') eq '小编'), $head->{author} // 'undef');
check('头部数据带 count',           (($head->{count} // 0) == 111), $head->{count} // 'undef');
check('头部数据的 img 是**已处理过**的 URL（缩略/代理，不是原图）',
	($head->{img} // '') eq $items->[0]{image}, ($head->{img} // 'undef') . ' vs ' . ($items->[0]{image} // 'undef'));

my $headB64 = $pt[3] // '';
my $emptyHead = Plugins::LxMusic::Plugin::encode_base64url('{}');

# ---------- 2. 请求参数：有头部数据 ⇒ mg 带 lean=1 ----------
my @req;
sub run_detail {
	my (%a) = @_;
	@req = ();
	my @feed;
	Plugins::LxMusic::Plugin::sdkSonglistDetailHandler(
		undef, sub { push @feed, $_[0] }, { index => 0, quantity => 50 }, undef,
		$a{src} || 'mg', $a{id} || '234431051', $a{head});
	return \@feed;
}
{
	no warnings 'redefine';
	no strict 'refs';
	*Plugins::LxMusic::Helper::request = sub {
		my ($class, %a) = @_;
		push @req, \%a;
		my %data = (list => [ map { { source => 'mg', songmid => "s$_", name => "歌$_", singer => 'A' } } 1 .. 5 ],
			limit => 50, total => 111);
		# 0.11.87（B-6）：真实上游**会回显我们请求的 rn**（实测 kw `rn=20/50/100/1000` 全部回显），
		# 所以桩也照此回显 —— 这样"首猜页宽 == 响应的 limit ⇒ 不再重取"这条断言才有意义。
		$data{limit} = $a{info}{rn} if $a{info}{rn};
		$data{info} = { name => '上游名', author => '上游作者', img => 'https://up.example/c.jpg', count => 999 }
			if $a{action} eq 'songlistdetail' && !$a{info}{lean};
		$a{cb}->({ ok => 1, data => \%data, ms => 12 });
		return 1;
	};
}

my $feed = run_detail(head => $headB64);
my $info = ($req[0] || {})->{info} || {};
check('mg + 有头部数据 ⇒ 请求带 lean=1', ($info->{lean} // 0) == 1, $info->{lean} // 'undef');
check('请求参数仍是 source/id/page', ($info->{source} // '') eq 'mg' && ($info->{id} // '') eq '234431051'
	&& ($info->{page} // 0) == 1);
check('lean 响应（无 info）时页头用带下来的 name',
	join('|', map { $_->{name} } @{ $feed->[0]{albumData} }) =~ /好想好想/,
	join('|', map { $_->{name} } @{ $feed->[0]{albumData} }));
check('lean 响应时页头带 author 与首数（111）',
	$feed->[0]{albumData}[1]{name} =~ /小编/ && $feed->[0]{albumData}[1]{name} =~ /111/,
	$feed->[0]{albumData}[1]{name});
check('lean 响应时封面来自列表行那份（已缩略/代理）',
	($feed->[0]{image} // '') eq $head->{img}, $feed->[0]{image} // 'undef');
check('lean 响应时 total = 上游 total（111）', ($feed->[0]{total} // 0) == 111, $feed->[0]{total} // 'undef');

# ---------- 3. 上游 info 优先（权威值不许被带下来的数据盖掉） ----------
@req = ();
# 换 id：详情 feed 有 120s 缓存（`pd|<src>|<id>|<index>`），同 id 第二次会直接命中缓存
$feed = run_detail(id => '999000111', head => $emptyHead);   # 没有头部数据 ⇒ 不发 lean ⇒ 上游给 info
check('无头部数据 ⇒ 不发 lean（行为与从前一致）', !($req[0]{info}{lean}), $req[0]{info}{lean} // 'undef');
# ⚠️ 中文比较必须两边同旗标：`_u()` 返回的是**字符**串，而本文件里的中文字面量是
# **未打旗标的 UTF-8 字节**（§5.3.19 同族坑）⇒ 直接用 `/上游名/` 匹配字符串会假失败。
my $UP_NAME = Encode::decode('UTF-8', '上游名');
my $UP_AUTH = Encode::decode('UTF-8', '上游作者');
check('上游 info 的 name/author/count 优先',
	$feed->[0]{albumData}[0]{name} =~ /$UP_NAME/ && $feed->[0]{albumData}[1]{name} =~ /$UP_AUTH/
	&& ($feed->[0]{total} // 0) == 999,
	$feed->[0]{albumData}[0]{name} . ' / ' . $feed->[0]{albumData}[1]{name} . ' / ' . ($feed->[0]{total} // '?'));

# ---------- 4. 非 mg 平台不传 lean ----------
@req = ();
run_detail(src => 'kw', id => '3677105457', head => $headB64);
check('kw 不传 lean（只有 mg 走这个接口）', !($req[0]{info}{lean}), $req[0]{info}{lean} // 'undef');
@req = ();
run_detail(src => 'mg', id => '555000222', head => $headB64);   # 同样换 id 避开缓存
check('对照：同一份头部数据在 mg 上就是 lean=1', ($req[0]{info}{lean} // 0) == 1);

# ---------- 5. kw 详情「按窗取数」（0.11.87，待办 B-6） ----------
# 实测依据（`tmp/kw_detail_probe.py` 直打上游 + `tmp/kw_detail_ab.py` 设备对照）：
#   · kw 详情接口 nplserver **认 rn/pn**（rn=50&pn=1 = 第 51-100 首，逐首不同；字节随行数线性）；
#   · vendored SDK 的 `limit_song = 1000` ⇒ 一次把整单拉回来（205 首 = 621356B）；
#   · "页宽猜 50、真页宽 1000" ⇒ index>0 时**先白打一次空页**（`pn=3&rn=1000` = 616B/100ms）再重取整单
#     （现场 idx=150：shim_ms=1334 / 整页 1863ms）。
# 本段钉死：kw 必须把"这一窗要几行"当 `rn` 传下去、**用它当上游页宽首猜**、并且**只打一次上游**。
sub kw_req {
	my (%a) = @_;
	@req = ();
	my @feed;
	Plugins::LxMusic::Plugin::sdkSonglistDetailHandler(
		undef, sub { push @feed, $_[0] }, { index => $a{index}, quantity => $a{qty} }, undef,
		$a{src} || 'kw', $a{id}, $a{head});
	return (\@req, \@feed);
}

my ($r1) = kw_req(index => 0, qty => 50, id => 'kw0001');
check('kw window=50 ⇒ 请求带 rn=50（把"要几行"告诉上游）', (($r1->[0]{info}{rn} // 0) == 50),
	$r1->[0]{info}{rn} // 'undef');
check('kw window=50 ⇒ page=1', (($r1->[0]{info}{page} // 0) == 1), $r1->[0]{info}{page} // 'undef');
check('kw：limit 与首猜页宽一致 ⇒ **只打一次上游**', @$r1 == 1, scalar @$r1);

# ⚠️ 这条是修复的核心：index=150、window=50 ⇒ 页宽=rn=50 ⇒ page=4/skip=0，
# 上游那一页（150-199）正好就是窗口 ⇒ 不该有第二次请求（从前会先打空页再重取整单）。
my ($r2) = kw_req(index => 150, qty => 50, id => 'kw0002');
check('kw idx=150 window=50 ⇒ page=4（rn 当页宽）', (($r2->[0]{info}{page} // 0) == 4), $r2->[0]{info}{page} // 'undef');
check('kw idx=150 ⇒ 仍然**只打一次上游**（消掉了那次空页往返）', @$r2 == 1, scalar @$r2);

# 窗口宽于旧默认 50 时，页宽必须跟着 rn 走（而不是仍按 50 猜出 page=3）
my ($r3) = kw_req(index => 100, qty => 300, id => 'kw0003');
check('kw window=300 idx=100 ⇒ rn=300', (($r3->[0]{info}{rn} // 0) == 300), $r3->[0]{info}{rn} // 'undef');
check('kw window=300 idx=100 ⇒ page=1（页宽=300，不是 50 猜出的 3）',
	(($r3->[0]{info}{page} // 0) == 1), $r3->[0]{info}{page} // 'undef');
check('kw window=300 ⇒ 只打一次上游', @$r3 == 1, scalar @$r3);

# window=1 = "点单行"的形态（多数被 _feed_cache_cover 命中）：下界 20 行，别抠到只取 1 行
my ($r4) = kw_req(index => 7, qty => 1, id => 'kw0004');
check('kw window=1 ⇒ rn 取**下界 20**（不抠成 1 行）', (($r4->[0]{info}{rn} // 0) == 20), $r4->[0]{info}{rn} // 'undef');
check('kw window=1 ⇒ page 按 20 行算（idx=7 ⇒ 第 1 页）', (($r4->[0]{info}{page} // 0) == 1), $r4->[0]{info}{page} // 'undef');

# 非 kw 平台必须**完全不受影响**：不带 rn、页宽仍按 50 猜（否则会动到 kg/tx/wy/mg 的既有行为）
my ($r5) = kw_req(src => 'tx', index => 100, qty => 300, id => 'tx0001');
check('非 kw（tx）⇒ info 里**没有** rn 键', !exists $r5->[0]{info}{rn}, join(',', sort keys %{ $r5->[0]{info} }));
check('非 kw（tx）⇒ 页宽仍按 50 猜（idx=100 ⇒ page=3）', (($r5->[0]{info}{page} // 0) == 3), $r5->[0]{info}{page} // 'undef');

print $failed ? "\n$failed FAILED\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
