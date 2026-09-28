#!/usr/bin/perl
# board-window-test.pl — 榜单窗口填充（0.11.83）的回归
#
# 背景（2026-09-25 用户报）：mg 榜单 > 热歌榜，列表显示「2 页 100 首」，
# 点页头「播放全部」后队列里却是 **300 行**（6 页）。设备实测（tmp/board_playall_play_mode_probe.py）：
#   修前 —— mg 100 首 → 队列 300 行（100 首 ×3，stride=100）；wy 200 首 → 队列 300 行（200 唯一）；
#   tx 300 首 → 300 唯一（正常）；kg 43 首 → 43（正常）。
# 根因：页头按钮走的是**枚举本 feed 的全部条目**（LMS 用一个大 quantity 问一次，我们夹到 300），
# 而 `sdkBoardTracksHandler` 的 WINDOW FILLING「按页补到窗口够为止」既**不去重**、也**不看上游 total**。
# 有些平台的上游**不认 page**（mg 的 querycontentbyId 恒回同一页；wy 一次给整榜）⇒
# 同一页被反复追加，凑满 300 才停。
#
# 本测试钉死修复后的两条不变量：
#   ① 跨上游页去重（键序 songmid/hash/id/name）：上游不认 page 时绝不重复追加；
#   ② 上游声明的 total 是硬上界：攒满 total 就不再打下一页。
# 另钉死几个不能回归的边界：页宽重算后去重表要清空、窗口越过榜尾回空页、缺键的行不能被去重吃掉。
#
# 用法：perl plugin/t/board-window-test.pl
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

use Slim::Utils::Prefs;
# 榜单源开关（_boardEnabled 读它；桩的默认值里没有这些键）
# ⚠️ Prefs 桩的 set 只吃**一对** key/value（多给会被静默丢掉）⇒ 必须逐条 set
my $P = Slim::Utils::Prefs::preferences('plugin.lxmusic');
$P->set(boardsMg => 1);
$P->set(boardsKw => 1);
$P->set(boardsTx => 1);
$P->set(boardsKg => 1);   # 0.11.96：TOP500 那组用例走 kg

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

# ---------- 上游替身 ----------
my (@CALLS, $UPSTREAM);

# %o: src / total / perpage / prefix / ignore_page（true = 不认 page，每次都给第一页）
sub make_upstream {
	my (%o) = @_;
	$o{perpage} ||= 100;
	$o{prefix}  ||= 'mg';
	return sub {
		my ($action, $info) = @_;
		return { ok => 0, error => 'wrong action ' . $action } unless $action eq 'boardlist';
		my $page  = $info->{page} || 1;
		my $start = $o{ignore_page} ? 0 : ($page - 1) * $o{perpage};
		my $n     = $o{total} - $start;
		$n = $o{perpage} if $n > $o{perpage};
		$n = 0 if $n < 0;
		my @list;
		if ($o{rows_are}) {                      # 自定义行（边界用例用）
			@list = @{ $o{rows_are} };
		}
		elsif ($n > 0) {
			# interval/singer/source 都要给：缺时长会让 _trackItems 补一条哨兵行，
			# 计数就对不上了（0.11.75 的页头兜底行）
			@list = map {
				{ songmid => sprintf('%s-%d', $o{prefix}, $start + $_), name => 'n' . ($start + $_),
				  singer => 'S', source => ($o{src} || 'mg'), interval => '03:30' }
			} (0 .. $n - 1);
		}
		return { ok => 1, data => { list => \@list, total => $o{total}, limit => $o{perpage},
			info => { name => '榜单', img => 'https://d.musicapp.migu.cn/x.webp' } } };
	};
}

sub run_board {
	my (%o) = @_;
	@CALLS  = ();
	$UPSTREAM = $o{upstream};
	my $feed;
	Plugins::LxMusic::Plugin::sdkBoardTracksHandler(
		undef,
		sub { $feed = $_[0] },
		{ quantity => $o{quantity}, index => ($o{index} || 0) },
		'tracks', ($o{src} || 'mg'), ($o{bangid} || '27186466'), '',
	);
	return $feed;
}

# Helper->request 替身（调用点是 `Plugins::LxMusic::Helper->request(...)` ⇒ 首参是类名）
{
	no warnings 'redefine';
	*Plugins::LxMusic::Helper::request = sub {
		my ($class, %args) = @_;
		my $info = $args{info} || {};
		push @CALLS, { action => $args{action}, page => ($info->{page} || 1), source => $info->{source} };
		my $res = $UPSTREAM->($args{action}, $info);
		$args{cb}->($res);
		return;
	};
}

sub items_of { return @{ (shift)->{items} || [] } }
sub mids_of  { return map { $_->{url} } items_of(shift) }

# ---------- 1. 上游不认 page（mg 形态）：total=100，窗口 300 ⇒ 只能出 100 行、只打 1 次上游 ----------
{
	my $feed = run_board(
		upstream => make_upstream(src => 'mg', total => 100, perpage => 200, ignore_page => 1, prefix => 'mg'),
		quantity => 300, src => 'mg');
	my @it = items_of($feed);
	my %seen;
	$seen{ $_->{name} // '' }++ for @it;
	check('mg 形态：窗口 300 只出 100 行（不再补出重复）', scalar(@it) == 100, scalar(@it));
	check('mg 形态：100 行两两不同', scalar(keys %seen) == 100, scalar(keys %seen));
	check('mg 形态：上游只被问 1 次（攒满 total 即收手）', scalar(@CALLS) == 1, scalar(@CALLS));
	check('mg 形态：feed 的 total 仍是上游值 100', ($feed->{total} || 0) == 100, $feed->{total} // '?');
	check('mg 形态：offset = 0', ($feed->{offset} || 0) == 0, $feed->{offset} // '?');
}

# ---------- 2. 正常分页（kw 形态）：total=300，页宽 100 ⇒ 窗口 300 要 3 页、300 行全唯一 ----------
{
	my $feed = run_board(
		upstream => make_upstream(src => 'kw', total => 300, perpage => 100, prefix => 'kw'),
		quantity => 300, src => 'kw');
	my @it = items_of($feed);
	my %mid;
	for my $it (@it) {
		my $u = $it->{url} || '';
		$mid{$u}++;
	}
	check('kw 形态：窗口 300 出 300 行', scalar(@it) == 300, scalar(@it));
	check('kw 形态：300 行两两不同', scalar(keys %mid) == 300, scalar(keys %mid));
	check('kw 形态：正好问上游 3 次', scalar(@CALLS) == 3, scalar(@CALLS));
	check('kw 形态：页码依次 1/2/3', join(',', map { $_->{page} } @CALLS) eq '1,2,3',
		join(',', map { $_->{page} } @CALLS));
}

# ---------- 3. 原生翻页：窗口 [50,100) 只问第 2 页，offset=50 ----------
{
	my $feed = run_board(
		upstream => make_upstream(src => 'kw', total => 300, perpage => 100, prefix => 'kw'),
		quantity => 50, index => 50, src => 'kw');
	my @it = items_of($feed);
	check('翻页：窗口 50 出 50 行', scalar(@it) == 50, scalar(@it));
	# kw 默认页宽 100 ⇒ 窗口 [50,100) 落在上游第 1 页里，取第 1 页再切片即可
	check('翻页：只问 1 次上游，且是第 1 页', scalar(@CALLS) == 1 && $CALLS[0]{page} == 1,
		join(',', map { $_->{page} } @CALLS));
	check('翻页：offset = 50', ($feed->{offset} || 0) == 50, $feed->{offset} // '?');
	check('翻页：total = 300', ($feed->{total} || 0) == 300, $feed->{total} // '?');
	check('翻页：首行编号 051（跨页连续）', index($it[0]{name} // '', '051') >= 0, $it[0]{name} // '?');
}

# ---------- 4. 窗口整体越过榜尾 ⇒ 空页（不是"获取失败"提示行）----------
{
	my $feed = run_board(
		upstream => make_upstream(src => 'kw', total => 300, perpage => 100, prefix => 'kw'),
		quantity => 50, index => 500, src => 'kw');
	my @it = items_of($feed);
	check('越过榜尾：items 为空', scalar(@it) == 0, scalar(@it));
	check('越过榜尾：不是 text 提示行', !(@it && ($it[0]{type} // '') eq 'text'),
		@it ? ($it[0]{type} // '?') : '-');
}

# ---------- 5. 去重只认键：同名不同 songmid 的两行都要留 ----------
{
	my $rows = [
		{ songmid => 'A1', source => 'mg', name => '同名歌', interval => '03:30' },
		{ songmid => 'A2', source => 'mg', name => '同名歌', interval => '03:30' },
	];
	my $feed = run_board(
		upstream => make_upstream(src => 'mg', total => 2, perpage => 200, rows_are => $rows),
		quantity => 50, src => 'mg');
	check('同名不同 songmid：两行都保留', scalar(items_of($feed)) == 2, scalar(items_of($feed)));
}

# ---------- 6. 缺键的行照留（去重是"防重复"，不是"防新"）----------
{
	my $rows = [ { source => 'mg', name => '无键一', interval => '03:30' },
	             { source => 'mg', name => '无键二', interval => '03:30' } ];
	my $feed = run_board(
		upstream => make_upstream(src => 'mg', total => 2, perpage => 200, rows_are => $rows),
		quantity => 50, src => 'mg');
	check('缺 songmid/hash/id 的行不被去重吃掉', scalar(items_of($feed)) == 2, scalar(items_of($feed)));
}

# ---------- 7. 不认 page 且 total 虚高：第二页全重复 ⇒ $added==0 立即收手（不再白打第 3 页）----------
#    （perpage 取 200 = mg 的默认页宽，避免触发页宽重算那一跳，专心测"重复即收手"）
{
	my $rows = [ map { { songmid => 'fixed-' . $_, source => 'mg', name => 'f' . $_, interval => '03:30' } } (1 .. 100) ];
	my $feed = run_board(
		upstream => make_upstream(src => 'mg', total => 250, perpage => 200, ignore_page => 1, rows_are => $rows),
		quantity => 300, src => 'mg');
	check('total 虚高：不重复追加（仍是 100 行）', scalar(items_of($feed)) == 100, scalar(items_of($feed)));
	check('total 虚高：第二页发现全重复后收手（共 2 次）', scalar(@CALLS) == 2, scalar(@CALLS));
}

# ---------- 8. 页宽重算（retune）不能把去重表留脏：limit≠默认页宽时重取仍要出满 ----------
#    mg 默认页宽表是 200；这里让上游报 limit=100 ⇒ 触发 retune 分支（清 acc 必须同时清去重表，
#    否则重取回来的同一批行会被判成"已见"，页头会退化成「获取失败」——0.11.83 第一版的坑）
{
	my $feed = run_board(
		upstream => make_upstream(src => 'mg', total => 100, perpage => 100, ignore_page => 1, prefix => 'mg'),
		quantity => 300, src => 'mg');
	my @it = items_of($feed);
	check('retune 后仍出满 100 行（去重表已随 acc 一起清空）', scalar(@it) == 100, scalar(@it));
	check('retune 后不是"获取失败"提示行', !(@it && ($it[0]{type} // '') eq 'text'),
		@it ? ($it[0]{type} // '?') : '-');
}

# ---------- 9. 0.11.96：窗口上限 300 → 1000（修「TOP500 播放全部只进 300 首」）----------
# 现场（用户 2026-09-27）：入口「kg榜单 > TOP500」列表显示 10 页 500 首，
# 点页头「播放全部」后队列**只有 6 页 300 首**。设备实测（tmp/board_playall_play_mode_probe.py
# kg 8888 --ui 3.0）两条路都给 **300 行、unique songmid=300、multiplier=1.0**
# ⇒ 不是 0.11.83 那种"重复追加"，是**真被夹断**（页头按钮的 quantity 由 LMS 给，
# 设备实测 maxPlaylistLength=2500，被 handler 顶部的 clamp 夹成 300）。
# 这一组就是那个 bug 的**反例钉**：窗口给得比 300 大时必须真的取满。
{
	my $feed = run_board(
		upstream => make_upstream(src => 'kg', total => 500, perpage => 100, prefix => 'kg'),
		quantity => 2500, src => 'kg');        # 设备实测 LMS 在 playall 时传的就是这个量级
	my @it = items_of($feed);
	my %u;
	$u{ $_->{url} // '' }++ for @it;
	check('[0.11.96] TOP500 形态：窗口 2500 必须出满 500 行（不再被夹到 300）',
		scalar(@it) == 500, scalar(@it));
	check('[0.11.96] TOP500 形态：500 行两两不同（不是重复追加）',
		scalar(keys %u) == 500, scalar(keys %u));
	check('[0.11.96] TOP500 形态：正好问上游 5 页（100/页 ×5 = 500）',
		scalar(@CALLS) == 5, scalar(@CALLS));
	check('[0.11.96] TOP500 形态：页码依次 1..5',
		join(',', map { $_->{page} } @CALLS) eq '1,2,3,4,5',
		join(',', map { $_->{page} } @CALLS));
	check('[0.11.96] TOP500 形态：feed 的 total 仍是上游值 500',
		($feed->{total} || 0) == 500, $feed->{total} // '?');
	check('[0.11.96] TOP500 形态：末行编号 500（绝对序号跨页连续）',
		index($it[-1]{name} // '', '500') >= 0, $it[-1]{name} // '?');
}

# ---------- 10. 新上限仍**有界**：上游远超 1000 时不许无限扇出，且不多打一次 ----------
#    多打的那一次是"取到 1000 后 FOR 循环还会再问一页"的经典 off-by-one。
{
	my $feed = run_board(
		upstream => make_upstream(src => 'kg', total => 5000, perpage => 100, prefix => 'kg'),
		quantity => 2500, src => 'kg');
	my @it = items_of($feed);
	check('[0.11.96] 有界：上游 5000 首时最多出 1000 行', scalar(@it) == 1000, scalar(@it));
	check('[0.11.96] 有界：正好 10 页，不多白打第 11 页',
		scalar(@CALLS) == 10, scalar(@CALLS));
}

# ---------- 11. 页宽重算那条路的页数上限也要放宽（否则 1000 会被 8 页夹成 800）----------
#    kg 默认页宽是 100；让上游报 limit=50 ⇒ 触发 retune，且 50 是既非 100 也非默认的值。
#    期望：仍然出满 1000 行（不是 8 页 ×50 = 400）。
{
	my %row_of;
	my $dynamic = sub {
		my ($action, $info) = @_;
		my $page = $info->{page} || 1;
		my $per  = 50;
		my $start = ($page - 1) * $per;
		my $n = 5000 - $start;
		$n = $per if $n > $per;
		$n = 0 if $n < 0;
		my @list = map {
			{ songmid => sprintf('kg-%d', $start + $_), name => 'n' . ($start + $_),
			  singer => 'S', source => 'kg', interval => '03:30' }
		} (0 .. ($n > 0 ? $n - 1 : -1));
		return { ok => 1, data => { list => \@list, total => 5000, limit => $per,
			info => { name => '榜单', img => '' } } };
	};
	@CALLS = ();
	$UPSTREAM = $dynamic;
	my $feed;
	Plugins::LxMusic::Plugin::sdkBoardTracksHandler(
		undef, sub { $feed = $_[0] }, { quantity => 2500, index => 0 }, 'tracks', 'kg', '8888', '');
	my @it = items_of($feed);
	check('[0.11.96] retune 路：页宽 50 时也要出满 1000 行（页数上限已同步放宽）',
		scalar(@it) == 1000, scalar(@it));
}

# ---------- 12. 源码级护栏：两条路的截断点必须**成组**放开 ----------
#    （本项目既有惯例：行为层不好构造的用源码级断言钉住写法）
{
	my $root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
	my $plug = do { local (@ARGV, $/) = (File::Spec->catfile($root, 'LxMusic', 'Plugin.pm')); <> };
	my $ph   = do { local (@ARGV, $/) = (File::Spec->catfile($root, 'LxMusic', 'ProtocolHandler.pm')); <> };
	check('[0.11.96] 护栏：handler 窗口夹取为 1000（不再是 300）',
		defined $plug && $plug =~ /\$window\s*=\s*1000\s+if\s+\$window\s*>\s*1000/,
		'找不到 $window = 1000 if $window > 1000');
	check('[0.11.96] 护栏：handler 页数上限为 24（不再是 8）',
		defined $plug && $plug !~ /\$max_pages\s*=\s*8\s+if\s+\$max_pages\s*>\s*8/
			&& $plug =~ /\$max_pages\s*=\s*24\s+if\s+\$max_pages\s*>\s*24/,
		'页数上限没跟着放开');
	check('[0.11.96] 护栏：explodePlaylist 的 $CAP = 1000（与 handler 同口径）',
		defined $ph && $ph =~ /my\s+\$CAP\s*=\s*1000;/,
		'explodePlaylist 的 CAP 没放开');
	check('[0.11.96] 护栏：explodePlaylist 的 $MAXPAGE 已放到 24',
		defined $ph && $ph =~ /my\s+\$MAXPAGE\s*=\s*24;/,
		'explodePlaylist 的 MAXPAGE 没放开（页宽 100 时会是 400 行的新截断点）');
}

print "\n" . ($failed ? "FAILED ($failed)\n" : "ALL OK\n");
exit($failed ? 1 : 0);
