#!/usr/bin/perl
# helper-test.pl — Helper.pm 存根测试（脱离 LMS）
# 用法：perl helper-test.pl
use strict;
use warnings;

use FindBin;
use File::Spec;
use lib File::Spec->catdir($FindBin::Bin);           # t/ —— AnyEvent stubs

# zip 平铺结构：Helper.pm 在插件根，包名 Plugins::LxMusic::Helper
# （LMS 将 InstalledPlugins/ 加入 @INC，解压后路径自然匹配包名）
BEGIN {
	$ENV{LX_TEST_VERBOSE} = $ENV{LX_TEST_VERBOSE} || 0;
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

# ---------- 6. installSource：名字清洗 ----------
{
	my $p = Plugins::LxMusic::Helper->installSource('../evil?name.js', 'var x=1;');
	check('installSource sanitised',   defined $p && $p !~ m{\?\;} && $p !~ m{\.\.}, $p // '');
}

print $failed ? "\nFAILED: $failed\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
