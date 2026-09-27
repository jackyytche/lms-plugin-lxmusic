#!/usr/bin/perl
# publish-dedupe-test.pl — 队列元数据"同内容不重复写库"的回归（0.11.86，待办 C-7）
# 用法：perl plugin/t/publish-dedupe-test.pl
#
# 现场（待办原文）：`explodePlaylist` 整榜入队时对**每一行**调一次 `publishQueueMetadata`，
# 300 首 = 300 次 `setRemoteMetadata`（写库 + 换来一条 playlist 通知），
# 而它排的 +3s **尾部补发**又把这 300 行原样重写一遍 ⇒ 300 首 ≈ 900 次写库
# （`_publish_cover` 先写 cover，再写 title/secs/kbps，最后补发再写一次）。
#
# 0.11.86 的改法：**内容指纹下沉到 `publishQueueMetadata`**（与两条补发路径共用
# `%REPUBLISHED`），并且整榜路径把 cover 与 title/secs/kbps **合并成一次发布**。
#
# 本套件钉死：
#   · 同内容连发两次 → LMS 只被写一次（第二次返回 0）；
#   · 任一字段变化 → 会再写一次（指纹不许把**新信息**吃掉）；
#   · 跳过的那些行**内存记录照旧合并**（封面/时长不能因为不写库就丢）；
#   · 整榜场景：发布一轮之后，尾部补发（republish_known_queued / republish_queued_rows）**零写入**。
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

package main;
use Plugins::LxMusic::ProtocolHandler;

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

my $PH = 'Plugins::LxMusic::ProtocolHandler';
my $U  = 'lxm://m/dedupe1';
my %row = (title => 'A - B', secs => 200, kbps => 320, cover => 'http://img/c.jpg', quality => 'flac');

# ---------- A 同内容不重复写 ----------
Slim::Music::Info::resetForTest();
my $w1 = $PH->publishQueueMetadata($U, { %row });
my $w2 = $PH->publishQueueMetadata($U, { %row });
check('A1 首次发布真的写了 LMS（返回 1）', $w1 ? 1 : 0, $w1 // 'undef');
check('A2 同内容第二次发布**不写**（返回 0）', $w2 ? 0 : 1, $w2 // 'undef');
check('A3 setRemoteMetadata 总共只被调一次', $Slim::Music::Info::CALLS == 1, $Slim::Music::Info::CALLS);

# ---------- B 新信息必须照写（指纹不能把变化吃掉） ----------
Slim::Music::Info::resetForTest();
my $w3 = $PH->publishQueueMetadata($U, { %row, kbps => 1411 });   # 播放后探到真实码率
check('B1 码率变化 ⇒ 再写一次', $w3 ? 1 : 0, $w3 // 'undef');
my $w4 = $PH->publishQueueMetadata($U, { %row, kbps => 1411 });
check('B2 新内容记下后又不写了', !$w4 && $Slim::Music::Info::CALLS == 1, $Slim::Music::Info::CALLS);

Slim::Music::Info::resetForTest();
my $w5 = $PH->publishQueueMetadata($U, { %row, kbps => 1411, cover => 'http://img/big.jpg' });
check('B3 封面变化 ⇒ 再写一次（整榜里 _publish_cover 的封面必须生效）',
	$w5 ? 1 : 0, $w5 // 'undef');

# ---------- C 跳过的行也要合并进 %METADATA（内存态不能丢） ----------
$PH->publishQueueMetadata('lxm://m/dedupe2', { title => 'T2', secs => 111, kbps => 0, cover => '', quality => '320k' });
$PH->publishQueueMetadata('lxm://m/dedupe2', { title => 'T2', secs => 111, kbps => 0, cover => '', quality => '320k' });
my $m2 = $PH->getMetadataFor(undef, 'lxm://m/dedupe2');
check('C1 第二次（未写库）后内存记录仍在', ref($m2) eq 'HASH' && ($m2->{title} // '') eq 'T2',
	ref $m2);
check('C2 内存记录带 secs', (($m2 || {})->{secs} // 0) == 111, ($m2 || {})->{secs} // 'undef');

# ---------- D 整榜场景：发布一轮后，尾部补发零写入 ----------
my @urls = map { "lxm://m/bulk$_" } 1 .. 300;
@Slim::Player::Playlist::PLAYLIST = @urls;
@Slim::Player::Client::CLIENTS    = (bless {}, 'FakeClient');
Slim::Music::Info::resetForTest();
for my $i (0 .. $#urls) {
	# 模拟 explodePlaylist 的"合并成一次发布"
	$PH->publishQueueMetadata($urls[$i], {
		title => "T$i", secs => 200, kbps => 320, cover => "http://img/$i.jpg", quality => 'flac',
	});
}
check('D1 300 行 = 300 次写（合并后每行一次，不再是每行两次）',
	$Slim::Music::Info::CALLS == 300, $Slim::Music::Info::CALLS);

Slim::Music::Info::resetForTest();
my $n = $PH->republish_known_queued();
check('D2 尾部补发对这 300 行**零写入**（指纹命中）', $n == 0 && $Slim::Music::Info::CALLS == 0,
	"n=$n calls=$Slim::Music::Info::CALLS");

# republish_queued_rows 同样受益（feed 路径的补发）
Slim::Music::Info::resetForTest();
my @rows = map { {
	url => $urls[$_], title => "T$_", secs => 200, kbps => 320,
	cover => "http://img/$_.jpg", quality => 'flac',
} } 0 .. $#urls;
my $n2 = $PH->republish_queued_rows(\@rows);
check('D3 feed 路径补发同样零写入', $n2 == 0 && $Slim::Music::Info::CALLS == 0,
	"n=$n2 calls=$Slim::Music::Info::CALLS");

print $failed ? "\n$failed FAILED\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
