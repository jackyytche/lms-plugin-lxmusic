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

	# ---- 订阅源导入（粘贴内容或 URL）----
	if ($params->{saveSettings} && $action eq 'import') {
		my $content = $params->{sourceContent} || '';
		my $name    = $params->{sourceName} || 'current.js';
		$content =~ s/^\s+|\s+$//g;

		if ($content =~ m{^https?://}i) {
			# URL 形式：交给 Helper 侧的导入逻辑（Plugin::_handleImport 已有实现），这里只记 URL
			$log->info("LxMusic settings: source URL import requested: $content");
			$params->{lxMessage} = "URL 导入请用工具页（/plugins/LxMusic/index.html?sourceurl=...）：$content";
		}
		elsif (length $content) {
			my $path = Plugins::LxMusic::Helper->installSource($name, $content);
			if ($path) {
				$prefs->set('sourceContent', $content);
				$prefs->set('sourceName',    $name);
				$params->{lxMessage} = "已导入订阅源：$name（" . length($content) . " 字节）";
				$log->info("LxMusic settings: source imported: $name");
			}
			else {
				$params->{lxMessage} = '订阅源导入失败（写盘错误，见 server.log）';
			}
		}
		else {
			$params->{lxMessage} = '订阅源内容为空';
		}
	}
	elsif ($params->{saveSettings} && $action eq 'clear') {
		$prefs->set('sourceContent', '');
		$prefs->set('sourceName',    '');
		my $path = Plugins::LxMusic::Helper->currentSourcePath;
		unlink($path) if $path && -f $path;
		Plugins::LxMusic::Helper->installSource('cleared.js', '// cleared from settings page');
		$params->{lxMessage} = '已清除订阅源';
		$log->info('LxMusic settings: source cleared');
	}

	# ---- 诊断信息（渲染进模板）----
	my $src = Plugins::LxMusic::Helper->sourceInfo;
	$params->{lxSourceStatus} = $src->{installed}
		? '已安装：' . ($prefs->get('sourceName') || 'current.js')
			. '（' . length($prefs->get('sourceContent') || '') . ' 字节）'
		: '未安装订阅源';
	$params->{lxVersion}   = $Plugins::LxMusic::VERSION || '?';
	$params->{lxEngine}    = $src->{engine} || 'see server.log';
	$params->{lxSourcePath} = Plugins::LxMusic::Helper->currentSourcePath || '(none)';

	my $logLevel = eval { Slim::Utils::Log->logLevelForCategory('plugin.lxmusic') } || $prefs->get('logLevel') || '?';
	$params->{lxLogLevel} = $logLevel;

	return $class->SUPER::handler($client, $params, $callback, $httpClient, $response);
}

1;

__END__

=head1 NAME

Plugins::LxMusic::Settings - LX Music 设置页

=cut
