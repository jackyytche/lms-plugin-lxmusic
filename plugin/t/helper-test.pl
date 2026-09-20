#!/usr/bin/perl
# helper-test.pl — Helper.pm 存根测试（脱离 LMS）
# 用法：perl helper-test.pl
use strict;
use warnings;

use FindBin;
use File::Spec;
use lib File::Spec->catdir($FindBin::Bin);           # t/ —— AnyEvent stubs

# zip 平铺结构：Helper.pm 在插件根，包名 Plugins::LxMusic::Helper
# （LMS 将 InstalledPlugins/ 加入 @INC，解压后路径自然匹配包名）。
# 本测试树里没有 Plugins/ 目录，而 Helper.pm 会 `use Plugins::LxMusic::Sources`
# ⇒ 给 @INC 挂一个映射钩子：Plugins/LxMusic/<X>.pm → <插件根>/<X>.pm
# （优先 CI/本地建的 t_build/Plugins/LxMusic）。这样 `perl t/helper-test.pl`
# 在 CI 与本地都能独立跑通，不依赖外部 -I 参数。
# 2026-09-21 修：此前 CI 恒失败于 `Can't locate Plugins/LxMusic/Sources.pm in @INC`。
BEGIN {
	$ENV{LX_TEST_VERBOSE} = $ENV{LX_TEST_VERBOSE} || 0;
	my $root  = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
	my $build = File::Spec->catdir($root, 't_build', 'Plugins', 'LxMusic');
	unshift @INC, sub {
		my ($self, $file) = @_;
		return unless $file =~ m{^Plugins/LxMusic/([^/]+\.pm)$};
		for my $dir ($build, File::Spec->catdir($root, 'LxMusic')) {
			my $p = File::Spec->catfile($dir, $1);
			next unless -f $p;
			open my $fh, '<', $p or next;
			return $fh;
		}
		return;
	};
	my $helper = File::Spec->catfile($FindBin::Bin, '..', 'LxMusic', 'Helper.pm');
	require $helper;
	Plugins::LxMusic::Helper->import if Plugins::LxMusic::Helper->can('import');
}

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

# ---------- 1. _parse：正常 RESULT ----------
{
	my ($ok, $data, $err, $logs, $alerts) = Plugins::LxMusic::Helper->_parse(
		"LOG http GET x -> 200\nRESULT {\"ok\":true,\"data\":\"http://a/b.mp3\"}\n");
	check('parse ok=1',               $ok == 1);
	check('parse data url',           ($data || '') eq 'http://a/b.mp3');
	check('parse log captured',       @$logs == 1 && $logs->[0] =~ /GET x/);
}

# ---------- 2. _parse：错误 RESULT ----------
{
	my ($ok, $data, $err) = Plugins::LxMusic::Helper->_parse(
		"RESULT {\"ok\":false,\"error\":\"timeout after 20s\"}\n");
	check('parse err ok=0',      $ok == 0);
	check('parse err message',   ($err || '') eq 'timeout after 20s');
}

# ---------- 3. _parse：无 RESULT / 坏 JSON ----------
{
	my ($ok, undef, $err) = Plugins::LxMusic::Helper->_parse("LOG only\n");
	check('parse no-result',     $ok == 0 && $err =~ /no RESULT/);

	($ok, undef, $err) = Plugins::LxMusic::Helper->_parse("RESULT {broken\n");
	check('parse bad-json',      $ok == 0 && $err =~ /bad RESULT json/);
}

# ---------- 4. _parse：多行 JSON / 引擎噪音 / ALERT ----------
{
	my ($ok, $data, undef, $logs, $alerts) = Plugins::LxMusic::Helper->_parse(
		"noise line\nALERT {\"title\":\"vip\"}\nRESULT {\"ok\":true,\"data\":{\"url\":\"x\"}}\nLOG l1\n");
	check('parse noise ignored',  $ok == 1 && ref $data eq 'HASH' && $data->{url} eq 'x');
	check('parse alert captured', @$alerts == 1);
}

# ---------- 5. init：引擎复制 + 自检（fork/exec 能力，Windows 可跑） ----------
{
	my $r = eval { Plugins::LxMusic::Helper->init };
	check('init returned true',   $r ? 1 : 0, $@);
}

# ---------- 6. installSource：名字清洗 + 落盘（内容过短会被拒，用真实形状的桩） ----------
{
	# Sources::addContent 的校验：≥50 字节 + 必须有 @name 头。
	# 桩内容**保持确定性**（不带 pid/时间），这样 CI 的日志每次一样、回写步骤报 "no change"，
	# 不会每次推送都多一条 ci: regression log 提交；代价是同一台机器跑第二遍会命中
	# "内容完全相同，已跳过"（Sources 按内容 sha1 去重）——下面按"已装"分支取回已有路径。
	my $src = "/**\n"
		. " * \@name Test Fixture Source\n"
		. " * \@description deterministic fixture for t/helper-test.pl\n"
		. " */\n"
		. "const { EVENT_NAMES, on, send } = globalThis.lx;\n"
		. "on(EVENT_NAMES.request, () => { send(EVENT_NAMES.inited, { status: 'success', sources: {} }); });\n";
	my $p = Plugins::LxMusic::Helper->installSource('../evil?name.js', $src);
	if (!defined $p) {
		my ($rec) = grep { ($_->{name} // '') eq 'Test Fixture Source' } @{ Plugins::LxMusic::Sources->list };
		$p = $rec ? Plugins::LxMusic::Sources->pathFor($rec->{id}) : undef;
	}
	check('installSource returns a path',  defined $p && $p =~ /\.js$/, $p // '(undef)');
	check('installSource path sanitised',  defined $p && $p !~ /[?;]/ && $p !~ m{\.\.}, $p // '');
	check('installSource wrote the file',  defined $p && -s $p && (-s $p) >= 50, defined $p ? (-s $p) : 'no path');
	check('installSource rejects junk',    !defined Plugins::LxMusic::Helper->installSource('junk.js', 'var x=1;'));
}

print $failed ? "\nFAILED: $failed\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
