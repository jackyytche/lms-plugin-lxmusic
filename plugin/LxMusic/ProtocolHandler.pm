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
use Slim::Player::ProtocolHandlers;
use Slim::Control::Request;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;      # 0.11.26：曲末预取的定时器（对齐落雪 PC 的"剩余 <10s 才预取"）

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
	my ($url, $direct, $fmt, $kbps, $secs, $len) = @_;
	return unless $url && $direct;
	%RESOLVE_CACHE = () if keys %RESOLVE_CACHE > $MAX_CACHE;
	my $rec = {
		direct => $direct, fmt => $fmt, kbps => $kbps, secs => $secs, len => $len,
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
	my ($class, $song, $url, $info, $direct, $args, $cb, $fmt, $kbps, $secs) = @_;

	my $qLabel = $class->qualityLabel($info->{type});

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
	$publish->();

	$class->cache_metadata($url, { title => $info->{name}, quality => $qLabel, format => $fmt });

	# 用真实格式覆盖 CDN 撒谎的 Content-Type（只用 LMS 公开 API）
	if ($fmt) {
		eval { Slim::Music::Info::setContentType($url, $fmt) };
		eval { Slim::Music::Info::setContentType($direct, $fmt) };
	}

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

# 预取下一首：**按落雪 PC 的做法，等到"快播完"再取**（0.11.26，§5.11.94）。
# 旧版是"本首一开始就预取"（0.5.1），但那条缓存根本撑不到下一首——直链寿命实测 4s~13min，
# 白花一次解析，还容易把死链写进缓存。现在用缓存里的曲长算出"曲末前 15 秒"，到点再取
# （PC 端是剩余 <10s，同款思路）。$when_due=1 表示"定时器到点了，直接取"。
sub _prefetch_next {
	my ($class, $song, $url, $when_due) = @_;

	$log->info('LxMusic: prefetch entry (when_due=' . ($when_due ? 1 : 0) . ', blessed='
		. (blessed($song) ? 1 : 0) . ')') if $when_due;

	return unless blessed($song) && $song->can('master');
	my $client = $song->master() or do {
		$log->info('LxMusic: prefetch skip: no client') if $when_due;
		return;
	};

	unless ($when_due) {
		my $c    = _cache_get($url);
		my $secs = ($c && $c->{secs}) ? $c->{secs} : 0;
		my $lead = 15;
		if ($secs > $lead * 2) {
			my $delay = $secs - $lead;
			$log->info("LxMusic: prefetch scheduled in ${delay}s (track ${secs}s, PC-parity)");
			Slim::Utils::Timers::setTimer($client, time() + $delay, sub {
				# 0.11.27 诊断：确认定时器到底有没有触发
				# （0.11.26 现场：到点那一刻日志里完全没有插件行为，怀疑 $song 已被释放）
				$log->info("LxMusic: prefetch timer FIRED (scheduled ${delay}s after track start)");
				$class->_prefetch_next($song, $url, 1);
			});
			return;
		}
	}

	my $tracks = eval { Slim::Player::Playlist::tracks($client) };
	unless ($tracks && ref($tracks) eq 'ARRAY' && @$tracks) {
		$log->info('LxMusic: prefetch skip: empty playlist') if $when_due;
		return;
	}

	my ($idx) = grep { blessed($tracks->[$_]) && $tracks->[$_]->can('url') && $tracks->[$_]->url eq $url }
		0 .. $#$tracks;
	unless (defined $idx && $idx < $#$tracks) {
		$log->info('LxMusic: prefetch skip: current url not found or no next item') if $when_due;
		return;
	}

	my $nextTrack = $tracks->[ $idx + 1 ];
	return unless blessed($nextTrack) && $nextTrack->can('url');
	my $nextUrl = $nextTrack->url;
	return unless $nextUrl && $nextUrl =~ m{^lxm://};
	# 已有"新鲜"缓存就不必再取；但过老的条目要重取（否则预取出来的也是死链，见 _fresh_window）
	my $nc = _cache_get($nextUrl);
	if ($nc && (time() - ($nc->{born} || 0)) < _fresh_window()) {
		$log->info('LxMusic: prefetch skip: next already fresh (age=' . (time() - ($nc->{born} || 0)) . 's)')
			if $when_due;
		return;
	}

	my $ninfo = eval { $class->parseUrl($nextUrl) } or return;

	$log->info('LxMusic: prefetch next (' . ($ninfo->{name} || '') . ')');
	Plugins::LxMusic::Helper->resolveTrack(
		music   => $ninfo->{music},
		src     => $ninfo->{src},
		type    => $ninfo->{type},
		timeout => 20,
		# 0.11.25：预取**也要校验**（对齐落雪 PC 的 usePreloadNextMusic：先 getMusicUrl 缓存，
		# 再用真实媒体元素 checkMusicUrl 验证，不行就 isRefresh 重取）。校验失败的候选会被
		# resolveTrack 的阶梯自动跳过（现在还是并行的）⇒ 落进缓存的必然是"探针能取到音频字节"的链。
		# 这段是后台行为，慢一点无所谓（用户看不到），换来的是点击那一刻不再赌 URL 还活着。
		verify  => 1,
		cb      => sub {
			my ($res) = @_;
			if ($res->{ok} && $res->{url}) {
				# 必须写全记录：只写 direct 会让播放路径拿不到 fmt/kbps/secs，
				# 表现就是 tx 那种"正在播放"缺格式码率（0.11.22 修过同类问题）
				_cache_put($nextUrl, $res->{url}, $res->{format}, $res->{actualKbps},
					$res->{secs}, $res->{length});
				$log->info('LxMusic: prefetched ok via [' . ($res->{source} // '?') . ']'
					. (defined $res->{actualKbps} ? " ~$res->{actualKbps}kbps" : '') . ' verified');
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
		# 只跳过"还新鲜"的条目；过老的照旧重热（否则缓存的死链会让点击直接无声）
		my $c = _cache_get($u);
		next if $c && (time() - ($c->{born} || 0)) < _fresh_window();

		my $info = eval { $class->parseUrl($u) } or next;

		$n++;
		$log->info('LxMusic: warm ' . $n . ' (' . ($info->{name} || '') . ')');
		Plugins::LxMusic::Helper->resolveTrack(
			music   => $info->{music},
			src     => $info->{src},
			type    => $info->{type},
			timeout => 20,
			# 0.11.25：预热同样带校验（见 _prefetch_next 的注释）——预热本来就是后台行为，
			# 校验失败的候选由阶梯跳过，落进缓存的就是"探针验过"的链。
			verify  => 1,
			cb      => sub {
				my ($res) = @_;
				if ($res->{ok} && $res->{url}) {
					_cache_put($u, $res->{url}, $res->{format}, $res->{actualKbps},
						$res->{secs}, $res->{length});
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
	if ($cached && $age < 90) {
		$log->info('LxMusic: resolve cache HIT (' . ($info->{name} || '') . ") age=${age}s — fresh, using it");
		$class->_finish_resolve($song, $url, $info, $cached->{direct}, $args, $cb,
			$cached->{fmt}, $cached->{kbps}, $cached->{secs});
		$class->_prefetch_next($song, $url);
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
			_cache_put($url, $direct, $res->{format}, $res->{actualKbps}, $res->{secs}, $res->{length});

			# 实际档位/码率如实进队列元数据（PC 端拿不到这个信息，我们靠 HEAD 反推）
			$class->cache_metadata($url, {
				title     => $info->{name},
				source    => $res->{source},
				quality   => $res->{quality},
				kbps      => $res->{actualKbps},
				format    => $res->{format},
			});

			# 直链是实际流地址；playlist 里保持稳定的 lxm:// URL
			$class->_finish_resolve($song, $url, $info, $direct, $args, $cb,
				$res->{format}, $res->{actualKbps}, $res->{secs});
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
				@list = @list[ 0 .. 99 ] if @list > 100;
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
					push @urls, $u;
				}
				$cb->(\@urls);
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
		# 解析后才知道的真实值（0.11.10）：getMetadataFor 用它们给 UI 发
		# "格式"标签与**数字**码率（此前误把档位 key 当码率发 ⇒ 队列行显示 br=flac24bit）
		kbps    => $info->{kbps}    || 0,
		format  => $info->{format}  || '',
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
	# 估算码率（types[].size ÷ 时长，Plugin::_trackItems 算出）：写进行属性，
	# 队列行立刻能看到码率；播放后用真实探测值覆盖（_finish_resolve）
	$meta{bitrate} = int($info->{kbps}) if $info->{kbps} && $info->{kbps} > 0;
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
