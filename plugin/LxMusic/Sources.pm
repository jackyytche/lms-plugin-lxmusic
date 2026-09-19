# Plugins/LxMusic/Sources.pm — 多订阅源注册表（M0.6）
# ============================================================
# 背景：PC 端同时只能启用 1 个自定义源（radio），本插件按用户要求做成
# 「多源并存 + 顺序聚合」：
#   - 元数据（顺序/启用/来源URL/名称/大小/sha1）存 prefs `sourcesJson`（JSON 字符串，
#     不把 64KB 正文塞进 prefs —— prefs 每次变更都会全量 YAML dump）
#   - 源文件正文落 <<prefsdir>>/lxmusic/sources/<id>.js（持久目录；/tmp 是 tmpfs，重启即失）
#   - 导入三条路：在线订阅(URL) / 服务器文件路径 / 目录内所有 .js；外加老的"单源"迁移
#   - 校验对齐 PC 端（refs/lx-music-desktop src/main/modules/userApi/utils.ts:53-119）：
#     必须以 /* 块注释开头（否则"无效的自定义源"）、头部 `* @key value`、
#     长度上限 name24/description36/author56/homepage1024/version36、按内容去重、上限 20 个
# ============================================================

package Plugins::LxMusic::Sources;

use strict;
use warnings;

use Digest::SHA qw(sha1_hex);
use Encode ();
use File::Basename qw(basename);
use File::Path qw(mkpath);
use File::Spec;
use JSON::XS ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = Slim::Utils::Log->logger('plugin.lxmusic');
my $prefs = preferences('plugin.lxmusic');

# 注意：**不用** ->utf8。prefs 是 YAML::XS::Dump 落盘的（Prefs/Namespace.pm:327），
# utf8 模式会产出含高位字节的"字节串"，YAML 那边会被当二进制/乱码；字符模式则把
# 非 ASCII 转义成 \uXXXX ⇒ 落盘一定是纯 ASCII，读写往返稳定。
my $JSON = JSON::XS->new->canonical;
my $MAX  = 20;                              # 与 PC 端一致的源数量上限
my $MAX_BYTES = 2 * 1024 * 1024;            # 单源大小上限（PC 端 9MB，这里收紧）
my %META_CAP = (name => 24, description => 36, author => 56, homepage => 1024, version => 36);

# ---------- 路径 ----------
# 持久目录：prefs 目录（一定可写且跨重启），不要用 /tmp（tmpfs）
sub dir {
	my ($class) = @_;
	my $base = eval { Slim::Utils::Prefs::dir() } || File::Spec->tmpdir();
	my $d = File::Spec->catdir($base, 'lxmusic', 'sources');
	mkpath($d) unless -d $d;
	return $d;
}

sub pathFor {
	my ($class, $id) = @_;
	$id = _safeId($id) or return undef;
	return File::Spec->catfile($class->dir, "$id.js");
}

sub _safeId {
	my ($id) = @_;
	return undef unless defined $id;
	$id =~ s/[^A-Za-z0-9_-]//g;
	return length $id ? $id : undef;
}

sub _chars {
	my ($s) = @_;
	return $s if !defined $s || utf8::is_utf8($s);
	my $u = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK()) };
	return defined $u ? $u : $s;
}

# 拼接文案用：先归一成字符再拼。直接 `.` 会产生"混旗标串"（本文件的中文字面量是字节串，
# JSON 解出的源名是旗标串）⇒ 上层 _ent 会把字面量的每个字节单独转义 ⇒ 双重编码乱码。
sub _m { return join('', map { my $x = _chars($_); defined $x ? $x : '' } @_) }

# ---------- 注册表读写 ----------
sub list {
	my ($class) = @_;
	my $raw = $prefs->get('sourcesJson') || '';
	my $l = eval { $JSON->decode($raw) };
	$l = [] unless ref $l eq 'ARRAY';
	return [ grep { ref $_ eq 'HASH' && $_->{id} } @$l ];
}

sub _save {
	my ($class, $list) = @_;
	$prefs->set('sourcesJson', $JSON->encode($list));
	return $list;
}

sub get {
	my ($class, $id) = @_;
	$id = _safeId($id) or return undef;
	for my $s (@{ $class->list }) { return $s if $s->{id} eq $id }
	return undef;
}

# 启用且文件仍在的源（顺序 = 聚合优先级）
sub enabled {
	my ($class) = @_;
	return [ grep { $_->{enabled} && -f ($class->pathFor($_->{id}) // '') } @{ $class->list } ];
}

sub firstEnabledPath {
	my ($class) = @_;
	my $e = $class->enabled;
	return @$e ? $class->pathFor($e->[0]->{id}) : undef;
}

sub count { my ($class) = @_; return scalar @{ $class->list } }

# ---------- 源脚本校验 / 元数据（对齐 PC 端） ----------
sub parseMeta {
	my ($class, $content) = @_;
	$content = _chars($content);
	return (undef, '脚本不是以 /* 块注释开头（不是洛雪自定义源）')
		unless defined $content && $content =~ m{^\s*/\*};
	my ($head) = $content =~ m{^\s*/\*(.*?)\*/}s;
	$head = '' unless defined $head;
	my %m;
	while ($head =~ /^[ \t]*\*[ \t]*\@(\w+)[ \t]+(.+?)[ \t]*$/mg) { $m{$1} = $2 }
	if (my $cap = $META_CAP{name} || 0) {
		for my $k (keys %META_CAP) {
			next unless defined $m{$k};
			$m{$k} = substr($m{$k}, 0, $META_CAP{$k});
		}
	}
	return (\%m, undef);
}

# ---------- 导入 ----------
# addContent(content=>..., name=>..., origin=>'url|file|legacy', url=>...)
# 返回 ($record, $err)
sub addContent {
	my ($class, %a) = @_;

	my $content = _chars($a{content});
	return (undef, '内容为空') unless defined $content && $content =~ /\S/;
	$content =~ s/\r\n/\n/g;                 # 与 Helper::installSource 一致（LF 规范化）
	return (undef, '内容过短（< 50 字节），不像是订阅源') if length($content) < 50;
	return (undef, '内容过大（> ' . int($MAX_BYTES / 1024) . ' KB）') if length($content) > $MAX_BYTES;

	my ($meta, $err) = $class->parseMeta($content);
	return (undef, $err) if $err;
	return (undef, '不是洛雪自定义源（缺少 @name 头）') unless $meta->{name};

	my $sha  = sha1_hex(Encode::encode('UTF-8', $content));
	my $list = $class->list;
	for my $s (@$list) {
		return (undef, _m('与已有订阅源「', $s->{name}, '」内容完全相同，已跳过')) if ($s->{sha1} // '') eq $sha;
	}
	return (undef, "订阅源数量已达上限 $MAX 个（与 PC 端一致）") if @$list >= $MAX;

	my $id   = _newId($sha);
	my $path = $class->pathFor($id);
	my $fh;
	unless (open($fh, '>:encoding(UTF-8)', $path)) {
		return (undef, "写盘失败：$!");
	}
	print {$fh} $content;
	close $fh;

	my $rec = {
		id      => $id,
		# 显示名优先用脚本自己声明的 @name（PC 端同款），其次调用方给的名字，最后兜底
		name    => substr($meta->{name} || $a{name} || "source_$id", 0, $META_CAP{name}),
		origin  => ($a{origin} || 'file'),
		url     => ($a{url} // ''),
		enabled => 1,
		added   => time(),
		bytes   => (-s $path),
		sha1    => $sha,
		meta    => { map { $_ => $meta->{$_} } grep { defined $meta->{$_} } qw(description author homepage version) },
	};
	push @$list, $rec;
	$class->_save($list);
	$log->warn(sprintf('LxMusic Sources: added %s (%s, %s, %d bytes)',
		$rec->{id}, $rec->{name}, $rec->{origin}, $rec->{bytes}));
	return ($rec, undef);
}

sub _newId {
	my ($sha) = @_;
	my $id = substr(sha1_hex($sha . time() . rand()), 0, 8);
	my $exists = 0;
	$exists = 1 for grep { $_->{id} eq $id } @{ __PACKAGE__->list };
	return $exists ? _newId($sha . rand()) : $id;
}

# 在线订阅：下载后按内容导入。$fetcher 由调用方提供（Plugin::_fetch），便于测试注入
sub addUrl {
	my ($class, $url, $fetcher) = @_;
	return (undef, 'URL 必须以 http:// 或 https:// 开头') unless defined $url && $url =~ m{^https?://\S+$}i;
	$fetcher ||= \&Plugins::LxMusic::Plugin::_fetch;
	my ($body, $err) = $fetcher->($url);
	return (undef, '下载失败：' . ($err || 'empty')) if $err || !defined $body || $body !~ /\S/;
	my $name = ($url =~ m{([^/?#]+?)(?:\.js)?(?:[?#].*)?$})[0] || '';
	$name =~ s/\.js$//i;
	return $class->addContent(content => $body, name => $name, origin => 'url', url => $url);
}

# 本地导入：读服务器上的一个文件（LMS 设置页可用 selectFile 选项选择路径）
sub addFile {
	my ($class, $path) = @_;
	$path = _chars($path);
	return (undef, '未填写文件路径') unless defined $path && $path =~ /\S/;
	$path =~ s/^\s+|\s+$//g;
	return (undef, _m('文件不存在：', $path)) unless -f $path;
	my $size = -s $path;
	return (undef, "文件过大（> " . int($MAX_BYTES / 1024) . " KB）") if defined $size && $size > $MAX_BYTES;
	my $content = _readFile($path);
	return (undef, _m('读取失败：', $path)) unless defined $content;
	my $name = basename($path);
	$name =~ s/\.js$//i;
	return $class->addContent(content => $content, name => $name, origin => 'file', url => $path);
}

# 本地导入：读一个目录里所有 .js（用户把多个源丢进同一目录时省事）
sub addDir {
	my ($class, $dirpath) = @_;
	$dirpath = _chars($dirpath);
	return (undef, '未填写目录路径') unless defined $dirpath && $dirpath =~ /\S/;
	$dirpath =~ s/^\s+|\s+$//g;
	return (undef, _m('目录不存在：', $dirpath)) unless -d $dirpath;
	my @files = sort glob(File::Spec->catfile($dirpath, '*.js'));
	return (undef, _m('目录里没有 .js：', $dirpath)) unless @files;
	my (@ok, @bad);
	for my $f (@files) {
		my ($rec, $err) = $class->addFile($f);
		if ($rec) { push @ok, $rec->{name} } else { push @bad, _m(basename($f), '（', $err, '）') }
	}
	return ({ ok => \@ok, bad => \@bad }, undef);
}

sub _readFile {
	my ($path) = @_;
	open(my $fh, '<:raw', $path) or return undef;
	local $/;
	my $s = <$fh>;
	close $fh;
	return $s;
}

# ---------- 管理 ----------
sub setEnabled {
	my ($class, $id, $on) = @_;
	my $list = $class->list;
	my $found = 0;
	for my $s (@$list) {
		next unless $s->{id} eq (_safeId($id) // '');
		$s->{enabled} = $on ? 1 : 0;
		$found = 1;
	}
	$class->_save($list) if $found;
	return $found;
}

# dir = -1 上移 / +1 下移
sub move {
	my ($class, $id, $delta) = @_;
	$id = _safeId($id) or return 0;
	my $list = $class->list;
	my ($i) = grep { $list->[$_]{id} eq $id } 0 .. $#$list;
	return 0 unless defined $i;
	my $j = $i + ($delta < 0 ? -1 : 1);
	return 0 if $j < 0 || $j > $#$list;
	@$list[$i, $j] = @$list[$j, $i];
	$class->_save($list);
	return 1;
}

sub remove {
	my ($class, $id) = @_;
	$id = _safeId($id) or return 0;
	my $list = $class->list;
	my @keep = grep { $_->{id} ne $id } @$list;
	return 0 if @keep == @$list;
	my $path = $class->pathFor($id);
	unlink($path) if $path && -f $path;
	$class->_save(\@keep);
	$log->warn("LxMusic Sources: removed $id");
	return 1;
}

# 在线源重新拉取（PC 端没有的能力：我们保留了来源 URL，所以能"更新"）
sub refresh {
	my ($class, $id, $fetcher) = @_;
	my $rec = $class->get($id) or return (undef, '未找到该订阅源');
	return (undef, '该源不是在线订阅（没有来源 URL）') unless $rec->{url} && $rec->{url} =~ m{^https?://};
	$fetcher ||= \&Plugins::LxMusic::Plugin::_fetch;
	my ($body, $err) = $fetcher->($rec->{url});
	return (undef, '下载失败：' . ($err || 'empty')) if $err || !defined $body || $body !~ /\S/;
	$body = _chars($body);
	$body =~ s/\r\n/\n/g;
	my $sha = sha1_hex(Encode::encode('UTF-8', $body));
	if ($sha eq ($rec->{sha1} // '')) {
		return ({ unchanged => 1, name => $rec->{name} }, undef);
	}
	my $path = $class->pathFor($rec->{id});
	my $fh;
	unless (open($fh, '>:encoding(UTF-8)', $path)) {
		return (undef, "写盘失败：$!");
	}
	print {$fh} $body;
	close $fh;
	my ($meta) = $class->parseMeta($body);
	my $list = $class->list;
	for my $s (@$list) {
		next unless $s->{id} eq $rec->{id};
		$s->{bytes} = -s $path;
		$s->{sha1}  = $sha;
		$s->{added} = time();
		$s->{meta}  = { map { $_ => $meta->{$_} } grep { defined $meta->{$_} } qw(description author homepage version) };
	}
	$class->_save($list);
	return ({ refreshed => 1, name => $rec->{name}, bytes => (-s $path) }, undef);
}

# ---------- 老单源迁移（幂等） ----------
# 0.6.x 的 prefs：sourceContent(正文) + sourceName；文件在 /tmp（易失）
sub migrateLegacy {
	my ($class) = @_;
	my $content = $prefs->get('sourceContent');
	return 0 unless defined $content && $content =~ /\S/;
	return 0 if $class->count;      # 已经有新结构就不再迁移
	my ($rec, $err) = $class->addContent(
		content => $content,
		name    => ($prefs->get('sourceName') || ''),
		origin  => 'legacy',
	);
	unless ($rec) {
		$log->error("LxMusic Sources: legacy migration failed: $err");
		return 0;
	}
	$prefs->set('sourceContent', '');
	$prefs->set('sourceName',    '');
	$log->warn("LxMusic Sources: legacy single source migrated -> $rec->{id} ($rec->{name}, $rec->{bytes} bytes)");
	return 1;
}

# 诊断用：给设置页/工具页看的一行摘要
sub status {
	my ($class) = @_;
	my $all = $class->list;
	my $on  = $class->enabled;
	return {
		total   => scalar @$all,
		enabled => scalar @$on,
		dir     => $class->dir,
		names   => [ map { $_->{name} } @$on ],
	};
}

1;
