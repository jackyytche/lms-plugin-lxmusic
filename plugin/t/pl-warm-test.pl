#!/usr/bin/perl
# pl-warm-test.pl — 歌单树"进平台就并行预热下一层"的回归（0.11.86，待办 B-4）
# 用法：perl plugin/t/pl-warm-test.pl
#
# 现场：歌单是四层下钻（平台 → 排序 tab → 分类标签 → 列表），每层都要等一次上游，
# 用户体感的"mg 加载慢"就是逐层叠加出来的（实测单层 pl-list 604ms / pl-detail 893ms）。
# 0.11.86 起：进入某平台时立刻并发发两件事——① 分类标签（只吃 source，不必等排序）；
# ② 默认排序 × 全部标签 × 第 1 页列表（排序一到手就发）。两者都是 `bg` 优先级
# （Helper 忙就丢弃，绝不跟用户抢 worker），结果写进与前台**同一套**缓存。
#
# 这个套件钉死：
#   · 发的是哪两个请求、参数对不对（sortId=第一个排序、tagId=''、page=1）；
#   · **必须是 bg**（否则会重现 0.11.58 的"预热把用户挤在后面"）；
#   · 标签请求**先于**排序请求（"并行"的定义：标签不等排序）；
#   · 第二次进同一平台：两样都在缓存里 ⇒ 一个上游请求都不发（幂等）。
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

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

my @req;
{
	no warnings 'redefine';
	no strict 'refs';
	*Plugins::LxMusic::Helper::request = sub {
		my ($class, %a) = @_;
		push @req, \%a;
		# 全部同步回调：让测试能在一次调用里看到完整的连锁反应
		if ($a{action} eq 'songlistsorts') {
			$a{cb}->({ ok => 1, data => { sorts => [
				{ name => '热歌', id => 'hot' }, { name => '新歌', id => 'new' },
			] } });
		}
		elsif ($a{action} eq 'songlisttags') {
			$a{cb}->({ ok => 1, data => {
				tags   => [ { name => '流行', id => 'pop' }, { name => '摇滚', id => 'rock' } ],
				hotTag => [ { name => '热门', id => 'hot' } ],
			} });
		}
		elsif ($a{action} eq 'songlistbytag') {
			# limit=30 与 `_pl_list_fetch` 的初始猜测一致 ⇒ 不触发"页宽校正"二次取数
			# （真实的 kw/kg/tx 页宽各不相同，那一路已有 0.11.33 的回归覆盖）
			$a{cb}->({ ok => 1, data => {
				limit => 30, total => 1000,
				list  => [ map { { id => "pl$_", name => "歌单$_", img => '' } } 1 .. 20 ],
			}, ms => 12 });
		}
		return 1;
	};
}

my $P = 'Plugins::LxMusic::Plugin';
my @feed;
Plugins::LxMusic::Plugin::sdkPlSortsHandler(undef, sub { push @feed, $_[0] }, {}, undef, 'kg');

my @actions = map { $_->{action} } @req;
check('进平台：发出了 标签 + 排序 + 第一页列表 三个上游请求',
	join(',', @actions) eq 'songlisttags,songlistsorts,songlistbytag',
	join(',', @actions));
check('并行：分类标签**先于**排序发出（标签不吃排序，不必等）',
	($actions[0] // '') eq 'songlisttags', join(',', @actions));

my ($tags) = grep { $_->{action} eq 'songlisttags' } @req;
# ⚠️ 取值先落成词法变量：`!defined ($h || {})->{k}` 会被 Perl 解析成
# `(defined($h || {}))->{k}`（defined 是具名一元运算符，优先级高于 `->`）
# ⇒ 拿 1 当哈希解引用直接炸。这里一律先 `my $info = ... || {}`。
my $tinfo = ($tags || {})->{info} || {};
check('标签请求带 bg 优先级（忙则被 Helper 丢弃，不跟用户抢 worker）',
	(($tags || {})->{priority} // '') eq 'bg', ($tags || {})->{priority} // 'undef');
check('标签请求参数 = { source }（不带排序）',
	($tinfo->{source} // '') eq 'kg' && !defined $tinfo->{sortId},
	($tinfo->{source} // 'undef'));

my ($sorts) = grep { $_->{action} eq 'songlistsorts' } @req;
check('排序请求是**前台**优先级（用户正在等的这一层不能被丢）',
	!defined(($sorts || {})->{priority}), ($sorts || {})->{priority} // 'undef');

my ($list) = grep { $_->{action} eq 'songlistbytag' } @req;
my $linfo = ($list || {})->{info} || {};
check('列表预热带 bg 优先级', (($list || {})->{priority} // '') eq 'bg', ($list || {})->{priority} // 'undef');
check('列表预热 = 第一个排序 × 全部标签 × 第 1 页',
	($linfo->{source} // '') eq 'kg'
	&& ($linfo->{sortId} // '') eq 'hot'
	&& ($linfo->{tagId}  // '') eq ''
	&& ($linfo->{page}   // 0) == 1,
	join(',', map { "$_=" . ($linfo->{$_} // '?') } qw(source sortId tagId page)));

check('sorts 层照常给 LMS 两行排序 tab', @feed == 1 && @{ $feed[0]{items} } == 2,
	scalar(@feed) ? scalar(@{ $feed[0]{items} }) : 'no feed');

# ---------- 第二次进同一平台：两样都在缓存里 ⇒ 零上游请求 ----------
@req = ();
@feed = ();
Plugins::LxMusic::Plugin::sdkPlSortsHandler(undef, sub { push @feed, $_[0] }, {}, undef, 'kg');
check('再进同一平台：tags 与第一页列表都命中缓存 -> 一个上游请求都不发',
	@req == 0, join(',', map { $_->{action} } @req));
check('再进同一平台：仍然照常渲染排序 tab', @feed == 1 && @{ $feed[0]{items} } == 2);

# ---------- 覆盖（区分 tags 与 list 各自的缓存）----------
# 清掉标签缓存后，只应重新发标签；列表页仍在 feed 缓存里，不该重发。
{
	no warnings 'redefine';
	no strict 'refs';
	my $meta = Plugins::LxMusic::Plugin::_pl_meta('mg');
	$meta->{tags} = undef; $meta->{tags_at} = 0;
}
@req = ();
# mg 从未进过 ⇒ sorts 要现取；但列表预热会照发（首次）
Plugins::LxMusic::Plugin::sdkPlSortsHandler(undef, sub { }, {}, undef, 'mg');
@actions = map { $_->{action} } @req;
check('新平台：三个请求齐全（mg 首次）',
	join(',', @actions) eq 'songlisttags,songlistsorts,songlistbytag', join(',', @actions));

# 再清标签缓存（保留 feed 缓存）⇒ 只补标签，不重发列表
{
	no warnings 'redefine';
	no strict 'refs';
	my $meta = Plugins::LxMusic::Plugin::_pl_meta('mg');
	$meta->{tags} = undef; $meta->{tags_at} = 0;
}
@req = ();
Plugins::LxMusic::Plugin::sdkPlSortsHandler(undef, sub { }, {}, undef, 'mg');
@actions = map { $_->{action} } @req;
check('标签过期但列表还在缓存：只补标签请求（不重复打列表）',
	join(',', @actions) eq 'songlisttags', join(',', @actions));

# ---------- 防御：平台为空不炸 ----------
{
	my $ok = eval { Plugins::LxMusic::Plugin::_pl_warm_platform(undef, undef); 1 };
	check('_pl_warm_platform(undef) 直接返回（不炸）', $ok ? 1 : 0, $@);
	$ok = eval { Plugins::LxMusic::Plugin::_pl_warm_platform('kg', []); 1 };
	check('_pl_warm_platform(src, []) 只热标签、不炸', $ok ? 1 : 0, $@);
}

print $failed ? "\n$failed FAILED\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
