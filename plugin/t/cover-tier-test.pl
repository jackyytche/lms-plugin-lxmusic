#!/usr/bin/perl
# cover-tier-test.pl — 封面档位 + 时长兜底的回归（0.11.72 / 0.11.75 / 0.11.76）
#
# 覆盖三处**用户报过**的缺陷，都在这里钉死：
#   ① 「正在播放」封面发虚：队列/正在播放必须用**大图档**（coverThumbBig=500），
#      列表行仍用列表档（300）。
#   ② mg 榜单曲目页头没有「播放全部/添加」按钮：LMS 用 `itemsHaveAudio`（要求至少一行
#      audio 且 `defined duration`）决定渲不渲染页头按钮，而 mg 那一路的上游 `interval`
#      是 null ⇒ 必须能用 `types[].size ÷ 档位标称码率` 估算出时长。
#   ③ `Helper::coverThumbSize` 被当**方法**调用：首参收到类名字符串 ⇒ `int()` = 0
#      ⇒ 缩略尺寸静默失效（kw 代理目标没有尺寸段、tx 恒 500）。
#
# 用法：perl plugin/t/cover-tier-test.pl
use strict;
use warnings;

use FindBin;
use File::Spec;

use lib File::Spec->catdir($FindBin::Bin);

BEGIN {
	# 与 resolve-parallel-test.pl 同一套加载钩子（zip 平铺结构 + t_build 过期副本取 mtime 新的）
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

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

sub b64url_dec {
	my ($s) = @_;
	$s =~ tr{-_}{+/};
	my $pad = (4 - length($s) % 4) % 4;
	require MIME::Base64;
	return MIME::Base64::decode_base64($s . ('=' x $pad));
}

my $H = 'Plugins::LxMusic::Plugin';

# ---------- 1. coverThumbSize：方法/函数两种调用法都必须给出正确的档位 ----------
{
	check('size: 函数调用默认 -> 300',
		Plugins::LxMusic::Helper::coverThumbSize() == 300,
		Plugins::LxMusic::Helper::coverThumbSize());
	check('size: 函数调用 kind=big -> 500',
		Plugins::LxMusic::Helper::coverThumbSize(undef, 'big') == 500,
		Plugins::LxMusic::Helper::coverThumbSize(undef, 'big'));
	# ↓ 0.11.76 的回归点：这里是**方法**调用，历史上返回 0
	check('size: 方法调用默认 -> 300（曾被类名污染成 0）',
		Plugins::LxMusic::Helper->coverThumbSize() == 300,
		Plugins::LxMusic::Helper->coverThumbSize());
	check('size: 方法调用 kind=big -> 500（曾被类名污染成 0）',
		Plugins::LxMusic::Helper->coverThumbSize(undef, 'big') == 500,
		Plugins::LxMusic::Helper->coverThumbSize(undef, 'big'));
	check('size: 显式像素优先于档位',
		Plugins::LxMusic::Helper->coverThumbSize(240) == 240,
		Plugins::LxMusic::Helper->coverThumbSize(240));
}

# ---------- 2. kw 代理目标里必须带尺寸段（列表 300 / 队列·正在播放 500） ----------
{
	my $t = { source => 'kw', songmid => '641820680' };
	my $list = $H->_coverOf($t);
	my $big  = $H->_coverOf($t, 'big');
	my ($tl) = $list =~ m{/plugins/LxMusic/cover\?u=([^&]+)};
	my ($tb) = $big  =~ m{/plugins/LxMusic/cover\?u=([^&]+)};
	check('kw: 列表档代理目标 = kw:<songmid>:300',
		defined $tl && b64url_dec($tl) eq 'kw:641820680:300',
		defined $tl ? b64url_dec($tl) : 'no proxy url');
	check('kw: 大图档代理目标 = kw:<songmid>:500（正在播放不再发虚）',
		defined $tb && b64url_dec($tb) eq 'kw:641820680:500',
		defined $tb ? b64url_dec($tb) : 'no proxy url');
	check('kw: 两档是不同 URL（图像缓存不会互相污染）', (defined $tl && defined $tb) ? $tl ne $tb : 0);
}

# ---------- 3. 可直取的源：大图档要真的换到尺寸段 ----------
{
	my $wy = 'https://p2.music.126.net/x==/109951168163397768.jpg';
	my $ty = { source => 'wy', img => $wy };
	check('wy: 列表档 300', $H->_coverOf($ty) =~ /param=300y300/, $H->_coverOf($ty));
	check('wy: 大图档 500', $H->_coverOf($ty, 'big') =~ /param=500y500/, $H->_coverOf($ty, 'big'));

	my $tx = { source => 'tx', albumMid => '002iWKlh2DcjFL' };
	check('tx: 列表档 R300x300', $H->_coverOf($tx) =~ /R300x300/, $H->_coverOf($tx));
	check('tx: 大图档 R500x500', $H->_coverOf($tx, 'big') =~ /R500x500/, $H->_coverOf($tx, 'big'));

	# mg：上游 `.webp` 改 `.jpg`（/data/oss/resource/ 实测 .jpg 才是真 JPEG）
	my $mg = { source => 'mg', img => 'https://d.musicapp.migu.cn/data/oss/resource/00/4t/9y/aaa.webp' };
	check('mg: webp -> jpg', $H->_coverOf($mg) =~ /aaa\.jpg$/, $H->_coverOf($mg));
	check('mg: mg 直取（不经我们的代理）',
		$H->_coverOf($mg) !~ m{/plugins/LxMusic/cover}, $H->_coverOf($mg));
}

# ---------- 4. 封面 URL 是否该走插件代理（0.11.72：mg 直取） ----------
{
	check('proxy: migu 域不中转（WebP + 谎报 MIME 的坑）',
		$H->_shouldProxyCover('https://d.musicapp.migu.cn/data/oss/service66/00/2b/35/fx.webp') == 0);
	check('proxy: kw 图床仍中转（需 UA/Referer）',
		$H->_shouldProxyCover('http://img1.kwcdn.kuwo.cn/star/albumcover/500/a.jpg') == 1);
	check('proxy: 非 http 一律不中转', $H->_shouldProxyCover('foo.jpg') == 0);
}

# ---------- 5. 时长：上游给了就用，没给就按 体积÷标称码率 估算（页头按钮的门槛） ----------
{
	check('secs: mm:ss -> 秒', $H->_secsOf({ interval => '04:30' }) == 270,
		$H->_secsOf({ interval => '04:30' }));
	check('secs: hh:mm:ss -> 秒', $H->_secsOf({ interval => '01:02:03' }) == 3723,
		$H->_secsOf({ interval => '01:02:03' }));
	check('secs: 数字串直接当秒', $H->_secsOf({ interval => '199' }) == 199);

	# 现场值：mg 热歌榜首曲（设备端源不给 interval，只有 types[].size）
	my $mg1 = { types => [ { type => '128k', size => '4.12 MiB' },
	                       { type => '320k', size => '10.29 MiB' },
	                       { type => 'flac', size => '30.07 MiB' } ] };
	check('secs: 无 interval 时按 128k 体积估算 = 270s（与上游真实 04:30 吻合）',
		$H->_secsOf($mg1) == 270, $H->_secsOf($mg1));
	my $mg2 = { types => [ { type => '128k', size => '3.41 MiB' } ] };
	check('secs: 第二首估算 223s', $H->_secsOf($mg2) == 223, $H->_secsOf($mg2));

	check('secs: 只有 flac 体积（无标称码率）-> 不硬造',
		!defined $H->_secsOf({ types => [ { type => 'flac', size => '30.07 MiB' } ] }),
		$H->_secsOf({ types => [ { type => 'flac', size => '30.07 MiB' } ] }) // 'undef');
	check('secs: 什么都没有 -> undef', !defined $H->_secsOf({}), 'undef');
	check('secs: 明显不合理的估算被丢弃',
		!defined $H->_secsOf({ types => [ { type => '128k', size => '1 B' } ] }));
}

print $failed ? "\n$failed FAILED\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
