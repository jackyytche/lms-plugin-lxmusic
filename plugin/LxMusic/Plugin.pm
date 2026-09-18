# Plugins/LxMusic/Plugin.pm — 洛雪音乐插件入口
# ============================================================
# v0.1.0-alpha1：引擎就绪 + 订阅导入(Web) + 菜单(取链测试) + lxm:// 协议。
# 聚合搜索/分类浏览在 alpha2 接入 musicSdk 后开启。
# ============================================================

package Plugins::LxMusic::Plugin;

use strict;
use warnings;
use utf8;

use Encode qw(encode_utf8);
use HTML::Entities qw(encode_entities);
use JSON::XS ();
use MIME::Base64 qw(encode_base64url decode_base64url);
use Time::HiRes qw(time);
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::Pages;

use Plugins::LxMusic::Helper;
use Plugins::LxMusic::ProtocolHandler;

my $log = logger('plugin.lxmusic');

my $prefs = preferences('plugin.lxmusic');

my $JSON = JSON::XS->new->utf8->canonical;

sub getDisplayName { '洛雪音乐 (LX Music)' }

sub initPlugin {
	my ($class) = @_;

	$prefs->init({
		sourceContent => '',     # 订阅源脚本全文
		sourceName    => '',     # 展示名
		quality       => '320k', # 默认音质（共识：320k）
	});

	# 引擎就绪（复制到 tmpfs + 自检）
	unless (Plugins::LxMusic::Helper->init) {
		$log->error('LxMusic: engine init FAILED — check server.log');
	}

	# 恢复已导入的订阅源（tmpfs 重启清空）
	if (my $content = $prefs->get('sourceContent')) {
		my $path = Plugins::LxMusic::Helper->installSource(
			($prefs->get('sourceName') || 'current') . '.js', $content);
		$log->info("LxMusic: source restored: $path");
	}

	if (main::WEBUI) {
		Slim::Web::Pages->addPageFunction(
			'plugins/LxMusic/index\.html',
			sub { $class->webHandler(@_) },
		);
	}

	$class->SUPER::initPlugin(
		feed => \&handleFeed,
		tag  => 'lxmusic',
		menu => 'apps',
	);

	$log->info('LxMusic: ready');
	return;
}

sub shutdownPlugin {
	my ($class) = @_;
	Plugins::LxMusic::Helper->shutdown;
	return;
}

# ================================================== 菜单
sub handleFeed {
	my ($client, $cb, $params, $args) = @_;

	my $src = Plugins::LxMusic::Helper->sourceInfo;
	my $status = $src->{installed}
		? '订阅源: ' . ($prefs->get('sourceName') || 'current.js')
		: '订阅源: 未导入（请到网页设置导入）';

	my @items = (
		{
			name        => '播放测试（输入歌曲ID）',
			type        => 'search',
			url         => \&testHandler,
			passthrough => ['test'],
		},
		{
			name => $status,
			type => 'text',
		},
	);

	$cb->({ items => \@items });
	return;
}

# 播放测试：输入 kw 歌曲 ID（数字），取链并给出可播放条目
sub testHandler {
	my ($client, $cb, $args) = @_;
	my $input = $args->{search} || '';

	unless ($input =~ /^\s*(\d{4,20})\s*$/) {
		$cb->({ items => [ {
			name => '请输入酷我(kw)数字歌曲ID（网页设置页有获取方法）',
			type => 'text',
		} ] });
		return;
	}
	my $mid = $1;

	my $music = { songmid => $mid };
	my $title = "kw #$mid";
	my $url   = Plugins::LxMusic::ProtocolHandler->buildUrl(
		music => $music, src => 'kw',
		type  => ($prefs->get('quality') || '320k'),
		name  => $title,
	);

	$cb->({ items => [ {
		name => "$title - 点击播放（先取链）",
		type => 'audio',
		url  => $url,
	} ] });
	return;
}

# ================================================== Web 设置/诊断页
sub webHandler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	my $msg    = '';
	my $status = '';
	my $testResult = '';

	# --- POST: 导入（粘贴 or URL） ---
	if ($params->{import} && ($params->{source} || $params->{sourceurl})) {
		my ($name, $content, $err);
		if (my $s = $params->{source}) {
			$content = $s;
			$name    = 'pasted.js';
		} elsif (my $u = $params->{sourceurl}) {
			$u = "http://$u" unless $u =~ m{^https?://}i;
			($content, $err) = _fetch($u);
			$name = [$u =~ m{([^/]+)$}]->[0] || 'downloaded.js';
		}
		if ($err) {
			$msg = "导入失败：$err";
		} elsif ($content && $content =~ /\S/ && length($content) > 50) {
			# 简单校验：lx 源脚本应有 on/request 特征
			my $looksOk = $content =~ /(lx\s*\.\s*on|EVENT_NAMES|on\s*\(\s*['"]?request)/;
			my $savedName = _safeName($name);
			$prefs->set('sourceContent', $content);
			$prefs->set('sourceName', $savedName);
			Plugins::LxMusic::Helper->installSource("$savedName.js", $content);
			$msg = '导入' . ($looksOk ? '' : '（警告：内容不像洛雪源脚本，仍已保存）')
				. "：$savedName.js，" . length($content) . ' 字节';
		} else {
			$msg = '导入失败：内容为空或过短';
		}
	}

	# --- GET: 播放测试（异步取链后重渲染） ---
	if (my $mid = $params->{testmid}) {
		if ($mid =~ /^(\d{4,20})$/) {
			return _testMusicUrl($1, $client, $params, $callback, $httpClient, $response);
		}
		$msg = '测试ID格式不对';
	}

	# --- 状态 ---
	my $src = Plugins::LxMusic::Helper->sourceInfo;
	$status = $src->{installed}
		? sprintf('已导入：%s（%d 字节）',
			encode_entities($prefs->get('sourceName') || 'current.js'),
			length($prefs->get('sourceContent') || ''))
		: '未导入订阅源';

	my $body = _html($msg, $status, $testResult);
	$body = encode_utf8($body);

	$response->code(200);
	$response->header('Content-Type' => 'text/html; charset=utf-8');
	$callback->($client, $params, \$body, $httpClient, $response);
	return;
}

sub _testMusicUrl {
	my ($mid, $client, $params, $callback, $httpClient, $response) = @_;

	my $sourcePath = Plugins::LxMusic::Helper->currentSourcePath();
	unless ($sourcePath) {
		my $body = encode_utf8(_html('尚未导入订阅源', '', ''));
		$response->code(200);
		$response->header('Content-Type' => 'text/html; charset=utf-8');
		$callback->($client, $params, \$body, $httpClient, $response);
		return;
	}

	my $started = Time::HiRes::time();
	Plugins::LxMusic::Helper->request(
		source   => $sourcePath,
		action   => 'musicUrl',
		sourceId => 'kw',
		info     => { musicInfo => { songmid => $mid }, type => ($prefs->get('quality') || '320k') },
		timeout  => 20,
		cb       => sub {
			my ($res) = @_;
			my $elapsed = sprintf('%.2f', Time::HiRes::time() - $started);
			my $text;
			if ($res->{ok} && $res->{data} && !ref($res->{data})) {
				$text = sprintf('✅ 取链成功（%ss）：<a href="%s">%s</a>',
					$elapsed, encode_entities($res->{data}), encode_entities(substr($res->{data}, 0, 120)));
			} else {
				my $err = encode_entities($res->{error} || 'unknown');
				my $logs = join("\n", map { encode_entities($_) } @{ $res->{logs} || [] });
				$text = "❌ 取链失败（${elapsed}s）：$err" . ($logs ? "<pre>$logs</pre>" : '');
			}
			my $body = encode_utf8(_html('', '', $text));
			$response->code(200);
			$response->header('Content-Type' => 'text/html; charset=utf-8');
			$callback->($client, $params, \$body, $httpClient, $response);
		},
	);
	return;
}

# 服务器端拉取订阅（阻塞式，导入是低频操作；URL 校验后走 http/https）
sub _fetch {
	my ($url) = @_;
	return (undef, 'URL 过长') if length($url) > 500;
	return (undef, '仅支持 http/https') unless $url =~ m{^https?://}i;

	my $out = eval {
		local $ENV{PATH} = '/usr/bin:/bin';
		open(my $fh, '-|', '/usr/bin/curl', '-sS', '-L', '--max-time', '30', $url) or die "curl: $!";
		local $/;
		my $s = <$fh>;
		close $fh;
		$s;
	};
	return (undef, "下载失败: $@") if $@ || !defined $out;
	return (undef, '下载内容为空') unless $out =~ /\S/;
	return ($out, undef);
}

sub _safeName {
	my ($name) = @_;
	$name ||= 'source';
	$name =~ s/\.{2,}/_/g;
	$name =~ s/[^\w.-]/_/g;
	$name =~ s/^[.\-]+//;
	$name = 'source' if $name eq '';
	return $name;
}

sub _html {
	my ($msg, $status, $testResult) = @_;

	$status ||= do {
		my $src = Plugins::LxMusic::Helper->sourceInfo;
		$src->{installed} ? '已导入' : '未导入订阅源';
	};

	my $msgBlock  = $msg        ? qq{<div class="msg">$msg</div>}        : '';
	my $testBlock = $testResult ? qq{<div class="msg">$testResult</div>} : '';

	return <<"ENDHTML";
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>洛雪音乐 - 设置</title>
<style>
	body { font-family: -apple-system,'Segoe UI','Microsoft YaHei',sans-serif; margin: 2em auto; max-width: 52em; padding: 0 1em; color: #222; }
	h1 { font-size: 1.4em; } h2 { font-size: 1.1em; margin-top: 1.6em; }
	textarea { width: 100%; height: 10em; font-family: monospace; font-size: 12px; }
	input[type=text] { width: 60%; }
	button { padding: .4em 1.2em; }
	.msg { padding: .6em 1em; background: #eef; border: 1px solid #ccd; border-radius: 6px; margin: .8em 0; }
	.status { color: #555; }
	pre { background: #f6f6f6; padding: .6em; overflow: auto; max-height: 14em; }
	.box { border: 1px solid #ddd; border-radius: 8px; padding: 1em; margin: 1em 0; }
</style>
</head>
<body>
<h1>洛雪音乐 (LX Music) <span style="font-size:.6em;color:#888">v0.1.0-alpha1</span></h1>

<div class="box">
<h2>订阅源状态</h2>
<p class="status">$status</p>
<p>当前音质：320k（默认）</p>
</div>

<h2>导入订阅源</h2>
<form method="post">
<p>方式一：粘贴洛雪自定义源脚本全文（.js）</p>
<textarea name="source" placeholder="把订阅源脚本内容粘贴到这里…"></textarea>
<p>方式二：订阅源 URL（http/https 直链）</p>
<p><input type="text" name="sourceurl" placeholder="https://…/source.js"></p>
<p><button type="submit" name="import" value="1">导入并启用</button></p>
</form>
$msgBlock

<h2>播放测试（M0.1）</h2>
<form method="get">
<p>输入酷我(kw)数字歌曲ID，服务器端直接测试「取链」全链：</p>
<p><input type="text" name="testmid" placeholder="例如 128908374">
<button type="submit">开始取链测试</button></p>
</form>
$testBlock

<p style="color:#999;font-size:.85em">提示：手机端酷我网页版播放页 URL 中的 ID 或分享链接里的数字即歌曲ID。</p>
</body>
</html>
ENDHTML
}

1;
