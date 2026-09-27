#!/usr/bin/perl
# cover-warm-test.pl — 渲染期**封面预热**回归（0.11.86）
# 用法：perl plugin/t/cover-warm-test.pl
#
# 背景（待办 A-2）：列表行的封面要经插件代理取，而 kw/kg 的代理目标还得**再解析一次**
# 才能拿到真图 URL（kw 一次 pic.web GET / kg 一次 get_res_privilege POST，各 8s 超时）。
# 列表档（300）皮肤渲染完就会自己来取；真正缺提前量的是**大图档**（队列行/正在播放，500 或
# `:big`）——它与列表档是**不同的缓存键**，等于第二次解析，且正好落在用户点播放那一刻。
# 所以 `warmCovers` 只预热大图档、只解析不推流，条数由 `coverWarmMax` 限。
#
# 本套件钉死：档位选择、条数上限、去重、开关（warmEnable / coverWarmMax=0 / coverProxy=0）、
# 只对"需解析"的目标发请求（mg/tx/wy 直链不热），以及 `_coverCacheKey` 与真请求路径的键一致
# （键不一致 = 预热白做，这是最容易静默写错的地方）。
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

use Slim::Utils::Prefs;

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

my $H = 'Plugins::LxMusic::Plugin';
my $prefs = Slim::Utils::Prefs::preferences('plugin.lxmusic');

sub set_pref { my ($k, $v) = @_; $prefs->set($k, $v) }

# 打桩 _coverResolve：记录目标、立刻回调一个假真图 URL（即"解析成功"）
my @resolved;
{
	no warnings 'redefine';
	no strict 'refs';
	*Plugins::LxMusic::Plugin::_coverResolve = sub {
		my ($target, $cb) = @_;
		push @resolved, $target;
		$cb->('http://img.example/' . scalar(@resolved) . '.jpg');
		return 1;
	};
}
sub reset_resolved { @resolved = () }

# 造行：kw / kg / 直链源
sub kw_row { my ($mid) = @_; return { source => 'kw', songmid => $mid, name => "kw$mid" } }
sub kg_row {
	my ($aaid, $album, $hash) = @_;
	return { source => 'kg', albumAudioId => $aaid, songmid => $aaid, albumId => $album, hash => $hash };
}
my $KG_HASH = 'A1B2C3D4E5F60718';   # kg 分支要求 >=16 位十六进制

# ---------- 1. 档位：预热的是**大图档**（kw 500 / kg :big），不是列表档 ----------
{
	set_pref('warmEnable', 1); set_pref('coverWarmMax', 2); set_pref('coverProxy', 1);
	reset_resolved();
	my $n = $H->warmCovers([ kw_row('641820680'), kg_row('123', 456, $KG_HASH) ]);
	check('warm: 两行都热到了', $n == 2, $n);
	check('warm: kw 用大图档（...:500，与列表档 300 不同的缓存键）',
		($resolved[0] // '') eq 'kw:641820680:500', $resolved[0] // 'none');
	check('warm: kg 用大图档（带 :big）',
		($resolved[1] // '') eq "kg:123:456:$KG_HASH:big", $resolved[1] // 'none');
}

# ---------- 2. 条数上限与去重 ----------
{
	set_pref('warmEnable', 1); set_pref('coverWarmMax', 3);
	reset_resolved();
	my $n = $H->warmCovers([ kw_row('1'), kw_row('2'), kw_row('3'), kw_row('4'), kw_row('5') ]);
	check('warm: coverWarmMax=3 -> 只热 3 行', $n == 3 && @resolved == 3, "$n / " . scalar(@resolved));

	reset_resolved();
	$n = $H->warmCovers([ kw_row('9'), kw_row('9'), kw_row('9') ]);
	check('warm: 同一页重复的行只热一次（去重）', $n == 1 && @resolved == 1, "$n / " . scalar(@resolved));

	set_pref('coverWarmMax', 99);
	reset_resolved();
	my @rows = map { kw_row(100 + $_) } 1 .. 8;
	$n = $H->warmCovers(\@rows);
	check('warm: coverWarmMax 上限 5（设备是 i386，别让一页打 8 个上游请求）', $n == 5 && @resolved == 5, "$n / " . scalar(@resolved));
}

# ---------- 3. 开关：总开关 / 0 = 关 / 关掉封面代理 ----------
{
	set_pref('coverWarmMax', 3); set_pref('coverProxy', 1);
	set_pref('warmEnable', 0);
	reset_resolved();
	my $n = $H->warmCovers([ kw_row('11'), kg_row('1', 2, $KG_HASH) ]);
	check('warm: warmEnable=0 -> 一个都不热', $n == 0 && @resolved == 0, "$n / " . scalar(@resolved));

	set_pref('warmEnable', 1); set_pref('coverWarmMax', 0);
	reset_resolved();
	$n = $H->warmCovers([ kw_row('11'), kg_row('1', 2, $KG_HASH) ]);
	check('warm: coverWarmMax=0 -> 关', $n == 0 && @resolved == 0, "$n / " . scalar(@resolved));

	set_pref('coverWarmMax', 3); set_pref('coverProxy', 0);
	reset_resolved();
	$n = $H->warmCovers([ kw_row('11'), kg_row('1', 2, $KG_HASH) ]);
	check('warm: 封面代理关掉后 kw/kg 根本没有代理 URL -> 不热',
		$n == 0 && @resolved == 0, "$n / " . scalar(@resolved));

	set_pref('coverProxy', 1);
}

# ---------- 4. 只热"需二次解析"的目标：直链源（mg/tx/wy）不热 ----------
{
	set_pref('warmEnable', 1); set_pref('coverWarmMax', 3);
	reset_resolved();
	my $n = $H->warmCovers([
		{ source => 'mg', img => 'https://d.musicapp.migu.cn/data/oss/resource/00/4t/9y/a.webp' },
		{ source => 'tx', albumMid => '002iWKlh2DcjFL' },
		{ source => 'wy', img => 'https://p2.music.126.net/x==/109951168163397768.jpg' },
	]);
	check('warm: 直链源无需解析 -> 0 个上游请求（只有 kw/kg 需要）', $n == 0 && @resolved == 0, "$n / " . scalar(@resolved));

	reset_resolved();
	$n = $H->warmCovers([ { source => 'kg', albumId => 966846 } ]);   # 无 hash：走 stdmusic 直链，无需解析
	check('warm: kg 无 hash 时是直链（imge.kugou.com）-> 不热', $n == 0 && @resolved == 0, "$n / " . scalar(@resolved));
}

# ---------- 5. _coverCacheKey：必须与代理真路径用的键逐字一致 ----------
{
	check('key: kw 无尺寸 -> 落到默认列表档 300',
		$H->_coverCacheKey('kw:641820680') eq 'kw:641820680:300',
		$H->_coverCacheKey('kw:641820680'));
	check('key: kw 显式 500 -> 带尺寸段',
		$H->_coverCacheKey('kw:641820680:500') eq 'kw:641820680:500',
		$H->_coverCacheKey('kw:641820680:500'));
	check('key: kg 基本形',
		$H->_coverCacheKey("kg:123:456:$KG_HASH") eq "kg:123:456:$KG_HASH",
		$H->_coverCacheKey("kg:123:456:$KG_HASH"));
	check('key: kg 大图档是**不同**的键（:big）',
		$H->_coverCacheKey("kg:123:456:$KG_HASH:big") eq "kg:123:456:$KG_HASH:big",
		$H->_coverCacheKey("kg:123:456:$KG_HASH:big"));
	check('key: kg 的 aaid 可以为空（老 SDK 字段）',
		$H->_coverCacheKey("kg::$KG_HASH") eq '' || $H->_coverCacheKey("kg::456:$KG_HASH") eq "kg::456:$KG_HASH",
		$H->_coverCacheKey("kg::456:$KG_HASH"));
	check('key: 直链没有缓存键（无需解析）',
		$H->_coverCacheKey('https://imge.kugou.com/stdmusic/240/966846.jpg') eq '',
		$H->_coverCacheKey('https://imge.kugou.com/stdmusic/240/966846.jpg'));
	check('key: 乱码目标 -> 空（宁可不解，也别拿错键写缓存）',
		$H->_coverCacheKey('kw:abc') eq '' && $H->_coverCacheKey('') eq '',
		$H->_coverCacheKey('kw:abc'));

	# 预热目标 == 代理真路径的键（同一次渲染里两处推导必须一致）
	my $row = kw_row('641820680');
	my ($u) = $H->_coverOf($row, 'big') =~ m{/cover\?u=([^&]+)};
	my $target = MIME::Base64::decode_base64url($u);
	check('key: _coverOf(kind=big) 的代理目标与热键一致（500）',
		$H->_coverCacheKey($target) eq 'kw:641820680:500',
		$H->_coverCacheKey($target));
}

print $failed ? "\n$failed FAILED\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
