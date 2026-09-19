# Plugins/LxMusic/Plugin.pm
# ============================================================
# v0.1.0-alpha1: engine bootstrap, Web import/diag page,
# XMLBrowser feed (play-test), lxm:// protocol handler wired.
# NOTE: no "use utf8" on purpose - CJK text lives as raw UTF-8
# bytes (page output and log lines are byte-safe as-is).
# ============================================================

package Plugins::LxMusic::Plugin;

use strict;
use warnings;

# 基类必须是 OPMLBased（不是 Base）：feed/tag/menu 参数、CLI 'lxmusic items'
# dispatch、Jive/player 菜单注册、setMode(xmlbrowser push) 全在 OPMLBased——
# 0.1~0.3.0 误继承 Base，XMLBrowser 菜单从未注册过（latent bug，设备无入口）。
# webPages 不冲突：OPMLBased 注册小写 plugins/lxmusic/index.html（浏览 UI），
# 本插件自注册大写 plugins/LxMusic/index.html（设置/导入/搜索页，正则大小写敏感）。
use base qw(Slim::Plugin::OPMLBased);

use HTML::Entities qw(encode_entities);
use Encode ();
use JSON::XS ();
use MIME::Base64 qw(encode_base64url decode_base64url);
use Time::HiRes qw(time);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Network;
use Slim::Web::Pages;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Control::Request;
use Slim::Player::Client;

use Plugins::LxMusic::Helper;
use Plugins::LxMusic::ProtocolHandler;

# 注册日志分类（LMS 调试页才会列出并可调级别；不注册则 warn/info 静默丢失——排障断腿）
my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.lxmusic',
	'defaultLevel' => 'ERROR',
	'description'  => 'LX Music',
});

my $prefs = preferences('plugin.lxmusic');

sub getDisplayName { 'LX Music' }

sub initPlugin {
	my ($class) = @_;

	$prefs->init({
		sourceContent  => '',
		sourceName     => '',
		quality        => '320k',
		# ---- M0.5 设置页（0.6.0）新增 ----
		bridgeTimeout  => 7,     # 桥级 per-request 超时（秒；migu 内部再打 3 折）
		helperConcurrency => 2,  # Helper 并发子进程上限（整单入队风暴防护）
		resolveTtl     => 600,   # 解析缓存 TTL（秒）
		coverProxy     => 1,     # 封面代理（kg/kw 需经插件中转，设备侧才出图）
		boardsKg       => 1,
		boardsTx       => 1,
		boardsWy       => 1,
		boardsMg       => 1,
	});

	unless (Plugins::LxMusic::Helper->init) {
		$log->error('LxMusic: engine init FAILED, check server.log');
	}

	if (my $content = $prefs->get('sourceContent')) {
		my $name = $prefs->get('sourceName') || 'current';
		my $path = Plugins::LxMusic::Helper->installSource($name . '.js', $content);
		$log->info('LxMusic: source restored: ' . ($path || 'FAILED'));
	}

	if (main::WEBUI) {
		Slim::Web::Pages->addPageFunction(
			'plugins/LxMusic/index\.html',
			sub { $class->webHandler(@_) },
		);
		Slim::Web::Pages->addPageFunction(
			'plugins/LxMusic/playlist\.m3u',
			sub { $class->webHandler(@_) },
		);
		Slim::Web::Pages->addPageFunction(
			'plugins/LxMusic/cover',
			sub { $class->webHandler(@_) },
		);

		# M0.5: 正式设置页（设置 → 插件 → LX Music）
		require Plugins::LxMusic::Settings;
		Plugins::LxMusic::Settings->new();
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

# ================================================== feed menu

sub handleFeed {
	my ($client, $cb, $params, $args) = @_;

	my $src    = Plugins::LxMusic::Helper->sourceInfo;
	my $status = $src->{installed}
		? 'source: ' . ($prefs->get('sourceName') || 'current.js')
		: 'source: none (import via web page)';

	my @items = (
		{
			name        => _u('搜索歌曲'),
			type        => 'search',
			url         => \&sdkSearchHandler,
			passthrough => ['search'],
		},
		{
			name        => _u('搜索歌单'),
			type        => 'search',
			url         => \&sdkSonglistSearchHandler,
			passthrough => ['search'],
		},
		# kw 榜单上游(wbd)签名校验已变(10012)——搜索不受影响，榜单用其余四源
		(
			map { {
				name        => _u($_ . '榜单'),
				type        => 'link',
				url         => \&sdkBoardsHandler,
				passthrough => [ 'boards', $_ ],
			} } grep { _boardEnabled($_) } qw(kg tx wy mg)
		),
		{
			name        => 'Play test (enter song id)',
			type        => 'search',
			url         => \&testHandler,
			passthrough => ['test'],
		},
		{
			name => $status,
			type => 'text',
		},
	);

	# 榜单源全关时给一行提示，避免"菜单像坏了"的错觉（设置页可重新打开）
	if (!grep { _boardEnabled($_) } qw(kg tx wy mg)) {
		splice(@items, 2, 0, { name => _u('（榜单源已在设置页全部关闭）'), type => 'text' });
	}

	$cb->({ items => \@items });
	return;
}

# 榜单源开关（设置页 0.6.0）：每次渲染读 prefs，改完立即生效
sub _boardEnabled {
	my ($src) = @_;
	my %pref = (kg => 'boardsKg', tx => 'boardsTx', wy => 'boardsWy', mg => 'boardsMg');
	my $p = $pref{$src} or return 0;
	return $prefs->get($p) ? 1 : 0;
}

# kw numeric song id -> musicUrl play item
sub testHandler {
	my ($client, $cb, $args) = @_;
	my $input = $args->{search} || '';

	unless ($input =~ /^\s*(\d{4,20})\s*$/) {
		$cb->({ items => [ {
			name => 'enter a numeric kw song id (see web page howto)',
			type => 'text',
		} ] });
		return;
	}
	my $mid = $1;

	my $url = Plugins::LxMusic::ProtocolHandler->buildUrl(
		music => { songmid => $mid },
		src   => 'kw',
		type  => ($prefs->get('quality') || '320k'),
		name  => ('kw #' . $mid),
	);

	$cb->({ items => [ {
		name => 'kw #' . $mid . ' - tap to play',
		type => 'audio',
		url  => $url,
	} ] });
	return;
}

# ================================================== M0.2: 搜索/榜单（vendored musicSdk）

# 本插件刻意不用 use utf8（字节安全，见文件头注）——字符串字面量是 raw UTF-8
# 字节串。XMLBrowser/CLI 通道会对未打旗标的字节串按 latin1 再编码（设备实证：
# 菜单名双重编码乱码）。此 helper 把字节串解码成字符旗标串；JSON::XS 解出来的
# 数据本身就是旗标串，直接透传。
sub _u {
	my ($s) = @_;
	return $s if !defined $s || utf8::is_utf8($s);
	return Encode::decode('UTF-8', $s);
}

# XMLBrowser passthrough 语义（slimserver XMLBrowser.pm L521）：
#   coderef->($client, $cb, \%args, @passthrough_flat)

my %BOARDS_CACHE;    # source => [ {id,name,bangid,...} ]

# 搜索入口：XMLBrowser type=search → $args->{search}
sub sdkSearchHandler {
	my ($client, $cb, $args) = @_;
	my $q = $args->{search} || '';
	$q =~ s/^\s+|\s+$//g;

	unless (length $q) {
		$cb->({ items => [ { name => _u('输入搜索词'), type => 'text' } ] });
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'search',
		info    => { query => $q },   # 无 source = searchMusic 跨源聚合
		timeout => 45,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data}) {
				$cb->({ items => [ { name => _u('搜索失败: ') . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}
			my @items;
			for my $grp (@{ $res->{data} }) {
				next unless $grp && $grp->{list} && @{ $grp->{list} };
				my $srcName = $grp->{source} || '?';
				push @items, @{ _trackItems([ @{ $grp->{list} }[0 .. 11] ], "[$srcName] ") };
			}
			@items = @items[ 0 .. 79 ] if @items > 80;
			$cb->({ items => @items ? \@items : [ { name => _u('无结果'), type => 'text' } ] });
		},
	);
	return;
}

# 榜单目录（source 由 passthrough 传入）
sub sdkBoardsHandler {
	my ($client, $cb, $args, $mode, $src) = @_;
	$src ||= 'kg';

	# 防御：设置页关掉某源后，旧菜单项/已下钻的链接仍可能带该源进来
	if (!_boardEnabled($src)) {
		$cb->({ items => [ { name => _u('该榜单源已在设置页关闭'), type => 'text' } ] });
		return;
	}

	if (my $cached = $BOARDS_CACHE{$src}) {
		$cb->({ items => _boardItems($src, $cached) });
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'boards',
		info    => { source => $src },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data} && $res->{data}{list}) {
				$cb->({ items => [ { name => '榜单获取失败: ' . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}
			$BOARDS_CACHE{$src} = $res->{data}{list};
			$cb->({ items => _boardItems($src, $res->{data}{list}) });
		},
	);
	return;
}

sub _boardItems {
	my ($src, $boards) = @_;
	return [ map { {
		name        => _u($_->{name} || '?'),
		type        => 'link',
		url         => \&sdkBoardTracksHandler,
		passthrough => [ 'tracks', $src, ($_->{bangid} || $_->{id} || '') ],
	} } @$boards ];
}

# 榜单曲目（source/bangid 由 passthrough 传入）；支持 XMLBrowser 窗口（index/quantity）
sub sdkBoardTracksHandler {
	my ($client, $cb, $args, $mode, $src, $bangid) = @_;
	$src    ||= 'kg';
	$bangid ||= '';

	if (!_boardEnabled($src)) {
		$cb->({ items => [ { name => _u('该榜单源已在设置页关闭'), type => 'text' } ] });
		return;
	}

	# 客户端窗口：Material/达菲皮肤滚到第 N 行会用 index/quantity 再请求
	my $index  = $args->{index} || 0;
	my $window = $args->{quantity} || 50;
	$window = 50 if $window < 1 || $window > 300;
	my $page   = int($index / 50) + 1;      # 上游页宽按 50 计
	my $skip   = $index % 50;

	Plugins::LxMusic::Helper->request(
		action  => 'boardlist',
		info    => { source => $src, bangid => $bangid, page => $page },
		timeout => 45,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data} && $res->{data}{list}) {
				$cb->({ items => [ { name => _u('获取失败: ') . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}
			my @list = @{ $res->{data}{list} };
			@list = @list[ $skip .. $#list ] if $skip && @list > $skip;
			@list = @list[ 0 .. $window - 1 ] if @list > $window;
			$cb->({ items => _trackItems(\@list, _u("[$src] ")) });
		},
	);
	return;
}

# track(search/boardlist 产出) -> lxm:// audio 项
sub _trackItems {
	my ($list, $prefix) = @_;
	$prefix ||= '';
	my $q     = $prefs->get('quality') || '320k';
	my @items;
	my $n = 0;
	for my $t (@$list) {
		next unless $t && ref($t) eq 'HASH';
		$n++;
		my $name   = _u($t->{name}   || '?');
		my $singer = _u($t->{singer} || '');
		my $url = Plugins::LxMusic::ProtocolHandler->buildUrl(
			music => $t,
			src   => ($t->{source} || 'kw'),
			type  => $q,
			name  => ($singer ne '' ? "$singer - $name" : $name),
		);
		next unless $url;
		my ($secs, $cover) = (_secsOf($t), _coverOf($t));
		# 渲染期发布队列元数据（喜马拉雅 0.1.47 同款）：队列行才有歌名/时长；封面进 LMS 图像缓存
		Plugins::LxMusic::ProtocolHandler->publishQueueMetadata($url, {
			title   => ($singer ne '' ? "$singer - $name" : $name),
			secs    => $secs,
			cover   => $cover,
			quality => $q,
		});
		push @items, {
			name => sprintf('%03d %s%s%s', $n, $prefix, $name, ($singer ne '' ? " - $singer" : '')),
			type => 'audio',
			url  => $url,
			(length $cover ? (image => $cover) : ()),
			(defined $secs ? (duration => $secs) : ()),
		};
		last if $n >= 1000;   # 安全上限（真分页见 handler 的 index/quantity 处理）
	}
	$log->debug('LxMusic: rows=' . scalar(@items) . ' without-cover='
		. scalar(grep { !$_->{image} } @items)
		. ' without-duration=' . scalar(grep { !defined $_->{duration} } @items));

	# 渲染期预热前几首（点哪首都是缓存命中）——异步，不阻塞页面
	Plugins::LxMusic::ProtocolHandler->warmTracks([ map { $_->{url} } @items ], 3) if @items;
	return \@items;
}

# 'mm:ss' / 'hh:mm:ss' -> 秒
sub _secsOf {
	my ($t) = @_;
	my $iv = $t->{interval} || $t->{duration};
	return undef unless defined $iv && $iv ne '';
	return int($iv) if $iv =~ /^\d+$/;
	my @p = split(/:/, $iv);
	return undef unless @p;
	my $s = 0;
	$s = $s * 60 + ($_ || 0) for @p;
	return $s > 0 ? $s : undef;
}

# 曲目封面：各源 musicInfo 字段不一（wy/tx/mg 有 img；kg/kw 常为 null）
# - kg：albumId 可直出 stdmusic 封面（实测 https://imge.kugou.com/stdmusic/240/966846.jpg -> 200/17.8KB）
# - tx：img 缺失时用 albumMid 推导 T002 封面
# - kw：PC 端 getPic = pic.web?rid=<songmid>，其响应体才是图片 URL（纯文本）——
#       列表行改指插件自己的封面代理（懒加载 + LMS 图像缓存 30 天，不阻塞列表）
sub _coverOf {
	my ($t) = @_;
	my $src = $t->{source} || '';

	# 设置页「封面代理」开关（0.6.0）：关掉后 kg/kw 列表行不再经插件中转 ——
	# 代价是这两源无图（kg 的 CDN 设备侧直连不出图；kw 的图 URL 必须由代理解析
	# pic.web 才能拿到），换来少一次中转。mg 本来就是直取，不受开关影响。
	my $proxy = $prefs->get('coverProxy') ? 1 : 0;

	if ($src eq 'kg' && ($t->{albumId} || '') =~ /^\d+$/) {
		my $direct = 'https://imge.kugou.com/stdmusic/240/' . $t->{albumId} . '.jpg';
		return $proxy ? _coverProxyUrl($direct) : $direct;
	}
	if ($src eq 'mg' && ($t->{img} || '') =~ m{^https?://}) {
		# mg 直连本来就可用（用户实测：走代理前有图）——保持直取，不中转
		my $img = $t->{img};
		$img =~ s/\.webp$/.jpg/i;
		return _u($img);
	}
	if ($src eq 'kw' && ($t->{songmid} || '') =~ /^\d+$/) {
		# 代理内解析 pic.web 再取图；关掉代理则无图可给（pic.web 返回的是文本 URL）
		return $proxy ? _coverProxyUrl('kw:' . $t->{songmid}) : '';
	}

	for my $k (qw(img pic albumPic picUrl cover)) {
		my $v = $t->{$k};
		if (defined $v && $v ne '' && $v =~ m{^https?://}) {
			$v =~ s/\.webp$/.jpg/i;
			return _u($v);
		}
	}
	if ($src eq 'tx' && ($t->{albumMid} || '') =~ /^[A-Za-z0-9]+$/) {
		return 'https://y.gtimg.cn/music/photo_new/T002R300x300M000' . $t->{albumMid} . '.jpg';
	}
	return '';
}

# 封面代理 URL（懒加载 + LMS 图像缓存；设备侧不可直连的 CDN 由此中转并补 Referer/UA）
sub _coverProxyUrl {
	my ($target) = @_;
	my $srv  = eval { Slim::Utils::Network::serverAddr() } || '127.0.0.1';
	my $port = $prefs->get('httpPort') || 9000;
	return "http://$srv:$port/plugins/LxMusic/cover?u=" . encode_base64url($target);
}

# ---------- M0.3 歌单：搜索 -> 详情 -> 播放/整单 ----------

my $TRACK_JSON = JSON::XS->new->utf8->canonical;   # track/playlist hash -> compact JSON

sub sdkSonglistSearchHandler {
	my ($client, $cb, $args) = @_;
	my $q = $args->{search} || '';
	$q =~ s/^\s+|\s+$//g;

	unless (length $q) {
		$cb->({ items => [ { name => _u('输入歌单关键词'), type => 'text' } ] });
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'songlist',
		info    => { query => $q },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data}) {
				$cb->({ items => [ { name => _u('歌单搜索失败: ') . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}
			my @items;
			for my $grp (@{ $res->{data} }) {
				next unless $grp && $grp->{list} && @{ $grp->{list} };
				my $src = $grp->{source} || '?';
				for my $pl (@{ $grp->{list} }) {
					next unless $pl && $pl->{id};
					my $name = _u($pl->{name} || '?');
					# 分隔符也必须走 _u()：join 混用旗标/未旗标串会把 '·' 的字节按 latin1 再编码（Â·）
					my $meta = join(_u(' · '), grep { $_ ne '' } (
						$src,
						($pl->{total} ? _u($pl->{total}) . _u('首') : ''),
						($pl->{author} ? _u($pl->{author}) : ''),
					));
					push @items, {
						name        => _u('🎼 ') . $name . ($meta ne '' ? "  ($meta)" : ''),
						type        => 'link',
						url         => \&sdkSonglistDetailHandler,
						passthrough => [ 'songlistdetail', $src, $pl->{id} ],
						(($pl->{img} && $pl->{img} =~ m{^https?://}) ? (image => _u($pl->{img})) : ()),
					};
					last if @items >= 40;
				}
			}
			$cb->({ items => @items ? \@items : [ { name => _u('无歌单结果'), type => 'text' } ] });
		},
	);
	return;
}

sub sdkSonglistDetailHandler {
	my ($client, $cb, $args, $mode, $src, $plid) = @_;
	$src  ||= 'kg';
	$plid ||= '';

	unless (length $plid) {
		$cb->({ items => [ { name => _u('歌单 id 缺失'), type => 'text' } ] });
		return;
	}

	my $index  = $args->{index} || 0;
	my $window = $args->{quantity} || 50;
	$window = 50 if $window < 1 || $window > 300;
	my $page   = int($index / 50) + 1;
	my $skip   = $index % 50;

	Plugins::LxMusic::Helper->request(
		action  => 'songlistdetail',
		info    => { source => $src, id => $plid, page => $page },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data} && $res->{data}{list}) {
				$cb->({ items => [ { name => _u('歌单详情失败: ') . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}
			my $info = $res->{data}{info} || {};
			my @items;
			push @items, {
				name => _u('🎼 ') . _u($info->{name} || $plid)
					. ($info->{author} ? _u(' · ') . _u($info->{author}) : ''),
				type => 'text',
				(($info->{img} && $info->{img} =~ m{^https?://}) ? (image => _u($info->{img})) : ()),
			};
			# 整单入队：m3u 会被 LMS 当"单条链式流"（队列只 1 条）——改为链接项，
			# 点它由插件侧展开（clear + play 首曲 + add 其余，add 仅 5ms 不阻塞）
			push @items, {
				name        => _u('▶ 播放整个歌单（替换队列）'),
				type        => 'link',
				url         => \&sdkSonglistPlayAllHandler,
				passthrough => [ 'songlistplay', $src, $plid ],
			};
			my @list = @{ $res->{data}{list} };
			@list = @list[ $skip .. $#list ] if $skip && @list > $skip;
			@list = @list[ 0 .. $window - 1 ] if @list > $window;
			my $tracks = _trackItems(\@list);
			push @items, @$tracks;
			$cb->({ items => \@items });
		},
	);
	return;
}

# 整单入队：插件侧展开（LMS 对远程 m3u 只当单条链式流，队列里看不到整单）
sub sdkSonglistPlayAllHandler {
	my ($client, $cb, $args, $mode, $src, $plid) = @_;
	$src  ||= 'kg';
	$plid ||= '';

	unless (length $plid) {
		$cb->({ items => [ { name => _u('歌单 id 缺失'), type => 'text' } ] });
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'songlistdetail',
		info    => { source => $src, id => $plid },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data} && $res->{data}{list} && @{ $res->{data}{list} }) {
				$cb->({ items => [ { name => _u('整单入队失败: ') . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}

			my @list = @{ $res->{data}{list} };
			@list = @list[ 0 .. 99 ] if @list > 100;   # 入队上限 100，防超长单拖慢解析
			my $tracks = _trackItems(\@list);

			my @urls = map { $_->{url} } grep { $_ && $_->{url} } @$tracks;
			my $n = scalar @urls;
			my $queued = 0;

			if ($n) {
				# 目标播放器：优先请求自身的 client（Web/kiosk 页带 ?player=），否则第一个已连接播放器
				my $player = $client;
				unless (ref($player) && $player->can('id') && $player->id && $player->can('power')) {
					my @clients = Slim::Player::Client::clients();
					($player) = grep { $_->can('power') } @clients;
				}
				if ($player) {
					eval {
						Slim::Control::Request::executeRequest($player, [ 'playlist', 'clear' ]);
						Slim::Control::Request::executeRequest($player, [ 'playlist', 'play', $urls[0] ]);
						for my $u (@urls[ 1 .. $#urls ]) {
							Slim::Control::Request::executeRequest($player, [ 'playlist', 'add', $u ]);
						}
						$queued = $n;
					};
					if ($@) {
						$log->error('LxMusic: play-all enqueue failed: ' . $@);
					}
				}
				else {
					$log->warn('LxMusic: play-all has no target player (client=' . (ref($client) || 'undef') . ')');
				}
			}

			my $info = $res->{data}{info} || {};
			my @items;
			push @items, {
				name => _u('🎼 ') . _u($info->{name} || $plid)
					. _u('  · 已入队 ') . $queued . _u(' 首'),
				type => 'text',
			};
			push @items, @$tracks;
			$cb->({ items => \@items });
		},
	);
	return;
}

# ================================================== web page

sub webHandler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	my $msg       = '';
	my $testHtml  = '';

	if ($params->{import} && ($params->{source} || $params->{sourceurl})) {
		($msg) = _handleImport($params);
	}

	if (my $mid = $params->{testmid}) {
		if ($mid =~ /^(\d{4,20})$/) {
			return _testMusicUrl($1, $client, $params, $callback, $httpClient, $response);
		}
		$msg = 'bad test id format';
	}

	# M0.2: web 搜索 + 单曲直链试听
	if (defined $params->{q} && length $params->{q}) {
		return _webPlSearch($params->{q}, $client, $params, $callback, $httpClient, $response)
			if ($params->{type} || '') eq 'pl';
		return _webSearch($params->{q}, ($params->{src} || ''), $client, $params, $callback, $httpClient, $response);
	}
	if (my $trackB64 = $params->{track}) {
		return _webPreview($trackB64, $client, $params, $callback, $httpClient, $response);
	}
	# M0.4: 封面代理（列表行图懒加载入口；设备侧不可直连的 CDN 由此中转）
	if (defined $params->{u}) {
		return _coverProxy($params->{u}, $client, $params, $callback, $httpClient, $response);
	}
	if (defined $params->{kw}) {   # 兼容旧链接
		return _coverProxy(encode_base64url('kw:' . $params->{kw}), $client, $params, $callback, $httpClient, $response);
	}
	# M0.3: 整单 m3u（XMLBrowser '播放整个歌单' 项与页面共用）
	if (my $plref = $params->{pl}) {
		return _playlistM3u($plref, $client, $params, $callback, $httpClient, $response);
	}
	# M0.3: 歌单详情页
	if (my $plid = $params->{plid}) {
		return _webPlDetail($plid, ($params->{plsrc} || 'kg'), $client, $params, $callback, $httpClient, $response);
	}

	my $src    = Plugins::LxMusic::Helper->sourceInfo;
	my $status = $src->{installed}
		? 'installed: ' . encode_entities($prefs->get('sourceName') || 'current.js')
		  . ' (' . length($prefs->get('sourceContent') || '') . ' bytes)'
		: 'no source imported';

	my $msgBlock = $msg ? '<div class="msg">' . $msg . '</div>' : '';
	my $testBlock = $testHtml ? '<div class="msg">' . $testHtml . '</div>' : '';

	my $body = _page($status, $msgBlock, $testBlock);
	$response->code(200);
	$response->header('Content-Type' => 'text/html; charset=utf-8');
	$callback->($client, $params, \$body, $httpClient, $response);
	return;
}

sub _handleImport {
	my ($params) = @_;

	my ($content, $name, $err);

	if ($params->{source}) {
		$content = $params->{source};
		$name    = 'pasted';
	}
	else {
		my $u = $params->{sourceurl};
		$u = 'http://' . $u unless $u =~ m{^https?://}i;
		($content, $err) = _fetch($u);
		$name = ($u =~ m{([^/]+)$})[0] || 'downloaded';
	}

	return ('import failed: ' . encode_entities($err)) if $err;
	return 'import failed: empty content'
		unless $content && $content =~ /\S/ && length($content) > 50;

	# v6 源多为混淆版，明文特征有限：认 SERVER_SCRIPT_CONFIG / @name 头 / 通用挂载
	my $looksOk = ($content =~ /SERVER_SCRIPT_CONFIG/
		|| $content =~ /\@name/
		|| $content =~ /EVENT_NAMES/
		|| $content =~ /lx\s*\.\s*on/);
	my $safe = _safeName($name);
	$prefs->set('sourceContent', $content);
	$prefs->set('sourceName', $safe);
	Plugins::LxMusic::Helper->installSource($safe . '.js', $content);

	return 'imported ' . ($looksOk ? '' : '(WARNING: does not look like an lx source) ')
		. $safe . '.js, ' . length($content) . ' bytes';
}

sub _testMusicUrl {
	my ($mid, $client, $params, $callback, $httpClient, $response) = @_;

	my $sourcePath = Plugins::LxMusic::Helper->currentSourcePath();
	unless ($sourcePath) {
		my $body = _page('no source imported', '', '');
		$response->code(200);
		$response->header('Content-Type' => 'text/html; charset=utf-8');
		$callback->($client, $params, \$body, $httpClient, $response);
		return;
	}

	my $started = time();
	Plugins::LxMusic::Helper->request(
		source   => $sourcePath,
		action   => 'musicUrl',
		sourceId => 'kw',
		info     => {
			musicInfo => { songmid => $mid },
			type      => ($prefs->get('quality') || '320k'),
		},
		timeout  => 20,
		cb       => sub {
			my ($res) = @_;
			my $elapsed = sprintf('%.2f', time() - $started);
			my $text;
			if ($res->{ok} && $res->{data} && !ref($res->{data})) {
				$text = 'OK (' . $elapsed . 's): <a href="'
					. encode_entities($res->{data}) . '">'
					. encode_entities(substr($res->{data}, 0, 120)) . '</a>';
			}
			else {
				$text = 'FAIL (' . $elapsed . 's): '
					. encode_entities($res->{error} || 'unknown');
				my $logs = join("\n", map { encode_entities($_) } @{ $res->{logs} || [] });
				$text .= '<pre>' . $logs . '</pre>' if $logs;
			}
			my $body = _page('', '', '<div class="msg">' . $text . '</div>');
			$response->code(200);
			$response->header('Content-Type' => 'text/html; charset=utf-8');
			$callback->($client, $params, \$body, $httpClient, $response);
		},
	);
	return;
}

# server-side blocking fetch of a subscription url (low frequency op)
sub _fetch {
	my ($url) = @_;
	return (undef, 'url too long') if length($url) > 500;
	return (undef, 'only http/https allowed') unless $url =~ m{^https?://}i;

	my $out = eval {
		local $ENV{PATH} = '/usr/bin:/bin';
		open(my $fh, '-|', '/usr/bin/curl', '-sS', '-L', '--max-time', '30', $url) or die "curl: $!";
		local $/;
		my $s = <$fh>;
		close $fh;
		$s;
	};
	return (undef, "download failed: $@") if $@ || !defined $out;
	return (undef, 'empty download') unless $out =~ /\S/;
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

# ---------- M0.2 web: 搜索 + 试听 ----------

sub _respondPage {
	my ($client, $params, $callback, $httpClient, $response, $body, $code) = @_;
	$response->code($code || 200);
	$response->header('Content-Type' => 'text/html; charset=utf-8');
	$callback->($client, $params, \$body, $httpClient, $response);
	return;
}

sub _webSearch {
	my ($q, $src, $client, $params, $callback, $httpClient, $response) = @_;
	$q =~ s/^\s+|\s+$//g;

	my $started = time();
	Plugins::LxMusic::Helper->request(
		action  => 'search',
		info    => (length $src ? { query => $q, source => $src } : { query => $q }),
		timeout => 45,
		cb      => sub {
			my ($res) = @_;
			my $elapsed = sprintf('%.2f', time() - $started);
			# 诊断：无论成败都渲染 logs 尾部（0.3.3 现场定位通道）
			my $logTail = '';
			{
				my @lg = @{ $res->{logs} || [] };
				@lg = @lg[ $#lg - 39 .. $#lg ] if @lg > 40;
				$logTail = @lg ? '<details open><summary style="cursor:pointer">logs</summary><pre>'
					. join("\n", map { encode_entities($_) } @lg) . '</pre></details>' : '';
			}
			my $html;
			if ($res->{ok} && $res->{data}) {
				my @rows;
				my @groups = length($src) ? ($res->{data}) : @{ $res->{data} };
				for my $grp (@groups) {
					next unless $grp && $grp->{list};
					for my $t (@{ $grp->{list} }) {
						next unless $t && ref($t) eq 'HASH';
						my $mj = encodeTrackJson($t);
						next unless $mj;
						my $types = join('/', map { $_->{type} || '' } @{ $t->{types} || [] });
						my $link = '?track=' . encode_base64url($mj) . '&q=' . encode_entities($q)
							. (length $src ? '&src=' . encode_entities($src) : '');
						push @rows, sprintf(
							'<li><a href="%s">%s</a> <span style="color:#888">%s · %s%s</span></li>',
							$link,
							encode_entities(($t->{name} || '?') . ($t->{singer} ? ' - ' . $t->{singer} : '')),
							encode_entities($types),
							encode_entities($t->{source} || '?'),
							($grp->{total} ? ' · ' . encode_entities($grp->{total}) : ''),
						);
					}
				}
				$html = @rows
					? '<p class="status">"' . encode_entities($q) . '" ' . $elapsed . 's, '
						. scalar(@rows) . ' results (tap title to resolve &amp; preview)</p><ul>' . join('', @rows) . '</ul>'
					: '<p class="status">no results (' . $elapsed . 's)</p>';
			}
			else {
				my $logs = join("\n", map { encode_entities($_) } @{ $res->{logs} || [] });
				$html = '<div class="msg">search FAIL: ' . encode_entities($res->{error} || 'unknown')
					. ($logs ? "<pre>$logs</pre>" : '') . '</div>';
			}
			$html .= $logTail if $logTail;
			_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', $html));
		},
	);
	return;
}

# ---------- M0.3 web: 歌单搜索 / 详情 / 整单 m3u ----------

sub _webPlSearch {
	my ($q, $client, $params, $callback, $httpClient, $response) = @_;
	$q =~ s/^\s+|\s+$//g;

	my $started = time();
	Plugins::LxMusic::Helper->request(
		action  => 'songlist',
		info    => { query => $q },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			my $elapsed = sprintf('%.2f', time() - $started);
			my $logTail = '';
			{
				my @lg = @{ $res->{logs} || [] };
				@lg = @lg[ $#lg - 39 .. $#lg ] if @lg > 40;
				$logTail = @lg ? '<details open><summary style="cursor:pointer">logs</summary><pre>'
					. join("\n", map { encode_entities($_) } @lg) . '</pre></details>' : '';
			}
			my $html;
			if ($res->{ok} && $res->{data}) {
				my @rows;
				for my $grp (@{ $res->{data} }) {
					next unless $grp && $grp->{list} && @{ $grp->{list} };
					my $src = $grp->{source} || '?';
					for my $pl (@{ $grp->{list} }) {
						next unless $pl && $pl->{id};
						my $pid = encode_base64url($pl->{id});
						push @rows, sprintf(
							'<li><a href="?plid=%s&plsrc=%s">%s</a> <span style="color:#888">%s · %s首 · %s</span></li>',
							$pid, encode_entities($src),
							encode_entities($pl->{name} || '?'),
							encode_entities($src),
							encode_entities($pl->{total} || '?'),
							encode_entities($pl->{author} || ''),
						);
					}
				}
				$html = @rows
					? '<p class="status">歌单 "' . encode_entities($q) . '" ' . $elapsed . 's, '
						. scalar(@rows) . ' 个 (点歌单名看曲目)</p><ul>' . join('', @rows) . '</ul>'
					: '<p class="status">no playlist results (' . $elapsed . 's)</p>';
			}
			else {
				my $logs = join("\n", map { encode_entities($_) } @{ $res->{logs} || [] });
				$html = '<div class="msg">songlist FAIL: ' . encode_entities($res->{error} || 'unknown')
					. ($logs ? "<pre>$logs</pre>" : '') . '</div>';
			}
			$html .= $logTail if $logTail;
			_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', $html));
		},
	);
	return;
}

sub _webPlDetail {
	my ($plidB64, $src, $client, $params, $callback, $httpClient, $response) = @_;
	my $plid = eval { decode_base64url($plidB64) };
	unless ($plid) {
		_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', '<div class="msg">bad plid</div>'));
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'songlistdetail',
		info    => { source => $src, id => $plid },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			my $html;
			if ($res->{ok} && $res->{data} && $res->{data}{list}) {
				my $info = $res->{data}{info} || {};
				my $plRef = encode_base64url($TRACK_JSON->encode({ source => $src, id => $plid }));
				my @rows;
				my $n = 0;
				for my $t (@{ $res->{data}{list} }) {
					$n++;
					push @rows, sprintf('<li>%03d %s <span style="color:#888">%s</span></li>',
						$n,
						encode_entities(($t->{name} || '?') . ($t->{singer} ? ' - ' . $t->{singer} : '')),
						encode_entities($t->{source} || $src),
					);
				}
				$html = '<p class="status">' . encode_entities($info->{name} || $plid)
					. ($info->{author} ? ' · ' . encode_entities($info->{author}) : '')
					. ' · ' . scalar(@rows) . ' tracks</p>'
					. '<p><a href="/plugins/LxMusic/playlist.m3u?pl=' . $plRef . '">整单 m3u (给设备/播放器用)</a></p><ul>'
					. join('', @rows) . '</ul>';
			}
			else {
				$html = '<div class="msg">songlist detail FAIL: ' . encode_entities($res->{error} || 'unknown') . '</div>';
			}
			_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', $html));
		},
	);
	return;
}

sub _playlistM3u {
	my ($plref, $client, $params, $callback, $httpClient, $response) = @_;
	my $meta = eval { $TRACK_JSON->decode(decode_base64url($plref)) };
	unless ($meta && ref($meta) eq 'HASH' && $meta->{id}) {
		$response->code(400);
		$response->header('Content-Type' => 'text/plain; charset=utf-8');
		$callback->($client, $params, \('bad pl param'), $httpClient, $response);
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'songlistdetail',
		info    => { source => ($meta->{source} || 'kg'), id => $meta->{id} },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			my $q     = $prefs->get('quality') || '320k';
			# m3u 是字节流：EXTINF 标题与 #PLAYLIST 名都显式按 UTF-8 落字节，防乱码
			my $plName = ($res->{ok} && $res->{data}{info}{name}) ? _u($res->{data}{info}{name}) : 'LX Music playlist';
			my @lines = ('#EXTM3U', '#PLAYLIST:' . Encode::encode('UTF-8', $plName));
			if ($res->{ok} && $res->{data} && $res->{data}{list}) {
				my $cap = 30;   # m3u 截前 30 首：入队解析串行放行，防超长单拖爆队列
				for my $t (@{ $res->{data}{list} }) {
					last if $cap-- <= 0;
					next unless $t && ref($t) eq 'HASH';
					my $name = _u(($t->{singer} ? $t->{singer} . ' - ' : '') . ($t->{name} || '?'));
					my $url = Plugins::LxMusic::ProtocolHandler->buildUrl(
						music => $t,
						src   => ($t->{source} || $meta->{source} || 'kg'),
						type  => $q,
						name  => $name,
					);
					push @lines, '#EXTINF:-1,' . Encode::encode('UTF-8', $name), $url if $url;
				}
			}
			my $body = join("\n", @lines) . "\n";
			$response->code(200);
			$response->header('Content-Type' => 'audio/x-mpegurl');
			$callback->($client, $params, \$body, $httpClient, $response);
			return;
		},
	);
	return;
}

# ---------- M0.4 web: 封面代理（懒加载；设备侧不可直连的 CDN 由此中转） ----------

my %COVER_CACHE;   # target => 图片 URL（kw 的 pic.web 解析结果）

sub _respondImage {
	my ($ct, $body, $client, $params, $callback, $httpClient, $response) = @_;
	$response->code(200);
	$response->header('Content-Type' => ($ct && $ct =~ m{^image/} ? $ct : 'image/jpeg'));
	$response->header('Cache-Control' => 'max-age=86400');
	$callback->($client, $params, \$body, $httpClient, $response);
	return;
}

sub _respondCoverFail {
	my ($why, $client, $params, $callback, $httpClient, $response) = @_;
	$response->code(404);
	$response->header('Content-Type' => 'text/plain; charset=utf-8');
	$callback->($client, $params, \($why), $httpClient, $response);
	return;
}

# 来源 Referer/UA：kg/mg 等 CDN 常按来源校验，设备侧直连不出图多半是这个原因
sub _refererFor {
	my ($url) = @_;
	return 'https://music.migu.cn/'    if $url =~ /migu\.cn/i;
	return 'https://www.kugou.com/'    if $url =~ /kugou\.com/i;
	return 'https://www.kuwo.cn/'      if $url =~ /kuwo\.cn|kwcdn/i;
	return 'https://y.qq.com/'         if $url =~ /gtimg\.cn|qq\.com/i;
	return 'https://music.163.com/'    if $url =~ /126\.net|163\.com/i;
	return '';
}

sub _streamImage {
	my ($imgUrl, $client, $params, $callback, $httpClient, $response) = @_;

	my $ua = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36';
	# ⚠️ SimpleAsyncHTTP 没有 ->request()；header 是作为 get() 的额外参数传给
	# Net::HTTP::NB::formatRequest（LMS 源码 L49-53 注释明示）。用错方法会让
	# 页面处理器崩溃，端点对任何 URL 都返回连接失败（0.5.8 现场）
	my @hdr = ('User-Agent' => $ua, 'Accept' => 'image/*,*/*;q=0.8');
	if (my $ref = _refererFor($imgUrl)) {
		push @hdr, 'Referer' => $ref;
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $res  = shift;
			my $code = ($res && $res->can('code')) ? $res->code : 0;
			my $ct   = ($res && $res->can('header')) ? ($res->header('Content-Type') || '') : '';
			my $body = $res ? $res->content : '';
			$body = '' unless defined $body;
			if ($code == 200 && length $body) {
				return _respondImage($ct, $body, $client, $params, $callback, $httpClient, $response);
			}
			$log->warn("LxMusic: cover upstream $code ct=$ct url=" . substr($imgUrl, 0, 90));
			return _respondCoverFail("upstream $code", $client, $params, $callback, $httpClient, $response);
		},
		{ timeout => 12 },
	)->get($imgUrl, @hdr);
	return;
}

sub _coverProxy {
	my ($uParam, $client, $params, $callback, $httpClient, $response) = @_;

	my $target = eval { decode_base64url($uParam) };
	unless (defined $target && length $target) {
		return _respondCoverFail('bad cover param', $client, $params, $callback, $httpClient, $response);
	}

	# kw：先解析 pic.web（响应体是图片 URL 纯文本，落雪 PC 端 getPic 同款），再取图
	if ($target =~ /^kw:(\d+)$/) {
		my $songmid = $1;
		if (my $cached = $COVER_CACHE{"kw:$songmid"}) {
			return _streamImage($cached, $client, $params, $callback, $httpClient, $response);
		}
		my $api = 'http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid=' . $songmid;
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $res = shift;
				my $img = $res ? $res->content : '';
				$img = '' unless defined $img;
				$img =~ s/^\s+|\s+$//g;
				if ($img =~ m{^https?://\S+$}) {
					%COVER_CACHE = () if keys %COVER_CACHE > 300;
					$COVER_CACHE{"kw:$songmid"} = $img;
					return _streamImage($img, $client, $params, $callback, $httpClient, $response);
				}
				$log->debug('LxMusic: kw pic.web miss for ' . $songmid);
				return _respondCoverFail('no cover', $client, $params, $callback, $httpClient, $response);
			},
			{ timeout => 8 },
		)->get($api);
		return;
	}

	unless ($target =~ m{^https?://}i) {
		return _respondCoverFail('bad cover url', $client, $params, $callback, $httpClient, $response);
	}

	return _streamImage($target, $client, $params, $callback, $httpClient, $response);
}

# track hash -> compact JSON（web 链接用；与 XMLBrowser 的 lxm:// 同一 musicInfo 形状）
sub encodeTrackJson {	my ($t) = @_;
	return eval { $TRACK_JSON->encode($t) } || '';
}

sub _webPreview {
	my ($trackB64, $client, $params, $callback, $httpClient, $response) = @_;

	my $mj  = eval { decode_base64url($trackB64) };
	my $track = eval { JSON::XS->new->utf8->decode($mj) };
	unless ($track && ref($track) eq 'HASH' && ($track->{source} || $track->{songmid} || $track->{hash})) {
		_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', '<div class="msg">bad track param</div>'));
		return;
	}

	my $src     = $track->{source} || 'kw';
	my $started = time();
	Plugins::LxMusic::Helper->request(
		source   => Plugins::LxMusic::Helper->currentSourcePath(),
		action   => 'musicUrl',
		sourceId => $src,
		info     => {
			musicInfo => $track,
			type      => ($prefs->get('quality') || '320k'),
		},
		timeout  => 20,
		cb       => sub {
			my ($res) = @_;
			my $elapsed = sprintf('%.2f', time() - $started);
			my $title = encode_entities(($track->{name} || '?') . ($track->{singer} ? ' - ' . $track->{singer} : ''));
			my $html;
			if ($res->{ok} && $res->{data} && !ref($res->{data})) {
				my $u = encode_entities($res->{data});
				$html = '<div class="msg">OK (' . $elapsed . 's) ' . $title
					. '</div><p><audio controls src="' . $u . '" style="width:100%"></audio></p>'
					. '<p><a href="' . $u . '">direct link</a> · <a href="?q=' . encode_entities($params->{q} || $track->{name} || '') . '">back to search</a></p>';
			}
			else {
				my $logs = join("\n", map { encode_entities($_) } @{ $res->{logs} || [] });
				$html = '<div class="msg">FAIL (' . $elapsed . 's) ' . $title . ': '
					. encode_entities($res->{error} || 'unknown')
					. '<br><b>note:</b> 取直链需已导入订阅源（lxm 源负责 musicUrl）'
					. ($logs ? "<pre>$logs</pre>" : '') . '</div>';
			}
			_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', $html));
		},
	);
	return;
}

# static page assembled from byte lines (no heredoc)
sub _page {
	my ($status, $msgBlock, $testBlock) = @_;

	my @l = (
		'<!DOCTYPE html><html><head><meta charset="utf-8">',
		'<meta name="viewport" content="width=device-width, initial-scale=1">',
		'<title>LX Music - settings</title>',
		'<style>',
		'body { font-family: sans-serif; margin: 2em auto; max-width: 52em; padding: 0 1em; color: #222; }',
		'h1 { font-size: 1.4em; } h2 { font-size: 1.1em; margin-top: 1.6em; }',
		'textarea { width: 100%; height: 10em; font-family: monospace; font-size: 12px; }',
		'input[type=text] { width: 60%; }',
		'.msg { padding: .6em 1em; background: #eef; border: 1px solid #ccd; border-radius: 6px; margin: .8em 0; }',
		'.status { color: #555; } pre { background: #f6f6f6; padding: .6em; overflow: auto; max-height: 14em; }',
		'.box { border: 1px solid #ddd; border-radius: 8px; padding: 1em; margin: 1em 0; }',
		'</style></head><body>',
		'<h1>LX Music <span style="font-size:.6em;color:#888">v'
			. encode_entities(Plugins::LxMusic::Helper->pluginVersion) . '</span></h1>',
		'<div class="box"><h2>Source status</h2><p class="status">' . $status . '</p>',
		'<p>quality: ' . encode_entities($prefs->get('quality') || '320k')
			. '（设置页可改） · 封面代理: '
			. ($prefs->get('coverProxy') ? 'on' : 'off') . '</p></div>',
		'<h2>Import source</h2>',
		'<form method="post">',
		'<p>Option 1: paste the lx custom-source script (.js) below</p>',
		'<textarea name="source" placeholder="paste source script here"></textarea>',
		'<p>Option 2: subscription URL (http/https)</p>',
		'<p><input type="text" name="sourceurl" placeholder="https://.../source.js"></p>',
		'<p><button type="submit" name="import" value="1">Import &amp; enable</button></p>',
		'</form>',
		$msgBlock,
		'<h2>Play test (M0.1)</h2>',
		'<form method="get">',
		'<p>Enter a numeric Kuwo song id to test the musicUrl chain:</p>',
		'<p><input type="text" name="testmid" placeholder="e.g. 128908374">',
		'<button type="submit">Run test</button></p>',
		'</form>',
		$testBlock,
		'<p style="color:#999;font-size:.85em">Hint: the numeric id in the Kuwo web-player URL is the song id.</p>',
		'<h2>Search (M0.2)</h2>',
		'<form method="get">',
		'<p><input type="text" name="q" placeholder="song / artist keyword"> ',
		'<select name="src"><option value="">all sources</option><option>kw</option><option>kg</option><option>tx</option><option>wy</option><option>mg</option></select> ',
		'<button type="submit">Search</button></p>',
		'</form>',
		'</body></html>',
	);

	return join('', @l);
}

1;
