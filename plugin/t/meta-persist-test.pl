#!/usr/bin/perl
# meta-persist-test.pl — 元数据持久化回归（0.11.91）
# 用法：perl plugin/t/meta-persist-test.pl
#
# 背景（用户 2026-09-27 报）：达菲一重启，**播放队列里的曲目封面就没了**。
# 机制：封面/标签是我们用 `setRemoteMetadata` 发布进 LMS 的，而"我们知道的元数据"只活在内存
# `%METADATA` 里；补发只在"队列变更"时触发，重启本身不触发 ⇒ 重启后队列行退回裸 URL。
# 修法：① 元数据落盘（本套件）② 启动读回 ③ `getMetadataFor` 读 LMS 自己的
# `remote_image_<url>` 缓存兜底（LMS 在 setRemoteMetadata 时已写好，30 天 TTL）。
#
# 本套件钉死的是**"有界"这三个字**（用户的明确要求是"防止无限膨胀"）：
#   TTL 过期要丢、超上限要砍、**队列里的行既不过期也不被砍**、编码后超体积要自动继续缩、
#   关掉开关就真的一个字节都不写、坏文件不能把插件带崩。
#
# ⚠️ 用 `LX_DATA_DIR` 把落盘目录指到临时目录（**不要在真机上跑成写 prefs 目录**）。
use strict;
use warnings;

use FindBin;
use File::Spec;
use File::Path qw(mkpath rmtree);

use lib File::Spec->catdir($FindBin::Bin);

my $TMPDIR = File::Spec->catdir(File::Spec->tmpdir, 'lxmeta-test-' . $$);
mkpath($TMPDIR);
$ENV{LX_DATA_DIR} = $TMPDIR;      # 必须在 Helper::data_dir 被调用前设好

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
}

# 假的 LMS 图片缓存（`Slim::Utils::Cache`）：`getMetadataFor` 的兜底要用它。
# 预置 %INC 让 `require` 变成 no-op —— 本套件不想依赖真的 LMS。
our %FAKE_CACHE;
{
	package Slim::Utils::Cache;
	sub new { return bless {}, shift }
	sub get { my ($self, $k) = @_; return $FAKE_CACHE{$k} }
}
$INC{'Slim/Utils/Cache.pm'} = 1;

require Plugins::LxMusic::ProtocolHandler;

use Slim::Utils::Prefs;

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

my $P    = 'Plugins::LxMusic::ProtocolHandler';
my $prefs = Slim::Utils::Prefs::preferences('plugin.lxmusic');
sub set_pref { my ($k, $v) = @_; $prefs->set($k, $v) }

my $META_FILE = File::Spec->catfile($TMPDIR, 'meta.json');

sub read_json {
	return undef unless -f $META_FILE;
	open(my $fh, '<', $META_FILE) or return undef;
	local $/;
	my $raw = <$fh> // '';
	close $fh;
	require JSON::XS;
	return eval { JSON::XS->new->utf8->decode($raw) };
}

sub url { my ($n) = @_; return "lxm://m/AAA$n?s=kw&t=flac&n=song$n" }

# 干净起步
unlink $META_FILE if -f $META_FILE;
$P->_meta_reset_memory;
set_pref('metaCache', 1);
set_pref('metaCacheMax', 800);
set_pref('metaCacheDays', 30);

# ---------------------------------------------------------------- 1. 写入路径
{
	my $n = $P->meta_save(1);
	check('空缓存 force 保存不写文件（没脏数据就不该落盘）', !$n && !-f $META_FILE, "n=$n");

	$P->cache_metadata(url(1), {
		title => '歌名一', cover => 'https://img.example/1.jpg', quality => 'flac',
		secs => 210, kbps => 1010, samplerate => 44100, samplesize => 16, channels => 2,
	});
	my $ok = $P->meta_save(1);
	check('有脏数据时 force 保存返回真', $ok ? 1 : 0);
	check('落盘文件存在', -f $META_FILE ? 1 : 0);

	my $d = read_json();
	check('落盘 JSON 合法且带版本号', (ref($d) eq 'HASH' && ($d->{v} || 0) >= 1) ? 1 : 0);
	my $row = $d->{rows}{ url(1) };
	check('行里有封面/标题/档位/码率',
		(ref($row) eq 'HASH' && $row->{cover} && $row->{title} && $row->{quality} && $row->{kbps}) ? 1 : 0,
		($row ? join(',', map { "$_=" . ($row->{$_} // '') } sort keys %$row) : 'no row'));
	check('音频属性（采样率/位深/声道）也落盘',
		($row && $row->{samplerate} == 44100 && $row->{samplesize} == 16 && $row->{channels} == 2) ? 1 : 0);
	check('★ 绝不落直链（第三方直链 84 秒~13 分钟就失效，落盘再复用=点了没声）',
		($row && !exists $row->{direct} && !exists $row->{expires}) ? 1 : 0);
	open(my $fh, '<', $META_FILE); local $/; my $raw = <$fh> // ''; close $fh;
	check('文件正文里没有 direct/expires 字样', ($raw !~ /direct|expires/) ? 1 : 0);
	check('保存后脏标记清掉', $P->meta_stats->{dirty} ? 0 : 1);
}

# ---------------------------------------------------------------- 2. 读回
{
	$P->_meta_reset_memory;
	check('重置后内存为空', $P->meta_stats->{rows} == 0 ? 1 : 0);

	my $n = $P->meta_load;
	check('读回 1 行', $n == 1 ? 1 : 0, "n=" . ($n // 'undef'));
	my $st = $P->meta_stats;
	check('内存里 1 条', $st->{rows} == 1 ? 1 : 0);

	my $m = $P->getMetadataFor(undef, url(1));
	check('getMetadataFor 拿回封面', ($m && $m->{cover} && $m->{cover} =~ /1\.jpg$/) ? 1 : 0,
		($m ? join(',', sort keys %$m) : 'empty'));
	check('getMetadataFor 拿回档位标签', ($m && ($m->{type} // '') eq 'FLAC') ? 1 : 0, ($m->{type} // '?'));
	check('getMetadataFor 拿回数字码率的 bitrate', ($m && ($m->{bitrate} // 0) == 1010) ? 1 : 0);
	check('二次 meta_load 是幂等的（不重复灌）', ($P->meta_load == 0) ? 1 : 0);
}

# ---------------------------------------------------------------- 3. TTL / 上限 / 有界
{
	# 直接测纯函数 _meta_select：ttl / budget / protect 三个维度
	my $now = time();
	my $rows = {
		'old'   => { cover => 'c', t => $now - 40 * 86400 },
		'fresh' => { cover => 'c', t => $now - 1 * 86400 },
		'newer' => { cover => 'c', t => $now - 100 },
	};
	my ($sel, $dt, $dc) = $P->_meta_select($rows, {}, 100, 30 * 86400);
	check('TTL：超过 30 天的条目被丢掉', ($dt == 1 && !$sel->{old}) ? 1 : 0, "dt=$dt");
	check('TTL：没过期的留着', ($sel->{fresh} && $sel->{newer}) ? 1 : 0);

	($sel, $dt, $dc) = $P->_meta_select($rows, {}, 100, 0);
	check('ttl=0 表示不按时间淘汰（内存裁剪用它）', ($dt == 0 && scalar(keys %$sel) == 3) ? 1 : 0, "dt=$dt");

	($sel, $dt, $dc) = $P->_meta_select($rows, {}, 2, 30 * 86400);
	check('上限：砍到 2 条', scalar(keys %$sel) == 2 ? 1 : 0, 'kept=' . join(',', sort keys %$sel));
	check('上限：留下的是最近使用的（newer + fresh）', ($sel->{newer} && $sel->{fresh} && !$sel->{old}) ? 1 : 0,
		'kept=' . join(',', sort keys %$sel));

	# protected（在队列里的行）：既不过期、也不被上限砍
	my $prot = { old => 1 };
	($sel, $dt, $dc) = $P->_meta_select($rows, $prot, 1, 30 * 86400);
	check('★ 队列里的行不被 TTL 丢', ($sel->{old} ? 1 : 0), 'kept=' . join(',', sort keys %$sel));
	check('★ 队列里的行优先于上限保留', (scalar(keys %$sel) >= 1 && $sel->{old}) ? 1 : 0,
		'kept=' . join(',', sort keys %$sel));

	# ★ 0.11.92 设备实测的漏洞（单测第一版漏了这一类）：受保护行**多到超过上限**时，
	#   旧算法一行都删不掉（kept = total − budget + P）⇒ 条数上限与体积护栏一起被架空。
	{
		my %r2 = map { ("p$_" => { cover => 'c', t => $now - $_ }) } 1 .. 1000;   # 全部"在队列里"
		my %g2 = map { ("p$_" => 1) } 1 .. 1000;
		my ($s2) = $P->_meta_select(\%r2, \%g2, 800, 30 * 86400);
		check('★ 全部受保护时也不许突破上限（受保护集合先做硬上限）',
			(scalar(keys %$s2) <= 800) ? 1 : 0, 'kept=' . scalar(keys %$s2));

		my %r3 = (%r2, map { ("f$_" => { cover => 'c', t => $now - $_ }) } 1 .. 1000);
		my ($s3, undef, $d3) = $P->_meta_select(\%r3, \%g2, 100, 30 * 86400);
		check('★ 上限是硬上限：1000 受保护 + 1000 普通、budget=100 ⇒ 仍只留 100',
			(scalar(keys %$s3) == 100) ? 1 : 0, 'kept=' . scalar(keys %$s3) . " dropped=$d3");
	}

	# 落到真文件的上限：把上限调小，加更多条目，force 保存后文件里不许超
	$P->_meta_reset_memory;
	unlink $META_FILE if -f $META_FILE;
	set_pref('metaCacheMax', 20);
	for my $i (1 .. 40) { $P->cache_metadata(url($i), { title => "t$i", cover => "https://img.example/$i.jpg" }) }
	$P->meta_save(1);
	my $d = read_json();
	my $kept = ($d && ref($d->{rows}) eq 'HASH') ? scalar(keys %{ $d->{rows} }) : -1;
	check('★ 上限：落盘条数不超过 metaCacheMax', ($kept > 0 && $kept <= 20) ? 1 : 0, "kept=$kept");
	set_pref('metaCacheMax', 800);
}

# ---------------------------------------------------------------- 4. 体积护栏
{
	$P->_meta_reset_memory;
	unlink $META_FILE if -f $META_FILE;
	set_pref('metaCacheMax', 5000);
	my $long = 'https://img.example/' . ('x' x 300) . '.jpg';
	for my $i (1 .. 2000) {
		$P->cache_metadata(sprintf('lxm://m/BIG%04d?s=kw&t=flac', $i), { title => "big$i", cover => $long })
	}
	$P->meta_save(1);
	my $size = -f $META_FILE ? (-s $META_FILE) : -1;
	check('★ 体积护栏：编码超 512KB 时自动继续缩（文件 <= 512KB）',
		($size > 0 && $size <= 512 * 1024) ? 1 : 0, "size=$size");
	my $d = read_json();
	check('体积护栏下文件仍是合法 JSON', (ref($d) eq 'HASH' && ref($d->{rows}) eq 'HASH') ? 1 : 0);
	set_pref('metaCacheMax', 800);
}

# ---------------------------------------------------------------- 5. 开关 / 坏文件 / 清理
{
	$P->_meta_reset_memory;
	unlink $META_FILE if -f $META_FILE;
	set_pref('metaCache', 0);
	$P->cache_metadata(url(9), { title => 'off', cover => 'https://img.example/9.jpg' });
	my $n = $P->meta_save(1);
	check('★ 开关关掉：一个字节都不写（连 force 也不写）', (!$n && !-f $META_FILE) ? 1 : 0, "n=$n");
	check('开关关掉：不置脏标记（不会让定时器空转）', $P->meta_stats->{dirty} ? 0 : 1);
	set_pref('metaCache', 1);

	# 坏文件：不能 die，且要当"没数据"处理
	open(my $fh, '>', $META_FILE) or die $!;
	print $fh "{ this is not json";
	close $fh;
	$P->_meta_reset_memory;
	my $r = eval { $P->meta_load };
	check('坏 JSON 文件：meta_load 不 die 且返回 0', (!$@ && !$r) ? 1 : 0, ($@ || "r=" . ($r // 'undef')));
	check('坏文件后内存仍为空', $P->meta_stats->{rows} == 0 ? 1 : 0);

	# 合法 JSON 但结构不对
	open($fh, '>', $META_FILE) or die $!;
	print $fh '{"v":1,"rows":"nope"}';
	close $fh;
	$P->_meta_reset_memory;
	$r = eval { $P->meta_load };
	check('结构不对（rows 不是 hash）：不 die 且返回 0', (!$@ && !$r) ? 1 : 0, ($@ || "r=" . ($r // 'undef')));

	# 只有"非 lxm://"的脏行
	open($fh, '>', $META_FILE) or die $!;
	print $fh '{"v":1,"rows":{"http://x":{"cover":"http://c/1.jpg","t":' . time() . '}}}';
	close $fh;
	$P->_meta_reset_memory;
	$r = eval { $P->meta_load };
	check('非 lxm:// 的行被跳过（返回 0 行）', (!$@ && !$r) ? 1 : 0, ($@ || "r=" . ($r // 'undef')));

	# 过期行在 load 阶段就被丢掉
	open($fh, '>', $META_FILE) or die $!;
	print $fh '{"v":1,"rows":{"lxm://m/OLD":{'
		. '"cover":"https://img.example/o.jpg","t":' . (time() - 40 * 86400) . '}}}';
	close $fh;
	$P->_meta_reset_memory;
	$r = $P->meta_load;
	check('load 阶段丢掉过期行', (!$r && $P->meta_stats->{rows} == 0) ? 1 : 0, "r=" . ($r // 'undef'));

	# 一键清理
	$P->_meta_reset_memory;
	$P->cache_metadata(url(11), { title => 'x', cover => 'https://img.example/11.jpg' });
	$P->meta_save(1);
	my $cl = $P->meta_clear;
	check('清理：返回清掉的内存条数', (ref($cl) eq 'HASH' && $cl->{rows} == 1) ? 1 : 0);
	check('清理：磁盘文件被删除', (!-f $META_FILE && $cl->{removed}) ? 1 : 0);
	check('清理：内存清零', $P->meta_stats->{rows} == 0 ? 1 : 0);
}

# ---------------------------------------------------------------- 6. LMS 自带封面缓存的兜底
{
	$P->_meta_reset_memory;
	unlink $META_FILE if -f $META_FILE;
	my $u = url(77);
	$FAKE_CACHE{"remote_image_$u"} = 'https://img.example/lms-cached.jpg';

	my $m = $P->getMetadataFor(undef, $u);
	check('★ 内存没有时，从 LMS 的 remote_image_ 缓存取到封面',
		($m && ($m->{cover} // '') =~ /lms-cached/) ? 1 : 0, ($m ? join(',', sort keys %$m) : 'empty'));
	check('兜底命中后回填内存（下次 meta_save 会写进我们自己的文件）',
		($P->meta_stats->{rows} == 1) ? 1 : 0, 'rows=' . $P->meta_stats->{rows});

	# 脏值不许被当成封面 URL 透出去
	my $u2 = url(78);
	$FAKE_CACHE{"remote_image_$u2"} = 'not-a-url';
	my $m2 = $P->getMetadataFor(undef, $u2);
	check('LMS 缓存里不是 URL 的值被拒绝（不透给 UI）',
		(!$m2 || !$m2->{cover}) ? 1 : 0, ($m2 && $m2->{cover} ? $m2->{cover} : 'no cover'));

	# 非 lxm 协议不做这个兜底查询
	$FAKE_CACHE{'remote_image_http://other/x'} = 'https://img.example/nope.jpg';
	my $m3 = $P->getMetadataFor(undef, 'http://other/x');
	check('非 lxm:// 的 url 不走本插件的兜底', (!$m3 || !$m3->{cover}) ? 1 : 0);
}

# ---------------------------------------------------------------- 7. 节流 / 停机强制落盘
{
	$P->_meta_reset_memory;
	unlink $META_FILE if -f $META_FILE;
	set_pref('metaCache', 1);

	# ① 开机后第一发普通保存：不该等满 30 秒窗口（$META_LAST_SAVE 被重置为 0）
	$P->cache_metadata(url(88), { title => 'a', cover => 'https://img.example/88.jpg' });
	my $n1 = $P->meta_save(0);
	check('开机后第一发普通保存会落盘（不用等满节流窗口）', ($n1 && -f $META_FILE) ? 1 : 0, "n=$n1");

	# ② 紧接着再来一发：节流窗口内必须被拦下（设备是闪存，30 秒内不许反复写）
	$P->cache_metadata(url(90), { title => 'b', cover => 'https://img.example/90.jpg' });
	my $n2 = $P->meta_save(0);
	check('★ 节流：窗口内的普通保存被拦下', !$n2 ? 1 : 0, "n=$n2");
	my $d = read_json();
	check('★ 节流：窗口内文件内容确实没变（新条目还没进去）',
		($d && ref($d->{rows}) eq 'HASH' && !$d->{rows}{ url(90) }) ? 1 : 0);

	# ③ force 绕过节流（停机/设置页"立即保存"走这条）
	my $n3 = $P->meta_save(1);
	$d = read_json();
	check('★ force 绕过节流，新条目落盘',
		($n3 && $d && $d->{rows}{ url(90) }) ? 1 : 0, "n=$n3");
}

# ---------------------------------------------------------------- 8. LMS 缓存 TTL 守卫（0.11.92）
# 陷阱（Slim/Utils/DbCache.pm:171-196 的**分支顺序**）：
#   · **裸数字**（`3456000`）→ 只赋值、不补 now；又因为 >2592000 而**不补 now** ⇒ 被当绝对时间戳 ⇒ 一写就过期。
#   · **带单位的字符串**（`'31 days'`）→ 走字符串分支，那里**已经 `time()+N`** ⇒ 安全（这条曾被写反，本轮钉住）。
# 所以规则是"往 LMS 缓存写 TTL 一律经 Helper::lms_cache_expiry"（它把 >30 天换算成绝对时间戳）。
{
	# 复刻 LMS 的 _canonicalize_expiration_time（DbCache.pm:158-197），保真到"相对/绝对"这一段
	my %UNIT = (map(($_ => 1), qw(s second seconds sec)),
		map(($_ => 60), qw(m minute minutes min)),
		map(($_ => 3600), qw(h hour hours)),
		map(($_ => 86400), qw(d day days)),
		map(($_ => 604800), qw(w week weeks)),
		map(($_ => 2592000), qw(M month months)),
		map(($_ => 31536000), qw(y year years)));
	my $canon = sub {
		my ($e) = @_;
		if (lc($e // '') eq 'now') { $e = 0 }
		elsif (lc($e // '') eq 'never') { $e = -1 }
		elsif (($e // '') =~ /^\s*([+-]?(?:\d+|\d*\.\d*))\s*$/) { $e = $1 + 0 }
		elsif (($e // '') =~ /^\s*([+-]?(?:\d+|\d*\.\d*))\s*(\w*)\s*$/ && $UNIT{$2}) { $e = time() + $UNIT{$2} * $1 }
		else { $e = 3600 }
		$e += time() if $e <= 2592000 && $e > -1;
		return $e;
	};
	my $now = time();

	# ① 陷阱只发生在**裸数字**上：把 40 天当成数字传进去 ⇒ 被当绝对时间戳 ⇒ 已过期
	check('★ 陷阱复现：裸数字 40*86400(=3456000) 被 LMS 当成绝对时间戳（=已过期）',
		($canon->(40 * 86400) < $now) ? 1 : 0, 'canon=' . $canon->(40 * 86400) . " now=$now");
	check('★ 陷阱复现：裸数字 2592001（刚过 30 天）同样一写就过期',
		($canon->(2592001) < $now) ? 1 : 0, 'canon=' . $canon->(2592001));

	# ② 反过来钉住"字符串是安全的"——这条 0.11.92 一度写反过，必须由测试守住
	my $c31 = $canon->('31 days');
	check('★ 语义钉死：\'31 days\' 其实是**安全**的（字符串分支已加 now）',
		($c31 > $now && abs($c31 - ($now + 31 * 86400)) <= 3) ? 1 : 0, "canon=$c31");
	check('★ 语义钉死：\'1 year\' 同样安全（别再说它会被当 1970 年）',
		($canon->('1 year') > $now) ? 1 : 0);

	# ③ 边界：2592000（30 天，裸数字）仍是"相对"（因为它不 > 2592000）
	check('边界：裸数字 2592000 仍按相对处理（LMS 会补 now）',
		(abs($canon->(2592000) - ($now + 2592000)) <= 3) ? 1 : 0);

	# ④ 我们的守卫：任何秒数都不许产出"写下去就过期"的值
	my $H = 'Plugins::LxMusic::Helper';
	check('守卫：0 秒 = 立即过期（原样 0）', ($H->lms_cache_expiry(0) == 0) ? 1 : 0);
	check('守卫：30 天以内原样返回（交给 LMS 补 now）',
		($H->lms_cache_expiry(86400) == 86400 && $H->lms_cache_expiry(2592000) == 2592000) ? 1 : 0);
	check('守卫：负秒 = \'never\'（DbCache 存 t=-1 ⇒ 永不过期）',
		(($H->lms_cache_expiry(-1) // '') eq 'never') ? 1 : 0);
	check('守卫：undef 当 0 处理（立即过期，不会变成"永久"）',
		($H->lms_cache_expiry(undef) == 0) ? 1 : 0);
	# ⚠️ 先落成词法变量再断言：`my $x` 写在 check(...) 的实参里，作用域只到那个表达式
	# ⇒ 后面那个实参里的 `$x` 会报 "requires explicit package name"（Helper.pm 里记过同族坑）
	my $e40 = $H->lms_cache_expiry(40 * 86400);
	check('★ 守卫：>30 天返回 absolute epoch（>2592000 且 ≈ now+40d）',
		($e40 > 2592000 && abs($e40 - ($now + 40 * 86400)) <= 3) ? 1 : 0, "e=$e40");

	my $bad = 0;
	for my $s (1, 3600, 86400, 2592000, 2592001, 31 * 86400, 40 * 86400, 365 * 86400) {
		my $c = $canon->($H->lms_cache_expiry($s));
		$bad++ if $c < $now;     # 会被 LMS 判成过期 ⇒ 就是陷阱
	}
	check('★ 守卫：1 秒~365 天任何取值，经 LMS 算法都**不会**变成已过期', $bad == 0 ? 1 : 0, "bad=$bad");

	# ⑤ 写入包装：TTL 一定经守卫、参数顺序正确
	{
		package FakeCache;
		our @CALLS;
		sub new { bless {}, shift }
		sub set { my ($self, $k, $v, $e) = @_; push @CALLS, [$k, $v, $e]; return 1 }
	}
	my $fc = FakeCache->new;
	$H->lms_cache_set($fc, 'k10', 'v', 10 * 86400);
	$H->lms_cache_set($fc, 'k40', 'v', 40 * 86400);
	check('写入包装：调用形状 = set(key, value, expiry)',
		(@FakeCache::CALLS == 2 && $FakeCache::CALLS[0][0] eq 'k10' && $FakeCache::CALLS[0][1] eq 'v') ? 1 : 0);
	check('写入包装：10 天透传相对值 864000', ($FakeCache::CALLS[0][2] == 864000) ? 1 : 0, "e=$FakeCache::CALLS[0][2]");
	check('★ 写入包装：40 天自动换成绝对时间戳（不是裸 3456000）',
		($FakeCache::CALLS[1][2] > 2592000 && $FakeCache::CALLS[1][2] <= time() + 40 * 86400 + 3) ? 1 : 0,
		"e=$FakeCache::CALLS[1][2]");
	check('写入包装：cache 为 undef 时安全返回 0（不 die）', (!$H->lms_cache_set(undef, 'k', 'v', 100)) ? 1 : 0);

	# ⑥ 源码级护栏（**结构不变式**，比"扫 TTL 字面量"可靠）：
	#    除 Helper.pm 外，任何文件都不许直接对 LMS 缓存调 `->set` —— 必须经 Helper::lms_cache_set。
	#    （0.11.92 第一版护栏写成"扫 >30 天的 TTL 字符串"，既基于错误前提、又会命中我自己的注释。）
	my $dir = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..', 'LxMusic'));
	opendir(my $dh, $dir) or die "opendir $dir: $!";
	my @files = grep { /\.pm$/ } readdir($dh);
	closedir $dh;
	my @viol;
	for my $f (@files) {
		next if $f eq 'Helper.pm';      # 守卫本体在这里，它是唯一允许直接 set 的地方
		my $p = File::Spec->catfile($dir, $f);
		open(my $fh, '<', $p) or next;
		local $/; my $src = <$fh> // ''; close $fh;
		for my $line (split /\n/, $src) {
			next if $line =~ /^\s*#/;                                  # 注释里引用 LMS 源码不算（本轮踩过这个假阳性）
			next unless $line =~ /(?:Slim::Utils::Cache|_lms_image_cache|LMS_CACHE)/;
			next unless $line =~ /->set\s*\(/;
			push @viol, $f . ': ' . substr($line, 0, 90);
		}
	}
	check('★ 源码护栏：除 Helper.pm 外无人直接写 LMS 缓存（一律经 Helper::lms_cache_set）',
		!@viol ? 1 : 0, join(' | ', @viol));

	open(my $fh3, '<', File::Spec->catfile($dir, 'Helper.pm')) or die $!;
	local $/; my $hh = <$fh3> // ''; close $fh3;
	check('护栏有靶子：Helper.pm 定义了 lms_cache_expiry + lms_cache_set',
		($hh =~ /sub lms_cache_expiry/ && $hh =~ /sub lms_cache_set/) ? 1 : 0);

	# ⑦ 守卫必须"真有人用"（否则只是死代码，护栏也白立）
	open(my $fh2, '<', File::Spec->catfile($dir, 'ProtocolHandler.pm')) or die $!;
	local $/; my $ph = <$fh2> // ''; close $fh2;
	check('接线：ProtocolHandler 经 Helper::lms_cache_set 写 remote_image_（>30 天路径）',
		($ph =~ /lms_cache_set/) ? 1 : 0);
	check('接线：只在 metaCacheDays != 30 时才多写（默认路径零开销）',
		($ph =~ /meta_ttl_days\s*!=\s*30/) ? 1 : 0);
}

# ---------------------------------------------------------------- 9. 端到端复现设备现场（0.11.92 的护栏被架空）
# 设备实测（2026-09-27）：`meta_save: saved 1342 rows (1375554B)` —— **1.37MB，远超 512KB**。
# 现场成因：那一批行**全都"在队列里"**（`_queued_lxm_urls` 返回了 1342 条）⇒ 旧算法一行都淘汰不掉。
# 这里用桩把"设备/队列"造出来，钉死修复后的行为。
{
	$P->_meta_reset_memory;
	unlink $META_FILE if -f $META_FILE;
	set_pref('metaCacheMax', 800);

	Slim::Player::Client::resetForTest();
	Slim::Player::Playlist::resetForTest();
	push @Slim::Player::Client::CLIENTS, 'fake-client';      # 桩：一个播放器
	my $N = 1342;
	for my $i (1 .. $N) {
		my $u = sprintf('lxm://m/Q%05d?s=kw&t=flac', $i);
		$P->cache_metadata($u, { title => "t$i", cover => "https://img.example/$i.jpg", quality => 'flac' });
		push @Slim::Player::Playlist::PLAYLIST, $u;          # 桩：这批行全都在队列里
	}
	$P->meta_save(1);

	my $size = -f $META_FILE ? (-s $META_FILE) : -1;
	my $d    = read_json();
	my $kept = ($d && ref($d->{rows}) eq 'HASH') ? scalar(keys %{ $d->{rows} }) : -1;
	check('★ 设备现场复现：全部行都在队列里时，落盘条数仍 <= metaCacheMax',
		($kept > 0 && $kept <= 800) ? 1 : 0, "kept=$kept");
	check('★ 设备现场复现：体积护栏仍生效（<=512KB，修前是 1375554B）',
		($size > 0 && $size <= 512 * 1024) ? 1 : 0, "size=$size");
	check('★ 设备现场复现：文件仍是合法 JSON', (ref($d) eq 'HASH') ? 1 : 0);

	Slim::Player::Client::resetForTest();
	Slim::Player::Playlist::resetForTest();
}

# ---------------------------------------------------------------- 10. 空串 pref 不许静默关掉功能（0.11.94）
# 同族坑：`''` 是 **defined** 的。旧写法 `defined $v ? $v : $default` 会把空串原样返回 ⇒
# 布尔项变"关"、数字项变 0。设备实测 `pref_coverWarmMax` 就渲染成 `value=""`。
{
	my $H  = 'Plugins::LxMusic::Helper';
	my $PH = 'Plugins::LxMusic::ProtocolHandler';

	set_pref('workerEnable', '');
	check('空串 pref：workerEnable=\'\' 仍应视为默认"开"（常驻 worker 不被静默关掉）',
		$H->workerEnabled ? 1 : 0);
	set_pref('workerEnable', 1);

	set_pref('resolveTtl', '');
	check('空串 pref：resolveTtl=\'\' 应回落 600（不是 0 ⇒ 缓存出生即过期）',
		(Plugins::LxMusic::ProtocolHandler::_resolveTtl() == 600) ? 1 : 0,
		'ttl=' . Plugins::LxMusic::ProtocolHandler::_resolveTtl());
	set_pref('resolveTtl', 300);
	check('非空设定值仍被尊重（resolveTtl=300）',
		(Plugins::LxMusic::ProtocolHandler::_resolveTtl() == 300) ? 1 : 0,
		'ttl=' . Plugins::LxMusic::ProtocolHandler::_resolveTtl());
	set_pref('resolveTtl', 600);

	# ★ 0.11.95：结构性护栏 —— 模板里出现的每个 `pref_*` 控件，都必须在 Settings.pm 的 `prefs()` 名单里。
	#   不注册就等于**控件是死的**：用户改了、点了保存，后端根本不存（设备实测 `pref_coverWarmMax`
	#   一直是 `value=""`，正是这条漏的）。
	{
		my $root  = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..', '..'));
		my $tpl   = File::Spec->catfile($root, 'plugin', 'LxMusic', 'HTML', 'EN', 'plugins', 'LxMusic', 'settings', 'basic.html');
		my $setpm = File::Spec->catfile($root, 'plugin', 'LxMusic', 'Settings.pm');
		open(my $t1, '<', $tpl) or die "open $tpl: $!";
		local $/; my $th = <$t1> // ''; close $t1;
		open(my $t2, '<', $setpm) or die "open $setpm: $!";
		my $sp = <$t2> // ''; close $t2;
		my ($list) = $sp =~ /sub\s+prefs\s*\{.*?qw\((.*?)\)/s;
		my %reg = map { $_ => 1 } split /\s+/, ($list // '');
		my %seen;
		my @dead;
		while ($th =~ /name="pref_([A-Za-z0-9_]+)"/g) { $seen{$1} = 1 }
		push @dead, $_ for grep { !$reg{$_} } sort keys %seen;
		check('★ 结构护栏：模板里的每个 pref_* 控件都在 Settings::prefs() 里注册（没有"死控件"）',
			!@dead ? 1 : 0, 'unregistered: ' . join(',', @dead));
	}

	# warmCovers 的"空串 ⇒ 默认 3"在 cover-warm-test.pl 里测（那里有 kw/kg 行的桩与 _coverResolve 打桩）
}

# ---------------------------------------------------------------- 收尾
unlink $META_FILE if -f $META_FILE;
rmtree($TMPDIR, { keep_root => 0 });

if ($failed) { print "\n$failed 项失败\n"; exit 1 }
print "\n全部通过\n";
exit 0;
