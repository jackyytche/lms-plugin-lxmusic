# Plugins::LxMusic::Settings — 正式设置页（设置 → 插件 → LX Music）
#
# 覆盖：订阅源导入/查看/清除、音质档位、桥超时、Helper 并发、解析缓存 TTL、
# 封面代理开关、榜单源开关、诊断信息（引擎自检/版本/日志级别入口）。
# prefs 命名空间 plugin.lxmusic，保存后立即生效（Helper/ProtocolHandler 每次请求读 prefs）。

package Plugins::LxMusic::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::LxMusic::Helper;

my $log   = Slim::Utils::Log->logger('plugin.lxmusic');
my $prefs = preferences('plugin.lxmusic');

sub name { 'LX Music' }

sub page { 'plugins/LxMusic/settings/basic.html' }

# 由 Slim::Web::Settings 基类负责存取；表单字段名 = pref_<name>
sub prefs {
	return ($prefs, qw(
		quality bridgeTimeout helperConcurrency resolveTtl coverProxy
		boardsKg boardsTx boardsWy boardsMg
	));
}

sub handler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	my $action = $params->{lxAction} || '';

	# 复选框未勾选 ⇒ 表单根本不带该字段 ⇒ 基类会 set($pref, undef)。
	# 而 Prefs::Base::init 在下次重启时把 undef 当"未初始化"重新灌默认值(1)，
	# 开关会自己弹回（LMS 经典坑）。这里显式落 0，让"关"成为持久值。
	if ($params->{saveSettings}) {
		for my $b (qw(coverProxy boardsKg boardsTx boardsWy boardsMg)) {
			$params->{"pref_$b"} = 0 unless defined $params->{"pref_$b"};
		}
	}

	# ---- 订阅源导入（粘贴内容或 URL）----
	if ($params->{saveSettings} && $action eq 'import') {
		my $content = $params->{sourceContent} || '';
		my $name    = $params->{sourceName} || 'current.js';
		$content =~ s/^\s+|\s+$//g;

		if ($content =~ m{^https?://\S+$}i) {
			# URL 形式：插件侧 curl 拉取（与工具页 _handleImport 同一条实现）
			my ($body, $err) = Plugins::LxMusic::Plugin::_fetch($content);
			if ($err || !defined $body) {
				$params->{lxMessage} = '订阅源下载失败：' . ($err || 'empty');
			}
			else {
				$name    = ($content =~ m{([^/?#]+)(?:[?#].*)?$})[0] || 'downloaded';
				$params->{lxMessage} = _installSource($body, $name);
			}
		}
		elsif (length $content) {
			$params->{lxMessage} = _installSource($content, $name);
		}
		else {
			$params->{lxMessage} = '订阅源内容为空（粘贴源内容或源 URL）';
		}
	}
	elsif ($params->{saveSettings} && $action eq 'clear') {
		$prefs->set('sourceContent', '');
		$prefs->set('sourceName',    '');
		my $path = Plugins::LxMusic::Helper->currentSourcePath;
		unlink($path) if $path && -f $path;
		$params->{lxMessage} = '已清除订阅源（播放取直链将不可用，直到重新导入）';
		$log->info('LxMusic settings: source cleared');
	}

	# ---- 诊断信息（渲染进模板）----
	my $src     = Plugins::LxMusic::Helper->sourceInfo;
	my $srcPath = Plugins::LxMusic::Helper->currentSourcePath;
	if ($src->{installed} && $srcPath) {
		my $size = -s $srcPath;
		$params->{lxSourceStatus} = '已安装：' . ($prefs->get('sourceName') || 'current.js')
			. '（' . (defined $size ? $size : 0) . ' 字节）';
	}
	else {
		$params->{lxSourceStatus} = '未安装订阅源';
	}
	$params->{lxVersion}    = Plugins::LxMusic::Helper->pluginVersion;
	$params->{lxEngine}     = Plugins::LxMusic::Helper->engineStatus;
	$params->{lxSourcePath} = $srcPath || '(none)';

	my $logLevel = eval { Slim::Utils::Log->logLevelForCategory('plugin.lxmusic') } || $prefs->get('logLevel') || '?';
	$params->{lxLogLevel} = $logLevel;

	return $class->SUPER::handler($client, $params, $callback, $httpClient, $response);
}

# 订阅源落盘 + 落 prefs（工具页 _handleImport 的同款校验；返回给用户的消息）
sub _installSource {
	my ($content, $name) = @_;

	$content =~ s/^\s+|\s+$//g;
	return '订阅源内容为空' unless length $content;
	return '内容过短（< 50 字节），不像是洛雪订阅源' if length($content) < 50;

	# v6 源多为混淆版，明文特征有限：认 SERVER_SCRIPT_CONFIG / @name 头 / 通用挂载
	my $looksOk = ($content =~ /SERVER_SCRIPT_CONFIG/
		|| $content =~ /\@name/
		|| $content =~ /EVENT_NAMES/
		|| $content =~ /lx\s*\.\s*on/);

	my $safe = Plugins::LxMusic::Plugin::_safeName($name);
	$safe =~ s/\.js$//i;

	my $path = Plugins::LxMusic::Helper->installSource($safe . '.js', $content);
	return '订阅源导入失败（写盘错误，见 server.log）' unless $path;

	$prefs->set('sourceContent', $content);
	$prefs->set('sourceName',    $safe);
	$log->info("LxMusic settings: source imported: $safe.js (" . length($content) . ' bytes)');

	return ($looksOk ? '' : '（警告：内容不像洛雪订阅源，可能无法取链）')
		. '已导入订阅源：' . $safe . '.js（' . length($content) . ' 字节）';
}

1;

__END__

=head1 NAME

Plugins::LxMusic::Settings - LX Music 设置页

=cut
