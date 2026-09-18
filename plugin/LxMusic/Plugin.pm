# Plugins/LxMusic/Plugin.pm — 洛雪音乐插件入口（v0.1 骨架）
package Plugins::LxMusic::Plugin;

use strict;
use warnings;

use Slim::Utils::Log;

use Plugins::LxMusic::Helper;

my $log = Slim::Utils::Log->logger('plugin.lxmusic');

sub initPlugin {
	my ($class) = @_;

	$log->info('LxMusic: initialising');

	unless (Plugins::LxMusic::Helper->init) {
		$log->error('LxMusic: engine init FAILED — plugin features disabled');
		return;
	}

	# TODO(v0.1): XMLBrowser 菜单（导入/搜索/浏览）、lxm:// ProtocolHandler、
	#             Web 设置页（订阅导入 + 诊断）。骨架先保证引擎就绪。

	$log->info('LxMusic: ready');
	return;
}

sub shutdownPlugin {
	my ($class) = @_;
	Plugins::LxMusic::Helper->shutdown;
	return;
}

1;
