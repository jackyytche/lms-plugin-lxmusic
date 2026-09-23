# Plugins/LxMusic/ProtocolHandler — lxm:// 协议
# ============================================================
# 播放时把 lxm:// 伪 URL 解析为真实音频直链：
#   lxm://m/<base64url(musicInfo JSON)>?s=<platform>&t=<quality>&n=<title>
# 取链走 Plugins::LxMusic::Helper（qjs + 订阅源脚本，musicUrl action），
# 直链交给 LMS 流播：http 直链走 Slim::Player::Protocols::HTTP，
# https 直链走 Slim::Player::Protocols::HTTPS（TLS，见下面的基类选择）。
# 模式跟随 Plugins::Ximalaya::ProtocolHandler（含达菲 canTranscodeSeek 修正）。
# ============================================================

package Plugins::LxMusic::ProtocolHandler;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

# ⚠️ 基类选择（0.11.19）：**https 直链必须走 TLS**。
# 现场实证（2026-09-21，设备日志）：咪咕（星海音乐源 mg）解析出来的直链是
#   https://freetyst.nf.migu.cn/public/.../xxx.flac?...&Key=...&ua=Android_migu
# 而我们的处理器继承的是 Slim::Player::Protocols::HTTP —— 它底下是**纯明文**
# IO::Socket::INET（Slim::Formats::RemoteStream）。于是 LMS 拿明文 HTTP/1.0 去打
# 443 端口：
#   Opening connection to https://freetyst.nf.migu.cn/…: [freetyst.nf.migu.cn on port 443 …]
#   Request: GET /public/…/60054701923151339.flac?… HTTP/1.0
#   Response: HTTP/1.1 400 Bad Request          ← CDN 对明文请求的回应
#   → HTTP::new "Couldn't create socket binding" → PROBLEM_CONNECTING → 播放 70ms 就 stop
# （玩家/直链直接播放没问题：playlist 里放 https:// 时 LMS 用的是它自带的 HTTPS
#   处理器，TLS 正常 ⇒ 这就是"同一首歌，直链能放、插件播放失败"的根因。）
#
# 修法只用 LMS 公开代码：LMS 的 Slim::Player::Protocols::HTTPS = IO::Socket::SSL + HTTP，
# 它的 new() 内部按 URL 协议分流（http: → 走 HTTP 明文路径；https: → 走 SSL 握手路径，
# 且返回来的是我们自己的对象 ⇒ getSeekData/canTranscodeSeek 等覆盖仍然生效）。
# 所以只要运行环境有 SSL，就把基类换成它；没有 SSL 时保持 HTTP（并在 new 里明确报错）。
BEGIN {
	if (eval { require Slim::Networking::Async::HTTP; Slim::Networking::Async::HTTP->hasSSL() }
		&& eval { require Slim::Player::Protocols::HTTPS; 1 }) {
		our @ISA = ('Slim::Player::Protocols::HTTPS');
	}
}

use MIME::Base64 qw(encode_base64url decode_base64url);
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use Encode ();
use Scalar::Util qw(blessed);

use Slim::Music::Info;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Player::Playlist;
use Slim::Player::Client;      # 0.11.30：republish_queued_rows 要遍历所有播放器队列
use Slim::Player::ProtocolHandlers;
use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;      # 0.11.29：整榜入队后延迟补发队列元数据（见 explodePlaylist）

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
	my $su = (blessed($song) && $song->can('streamUrl')) ? $song->streamUrl : undef;
	# ⚠️ 0.11.22：`Slim::Player::Song` **没有 url 方法**（§5.10.55 同款坑）⇒ 旧写法
	# `$song->can('url') ? $song->url : undef` 恒为 undef，导致下面这段"开播前最后一刻校正"
	# 一直是**死代码**（设备日志里始终是 `song=?` 与 `fmt=<nocache>`），tx 那种 CDN 谎报
	# CT 的平台因此拿不到我们发布的码率/格式（"正在播放"那行空白）。
	# 正确来源是 currentTrack()->url（getSeekData 用的就是它）。
	my $u = (blessed($song) && $song->can('currentTrack')) ? eval { $song->currentTrack->url } : undef;
	$u = $song->url if (!$u && blessed($song) && $song->can('url'));

	# ⚠️ 播放前最后一刻校正流格式：LMS 扫描/开流时会用 CDN 声明的 Content-Type 覆盖
	# 类型缓存（QQ/网易的 .flac 直链声明 audio/x-ogg），不修就会把 FLAC 数据交给
	# OGG 解码器 ⇒ 进度条在走但完全无声（2026-09-21 设备日志实证，详见 §5.11.75）。
	# 只用 LMS 公开 API（setContentType / Track::content_type），不动 LMS 代码。
	my $c = (defined $u && length $u) ? _cache_get($u) : undef;
	if ($c && $c->{fmt} && blessed($song) && $song->can('currentTrack')) {
		my $t = $song->currentTrack();
		eval {
			Slim::Music::Info::setContentType($u, $c->{fmt});
			Slim::Music::Info::setContentType($c->{direct}, $c->{fmt}) if $c->{direct};
			$t->content_type($c->{fmt}) if $t && $t->can('content_type');
			# 时长/码率是 canSeek 的前提（Protocols::HTTP::canSeek），开播前再保一次
			my %m;
			$m{bitrate} = int($c->{kbps}) if $c->{kbps};
			$m{secs}    = int($c->{secs}) if $c->{secs};
			Slim::Music::Info::setRemoteMetadata($u, \%m) if %m;
		};
	}

	if ($log->is_info) {
		$log->info('LxMusic: getNextTrack song=' . ($u // '?') . ' streamUrl='
			. (defined $su && length $su ? substr($su, 0, 90) : '<undef>')
			. ' fmt=' . ($c ? ($c->{fmt} // '?') : '<nocache>'));
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
# 0.11.31：`%METADATA` 的声明上移到文件顶部（`republish_known_queued` 在 528 行就要用它，
# 词法变量必须先声明；原来它声明在 882 行的「元数据」段里，导致编译期报 "requires explicit package name"）
my %METADATA;
# 0.11.58：渲染期预热的在飞计数（全局只允许 1 个，见 `warmTracks` 的说明）
my $WARM_INFLIGHT = 0;
# 0.11.49：`%REPUBLISHED`（补发的**内容指纹**）也上移到顶部——`republish_queued_rows`（483 行）
# 与 `republish_known_queued`（585 行）都要用它。指纹语义：url => 上次真的写进 LMS 的内容签名；
# 签名相同 ⇒ 一个字节都不写（写就会换来一条新的 playlist 通知，那是自激回路的原料）。
my %REPUBLISHED;
my $prefs = preferences('plugin.lxmusic');   # 设置页可调（resolveTtl）

# 直链有 CDN 签名时效；TTL 由设置页控制（默认 600s）
sub _resolveTtl {
	my $n = $prefs->get('resolveTtl');
	return (defined $n && $n >= 0 && $n <= 3600) ? int($n) : 600;
}

# 播放路径的"新鲜窗口"（秒）：条目出生时间在这个窗口内才敢直接拿去播放。
# 依据：第三方直链的实际寿命**远短于** resolveTtl（网易实测 13 分钟后 403，kugou 实测 84 秒后
# 已死——0.11.23 的 90s 窗口因此在 kg 首行上翻过车），而"重新取链"实测只要 2~4s，LMS 能等。
# 所以宁可多取一次链，也不要赌旧链还活着：0.11.24 收紧到 30s。
# 注意：`resolveTtl` 仍是缓存条目的硬 TTL（元数据/getSeekData/工具页仍在用它）。
sub _fresh_window { 30 }

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
	my ($url, $direct, $fmt, $kbps, $secs, $len, $bits) = @_;
	return unless $url && $direct;
	%RESOLVE_CACHE = () if keys %RESOLVE_CACHE > $MAX_CACHE;
	my $rec = {
		direct => $direct, fmt => $fmt, kbps => $kbps, secs => $secs, len => $len,
		# 0.11.56：位深也要进缓存——命中路径要靠它算出**真实档位**，
		# 否则缓存命中时会退回"请求的档位"，于是又出现 "44.1kHz/16bit + FLAC 24bit" 这种自相矛盾。
		bits   => $bits,
		born   => time(),          # 出生时间：播放路径按它判"还新鲜吗"（_fresh_window）
		expires => time() + _resolveTtl(),
	};
	$RESOLVE_CACHE{$url}    = $rec;
	# 同一个记录也挂在直链 URL 下：拖动时 LMS 用 currentTrack()/streamUrl 来查，
	# 两个 URL 都可能被问到（0.11.18 的自实现 getSeekData 依赖它）
	$RESOLVE_CACHE{$direct} = $rec;
	return 1;
}

# 拖动支持（0.11.18）：**自己实现** getSeekData，不再依赖 LMS 的码率查询。
# 背景（现场实证）：LMS 的 Protocols::HTTP::getSeekData 第一行是
#     my $bitrate = $song->bitrate() || return;
# 码率查不到就返回 undef，而 StreamingController::_JumpToTime 里
#     return unless $seekdata || $restartIfNoSeek;
# 于是**拖动被静默丢弃**（日志：JumpToTime 之后没有 seek 的 open，几秒后才出现
# seek=false + streamMode=I）。同一首歌有时能拖有时不能，就是因为那一刻码率查得到/
# 查不到。这里用解析时缓存下来的真实数据算，永远有返回：
#   · 有探测长度 + 时长 ⇒ 按比例算字节偏移（最准）
#   · 只有码率        ⇒ 按码率算
#   · 都没有          ⇒ 只给 timeOffset，让转码器用 $START$ 跳过（我们声明了 canTranscodeSeek）
sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	return undef unless defined $newtime && $newtime > 0;

	my $lxm = eval { $song->currentTrack->url } // '';
	my $dir = eval { $song->streamUrl }        // '';
	my $c   = _cache_get($lxm) || _cache_get($dir) || {};

	my %d = (timeOffset => $newtime);
	if ($c->{len} && $c->{secs} && $c->{secs} > 0) {
		$d{sourceStreamOffset} = int($c->{len} * $newtime / $c->{secs});
	}
	elsif ($c->{kbps} && $c->{kbps} > 0) {
		$d{sourceStreamOffset} = int(($c->{kbps} * 1000 / 8) * $newtime);
	}

	$log->warn(sprintf('LxMusic getSeekData: newtime=%s kbps=%s len=%s offset=%s url=%s',
		$newtime, ($c->{kbps} // 'undef'), ($c->{len} // 'undef'),
		($d{sourceStreamOffset} // 'none'), substr($lxm || $dir, 0, 34)));
	return \%d;
}


# 解析收尾（快慢路径共用）：元数据 + 客户端刷新信号 + 流地址替换
sub _finish_resolve {
	my ($class, $song, $url, $info, $direct, $args, $cb, $fmt, $kbps, $secs, $tier) = @_;

	# 0.11.52：档位标签一律用**真实拿到的**（$tier 由 _actualTier 从 fmt/码率/位深推出来），
	# 拿不到才退回"请求的档位"。用户报的问题：pref 选 flac24bit 时，**连 128kbps 的 MP3
	# 也标成 "FLAC 24bit"**——因为旧代码直接拿 `$info->{type}`（请求值）当标签。
	my $qLabel = $class->qualityLabel(defined $tier && length $tier ? $tier : $info->{type});

	# ⚠️ ct 必须用"我们嗅到的真实格式"来定，不能用档位标签猜：QQ/网易 CDN 的 .flac
	# 直链会声明 Content-Type: audio/x-ogg，LMS 扫描时把这个错误类型写进轨道缓存，
	# Song::open 据此把 FLAC 流交给 OGG 解码器 ⇒ 位置在推进但完全无声
	# （2026-09-21 设备日志实证：Checking formats for: ogg-ogg-*-* → Transcoder:
	#   streamMode=I, streamformat=ogg）。
	my %MIME_OF = (
		flc => 'audio/flac', mp3 => 'audio/mpeg', ogg => 'audio/ogg',
		mp4 => 'audio/mp4', wav => 'audio/x-wav', ape => 'audio/x-ape', aac => 'audio/aac',
	);
	my $mime = ($fmt && $MIME_OF{$fmt}) || ($qLabel =~ /FLAC/i ? 'audio/flac' : 'audio/mpeg');

	# 时长兜底：解析结果没有就用曲目元数据里的 interval（"5:09"）
	$secs = Plugins::LxMusic::Helper::_secsOf($info->{music}) unless $secs;

	# 统一的元数据发布（解析后与扫描后各发一次）：LMS 的 scanUrl 会用嗅探结果
	# 覆盖同一 URL 的属性，只发一次会出现"格式/码率闪一下就没"（0.11.9 现场）。
	my $publish = sub {
		my %m = (ct => $mime, type => $qLabel);
		$m{bitrate} = int($kbps) if $kbps && $kbps > 0;   # kbps；"格式码率"靠它
		$m{secs}    = int($secs) if $secs && $secs > 0;   # 时长；canSeek 要求它已知
		$m{title}   = $info->{name} if $info->{name};
		eval { Slim::Music::Info::setRemoteMetadata($url, \%m) };

		# ⚠️ 同一份码率/时长**也必须发给真实直链 URL**（0.11.17）：
		# 拖动时 LMS 走 `HTTP::getSeekData`，它第一行是
		#   my $bitrate = $song->bitrate() || return;
		# 而 `$song->currentTrack()` 指向直链那条记录 ⇒ 直链没有 BITRATE 时
		# getSeekData 返回 undef ⇒ `_JumpToTime` 里 `return unless $seekdata`
		# ⇒ **拖动被静默丢弃**（日志实证：kw 15ms 后 `Song::open seek=true … streamMode=R`，
		# tx 完全没有 seek 的 open、之后是 `seek=false … streamMode=I`）。
		# 直链只发码率/时长，不发 title（避免覆盖直链行的显示名）。
		my %md;
		$md{ct}      = $mime;
		$md{bitrate} = int($kbps) if $kbps && $kbps > 0;
		$md{secs}    = int($secs) if $secs && $secs > 0;
		eval { Slim::Music::Info::setRemoteMetadata($direct, \%md) } if $direct;

		return \%m;
	};
	$log->debug('LxMusic: bc/finish-1 metadata');
	$publish->();

	$log->debug('LxMusic: bc/finish-2 cache');

	# 0.11.56：%METADATA 里的 `quality` 一律存**档位键**（'flac'/'flac24bit'/'320k'/…），
	# 显示标签由 qualityLabel() 现算。旧代码在这里存的是**标签**（'FLAC 24bit'），
	# 于是 getMetadataFor/补发 再经 qualityLabel 一过就成了 "FLAC 24BIT"（大写乱码），
	# 而且标签里带 "24bit" 会一直传下去 ⇒ 与 LMS 自己读到的真实 16bit 自相矛盾。
	$class->cache_metadata($url, {
		title   => $info->{name},
		quality => (defined $tier && length $tier ? $tier : $info->{type}),
		format  => $fmt,
	});

	# 用真实格式覆盖 CDN 撒谎的 Content-Type（只用 LMS 公开 API）
	if ($fmt) {
		eval { Slim::Music::Info::setContentType($url, $fmt) };
		eval { Slim::Music::Info::setContentType($direct, $fmt) };
	}

	# 封面：队列/正在播放也要有图（tx/wy/mg 直取，kg 推导，kw 异步 getPic）
	$log->debug('LxMusic: bc/finish-3 contentType done, cover next');
	eval { $class->_publish_cover($url, $info->{src}, $info->{music}) };
	$log->debug('LxMusic: bc/finish-4 cover done');

	# 晚到元数据：轮询客户端靠 playlist_timestamp 变化才会重取富 status（喜马拉雅 0.1.48/49 实证）
	# ⚠️⚠️ 0.11.50 排查开关：2026-09-22 夜把 LMS 搞崩的最小复现是"1 行 lxm:// 队列 + 播放"
	#   （本地库单曲播放稳、源直链直接入队播放也稳 ⇒ 凶手在我们的 lxm:// 播放链路里）。
	#   这一行是本插件在播放路径上**唯一主动发通知**的地方 ⇒ 单独做成开关做 A/B：
	#   `pref_notifyNewmetadata = 0` 关掉它。默认 1（保持 0.11.x 行为）。
	if (!defined $prefs->get('notifyNewmetadata') || $prefs->get('notifyNewmetadata')) {
		if (blessed($song) && $song->can('master')) {
			if (my $pc = $song->master()) {
				$pc->currentPlaylistUpdateTime(time())
					if blessed($pc) && $pc->can('currentPlaylistUpdateTime');
				$log->debug('LxMusic: bc/finish-5 notify newmetadata');
				Slim::Control::Request::notifyFromArray($pc, [ 'playlist', 'newmetadata' ]);
			}
		}
	}
	$log->debug('LxMusic: bc/finish-5b streamUrl');
	$song->streamUrl($direct) if blessed($song) && $song->can('streamUrl');
	$log->debug('LxMusic: bc/finish-6 done');
	if ($log->is_info) {
		$log->info('LxMusic: resolved ' . substr($url, 0, 40) . ' -> ' . substr($direct, 0, 80));
	}
	$args->{cb} = sub {
		my ($track, @rest) = @_;

		# ⚠️ 0.11.21：**LMS 扫描器拒收时的兜底**（"取链成功却完全无声"的第二类真凶）。
		# 现场（2026-09-21 设备日志 + 对照实验）：直链 CDN 声明
		#   Content-Type: application/octet-stream
		# （星海音乐源的 wy → http://m804.music.126.net/…、星海/独家的 kg →
		#   http://fsdg360.hw.kugou.com/…）时，LMS 的
		#   Slim::Utils::Scanner::Remote::readRemoteHeaders 会把它经 mimeToType 归成
		#   unk（不是音频）⇒ 走"这是播放列表"分支去 parsePlaylist ⇒ 二进制体解析失败
		#   ⇒ cb(undef) ⇒ Song.pm 报 PROBLEM_OPENING_REMOTE_URL ⇒ 整首立刻 stop。
		# 日志指纹：`resolved via [源] … fmt=flc` 之后 ~150ms 就是
		#   `Error: Can't open remote URL: lxm://…`，中间**没有** getNextTrack、没有
		#   RemoteStream::new（根本没去连 CDN）。
		# 对照实验（同一台本机 HTTP 服务、同一份 fLaC 字节、只改响应头）：
		#   audio/x-flac → 位置 1.4→5.6s；application/octet-stream → 秒停。
		# 而 kw 一直正常，因为 kuwo CDN 老实声明 audio/x-flac；裤佬给的 wy/kg 直链落在
		# 别的 CDN 节点（audio/mpeg[谎报]、audio/flac）也能过——所以这是"源给的节点决定"，
		# 不是取链失败。0.11.8 的嗅探覆盖只能救"谎报成另一种音频类型"的情况
		# （tx audio/x-ogg、裤佬 audio/mpeg），octet-stream 是扫描阶段就被丢掉，来不及覆盖。
		# 修法：我们早就知道真实格式（probe 魔数嗅探）⇒ 扫描失败时自己补一条 track
		# 交回 LMS，只走公开 API，且只影响原先必然失败的路径。
		if (!$track && $fmt) {
			my $t = eval { Slim::Music::Info::setContentType($direct, $fmt) };
			if (blessed($t)) {
				eval { $t->content_type($fmt) } if $t->can('content_type');
				eval { $t->title($info->{name}) } if $info->{name} && $t->can('title');
				$track = $t;
				$log->warn('LxMusic: scanner refused direct URL (lying Content-Type) -> '
					. 'synthesised track fmt=' . $fmt . ' ' . substr($direct, 0, 70));
			}
			else {
				$log->error('LxMusic: scanner refused direct URL and synth failed: ' . ($@ || '?'));
			}
		}

		if ($track && $info->{name}) {
			$track->title($info->{name});
			$track->url($url);
		}
		# 扫描回来的 Track 带着嗅探到的错误 CT，而播放格式正是从这里取
		# （Schema::contentType 对 track 对象直接读 content_type 字段）⇒ 改回真实格式
		if ($track && $fmt && $track->can('content_type')) {
			eval { $track->content_type($fmt) };
		}
		# 扫描还会冲掉我们发布的 bitrate/secs（表现："格式码率闪一下就没"+不能拖进度条）
		# ⇒ 扫完按真实值再发一次（见 $publish 注释）
		$publish->() if $track;
		# 透传扫描器给的其余参数（原本写成 $cb->($track, @_)，$track 被传了两次、
		# 后续参数整体错位一格；Song.pm 只读 ($newTrack,$error)，错位会让真实错误串丢失）
		$cb->($track, @rest);
	};
	$class->SUPER::scanUrl($direct, $args);
	return;
}

# ⚠️ 0.11.28：**曲末预取已整体删除**（原 `_prefetch_next`）。原因（0.11.27 诊断实证）：
#   ① 它从 0.5.1 起**从未生效**：用的是 `Slim::Player::Playlist::tracks()` —— 这个 API **不存在**
#      （`Slim::Player/Playlist.pm` 里只有 `playList`/`count`），每次都在 `$tracks` 为 undef 时静默 return；
#      日志现场：`prefetch timer FIRED` → `prefetch entry (when_due=1, blessed=1)` → `prefetch skip: empty playlist`。
#   ② 就算修对 API 也**多余**：**LMS 自己做 lookahead**——本首起播 ~8 秒就来要下一首的 URL，
#      并一直把流准备着（`StreamingController::_PlayAndNext … already fully streaming song`）。
#   ③ 自动连播实测切换 ~2 秒、切换点无重新取链 ⇒ 删掉它零回归，还省掉一次多余的解析与缓存写入。
# 现在"下一首"的准备完全交给 LMS lookahead；我们只保留**渲染期预热**（`warmTracks`）。

# 渲染期预热（0.5.2）：列表渲染完就后台解析前 N 首，用户点哪首都是缓存命中（秒开）。
# ⚠️ 0.11.58：**预热被严格限流**。现场实测（0.11.57，纯浏览 15 页 soak，一次都没点播）：
#   设置页诊断恒温显示「可播校验 在跑 22 个请求 / 全豆要 在跑 22 个请求」——因为每渲染一页
#   歌单/榜单就预热 3 首，而每首又按「档位 × 全部已启用源」派候选（含 verify 探测）。
#   这些 job 全排进**串行** worker，用户真正点歌时排在它们后面 ⇒ "解析慢、越用越卡"。
#   现在：① 全局同一时刻只允许 1 个预热在飞；② 预热请求标记为 bg，设备一忙就被 Helper
#   直接丢弃（不排队）；③ 默认只预热 1 首（`warmMax` 可调，`warmEnable=0` 彻底关）。
sub warmTracks {
	my ($class, $urls, $max) = @_;
	return 0 if defined $prefs->get('warmEnable') && !$prefs->get('warmEnable');
	$max = $prefs->get('warmMax') if !$max && defined $prefs->get('warmMax');
	$max ||= 1;
	return 0 unless $urls && ref($urls) eq 'ARRAY';
	return 0 if $WARM_INFLIGHT;         # ① 全局只允许 1 个预热在飞

	my $n = 0;
	for my $u (@$urls) {
		last if $n >= $max;
		next unless $u && $u =~ m{^lxm://};
		# 只跳过"还新鲜"的条目；过老的照旧重热（否则缓存的死链会让点击直接无声）
		my $c = _cache_get($u);
		next if $c && (time() - ($c->{born} || 0)) < _fresh_window();

		my $info = eval { $class->parseUrl($u) } or next;

		$n++;
		$WARM_INFLIGHT++;
		$log->info('LxMusic: warm ' . $n . ' (' . ($info->{name} || '') . ')');
		Plugins::LxMusic::Helper->resolveTrack(
			music    => $info->{music},
			src      => $info->{src},
			type     => $info->{type},
			timeout  => 20,
			priority => 'bg',           # ② 设备忙 ⇒ Helper 直接丢弃，不排队
			# 0.11.25：预热同样带校验（见 _prefetch_next 的注释）——预热本来就是后台行为，
			# 校验失败的候选由阶梯跳过，落进缓存的就是"探针验过"的链。
			verify  => 1,
			cb      => sub {
				my ($res) = @_;
				$WARM_INFLIGHT-- if $WARM_INFLIGHT > 0;
				if ($res->{ok} && $res->{url}) {
					_cache_put($u, $res->{url}, $res->{format}, $res->{actualKbps},
						$res->{secs}, $res->{length}, $res->{bits});
					$log->info('LxMusic: warm ok (' . ($info->{name} || '') . ') via ['
						. ($res->{source} // '?') . '] verified');
				}
				else {
					$log->warn('LxMusic: warm failed (' . ($info->{name} || '') . '): '
						. ($res->{error} || 'unknown'));
				}
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
			# 0.11.61：队列行/正在播放也走缩略（wy 原图 4.81MB/张，50 行就是 240MB）
			# 0.11.62：这里用**大图档**（`coverThumbBig`，默认 500）——"正在播放"面板会请求
			# 300~500px，用 300 的源会发虚；wy 的 500 档实测 621KB，仍比原图小 7.7 倍。
			return Plugins::LxMusic::Helper->coverThumb($v, undef, 'big');
		}
	}
	if (($src || '') eq 'kg' && ($m->{albumId} || '') =~ /^\d+$/) {
		return 'https://imge.kugou.com/stdmusic/240/' . $m->{albumId} . '.jpg';
	}
	if (($src || '') eq 'tx' && ($m->{albumMid} || '') =~ /^[A-Za-z0-9]+$/) {
		my $s = Plugins::LxMusic::Helper->coverThumbSize(undef, 'big') || 500;
		return 'https://y.gtimg.cn/music/photo_new/T002R' . $s . 'x' . $s
			. 'M000' . $m->{albumMid} . '.jpg';
	}
	return '';
}

# 封面 URL 推导（0.11.28 起**两条发布路径共用**这一份）。
# 现场（2026-09-21 用户报"队列小图/正在播放大图忽有忽无"）：列表与解析各写一份推导，
# 对同一首歌发布了**两个不同的封面 URL** ——
#   · kg：列表走封面代理（getPic 真图），解析路径却给 `imge.kugou.com/stdmusic/240/<albumId>.jpg`
#     （**已知对不同 albumId 返回同一张占位图**，见 Plugin::_coverOf 顶部注释）；
#   · kw：列表走代理（pic.web 解析），解析路径给裸 pic.web URL（无 UA/Referer，CDN 多半拒绝）。
# 统一到 `Plugin::_coverOf` 之后，队列行与正在播放行拿到的是同一个 URL。
sub _cover_url {
	my ($src, $music) = @_;
	my $cover = eval { Plugins::LxMusic::Plugin::_coverOf($music) } // '';
	$cover = _coverFromMusic($src, $music) unless $cover;
	return $cover;
}

# 0.11.30：**建队之后**再给"真的进了队列"的行补发一次元数据/封面。
# 现场（用户 2026-09-21）：页首"全部播放/添加"一次入队整榜（如 tx 热歌榜 300 首）时，
# **除正在播/预读的那一两首外，队列行全没封面**；实测（kw 榜 100 首）：
#     整榜入队 0/100 有图  →  事后重渲染一次榜单页 50/100 有图
# ⇒ **建队之前发布的封面不会被新建的队列行采用**，必须在建队之后再发一次。
# 这里遍历所有播放器的队列，**只补发真的在队列里的 URL**（所以单纯浏览页面时不会白干）。
# 调用方（`Plugin::_trackItems` 的 feed 路径 与 `explodePlaylist`）都用它。
sub republish_queued_rows {
	my ($class, $rows) = @_;

	return 0 unless $rows && ref($rows) eq 'ARRAY' && @$rows;
	my %want = map { $_->{url} => $_ } grep { $_ && $_->{url} } @$rows;
	return 0 unless %want;

	my ($n, $skip) = (0, 0);
	for my $client (Slim::Player::Client::clients()) {
		my $pl = eval { Slim::Player::Playlist::playList($client) };
		next unless $pl && ref($pl) eq 'ARRAY';
		for my $item (@$pl) {
			my $u = blessed($item) ? eval { $item->url } : $item;
			next unless $u && $want{$u};
			my $r = $want{$u};
			# 0.11.49：同一道内容指纹。本函数由**自持定时器**驱动（不是通知），本身不会自激，
			# 但用户连翻几页 feed 就会重复写同一批行 ⇒ 指纹让"没变就不写"。
			my $sig = join("\x1f", map { defined $_ ? $_ : '' }
				@{$r}{qw(cover title secs kbps quality)});
			if (($REPUBLISHED{$u} || '') eq $sig) { $skip++; next; }
			eval {
				$class->publishQueueMetadata($u, {
					title   => $r->{title},
					secs    => $r->{secs},
					kbps    => $r->{kbps},
					cover   => $r->{cover},
					quality => $r->{quality},
				});
			};
			$REPUBLISHED{$u} = $sig;
			$n++;
		}
	}
	%REPUBLISHED = () if scalar(keys %REPUBLISHED) > 3000;
	$log->info("LxMusic: re-published queue metadata for $n rows ($skip unchanged skipped, after the playlist was built)");
	return $n;
}

# 0.11.31：**事件驱动**版补发——队列一变就把"我们已知封面/元数据"的行再发一遍。
# 为什么不用定时器：0.11.29/0.11.30 的 Timer 版实测**回调根本没跑**（日志里连一行都没有，
# 而同一时期"手工重渲染一次榜单页"却能把封面补齐 ⇒ 手段有效、只是定时器这条路不通）。
# 这里订阅 LMS 的 playlist 通知（`Slim::Control::Request::subscribe`），队列一变就同步补发，
# 完全不依赖计时器；300 首入队会连发大量通知，用 2 秒去抖。
# 0.11.32：**尾部去抖**——最后一次队列通知之后 3 秒再补发。
# 现场（0.11.31 实测，级别开到 INFO 才看见）：
#   `playlist-triggered republish for 100 queued rows` 确实跑了，但那次补发发生在 LMS **还在批量建队**的过程中
#   ⇒ 发布过的封面又被随后的建队冲掉；而"事后手工重渲染榜单页"（晚得多）就有效。
# 所以不能"一有通知就补发"，要等"通知停下来"再补发：每次通知都（重新）排一个 +3s 的定时器，
# 它的宿主必须是**我们自己持有的持久 hashref**（实测：`$client` 宿主的定时器会被 LMS 在队列变更时 kill 掉，
# 而 Helper 的 worker 计时器用自持 hashref 一直好用）。
my $REPUB_OWNER = {};

# ⚠️⚠️ 0.11.48 断自激 → 0.11.49 **去自激**（2026-09-22 晚三次崩溃的真凶）
# 现场：日志里 `playlist-triggered republish for 300 queued rows` 每 **2~3 秒**一条、连着十几条，然后 LMS 死；
# 关键旁证：那十几秒里**队列成员一个都没变**（中间既没有 `getNextTrack` 也没有 `resolve`）。
# 机制：我们补发元数据（`setRemoteMetadata`）⇒ LMS 发出新的 `playlist` 通知 ⇒ 订阅者又排一次补发 ⇒ 又写 300 行……
# **+3s 尾部去抖正好等于循环周期**，于是一个 300 行的队列变成"每 3 秒 300 次元数据写入"，
# CPU 被点着（这台是 i386/无风扇小机）直到进程死。
#
# 0.11.48 曾经只是"加指纹 + 把节流放宽到 5s"。**5s 不是修复**：它只是把写入风暴的周期拉长，
# 一旦有人把间隔调小/队列更大，同样的回路照样能把机器点着。0.11.49 改成"**结构上不可能自激**"：
#   ① **确定性触发**（主路径）：改队列的两条我们**自己知道**的路径——`explodePlaylist`（整榜入队）与
#      `Plugin::_trackItems`（榜单页渲染/单曲入队）——各自排一次 +3s 尾部补发。
#      补发的**输入**从此只有"我们自己的代码"，**写元数据不可能再触发补发**（没有反馈边）。
#   ② **通知只当兜底**，且**只认改队列成员的命令**：元数据类 `playlist newmetadata`、播放状态类
#      `playlist newsong/open/stop/pause/sync/cant_open` 一律忽略——它们不可能改变队列内容，
#      而自激回路里收到的正是这一类（`_repub_worthy`）。
#   ③ `%REPUBLISHED` **内容指纹**（0.11.48 引入，保留）：内容没变的行一个字都不写。
#   ④ **自激探测器**：连续多轮"确实写了行、而队列成员却完全没变" ⇒ 隔离 60s 并只报一次。
#      比固定节流有针对性：正常操作零延迟，异常时自动降级而不是硬扛。
#   ⑤ DEBUG 级记录触发通知的原文（有上限），下次复现能直接读出"是谁在触发我们"。
my $REPUB_BUSY = 0;
my $REPUB_LAST = 0;
my $REPUB_MIN_INTERVAL = 1;      # 同一秒内不重复扫（**不再是节流上限**）
my $REPUB_SELF_ROUNDS = 0;       # 连续"写了行但队列没变"的轮数
my $REPUB_SELF_MAX    = 4;       # 达到就隔离
my $REPUB_QUARANTINE  = 0;       # 隔离截止时间（epoch）
my $REPUB_LAST_QSIG   = '';      # 上一轮队列成员签名
my $REPUB_DIAG        = 0;       # 通知原文诊断计数（有上限，避免刷日志）

# 会**改变队列成员**的 playlist 子命令（改这些才可能需要给新行补封面）。
# 相反，下面这些**永远不改队列内容**，收到就直接忽略：
#   newmetadata（元数据写入的通知——自激回路里就是它这一类）
#   newsong / open / stop / pause / sync / cant_open（播放状态）
#   index / jump / modified / name / path / ... （纯查询或播放位置）
my $REPUB_IGNORE = qr{^playlist\s+(?:newmetadata|newsong|open|stop|pause|sync|cant_open|index|jump|modified|name|path|artist|album|genre|duration|playlistsinfo|preview)\b};

sub _repub_worthy {
	my $req = shift;
	return 0 unless $req && ref($req);
	my $str = eval { $req->getRequestString } || '';
	return 0 if $str =~ $REPUB_IGNORE;
	return 1 if $str =~ m{^playlist\b};
	return 0;
}

sub _repub_fire {
	Plugins::LxMusic::ProtocolHandler->republish_known_queued();
}

# 只读诊断口（回归测试 t/republish-loop-test.pl 用它断言"指纹/隔离"状态；设置页也可显示）
sub republish_stats {
	my ($class) = @_;
	return {
		fingerprints => scalar(keys %REPUBLISHED),
		quarantine   => $REPUB_QUARANTINE,
		self_rounds  => $REPUB_SELF_ROUNDS,
		busy         => $REPUB_BUSY,
		last_qsig    => $REPUB_LAST_QSIG,
	};
}

sub _schedule_republish {
	Slim::Utils::Timers::killTimers($REPUB_OWNER, \&_repub_fire);
	Slim::Utils::Timers::setTimer($REPUB_OWNER, time() + 3, \&_repub_fire);
	return 1;
}

sub republish_known_queued {
	my ($class) = @_;

	return 0 if $REPUB_BUSY;                                   # 防重入
	my $now = time();
	return 0 if $now < $REPUB_QUARANTINE;                      # 自激隔离期
	return 0 if $now - $REPUB_LAST < $REPUB_MIN_INTERVAL;      # 同一秒不重复扫
	$REPUB_LAST = $now;
	$REPUB_BUSY = 1;

	my ($n, $skip) = (0, 0);
	my @qurls;
	eval {
		for my $client (Slim::Player::Client::clients()) {
			my $pl = eval { Slim::Player::Playlist::playList($client) };
			next unless $pl && ref($pl) eq 'ARRAY';
			for my $item (@$pl) {
				my $u = blessed($item) ? eval { $item->url } : $item;
				next unless $u && $u =~ m{^lxm://};
				push @qurls, $u;
				my $m = $METADATA{$u} or next;
				next unless $m->{cover} || $m->{title};
				# 指纹：内容没变 ⇒ 一个字节都不写（否则每写一次就换来一个新通知）
				my $sig = join("\x1f", map { defined $_ ? $_ : '' }
					@{$m}{qw(cover title secs kbps quality)});
				if (($REPUBLISHED{$u} || '') eq $sig) { $skip++; next; }
				$class->publishQueueMetadata($u, {
					title   => $m->{title},
					secs    => $m->{secs},
					kbps    => $m->{kbps},
					cover   => $m->{cover},
					quality => $m->{quality},
				});
				$REPUBLISHED{$u} = $sig;
				$n++;
			}
		}
	};
	$REPUB_BUSY = 0;
	%REPUBLISHED = () if scalar(keys %REPUBLISHED) > 3000;   # 上限，防内存无界

	# ④ 自激探测器：**写了行、而队列成员和上一轮完全一样** ⇒ 有东西在反复触发我们。
	# 正常操作不可能这样：真改队列 ⇒ 队列签名必变；只有自激回路才"队列不动却一直在写"。
	my $qsig = join("\x1e", @qurls);
	if ($n) {
		if ($qsig eq $REPUB_LAST_QSIG) {
			$REPUB_SELF_ROUNDS++;
			if ($REPUB_SELF_ROUNDS >= $REPUB_SELF_MAX) {
				$REPUB_QUARANTINE = $now + 60;
				$REPUB_SELF_ROUNDS = 0;
				$log->warn("LxMusic: republish wrote $n rows while the queue did not change"
					. " -> self-trigger suspected, republish quarantined for 60s");
			}
		}
		else {
			$REPUB_SELF_ROUNDS = 0;
		}
	}
	$REPUB_LAST_QSIG = $qsig;

	if ($n) {
		# ⚠️ 用 warn 而不是 info：插件默认级别是 ERROR，info 级**根本不会写进 server.log**
		#（0.11.29/30 我因此误判"定时器没跑"，白白多绕了两轮）
		$log->warn("LxMusic: republish: wrote $n rows, skipped $skip unchanged");
	}
	else {
		# no-op 走 debug：正常运行时不该刷屏（首轮之后每轮都是 no-op，这是**预期**）
		$log->debug("LxMusic: republish: no-op (queue=" . scalar(@qurls) . " rows, $skip current)");
	}
	return $n;
}

# eval 包一层：万一 LMS 版本里没有 subscribe（或测试存根没实现），插件照样加载
# 0.11.49：通知只当**兜底**（主路径是 ① 里两处确定性触发），并且：
#   · 只认改队列成员的命令（`_repub_worthy`）——元数据/播放状态通知一律忽略；
#   · **不再"立即补发"**（0.11.32 已实测那一次发生在 LMS 建队途中，会被随后的建队冲掉）；
#   · 我们自己的写入换来的通知直接忽略（同步重入那一半，`$REPUB_BUSY`）。
my $SUBSCRIBED = eval {
	Slim::Control::Request::subscribe(sub {
		my $req = shift;

		return if $REPUB_BUSY;

		# ⑤ 诊断：DEBUG 级记录触发通知的原文（有上限），下次复现可直接读出"谁在触发我们"
		if ($log->is_debug && $REPUB_DIAG < 40) {
			$REPUB_DIAG++;
			my $str = eval { $req->getRequestString } || '?';
			$log->debug("LxMusic: playlist notify: $str");
		}

		return unless _repub_worthy($req);

		# 只有"改队列成员"的通知才排尾部补发：等通知停下来（LMS 建队结束）+3s 再发一次。
		# 这一步是 0.11.32 的关键：建队途中发布会被随后的建队冲掉。
		Plugins::LxMusic::ProtocolHandler->_schedule_republish();
	}, [['playlist']]);
	1;
};
$log->warn('LxMusic: playlist subscribe unavailable (' . ($@ || 'no subscribe') . ')') unless $SUBSCRIBED;

sub _publish_cover {
	my ($class, $url, $src, $music) = @_;

	my $cover = _cover_url($src, $music);
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
				# 0.11.47：SimpleAsyncHTTP->new 是 (成功回调, **错误回调**, 参数)；
				# 从前少了中间那个 ⇒ 请求失败时在 LMS Select 循环里抛 "Not a CODE reference"
				sub {
					my ($http, $error) = @_;
					$log->warn('LxMusic: kw cover(publish) error: ' . ($error || '?'));
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

	# 命中缓存：**只信"年轻"的条目**（0.11.23）。
	# 背景（设备实测 2026-09-21）：网易的签名直链**十几分钟就 403**（同一 URL 13 分钟后本机复测
	# `HTTP 403 Forbidden`），而 `resolveTtl` 默认 600s ⇒ 缓存里躺着死链。把死链交给
	# `SUPER::scanUrl` 的后果特别隐蔽：LMS 的远端扫描请求拿不到有效响应，**回调永远不来**
	# ⇒ 连 `cb(undef)` 都没机会发 ⇒ 点了没声、几秒后 stop（日志里 `resolve cache HIT` 之后什么都没有）。
	# ⚠️ 0.11.22 曾试过"命中就先 probeUrl 探活"，实测**太慢**：死链在 CDN 侧是"不响应"而不是
	# "快速 403"，探测要等满 8s 超时（日志时间线：12:22:03 命中 → 12:22:13 才重新取链），
	# LMS 早在 ~4s 就放弃了 ⇒ 依然无声。所以改成**按年龄判断**：条目够年轻就直接用（起播快），
	# 超过新鲜窗口就**直接重新取链**（实测 3.2s，LMS 能等；B 组 A/B 就是这样 PASS 的），不做探测。
	my $cached = _cache_get($url);
	my $age = $cached ? (time() - ($cached->{born} || 0)) : 0;
	# ⚠️ 0.11.28 修：这里原本**硬编码 90**，而 0.11.24 把 `_fresh_window()` 改成 30 只改到了
	# （当时还没被证明是死代码的）预取路径 ⇒ 播放路径实际上一直还在用 90 秒窗口
	# （也就是 kg 实测"84 秒的直链已经死了"的那个窗口）。统一用 _fresh_window()。
	if ($cached && $age < _fresh_window()) {
		$log->info('LxMusic: resolve cache HIT (' . ($info->{name} || '') . ") age=${age}s — fresh, using it");
		# 0.11.56：命中也要算**真实档位**（此前不传 ⇒ 退回请求档位，于是永远显示 FLAC 24bit）
		# 0.11.60：连"上游声明的档位"一起传（`$info->{music}{types}`），与播放路径同一套推导
		my $ctier = $class->_actualTier($cached->{fmt}, $cached->{kbps}, $cached->{bits},
			(ref($info->{music}{types}) eq 'ARRAY' ? $info->{music}{types} : undef));
		$class->_finish_resolve($song, $url, $info, $cached->{direct}, $args, $cb,
			$cached->{fmt}, $cached->{kbps}, $cached->{secs}, $ctier);
		return;
	}
	if ($cached) {
		$log->info('LxMusic: cached link too old (' . ($info->{name} || '') . ") age=${age}s"
			. ' -> dropping and re-resolving (CDN links expire well before resolveTtl)');
		delete $RESOLVE_CACHE{$url};
		delete $RESOLVE_CACHE{ $cached->{direct} } if $cached->{direct};
	}

	$class->_resolve_fresh($song, $url, $info, $args, $cb);
	return;
}

# 真正取链（缓存未命中 / 缓存已失效时走这里）：多订阅源聚合 + 音质降级链 + 取链后校验（Helper::resolveTrack）
# 以前的"无源就 cb(undef) 静默失败"改成把原因写进元数据，客户端/日志都看得见
sub _resolve_fresh {
	my ($class, $song, $url, $info, $args, $cb) = @_;

	$log->info('LxMusic: resolving src=' . $info->{src} . ' want=' . $info->{type});

	Plugins::LxMusic::Helper->resolveTrack(
		music   => $info->{music},
		src     => $info->{src},
		type    => $info->{type},
		# 0.11.54：20s 太紧——mg（玉宁熙）要串行打 3 次上游、实测单曲 20~40s，
		# 一到点就判超时 ⇒ 整张歌单几乎全无声（用户报的就是这个）。给到 35s，
		# 慢源另有 Helper 侧的"改走 fork"保护（见 Helper::request 的 %WORKER_BAD）。
		# ⚠️ 0.11.58：**播放路径不能死等 35s**。LMS 自己约 4~8s 就放弃这次取链，用户看到的是
		# "点了半天没声"，而设备还在空转（这是"解析慢"的体感来源）。改为
		#   ① 单候选超时 14s（够快源 + 一次中转链跟跳）；
		#   ② 整体预算 `resolveBudget`（默认 10s）：到点就明确失败并放人，候选转后台跑完缓存。
		timeout  => 14,
		budget   => (defined $prefs->get('resolveBudget') ? $prefs->get('resolveBudget') : 10),
		priority => 'user',
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
			# 0.11.60：**真实档位**统一由这里算（fmt/码率/位深 + 上游 types[] 封顶），
			# 工具页与元数据都取这个值 ⇒ 同一曲目在任何位置显示一致（A0）
			my $tier = $class->_actualTier($res->{format}, $res->{actualKbps}, $res->{bits}, $res->{declared});
			$log->info(sprintf('LxMusic: resolved via [%s] type=%s%s verified=%s%s fmt=%s%s',
				$res->{source} // '?', $tier // $res->{quality} // '?',
				(defined $tier && defined $res->{quality} && $tier ne $res->{quality}
					? "(requested $res->{quality})" : ''),
				$res->{verified} ? 1 : 0,
				(defined $res->{actualKbps} ? " ~$res->{actualKbps}kbps" : ''),
				$res->{format} // '<undef>',
				(($res->{bits} || 0) ? " bits=$res->{bits}" : '')));
			_cache_put($url, $direct, $res->{format}, $res->{actualKbps}, $res->{secs}, $res->{length}, $res->{bits});

			# 实际档位/码率如实进队列元数据（PC 端拿不到这个信息，我们靠 HEAD 反推）
			$class->cache_metadata($url, {
				title     => $info->{name},
				source    => $res->{source},
				quality   => $tier // $res->{quality},
				kbps      => $res->{actualKbps},
				format    => $res->{format},
			});

			# 直链是实际流地址；playlist 里保持稳定的 lxm:// URL
			$class->_finish_resolve($song, $url, $info, $direct, $args, $cb,
				$res->{format}, $res->{actualKbps}, $res->{secs}, $tier);
			return;
		},
	);

	return;
}

# resolve 直链的真实连接（避免重定向循环）
sub new {
	my ($class, $args) = @_;
	$args->{url} = $args->{song}->streamUrl unless $args->{redir};
	my $u = defined $args->{url} ? $args->{url} : '';

	# 0.11.19：https 直链必须有 TLS 基类，否则 LMS 会拿明文 HTTP 打 443（见文件头注释）。
	# 这里显式报错，现场就不用再从 "400 Bad Request / PROBLEM_CONNECTING" 反推了。
	if ($u =~ m{^https://}i && !$class->isa('Slim::Player::Protocols::HTTPS')) {
		$log->error('LxMusic: https direct link but LMS has no SSL (IO::Socket::SSL missing) -> '
			. substr($u, 0, 80));
	}

	if ($log->is_info) {
		my $shown = length $u ? substr($u, 0, 90) : '<undef>';
		$log->info('LxMusic: player open -> ' . $shown);
	}

	my $self = eval { $class->SUPER::new($args) };
	$log->debug('LxMusic: bc/new-super ' . ($self ? 'ok' : 'FAILED'));
	if (!$self) {
		# 0.11.26：**开流失败就踢掉解析缓存**。现场（0.11.25 验收）：
		#   Can't open socket to [m704.music.126.net:80]: 110: Connection timed out → stream failed to open
		# 而**同一条 URL 20 秒后又能播**（CDN 边缘/网络抖动；我们的探针用的是系统 curl，且可能命中
		# 另一个 A 记录，所以探针通过 ≠ LMS 的 IO::Socket::INET 连得上）。
		# 踢掉条目后，下次点击/重试会重新取链（很可能换到另一个边缘主机），不再钉着连不上的那条。
		my $t = eval { $args->{song}->currentTrack->url } // '';
		if ($t) {
			my $c = $RESOLVE_CACHE{$t};
			delete $RESOLVE_CACHE{$t};
			delete $RESOLVE_CACHE{ $c->{direct} } if $c && $c->{direct};
			$log->warn('LxMusic: stream open failed -> dropped resolve cache for ' . substr($t, 0, 40)
				. ' (next try will re-resolve)');
		}
		return undef;
	}
	return $self;
}

# 整榜/整歌单/单曲三语义（0.11.1 榜单页头引入 lxm://b/；0.11.13 加 lxm://l/ 给歌单）：
#   lxm://b/<src>/<bangid> -> 展开为全榜 lxm:// 曲目 URL（上限 100，防超榜拖慢入队）
#   lxm://l/<src>/<plid>   -> 展开为整个歌单的 lxm:// 曲目 URL（同上限）
# 喜马拉雅 xmly://album/<id> 同款机制：LMS 对带 explodePlaylist 的协议做
# playlist play/add 时，先向协议要全量 URL 列表再 playtracks/addtracks
# （Slim::Control::Commands.pm L1383-1400）。曲目 URL 展开为自身（原语义不变）。
sub explodePlaylist {
	my ($class, $client, $url, $cb) = @_;

	my ($kind, $src, $id);
	if    ($url =~ m{^lxm://b/([a-z]+)/([A-Za-z0-9_-]+)$}) { ($kind, $src, $id) = ('board', $1, $2) }
	elsif ($url =~ m{^lxm://l/([a-z]+)/([A-Za-z0-9_-]+)$}) { ($kind, $src, $id) = ('songlist', $1, $2) }

	if ($kind) {
		Plugins::LxMusic::Helper->request(
			action  => ($kind eq 'board' ? 'boardlist' : 'songlistdetail'),
			info    => ($kind eq 'board'
				? { source => $src, bangid => $id, page => 1 }
				: { source => $src, id     => $id, page => 1 }),
			timeout => 45,
			cb      => sub {
				my ($res) = @_;
				unless ($res->{ok} && $res->{data} && $res->{data}{list} && @{ $res->{data}{list} }) {
					$log->error("LxMusic: $kind explode failed: " . ($res->{error} || 'empty list'));
					$cb->([]);
					return;
				}

				my @list = @{ $res->{data}{list} };
				# 0.11.33：整单入队上限 100 → 300（与歌单详情窗口上限一致）。
				# 起因：歌单页头"播放"从前根本不走这里（LMS 把详情 feed 的一页 50 首当播放列表入队），
				# 修好 `playlist` 属性后才真正落到 explodePlaylist；100 会让 >100 首的歌单仍然少一截。
				@list = @list[ 0 .. 299 ] if @list > 300;
				my $q = $prefs->get('quality') || '320k';
				my @urls;
				for my $t (@list) {
					next unless $t && ref($t) eq 'HASH';
					my $name = ($t->{singer} ? $t->{singer} . ' - ' : '') . ($t->{name} || '?');
					my $u = $class->buildUrl(
						music => $t,
						src   => ($t->{source} || $src),
						type  => $q,
						name  => $name,
					);
					next unless $u;
					# 入队前发布队列元数据（歌名/时长/封面/码率估算）——队列行渲染靠它，零额外 API
					$class->_publish_cover($u, ($t->{source} || $src), $t);
					my $secs = _secs_of_interval($t->{interval});
					my $est;
					if ($secs && ref($t->{types}) eq 'ARRAY') {
						my $biggest;
						for my $ty (@{ $t->{types} }) {
							next unless ref $ty eq 'HASH';
							my $b = eval { Plugins::LxMusic::Plugin::_bytesOf($ty->{size}) };
							next unless $b;
							$biggest = $b if !defined $biggest || $b > $biggest;
						}
						$est = int($biggest * 8 / 1000 / $secs) if $biggest;
					}
					$class->publishQueueMetadata($u, {
						title   => $name,
						secs    => $secs,
						kbps    => $est,
						quality => $q,
					});
					# 0.11.32：这里不再自己攒 @repub 快照——封面/歌名已进 %METADATA，
					# 由 playlist 通知的**尾部去抖**统一在"建队结束后"按队列实际内容补发。
					push @urls, $u;
				}
				$cb->(\@urls);

				# 0.11.29 曾在这里用 `setTimer($client, ...)` 补发；0.11.32 撤掉：
				# 实测 **`$client` 当宿主的定时器会被 LMS 在队列变更时 kill**（同一次测量里
				# `__PACKAGE__` 宿主的定时器照常触发，这个从不触发）⇒ 补发改由**自持 `$REPUB_OWNER`**
				# 的尾部去抖负责。
				# 0.11.49：这里**主动排一次**（确定性触发）——整榜入队的落点就是本函数，
				# 不再依赖"LMS 会不会为这次入队发通知"（那正是自激回路的入口）。
				_schedule_republish();
			},
		);
		return;
	}

	$cb->([$url]);
	return;
}

# 'mm:ss' / 秒数 -> 秒（与 Plugin::_secsOf 同语义，PH 侧自持一份避免包反向依赖）
sub _secs_of_interval {
	my ($iv) = @_;
	return undef unless defined $iv && $iv ne '';
	return int($iv) if $iv =~ /^\d+$/;
	my @p = split(/:/, $iv);
	return undef unless @p;
	my $s = 0;
	$s = $s * 60 + ($_ || 0) for @p;
	return $s > 0 ? $s : undef;
}

# ---------- 元数据 ----------
# （`my %METADATA;` 已上移到文件顶部——republish_known_queued 需要先声明）

sub cache_metadata {
	my ($class, $url, $info) = @_;

	# 0.11.31：上限从 200 提到 2000 —— 整榜 300 首要留下全部记录，
	# 否则 playlist 通知触发的补发会找不到早期行的封面（被自己挤掉了）。
	%METADATA = () if keys %METADATA > 2000;

	# 0.11.32：**合并而不是覆盖**。整榜入队（explodePlaylist）的顺序是
	#     _publish_cover($u,...)          # 先写入封面
	#     publishQueueMetadata($u,{...})  # 只带歌名/时长/码率，**没有 cover**
	# 旧实现第二个调用把整条记录替换掉 ⇒ cover 变 ''，后续补发就没封面可发（实测 0/100）。
	# 现在只在"本次给了非空值"时覆盖对应字段。
	my $old = $METADATA{$url} || {};
	my %new = (
		title   => $info->{title}   || $old->{title}   || '',
		quality => $info->{quality} || $old->{quality} || '',
		error   => $info->{error}   || $old->{error}   || '',
		cover   => $info->{cover}   || $old->{cover}   || '',
		secs    => $info->{secs}    || $old->{secs}    || 0,
		# 解析后才知道的真实值（0.11.10）：getMetadataFor 用它们给 UI 发
		# "格式"标签与**数字**码率（此前误把档位 key 当码率发 ⇒ 队列行显示 br=flac24bit）
		kbps    => $info->{kbps}    || $old->{kbps}    || 0,
		format  => $info->{format}  || $old->{format}  || '',
	);
	$METADATA{$url} = \%new;

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
	# 估算码率（types[].size ÷ 时长，Plugin::_trackItems 算出）：写进行属性，
	# 队列行立刻能看到码率；播放后用真实探测值覆盖（_finish_resolve）
	$meta{bitrate} = int($info->{kbps}) if $info->{kbps} && $info->{kbps} > 0;
	return 0 unless scalar keys %meta;

	Slim::Music::Info::setRemoteMetadata($url, \%meta);
	$class->cache_metadata($url, {
		title   => $info->{title},
		cover   => $info->{cover},
		secs    => $info->{secs},
		kbps    => $info->{kbps},       # 0.11.31：补发时要能带上估算码率
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
			# type 给人看：档位 key（flac24bit）→ 显示标签（FLAC 24bit）
			$meta{type} = $class->qualityLabel($m->{quality});
		}
		# bitrate 必须是**数字 kbps**；没有真实码率就别发（否则 UI 显示乱值）
		$meta{bitrate} = int($m->{kbps}) if $m->{kbps} && $m->{kbps} > 0;
		return %meta ? \%meta : {};
	}

	return {};
}

sub qualityLabel {
	my ($class, $type) = @_;
	$type = '' unless defined $type;
	# 0.11.56：**幂等**——已经是人读标签（带空格，如 'FLAC 24bit' / 'MP3 320kbps'）就原样返回。
	# 档位键永远不含空格，所以这条判断不会误伤；旧缓存/旧行里存的标签也不会再被 uc() 成
	# "FLAC 24BIT" 那种大写乱码。
	return $type if $type =~ /\s/;
	return 'MP3 128kbps'  if $type eq '128k';
	return 'MP3 192kbps'  if $type eq '192k';
	return 'MP3 256kbps'  if $type eq '256k';
	return 'MP3 320kbps'  if $type eq '320k';
	return 'FLAC'         if $type eq 'flac';
	return 'FLAC 24bit'   if $type eq 'flac24bit';
	return 'Hi-Res'       if $type eq 'hires';
	return 'AAC'          if $type eq 'aac';
	return uc($type);
}

# 0.11.52：**从真实交付物反推档位**（而不是拿请求值当结果）。
#   · flc + 位深>16 → flac24bit；位深<=16 或未知 → flac
#   · mp3 → 按实测码率分 320k / 256k / 192k / 128k
#   · m4a/aac → 'aac'（qualityLabel 会渲染成 AAC）
#   · 其它格式原样大写交给 qualityLabel
# 0.11.60：**再按"上游声明的档位"封顶**（`$declared`，来自该曲的 `types[]`）。
#   现场（A0 实测）：kw《晴天》上游只声明 `128k/320k/flac`，但交付流实测 1647kbps，
#   于是"码率≥1400 ⇒ 24bit"的启发式把它标成 **FLAC 24bit** —— 比上游声明的还高，用户看到
#   的就是"标签与来源自相矛盾"。规则：在"≤ 推出来的档位"的上游声明里取最高的那个。
my @TIER_ORDER = qw(128k 192k 256k 320k flac flac24bit hires);
my %TIER_RANK;
{ my $i = 0; $TIER_RANK{ $TIER_ORDER[$i] } = ++$i for 0 .. $#TIER_ORDER }

sub _actualTier {
	my ($class, $fmt, $kbps, $bits, $declared) = @_;
	my $f = lc($fmt // '');
	return undef unless length $f;

	# ⚠️ 0.11.60 踩坑：**不要写 `my $tier = EXPR if COND;`** —— 条件为假时那个 `my` 的初始化
	# 根本不执行，而词法变量是复用的 pad 槽，会**残留上一次调用的值** ⇒ 后面的 `!defined $tier`
	# 判空全部失效（实测：mp3 256/192/96、m4a、ape 全部返回上一次的 '320k'）。
	# 一律先无条件初始化，再用 if/elsif 赋值。
	my $tier;
	if ($f eq 'flc') {
		# 位深读到了就信它；**读不到**（探测没取到实体）时用码率兜底——
		# 16bit/44.1k FLAC ≈ 900~1100kbps（mg 实测 934），24bit 通常 ≥1400kbps（念心 tx 实测 1709）。
		$tier = ($bits || 0) > 16 ? 'flac24bit'
			: (($bits || 0) ? 'flac' : (($kbps && $kbps >= 1400) ? 'flac24bit' : 'flac'));
	}
	elsif ($f eq 'mp3') {
		# 0.11.58：按实测码率就近取标（192/256kbps 不再被压成"128k"，也不再一律写 320k）
		$tier = '320k' if $kbps && $kbps >= 300;
		$tier = '256k' if !defined $tier && $kbps && $kbps >= 224;
		$tier = '192k' if !defined $tier && $kbps && $kbps >= 160;
		$tier = '128k' if !defined $tier;
	}
	elsif ($f eq 'm4a' || $f eq 'aac' || $f eq 'mp4') {
		$tier = 'aac';
	}
	elsif ($f eq 'ogg') {
		$tier = 'OGG';
	}
	else {
		$tier = uc($f);
	}

	# 上游声明封顶：只在"声明的档位集合非空"且"我们推的档位不在声明里"时降级。
	if ($tier && $declared && ref($declared) eq 'ARRAY' && @$declared) {
		my %has = map { (ref($_) eq 'HASH' ? ($_->{type} // '') : $_) => 1 } @$declared;
		delete $has{''};
		if (%has && !$has{$tier}) {
			my $myrank = $TIER_RANK{$tier} || 99;
			my ($best, $bestrank) = (undef, -1);
			for my $d (keys %has) {
				my $r = $TIER_RANK{$d} or next;
				($best, $bestrank) = ($d, $r) if $r <= $myrank && $r > $bestrank;
			}
			if (defined $best) {
				$log->info("LxMusic: tier $tier capped to $best by the upstream types[] declaration");
				$tier = $best;
			}
		}
	}
	return $tier;
}

1;

__END__

=head1 NAME

Plugins::LxMusic::ProtocolHandler - lxm:// scheme handler

=cut
