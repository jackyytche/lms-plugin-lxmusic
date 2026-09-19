# Plugins::LxMusic::Settings — 正式设置页（设置 → 插件 → LX Music）
#
# 覆盖：订阅源导入/查看/清除、音质档位、桥超时、Helper 并发、解析缓存 TTL、
# 封面代理开关、榜单源开关、诊断信息（引擎自检/版本/日志级别入口）。
# prefs 命名空间 plugin.lxmusic，保存后立即生效（Helper/ProtocolHandler 每次请求读 prefs）。

package Plugins::LxMusic::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Encode ();
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::LxMusic::Helper;

my $log   = Slim::Utils::Log->logger('plugin.lxmusic');
my $prefs = preferences('plugin.lxmusic');

# 必须是 strings.txt 的 token（LMS 的 `name` 契约就是"字符串 token"）：设置下拉/
# 页面标题都用 `| string` 渲染它，返回显示串会渲染成空白行（0.6.3 现场踩到）。
sub name { 'PLUGIN_LXMUSIC' }

sub page { 'plugins/LxMusic/settings/basic.html' }

# 设置页模板是「纯 ASCII + 数字实体」（见 basic.html 头注，由 tmp/mk_settings_template.py 生成）：
# LMS 的 Template 对象没有 ENCODING（Slim/Web/Template/SkinManager.pm 的 Template->new），
# 传进模板的 UTF-8 字节串会被当 latin-1 再编码 ⇒ 浏览器双重编码乱码（设备实测）。
# 这里把非 ASCII 与 HTML 敏感字符一次转成数字实体，输出纯 ASCII —— 管道里任何
# 编码环节都改不坏，也不依赖服务器语言（EN 的达菲同样显示中文）。
sub _ent {
	my ($s) = @_;
	return '' unless defined $s;
	my $u = _chars($s);
	my $out = '';
	for my $c (split //, $u) {
		my $o = ord $c;
		$out .= ($o > 127 || $c eq '&' || $c eq '<' || $c eq '>' || $c eq '"' || $c eq "'")
			? '&#' . $o . ';'
			: $c;
	}
	return $out;
}

# 统一把"原始 UTF-8 字节串"变成旗标字符串（已是字符则原样）。
# 用途：URL 下载来的 body 是字节；直接塞给 prefs/installSource 会被二次编码。
sub _chars {
	my ($s) = @_;
	return $s if !defined $s || utf8::is_utf8($s);
	my $u = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK()) };
	return defined $u ? $u : $s;    # 非法 UTF-8 字节：原样处理，至少不崩
}

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
		my $probe   = $content;
		$probe =~ s/^\s+|\s+$//g;   # 只用来判形态；正文一律原样落盘（差一个字节都会改掉源签名）

		if ($probe =~ m{^https?://\S+$}i) {
			# URL 形式：插件侧 curl 拉取（与工具页 _handleImport 同一条实现）
			my ($body, $err) = Plugins::LxMusic::Plugin::_fetch($probe);
			if ($err || !defined $body) {
				$params->{lxMessage} = _ent('订阅源下载失败：' . ($err || 'empty'));
			}
			else {
				$name    = ($probe =~ m{([^/?#]+)(?:[?#].*)?$})[0] || 'downloaded';
				$params->{lxMessage} = _installSource($body, $name);
			}
		}
		elsif (length $probe) {
			$params->{lxMessage} = _installSource($content, $name);
		}
		else {
			$params->{lxMessage} = _ent('订阅源内容为空（粘贴源内容或源 URL）');
		}
	}
	elsif ($params->{saveSettings} && $action eq 'clear') {
		$prefs->set('sourceContent', '');
		$prefs->set('sourceName',    '');
		my $path = Plugins::LxMusic::Helper->currentSourcePath;
		unlink($path) if $path && -f $path;
		$params->{lxMessage} = _ent('已清除订阅源（播放取直链将不可用，直到重新导入）');
		$log->info('LxMusic settings: source cleared');
	}

	# ---- 诊断信息（渲染进模板）----
	my $src     = Plugins::LxMusic::Helper->sourceInfo;
	my $srcPath = Plugins::LxMusic::Helper->currentSourcePath;
	if ($src->{installed} && $srcPath) {
		my $size = -s $srcPath;
		$params->{lxSourceStatus} = _ent('已安装：' . ($prefs->get('sourceName') || 'current.js')
			. '（' . (defined $size ? $size : 0) . ' 字节）');
	}
	else {
		$params->{lxSourceStatus} = _ent('未安装订阅源');
	}
	$params->{lxVersion}    = _ent(Plugins::LxMusic::Helper->pluginVersion);
	$params->{lxEngine}     = _ent(Plugins::LxMusic::Helper->engineStatus);
	$params->{lxSourcePath} = _ent($srcPath || '(none)');

	my $logLevel = eval { Slim::Utils::Log->allCategories()->{'plugin.lxmusic'} }
		|| '默认 ERROR（可在「高级 → 日志」调整）';
	$params->{lxLogLevel} = _ent($logLevel);

	return $class->SUPER::handler($client, $params, $callback, $httpClient, $response);
}

# 订阅源落盘 + 落 prefs（工具页 _handleImport 的同款校验；返回给用户的消息）
sub _installSource {
	my ($content, $name) = @_;

	# 注意：这里绝不能再裁剪首尾空白——lx 源的完整性签名基于原版字节，
	# 多/少一个换行都会让 qjs 端 rawScript hash 与官方不一致（实测差 1 字节）。
	# 空内容判定用 /\S/，长度校验只是防呆。
	return _ent('订阅源内容为空') unless defined $content && $content =~ /\S/;
	return _ent('内容过短（< 50 字节），不像是洛雪订阅源') if length($content) < 50;

	$content = _chars($content);   # URL 下载是字节串 → 落 prefs/落盘前统一成字符

	# v6 源多为混淆版，明文特征有限：认 SERVER_SCRIPT_CONFIG / @name 头 / 通用挂载
	my $looksOk = ($content =~ /SERVER_SCRIPT_CONFIG/
		|| $content =~ /\@name/
		|| $content =~ /EVENT_NAMES/
		|| $content =~ /lx\s*\.\s*on/);

	my $safe = Plugins::LxMusic::Plugin::_safeName($name);
	$safe =~ s/\.js$//i;

	my $path = Plugins::LxMusic::Helper->installSource($safe . '.js', $content);
	return _ent('订阅源导入失败（写盘错误，见 server.log）') unless $path;

	$prefs->set('sourceContent', $content);
	$prefs->set('sourceName',    $safe);
	my $bytes = -s $path;    # 报"磁盘上的字节数"（字符数会被多字节中文误导）
	$bytes = length($content) unless defined $bytes;
	$log->info("LxMusic settings: source imported: $safe.js ($bytes bytes)");

	return _ent(($looksOk ? '' : '（警告：内容不像洛雪订阅源，可能无法取链）')
		. '已导入订阅源：' . $safe . '.js（' . $bytes . ' 字节）');
}

1;

__END__

=head1 NAME

Plugins::LxMusic::Settings - LX Music 设置页

=cut
