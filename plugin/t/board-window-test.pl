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

print "\n" . ($failed ? "FAILED ($failed)\n" : "ALL OK\n");
exit($failed ? 1 : 0);
