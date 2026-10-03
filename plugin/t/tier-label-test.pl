#!/usr/bin/perl
# tier-label-test.pl — 档位/码率标签推导的回归（A0，2026-09-25 矩阵实测值）
#
# 每一行都是**设备实测**的一格（`tmp/label_matrix.py` 的输出，见 tmp/label_matrix.json）：
#   平台 档位请求 → 实际交付 fmt/kbps/bits + 该平台 types[] 声明 → 我们发布的档位键 → 显示标签
# 覆盖三类历史错法：
#   ① 请求档位当显示值（128kbps 也写 "FLAC 24bit"）—— 0.11.52/0.11.56
#   ② 非梯档被"声明封顶"改成 flac（OGG→flac）—— 0.11.81
#   ③ **声明封顶把量出来的位深也压掉**（kw《晴天》bits=24 却显示 "FLAC"）—— 0.11.84
#
# 纪律：不接受"看起来对了"——每个断言后面都写着是哪一格实测出来的。
#
# 用法：perl plugin/t/tier-label-test.pl
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

my $H = 'Plugins::LxMusic::ProtocolHandler';

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

# 实测矩阵里各平台的 types[] 声明（原样抄自搜索结果）
my @KW  = ({ type => '128k' }, { type => '320k' }, { type => 'flac' });
my @KG  = ({ type => '128k' }, { type => '320k' }, { type => 'flac' }, { type => 'flac24bit' });
my @TX  = ({ type => '128k' }, { type => '320k' }, { type => 'flac' });
my @WY  = ({ type => '128k' }, { type => '320k' }, { type => 'flac' });
my @MG  = ({ type => '128k' }, { type => '320k' }, { type => 'flac' }, { type => 'flac24bit' });

sub tier {
	my ($fmt, $kbps, $bits, $decl, $sr) = @_;
	return $H->_actualTier($fmt, $kbps, $bits, $decl, $sr);
}

sub label { return $H->qualityLabel($_[0], $_[1]) }

# ---------- 1. 位深是量出来的 ⇒ 不受"上游声明"封顶（0.11.84） ----------
{
	# kw《晴天》请求 flac24bit：交付 fLaC、1647kbps、STREAMINFO 说 24bit；kw 只声明到 flac
	my $t = tier('flc', 1647, 24, \@KW);
	check('kw 晴天: flc+1647kbps+bits=24 ⇒ flac24bit（声明只到 flac 也不能压）',
		$t eq 'flac24bit', $t // 'undef');
	check('kw 晴天: 显示标签 = FLAC 24bit', label($t) eq 'FLAC 24bit', label($t));

	# wy《海阔天空》请求 flac24bit：交付 fLaC 1511kbps 24bit；wy 也只声明到 flac
	$t = tier('flc', 1511, 24, \@WY);
	check('wy 海阔天空: flc+1511kbps+bits=24 ⇒ flac24bit', $t eq 'flac24bit', $t // 'undef');
}

# ---------- 2. 位深量到是 16 ⇒ 就算上游声明里有 flac24bit 也只能说 FLAC ----------
{
	# kg《夜空中最亮的星》请求 flac24bit：交付 fLaC 1019kbps **16bit**（kg 声明里有 flac24bit）
	my $t = tier('flc', 1019, 16, \@KG);
	check('kg 夜空中最亮的星: bits=16 ⇒ flac（不信"声明有 24bit"）', $t eq 'flac', $t // 'undef');
	check('kg: 显示标签 = FLAC', label($t) eq 'FLAC', label($t));

	# tx《茶汤》请求 flac24bit：交付 fLaC 943kbps 16bit
	$t = tier('flc', 943, 16, \@TX);
	check('tx 茶汤: bits=16 ⇒ flac', $t eq 'flac', $t // 'undef');
}

# ---------- 3. 没量到位深时才用"码率启发式 + 声明封顶"（0.11.60 行为必须保留） ----------
{
	my $t = tier('flc', 1647, 0, \@KW);
	check('flc 1647kbps 但位深未知 ⇒ 声明封顶到 flac（不吹 24bit）', $t eq 'flac', $t // 'undef');
	$t = tier('flc', 1647, 0, undef);
	check('flc 1647kbps 位深未知且无声明 ⇒ 码率启发式判 flac24bit', $t eq 'flac24bit', $t // 'undef');
	$t = tier('flc', 1032, 0, \@MG);
	check('mg 起风了: 1032kbps 位深未知 ⇒ flac（不进 24bit 启发式）', $t eq 'flac', $t // 'undef');
}

# ---------- 4. mp3 按实测码率就近取标（0.11.58；192k 不再被压成 128k） ----------
{
	check('mp3 320kbps ⇒ 320k / MP3 320kbps', tier('mp3', 320, 0, undef) eq '320k');
	check('mp3 192kbps ⇒ 192k / MP3 192kbps（历史错法①）',
		label(tier('mp3', 192, 0, undef)) eq 'MP3 192kbps', label(tier('mp3', 192, 0, undef)));
	check('mp3 224kbps ⇒ 256k', tier('mp3', 224, 0, undef) eq '256k');
	check('mp3 160kbps ⇒ 192k', tier('mp3', 160, 0, undef) eq '192k');
	check('mp3 128kbps ⇒ 128k', tier('mp3', 128, 0, undef) eq '128k');
	check('mp3 无码率 ⇒ 128k（兜底，不乱标）', tier('mp3', 0, 0, undef) eq '128k');
}

# ---------- 5. 非梯档一律原样（OGG/APE/…，0.11.81 的回归点） ----------
{
	my $t = tier('ogg', 171, 0, \@TX);
	check('ogg 171kbps：不被声明封顶改写成 flac（历史错法②）', $t eq 'OGG', $t // 'undef');
	check('ogg 显示标签 = OGG', label($t) eq 'OGG', label($t));
	check('ape 原样', tier('ape', 800, 0, \@TX) eq 'APE', tier('ape', 800, 0, \@TX));
	check('wav 原样', tier('wav', 1411, 0, \@WY) eq 'WAV', tier('wav', 1411, 0, \@WY));
	# 实测：kg 128k 请求被源降级成 aac 97kbps ⇒ 标签必须是 AAC（不是 MP3 128kbps）
	my $a = tier('mp4', 97, 0, \@KG);
	check('kg 128k 请求实际交付 aac ⇒ aac / AAC', $a eq 'aac' && label($a) eq 'AAC', label($a));
}

# ---------- 6. qualityLabel 幂等 + 档位键全集 ----------
{
	check('幂等：已是人读标签原样返回', label('FLAC 24bit') eq 'FLAC 24bit', label('FLAC 24bit'));
	check('幂等：大写标签不被再 uc', label('MP3 320kbps') eq 'MP3 320kbps', label('MP3 320kbps'));
	check('128k 键 ⇒ MP3 128kbps', label('128k') eq 'MP3 128kbps');
	check('256k 键 ⇒ MP3 256kbps（0.11.58 新增键）', label('256k') eq 'MP3 256kbps');
	check('flac 键 ⇒ FLAC', label('flac') eq 'FLAC');
	check('flac24bit 键 ⇒ FLAC 24bit', label('flac24bit') eq 'FLAC 24bit');
	check('hires 键 ⇒ Hi-Res', label('hires') eq 'Hi-Res');
}

# ---------- 7. 空/异常输入不炸、不返回空标签 ----------
{
	check('空 fmt ⇒ undef', !defined tier('', 320, 0, undef));
	check('undef fmt ⇒ undef', !defined tier(undef, 320, 0, undef));
	check('未知键经 qualityLabel ⇒ 大写原样', label('xyz') eq 'XYZ', label('xyz'));
}

# ---------- 8. 采样率进判定与标签（0.11.99，用户 2026-09-29「96k 与 48k 看不出差别」） ----------
# 实测格（tmp/_gaobai_qiqiu_matrix_20260929.txt / _tier_guard_cross_platform_20260929.txt）：
#   kw 玉宁熙 flac24bit → 2903.2kbps 24bit 96000Hz
#   kw 星海/念心 flac   → 1752.2kbps 24bit 48000Hz
#   tx 玉宁熙 flac24bit → 2315.1kbps **16bit** 44100Hz（堵死"用码率猜 24bit"的那一格）
{
	# 8a 档位键**不变**（方案 B：采样率只细化显示，不改档位集）
	check('8a kw 96k/24bit ⇒ 档位键仍是 flac24bit',
		tier('flc', 2903, 24, undef, 96000) eq 'flac24bit',
		tier('flc', 2903, 24, undef, 96000) // 'undef');
	check('8a kw 48k/24bit ⇒ 档位键同样是 flac24bit',
		tier('flc', 1752, 24, undef, 48000) eq 'flac24bit',
		tier('flc', 1752, 24, undef, 48000) // 'undef');

	# 8b **显示层**能分辨 96k / 48k / 44.1k（这就是用户要的"看得出差别"）
	check('8b 96k/24bit ⇒ 标签 FLAC 24bit/96k',
		label('flac24bit', 96000) eq 'FLAC 24bit/96k', label('flac24bit', 96000));
	check('8b 48k/24bit ⇒ 标签 FLAC 24bit/48k',
		label('flac24bit', 48000) eq 'FLAC 24bit/48k', label('flac24bit', 48000));
	check('8b 88.2k/24bit ⇒ 标签 FLAC 24bit/88.2k',
		label('flac24bit', 88200) eq 'FLAC 24bit/88.2k', label('flac24bit', 88200));
	check('8b flac16/44.1k ⇒ 标签 FLAC/44.1k',
		label('flac', 44100) eq 'FLAC/44.1k', label('flac', 44100));
	check('8b hires/96k ⇒ 标签 Hi-Res/96k',
		label('hires', 96000) eq 'Hi-Res/96k', label('hires', 96000));

	# 8c 采样率未知 ⇒ 标签与 0.11.98 **逐字节相同**（不回归）
	check('8c 无采样率 ⇒ FLAC 24bit（与旧版一致）',
		label('flac24bit', 0) eq 'FLAC 24bit' && label('flac24bit', undef) eq 'FLAC 24bit');
	check('8c 有损档不加采样率后缀（分档依据是码率）',
		label('320k', 44100) eq 'MP3 320kbps' && label('128k', 48000) eq 'MP3 128kbps');

	# 8d **码率兜底陷阱**（用户 2026-09-29 报的那一格）：位深未知 + 采样率已知 ≤48k ⇒ 不吹 24bit
	check('8d 2315kbps + 位深未知 + 44100Hz ⇒ flac（此前会被吹成 flac24bit）',
		tier('flc', 2315, 0, undef, 44100) eq 'flac',
		tier('flc', 2315, 0, undef, 44100) // 'undef');
	check('8d 2315kbps + 位深未知 + 48000Hz ⇒ flac',
		tier('flc', 2315, 0, undef, 48000) eq 'flac',
		tier('flc', 2315, 0, undef, 48000) // 'undef');
	# 保留旧行为：**采样率也未知**（探测没取到实体）时仍可用码率启发式
	check('8d 1647kbps + 位深未知 + 采样率未知 ⇒ flac24bit（旧行为保留）',
		tier('flc', 1647, 0, undef, 0) eq 'flac24bit',
		tier('flc', 1647, 0, undef, 0) // 'undef');
	# 位深量到就是权威，采样率不参与
	check('8d 位深=16 且码率 2315 ⇒ flac（采样率不改变结论）',
		tier('flc', 2315, 16, undef, 96000) eq 'flac',
		tier('flc', 2315, 16, undef, 96000) // 'undef');
}

print $failed ? "\n$failed FAILED\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
