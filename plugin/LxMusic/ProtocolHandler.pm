# Plugins/LxMusic/ProtocolHandler — lxm:// 协议
# ============================================================
# 播放时把 lxm:// 伪 URL 解析为真实音频直链：
#   lxm://m/<base64url(musicInfo JSON)>?s=<platform>&t=<quality>&n=<title>
# 取链走 Plugins::LxMusic::Helper（qjs + 订阅源脚本，musicUrl action），
# 直链交给 Slim::Player::Protocols::HTTP 流播。
# 模式跟随 Plugins::Ximalaya::ProtocolHandler（含达菲 canTranscodeSeek 修正）。
# ============================================================

package Plugins::LxMusic::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

use MIME::Base64 qw(encode_base64url decode_base64url);
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use Encode ();
use Scalar::Util qw(blessed);

use Slim::Music::Info;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Player::Playlist;
use Slim::Player::ProtocolHandlers;
use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::LxMusic::Helper;
my $log = logger('plugin.lxmusic');
Slim::Player::ProtocolHandlers->registerHandler('lxm', __PACKAGE__);
my $JSON = JSON::XS->new->utf8->canonical;

# 达菲 seek 修正（Ximalaya 0.1.26 同款）：声明转码级 seek，
# daphile Decode 管道的 $START$ 才会拿到时间偏移。
sub canTranscodeSeek { 1 }

sub isRemote { 1 }

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	# 诊断（info 级，默认 ERROR 级别下不刷屏）：播放阶段 Song 对象上 streamUrl 是否还在
	if ($log->is_info) {
		my $su = (blessed($song) && $song->can('streamUrl')) ? $song->streamUrl : undef;
		my $u  = (blessed($song) && $song->can('url')) ? $song->url : '?';
		$log->info('LxMusic: getNextTrack song=' . $u . ' streamUrl='
			. (defined $su && length $su ? substr($su, 0, 90) : '<undef>'));
	}
	$successCb->();
}

sub shouldCacheImage { 1 }

# ---------- URL 构造/解析 ----------
sub buildUrl {
	my ($class, %a) = @_;

	my $music = $a{music} or return undef;
	my $src   = $a{src}   || 'kw';
	my $type  = $a{type}  || '320k';
	my $name  = $a{name}  || '';

	# name 可能是 raw UTF-8 字节串（.pm 字面量）：uri_escape_utf8 对未打旗标的
	# 字节串按 latin1 逐字节升级 → mojibake。统一解码成字符旗标串（已解码则透传）。
	if (defined $name && $name ne '' && !utf8::is_utf8($name)) {
		$name = Encode::decode('UTF-8', $name);
	}

	my $json = $JSON->encode($music);
	my $b64  = encode_base64url($json);
	my $q    = 's=' . uri_escape_utf8($src)
		. '&t=' . uri_escape_utf8($type)
		. '&n=' . uri_escape_utf8($name);

	return "lxm://m/$b64?$q";
}

sub parseUrl {
	my ($class, $url) = @_;

	my ($b64, $query) = $url =~ m{^lxm://m/([A-Za-z0-9_-]+)(?:\?(.*))?$};
	return undef unless $b64;

	my %q;
	if ($query) {
		for my $kv (split(/&/, $query)) {
			my ($k, $v) = split(/=/, $kv, 2);
			next unless $k;
			$q{$k} = uri_unescape($v // '');
		}
	}

	# 修复队列/正在播放乱码：uri_unescape 返回未打旗标的 UTF-8 字节串，
	# 直接交给 LMS（getMetadataFor/setRemoteMetadata）会被前端按 latin1 再编码一次。
	# 统一 decode 成字符旗标串（非法 UTF-8 时保留原值）。
	for my $k (keys %q) {
		next unless defined $q{$k} && length $q{$k};
		next if utf8::is_utf8($q{$k});
		my $decoded = eval { Encode::decode('UTF-8', $q{$k}, Encode::FB_CROAK()) };
		if (defined $decoded) {
			$q{$k} = $decoded;
		}
		else {
			$log->warn('LxMusic: url param not utf8 (' . $k . '), kept raw');
		}
	}

	my $json  = eval { decode_base64url($b64) } or return undef;
	my $music = eval { $JSON->decode($json) } or return undef;
	ref($music) eq 'HASH' or return undef;

	return {
		music => $music,
		src   => ($q{s} || 'kw'),
		type  => ($q{t} || '320k'),
		name  => ($q{n} || ''),
	};
}

# ---------- 解析缓存（0.5.1）：同一 lxm:// 在 TTL 内直接命中，零 fork ----------
my %RESOLVE_CACHE;      # url => { direct => 'http...', fmt => 'mp3'|'flc'|..., expires => epoch }
my $prefs = preferences('plugin.lxmusic');   # 设置页可调（resolveTtl）

# 直链有 CDN 签名时效；TTL 由设置页控制（默认 600s）
sub _resolveTtl {
	my $n = $prefs->get('resolveTtl');
	return (defined $n && $n >= 0 && $n <= 3600) ? int($n) : 600;
}

my $MAX_CACHE   = 200;

sub _cache_get {
	my ($url) = @_;
	my $c = $RESOLVE_CACHE{$url} or return undef;
	if (($c->{expires} || 0) > time()) {
		return $c;
	}
	delete $RESOLVE_CACHE{$url};
	return undef;
}

sub _cache_put {
	my ($url, $direct, $fmt) = @_;
	return unless $url && $direct;
	%RESOLVE_CACHE = () if keys %RESOLVE_CACHE > $MAX_CACHE;
	$RESOLVE_CACHE{$url} = { direct => $direct, fmt => $fmt, expires => time() + _resolveTtl() };
	return 1;
}


# 解析收尾（快慢路径共用）：元数据 + 客户端刷新信号 + 流地址替换
sub _finish_resolve {
	my ($class, $song, $url, $info, $direct, $args, $cb, $fmt) = @_;

	my $qLabel = $class->qualityLabel($info->{type});
	my %meta = (ct => ($qLabel =~ /FLAC/i ? 'audio/flac' : 'audio/mpeg'), type => $qLabel);
	$meta{title} = $info->{name} if $info->{name};
	Slim::Music::Info::setRemoteMetadata($url, \%meta);
	$class->cache_metadata($url, { title => $info->{name}, quality => $qLabel, format => $fmt });

	# 封面：队列/正在播放也要有图（tx/wy/mg 直取，kg 推导，kw 异步 getPic）
	eval { $class->_publish_cover($url, $info->{src}, $info->{music}) };

	# 晚到元数据：轮询客户端靠 playlist_timestamp 变化才会重取富 status（喜马拉雅 0.1.48/49 实证）
	if (blessed($song) && $song->can('master')) {
		if (my $pc = $song->master()) {
			$pc->currentPlaylistUpdateTime(time())
				if blessed($pc) && $pc->can('currentPlaylistUpdateTime');
			Slim::Control::Request::notifyFromArray($pc, [ 'playlist', 'newmetadata' ]);
		}
	}

	$song->streamUrl($direct) if blessed($song) && $song->can('streamUrl');
	if ($log->is_info) {
		$log->info('LxMusic: resolved ' . substr($url, 0, 40) . ' -> ' . substr($direct, 0, 80));
	}
	$args->{cb} = sub {
		my ($track) = @_;
		if ($track && $info->{name}) {
			$track->title($info->{name});
			$track->url($url);
		}
		$cb->($track, @_);
	};
	$class->SUPER::scanUrl($direct, $args);
	return;
}

# 预取下一首（0.5.1）：把下一首的 2.3s 解析藏在本首播放期间，切歌近乎零等待
sub _prefetch_next {
	my ($class, $song, $url) = @_;

	return unless blessed($song) && $song->can('master');
	my $client = $song->master() or return;

	my $tracks = eval { Slim::Player::Playlist::tracks($client) };
	return unless $tracks && ref($tracks) eq 'ARRAY' && @$tracks;

	my ($idx) = grep { blessed($tracks->[$_]) && $tracks->[$_]->can('url') && $tracks->[$_]->url eq $url }
		0 .. $#$tracks;
	return unless defined $idx && $idx < $#$tracks;

	my $nextTrack = $tracks->[ $idx + 1 ];
	return unless blessed($nextTrack) && $nextTrack->can('url');
	my $nextUrl = $nextTrack->url;
	return unless $nextUrl && $nextUrl =~ m{^lxm://};
	return if _cache_get($nextUrl);            # 已有缓存不必再取

	my $ninfo = eval { $class->parseUrl($nextUrl) } or return;

	$log->info('LxMusic: prefetch next (' . ($ninfo->{name} || '') . ')');
	Plugins::LxMusic::Helper->resolveTrack(
		music   => $ninfo->{music},
		src     => $ninfo->{src},
		type    => $ninfo->{type},
		timeout => 20,
		verify  => 0,                       # 预取只预热：不额外花一次 HEAD
		cb      => sub {
			my ($res) = @_;
			if ($res->{ok} && $res->{url}) {
				_cache_put($nextUrl, $res->{url});
				$log->info('LxMusic: prefetched ok via [' . ($res->{source} // '?') . ']');
			}
			else {
				$log->debug('LxMusic: prefetch failed: ' . ($res->{error} || 'unknown'));
			}
		},
	);
	return;
}

# 渲染期预热（0.5.2）：列表渲染完就后台解析前 N 首，用户点哪首都是缓存命中（秒开）。
# 受 Helper 并发闸（max 2）保护，不会打满设备；已在缓存里的跳过。
sub warmTracks {
	my ($class, $urls, $max) = @_;
	$max ||= 3;
	return 0 unless $urls && ref($urls) eq 'ARRAY';

	my $n = 0;
	for my $u (@$urls) {
		last if $n >= $max;
		next unless $u && $u =~ m{^lxm://};
		next if _cache_get($u);

		my $info = eval { $class->parseUrl($u) } or next;

		$n++;
		$log->info('LxMusic: warm ' . $n . ' (' . ($info->{name} || '') . ')');
		Plugins::LxMusic::Helper->resolveTrack(
			music   => $info->{music},
			src     => $info->{src},
			type    => $info->{type},
			timeout => 20,
			verify  => 0,                   # 预热不校验（真正播放时还会走一次带校验的解析）
			cb      => sub {
				my ($res) = @_;
				_cache_put($u, $res->{url}) if $res->{ok} && $res->{url};
			},
		);
	}
	return $n;
}

# 曲目封面推导（对齐落雪 PC：列表用 musicInfo.img；缺失时按源推导 / getPic）
# - tx/wy/mg：musicInfo.img 自带
# - kg：albumId 直出 stdmusic 封面（实测 200/17.8KB，比 PC 端的 get_res_privilege POST 更省）
# - kw：PC 端 getPic = pic.web?rid=<songmid>，响应体是图片 URL 纯文本（实测 200 -> kwcdn jpg 108KB）
#       该 URL 需要一次 GET 才能拿到，故只在解析时异步取（队列/正在播放有图），列表行不阻塞
sub _coverFromMusic {
	my ($src, $m) = @_;
	return '' unless $m && ref($m) eq 'HASH';

	for my $k (qw(img pic albumPic picUrl cover)) {
		my $v = $m->{$k};
		if (defined $v && $v ne '' && $v =~ m{^https?://}) {
			$v =~ s/\.webp$/.jpg/i;   # mg 的 webp 换成同路径 .jpg（实测 200/159KB jpeg）
			return $v;
		}
	}
	if (($src || '') eq 'kg' && ($m->{albumId} || '') =~ /^\d+$/) {
		return 'https://imge.kugou.com/stdmusic/240/' . $m->{albumId} . '.jpg';
	}
	if (($src || '') eq 'tx' && ($m->{albumMid} || '') =~ /^[A-Za-z0-9]+$/) {
		return 'https://y.gtimg.cn/music/photo_new/T002R300x300M000' . $m->{albumMid} . '.jpg';
	}
	return '';
}

sub _publish_cover {
	my ($class, $url, $src, $music) = @_;

	my $cover = _coverFromMusic($src, $music);
	if ($cover) {
		Slim::Music::Info::setRemoteMetadata($url, { cover => $cover });
		$class->cache_metadata($url, { cover => $cover });
		return 1;
	}

	# kw：一次轻量 GET 换图片 URL（PC 端同款 getPic），异步不阻塞主循环
	if (($src || '') eq 'kw' && $music && ($music->{songmid} || '') =~ /^\d+$/) {
		my $picApi = 'http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid='
			. $music->{songmid};
		eval {
			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					my $res = shift;
					my $img = $res ? $res->content : '';
					if ($img && $img =~ m{^https?://\S+$}) {
						$img =~ s/\s+$//;
						Slim::Music::Info::setRemoteMetadata($url, { cover => $img });
						$class->cache_metadata($url, { cover => $img });
						$log->debug('LxMusic: kw cover ok');
					}
					else {
						$log->debug('LxMusic: kw cover miss');
					}
				},
				{ timeout => 8 },
			)->get($picApi);
		};
		return 1;
	}

	return 0;
}

# ---------- 播放失败自动跳下一曲（pref autoSkipOnError，对齐 PC player.autoSkipOnError）----------
my %SKIPPED;      # url => ts      同一 URL 60s 内只跳一次
my %SKIP_BURST;   # clientid => [ts,...]

sub _auto_skip {
	my ($class, $song, $url, $why) = @_;
	return 0 unless $prefs->get('autoSkipOnError');

	# PC 语义：服务器繁忙（429 / too many requests）不换歌，等重试——这里同样不跳
	if (($why // '') =~ /429|too ?many|toomany/i) {
		$log->warn('LxMusic: rate-limited resolve failure, NOT auto-skipping: ' . $why);
		return 0;
	}

	my $now = time();
	return 0 if $SKIPPED{$url} && $now - $SKIPPED{$url} < 60;
	$SKIPPED{$url} = $now;

	my $client = eval { $song->master } or return 0;
	eval { require Slim::Player::Playlist; require Slim::Player::Source; 1 };
	my $cid = eval { $client->id } // '?';

	# 防连跳风暴：同一客户端 60s 内最多自动跳 3 次（整队全坏时不要无限跳下去）
	my @burst = grep { $now - $_ < 60 } @{ $SKIP_BURST{$cid} || [] };
	push @burst, $now;
	$SKIP_BURST{$cid} = \@burst;
	if (@burst > 3) {
		$log->error("LxMusic: too many auto-skips in 60s, stopping playback ($cid)");
		eval { $client->execute(['stop']) };
		return 0;
	}

	my $count = eval { Slim::Player::Playlist::count($client) } || 0;
	my $idx   = eval { Slim::Player::Source::playingSongIndex($client) };
	$idx = -1 unless defined $idx;
	my $next = $idx + 1;
	if ($count && $next >= $count) {
		$log->warn('LxMusic: failed on the last track, nothing to skip to (' . ($why // '') . ')');
		eval { $client->execute(['stop']) };
		return 0;
	}

	$log->warn("LxMusic: auto-skip to next track (index $idx -> $next of $count; why=$why)");
	eval { $client->execute([ 'playlist', 'jump', $next ]) };
	eval { $client->execute(['play']) };
	return 1;
}

# ---------- 播放解析 ----------
sub scanUrl {
	my ($class, $url, $args) = @_;

	my $song = $args->{song};
	my $cb   = $args->{cb};

	my $info = $class->parseUrl($url);
	unless ($info) {
		$log->error('LxMusic: cannot parse request url');
		$cb->(undef);
		return;
	}

	# 同步快路：命中缓存直接交父类，省掉 qjs fork + 上游请求（桌面版级别的瞬时起播）
	if (my $cached = _cache_get($url)) {
		$log->info('LxMusic: resolve cache HIT (' . ($info->{name} || '') . ')');
		$class->_finish_resolve($song, $url, $info, $cached->{direct}, $args, $cb, $cached->{fmt});
		$class->_prefetch_next($song, $url);
		return;
	}

	# M0.6：多订阅源聚合 + 音质降级链 + 取链后校验（Helper::resolveTrack）
	# 以前的"无源就 cb(undef) 静默失败"改成把原因写进元数据，客户端/日志都看得见
	$log->info('LxMusic: resolving src=' . $info->{src} . ' want=' . $info->{type});

	Plugins::LxMusic::Helper->resolveTrack(
		music   => $info->{music},
		src     => $info->{src},
		type    => $info->{type},
		timeout => 20,
		cb      => sub {
			my ($res) = @_;

			unless ($res->{ok} && $res->{url}) {
				my $why = $res->{error} || 'unknown';
				$log->error('LxMusic: resolve failed: ' . $why);
				$class->cache_metadata($url, { title => $info->{name}, error => $why });
				$class->_auto_skip($song, $url, $why);      # pref autoSkipOnError（默认开）
				$cb->(undef);
				return;
			}

			my $direct = $res->{url};
			$log->info(sprintf('LxMusic: resolved via [%s] type=%s verified=%s%s fmt=%s',
				$res->{source} // '?', $res->{quality} // '?', $res->{verified} ? 1 : 0,
				(defined $res->{actualKbps} ? " ~$res->{actualKbps}kbps" : ''),
				$res->{format} // '<undef>'));
			_cache_put($url, $direct, $res->{format});

			# 实际档位/码率如实进队列元数据（PC 端拿不到这个信息，我们靠 HEAD 反推）
			$class->cache_metadata($url, {
				title     => $info->{name},
				source    => $res->{source},
				quality   => $res->{quality},
				kbps      => $res->{actualKbps},
				format    => $res->{format},
			});

			# 直链是实际流地址；playlist 里保持稳定的 lxm:// URL
			$class->_finish_resolve($song, $url, $info, $direct, $args, $cb, $res->{format});
			$class->_prefetch_next($song, $url);
			return;
		},
	);

	return;
}

# resolve 直链的真实连接（避免重定向循环）
sub new {
	my ($class, $args) = @_;
	$args->{url} = $args->{song}->streamUrl unless $args->{redir};
	if ($log->is_info) {
		my $u = (defined $args->{url} && length $args->{url}) ? substr($args->{url}, 0, 90) : '<undef>';
		$log->info('LxMusic: player open -> ' . $u);
	}
	return $class->SUPER::new($args);
}

sub explodePlaylist {
	my ($class, $client, $url, $cb) = @_;
	$cb->([$url]);
	return;
}

# ---------- 元数据 ----------
my %METADATA;

sub cache_metadata {
	my ($class, $url, $info) = @_;

	%METADATA = () if keys %METADATA > 200;
	$METADATA{$url} = {
		title   => $info->{title}   || '',
		quality => $info->{quality} || '',
		error   => $info->{error}   || '',
		cover   => $info->{cover}   || '',
		secs    => $info->{secs}    || 0,
	};

	return 1;
}

# 渲染期发布队列/正在播放元数据（喜马拉雅 0.1.47 同款）：
# 不发布则队列行只有裸 URL（无歌名/无封面）；列表数据已在手，零额外 API 调用。
sub publishQueueMetadata {
	my ($class, $url, $info) = @_;
	return 0 unless $url && ref($info) eq 'HASH';

	my %meta;
	$meta{title} = $info->{title} if defined $info->{title} && $info->{title} ne '';
	$meta{secs}  = $info->{secs}  if $info->{secs} && $info->{secs} > 0;
	$meta{cover} = $info->{cover} if defined $info->{cover} && $info->{cover} ne '';
	return 0 unless scalar keys %meta;

	Slim::Music::Info::setRemoteMetadata($url, \%meta);
	$class->cache_metadata($url, {
		title   => $info->{title},
		cover   => $info->{cover},
		secs    => $info->{secs},
		quality => $info->{quality},
	});
	return 1;
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;

	if (my $m = $METADATA{$url}) {
		my %meta;
		$meta{title} = $m->{title} if $m->{title};
		$meta{cover} = $m->{cover} if $m->{cover};
		$meta{secs}  = $m->{secs}  if $m->{secs};
		if ($m->{quality}) {
			$meta{type}    = $m->{quality};
			$meta{bitrate} = $m->{quality};
		}
		return %meta ? \%meta : {};
	}

	return {};
}

sub qualityLabel {
	my ($class, $type) = @_;
	return 'MP3 128kbps'  if ($type || '') eq '128k';
	return 'MP3 320kbps'  if ($type || '') eq '320k';
	return 'FLAC'         if ($type || '') eq 'flac';
	return 'FLAC 24bit'   if ($type || '') eq 'flac24bit';
	return 'Hi-Res'       if ($type || '') eq 'hires';
	return uc($type // '');
}

1;

__END__

=head1 NAME

Plugins::LxMusic::ProtocolHandler - lxm:// scheme handler

=cut
