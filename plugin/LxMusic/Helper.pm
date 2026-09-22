# Plugins/LxMusic/Helper.pm — 洛雪音乐引擎宿主
# ============================================================
# 职责：
#   1) init：把插件自带的 qjs 引擎 + shim.mjs 复制到 tmpfs（达菲 /tmp），
#      修复可执行位（LMS 解压丢 +x），并做一次引擎自检（阻塞 <100ms）。
#   2) request：以「每 action 一个进程」模型运行
#         qjs shim.mjs <source.js> <action> <infoJSON>
#      异步：子进程输出重定向到临时文件，父进程用 LMS 原生
#      Slim::Utils::Timers 每 0.25s 轮询 waitpid(WNOHANG)，
#      完成/超时(KILL) 后解析文件回调。不依赖 AnyEvent —— 达菲主循环
#      不驱动 AE（Ximalaya 实证：须用 LMS 原生事件设施）。
#   3) installSource：把订阅源脚本安装进运行时目录。
#
# 进程协议（与 engine/shim.mjs 对齐）：
#   RESULT {"ok":true,"data":...} | RESULT {"ok":false,"error":"..."}
#   LOG <text>   ALERT <json>
# ============================================================

package Plugins::LxMusic::Helper;

use strict;
use warnings;

use Config ();
use Encode ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use File::Copy qw(copy);
use File::Path qw(mkpath rmtree);
use File::Spec;
use JSON::XS ();
use POSIX ();
use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::LxMusic::Sources;

my $log   = Slim::Utils::Log->logger('plugin.lxmusic');
my $prefs = preferences('plugin.lxmusic');

my $TMPDIR  = File::Spec->catdir(File::Spec->tmpdir(), 'LXMusic');
my $QJS     = File::Spec->catfile($TMPDIR, 'qjs');
my $SHIM    = File::Spec->catfile($TMPDIR, 'shim.mjs');
my $SDK     = File::Spec->catfile($TMPDIR, 'sdk.bundle.js');
my $SOURCES = File::Spec->catdir($TMPDIR, 'sources');

my $JSON = JSON::XS->new->utf8->allow_nonref;

my %JOBS;    # pid => job
my @WAITQ;   # 超出并发闸的请求闭包队列（FIFO）

# 常驻 worker 状态（声明必须在最前：shutdown 定义在 worker 段之前，词法变量不会向后可见）
my %WORKER;  # key => { pid, rd, wr, buf, ready, queue=>[], jobs=>{}, last, recent=>[], info, src, key }
my $WID = 0; # worker 请求自增 id（源内唯一即可）
my $PROBE_KEY = '__probe';   # 探测专用 worker（argv[1]='-'，shim 不加载任何订阅源）

# 并发上限改由设置页控制（每次判定读 prefs，改完立即生效）
sub _maxChildren {
	my $n = $prefs->get('helperConcurrency');
	$n = 2 unless defined $n && $n >= 1 && $n <= 8;
	return int($n);
}

# 桥级超时（秒）下发到子进程（shim 读 LX_BRIDGE_TIMEOUT）
sub _bridgeTimeout {
	my $n = $prefs->get('bridgeTimeout');
	$n = 7 unless defined $n && $n >= 2 && $n <= 30;
	return int($n);
}

# 设置页用的引擎状态
sub engineStatus {
	my ($class) = @_;
	return 'qjs 缺失' unless -f $QJS;
	return 'qjs 不可执行（+x 丢失）' unless -x $QJS;
	return 'shim 缺失' unless -f $SHIM;
	return 'sdk bundle 缺失（搜索/歌单不可用）' unless -f $SDK;
	return 'ok（qjs + shim + sdk 就绪）';
}

# 运行中代码的真实版本号：直接读随包 install.xml（单一事实源）。
# 不要硬编码版本字符串——页面/设置页的版本号是判断"设备跑的是哪版"的唯一可靠判据，
# 硬编码会让装机后仍显示旧版本（假阴性）。LMS 不会自动设置 $Plugins::LxMusic::VERSION。
my $PLUGIN_VERSION;
sub pluginVersion {
	my ($class) = @_;
	return $PLUGIN_VERSION if defined $PLUGIN_VERSION;

	$PLUGIN_VERSION = '?';
	my $dir = _pluginDir() or return $PLUGIN_VERSION;
	my $xml = File::Spec->catfile($dir, 'install.xml');
	if (open(my $fh, '<', $xml)) {
		local $/;
		my $s = <$fh> // '';
		close $fh;
		$PLUGIN_VERSION = $1 if $s =~ m{<version>\s*([^<\s]+)\s*</version>};
	}
	return $PLUGIN_VERSION;
}

# ---------- M0.6 多订阅源解析（音质裁剪 + 顺序聚合 + 取链校验）----------
# 对齐 PC 端语义（refs/lx-music-desktop）：
#   · 音质：core/music/utils.ts:223-235 getPlayQuality()——从用户档位往下，取第一个
#     「该曲目有 && 该源支持」的档位，一个都没有才退 128k；**只降不升**
#   · 失败换源：core/music/utils.ts:291-334——逐源重试（429 不换源）
#   · 实际码率：PC 端拿不到（源回传的 type 就是请求值，见 preload.js:83），
#     我们用 HEAD 的 Content-Length ÷ 时长反推，避免"以为在听 flac 其实是 128k"
my @QUALITY_LADDER = qw(flac24bit flac 320k 128k);   # PC: TRY_QUALITYS_LIST + 128k 兜底

sub _pref { my ($k, $d) = @_; my $v = $prefs->get($k); return defined $v ? $v : $d }

# 返回"该试哪些档位"（有序）——多源时外层按音质、内层按源，优先保音质
sub qualityLadder {
	my ($class, $want, $track, $declared) = @_;
	$want = '320k' unless defined $want && length $want;
	return ($want) unless _pref('qualityFallback', 1);

	my $idx;
	for my $i (0 .. $#QUALITY_LADDER) { $idx = $i, last if $QUALITY_LADDER[$i] eq $want }
	my @list = defined $idx ? @QUALITY_LADDER[ $idx .. $#QUALITY_LADDER ] : ($want, '128k');

	# 曲目实际具备的档位（搜索结果 types，对应 PC 的 musicInfo.meta._qualitys）
	my %have = (ref($track->{types}) eq 'ARRAY')
		? map { ($_->{type} => 1) } grep { ref $_ eq 'HASH' && $_->{type} } @{ $track->{types} }
		: ();
	# 源声明支持的档位（运行时探测；未知则不裁剪）
	my %decl = ($declared && ref $declared eq 'ARRAY') ? map { ($_ => 1) } @$declared : ();

	my @out = grep { (!%have || $have{$_}) && (!%decl || $decl{$_}) } @list;
	my %seen;
	@out = grep { !$seen{$_}++ } @out;
	return @out ? @out : ('128k');
}

# 'mm:ss' / 'hh:mm:ss' / 秒数 -> 秒（与 Plugin::_secsOf 同语义）
sub _secsOf {
	my ($t) = @_;
	my $iv = $t->{interval} // $t->{duration};
	return undef unless defined $iv && $iv ne '';
	return int($iv) if $iv =~ /^\d+$/;
	my @p = split(/:/, $iv);
	return undef unless @p;
	my $s = 0;
	$s = $s * 60 + ($_ || 0) for @p;
	return $s > 0 ? $s : undef;
}

# 魔数/后缀 -> LMS 内部格式名（注意 LMS 用 flc 表示 flac、mp4 表示 m4a，见 types.conf）
my %LMS_FORMAT = (
	mp3 => 'mp3', flac => 'flc', fla => 'flc', ogg => 'ogg', oga => 'ogg',
	m4a => 'mp4', mp4 => 'mp4', m4b => 'mp4', wav => 'wav', ape => 'ape', aac => 'aac',
);

# "播放器友好"直链：末段带音频后缀（.mp3/.flac/...）。达菲现场实测：
#   - 带后缀（如 kuwo 的 .../xxx.mp3）→ LMS 代理/转码链路正常，播放位置正常前进；
#   - 不带后缀的脚本中转链（如 yinyue.haitangw.net/kw/kw.php?type=mp3&id=...&level=exhigh）
#     → LMS 判不出代理流格式（contentType=unk），要么静默无声（位置停在 0 秒），
#       要么在补上 formatOverride 后直接把主循环卡死（2026-09-21 两次实测，需重启达菲）。
# 所以默认优先挑带后缀的直链，把中转链留作兜底（pref preferStreamable 可关）。
sub streamFriendly {
	my ($class, $url) = @_;
	return 0 unless defined $url && length $url;
	return $url =~ m%\.(?:mp3|mp2|flac|fla|m4a|mp4|m4b|ogg|oga|opus|wav|ape|aac|wma)(?:[?#].*)?$%i ? 1 : 0;
}

# 判定取链结果的真实格式（给 LMS 的 formatOverride 用）：
# 优先用探测嗅探到的魔数，其次看直链后缀，都不知道就返回 undef（让 LMS 自己判断）。
sub lmsFormat {
	my ($class, $magic, $url) = @_;
	return $LMS_FORMAT{$magic} if $magic && $LMS_FORMAT{$magic};
	if (defined $url && $url =~ m%\.([A-Za-z0-9]{2,4})(?:[?#].*)?$%) {
		my $e = lc $1;
		return $LMS_FORMAT{$e} if $LMS_FORMAT{$e};
	}
	return undef;
}

# 直链可播性探测（走 shim 的 probe：curl -I，不允许 HEAD 时退 Range 0-0）
sub probeUrl {
	my ($class, $url, $cb) = @_;
	$class->request(
		action  => 'probe',
		info    => { url => $url, timeout => 8 },
		timeout => 15,
		cb      => sub {
			my ($res) = @_;
			my $d    = (ref($res->{data}) eq 'HASH') ? $res->{data} : {};
			my $code = $d->{status} || 0;
			my $type = lc($d->{type} // '');
			my $magic = $d->{magic} // '';
			# 判定以 shim 的实体嗅探为主（魔数认得就放行）；没有魔数时退回 Content-Type 白名单，
			# 但 text/*（HTML 错误页）一律拒绝 —— 这类"HEAD 200 但 GET 是空壳"的直链会静默无声。
			my $ok = $res->{ok} && $code >= 200 && $code < 300
				&& ($magic ne '' || $type eq '' || $type =~ m{^(?:audio/|video/|application/(?:octet-stream|x-))});
			$cb->({
				ok     => $ok ? 1 : 0,
				status => $code,
				type   => $d->{type},
				length => $d->{length},
				method => $d->{method},
				magic  => $magic,
				bytes  => $d->{bytes},
				# 0.11.51：重定向链的**最终 URL**（无跳转时为空串）——上层用它替代原直链，
				# 免得把一条会 302 的聚合中转链交给 LMS 的开流路径（现场会挂死，见 shim 注释）。
				effective => ($d->{url_effective} && $d->{url_effective} ne $url)
					? $d->{url_effective} : '',
				error  => $ok ? undef : (($res->{error} // ($code ? "HTTP $code" : 'no response'))
					. ($type ne '' ? " type=$type" : '')
					. ($magic ne '' ? " magic=$magic" : '')
					. (defined $d->{bytes} ? " bytes=$d->{bytes}" : '')),
			});
		},
	);
}

# 多源解析：resolveTrack(music=>{}, src=>'kw', type=>'320k', cb=>sub{...})
# cb 收到 { ok, url, source, quality, verified, actualKbps, tries=>[{source,quality,why|ok}] }
sub resolveTrack {
	my ($class, %a) = @_;
	my $cb = $a{cb} or return;

	my $track = (ref($a{music}) eq 'HASH') ? $a{music} : {};
	my $wantVerify = defined $a{verify} ? $a{verify} : _pref('verifyUrl', 1);

	my $sources = Plugins::LxMusic::Sources->enabled;
	unless (@$sources) {
		return $cb->({
			ok    => 0,
			error => '没有可用的订阅源（设置 → 插件 → LX Music → 订阅源）',
			tries => [],
		});
	}

	my @ladder = $class->qualityLadder($a{type}, $track, $a{declaredQualitys});
	# 外层音质、内层源：优先保音质，同档位再依次换源（PC 只换源不降档，我们两者都做）
	my @cand;
	for my $q (@ladder) {
		for my $s (@$sources) { push @cand, [ $q, $s ] }
	}

	my @tries;
	my @deferred;          # 能取到、但不"播放器友好"的候选（无音频后缀的脚本中转链）
	my $preferFriendly = defined $a{preferFriendly} ? $a{preferFriendly} : _pref('preferStreamable', 1);

	# 0.11.24：**并行尝试候选**。原来是串行的（上一个彻底失败才试下一个），而现场最常见的形态是
	# "排在前面的源自己上游超时 ~4s → 才轮到后面的源成功"（wy 行 46 实测 `resolved OK (8.86s)`：
	# 独家音源@flac 先失败、星海@flac 才成功）⇒ 串起来就超过 LMS 的耐心（约 4~8s），
	# 表现为"点了没声"。这里开一个 **2 个候选的并行窗口**：谁先给出可用直链就用谁
	# （仍尊重 preferStreamable：无音频后缀的中转链只挂起、等友好直链）。
	# 窗口保守取 2：每个源一个常驻 worker，设备是双核达菲。
	# 全程对外语义不变（tries/source/quality/deferred 都照旧记录）。
	my $K        = 2;
	my $inflight = 0;
	my $done     = 0;
	my $dispatch;

	# 交付一个候选（写 tries + 回调）；$friendly 标记是否播放器友好
	my $finish = sub {
		my ($src, $q, $url, $tm, $friendly, $verified, $kbps, $magic, $len) = @_;
		return if $done;                 # 并行窗口下只交付一次
		$done = 1;
		my $suspect = ($kbps && $kbps < 64) ? 1 : 0;
		if ($suspect) {
			$log->warn("LxMusic resolve: SUSPECT short/preview file ([" . ($src->{name} // '?')
				. "] type=$q -> ~${kbps}kbps) — 可能是试听片段或残缺文件");
		}
		my $fmt = $class->lmsFormat($magic, $url);
		# 时长：曲目元数据里的 interval（搜索结果/榜单条目都有）；LMS 的
		# Protocols::HTTP::canSeek 要求 bitrate **和** duration 都已知才允许拖动
		my $secs = _secsOf($track);
		push @tries, { source => $src->{name}, quality => $q, ok => 1, verified => $verified,
			kbps => $kbps, suspect => $suspect, magic => $magic, format => $fmt,
			friendly => $friendly, %$tm };
		$log->warn("LxMusic resolve OK: [" . $src->{name} . "] type=$q verified=$verified"
			. (defined $kbps ? " ~${kbps}kbps" : '') . ($suspect ? ' (SUSPECT)' : '')
			. " total=" . ($tm->{ms} // '?') . 'ms path=' . ($tm->{path} // '?')
			. (defined $tm->{handler} ? " handler=$tm->{handler}ms" : '')
			. ' friendly=' . $friendly
			. ' url=' . substr($url, 0, 90));
		$cb->({
			ok         => 1,
			url        => $url,
			source     => $src->{name},
			sourceId   => $src->{id},
			quality    => $q,
			verified   => $verified,
			actualKbps => $kbps,
			secs       => $secs,
			length     => $len,          # 探测到的文件总字节数（拖动算偏移用）
			suspect    => $suspect,
			magic      => $magic,
			format     => $fmt,
			friendly   => $friendly,
			tries      => \@tries,
		});
		return;
	};

	# 校验后交付（verifyUrl 关掉则直接交付）
	my $verifyThenFinish = sub {
		my ($src, $q, $url, $tm, $friendly, $settle) = @_;
		return $finish->($src, $q, $url, $tm, $friendly, 0, undef, undef) unless $wantVerify;
		my $tv = Time::HiRes::time();
		$class->probeUrl($url, sub {
			my ($pi) = @_;
			$tm->{verify} = int((Time::HiRes::time() - $tv) * 1000 + 0.5);
			$tm->{ms} = ($tm->{ms} || 0) + $tm->{verify};   # 总耗时 = 取链 + 校验
			if ($pi->{ok}) {
				my $secs = _secsOf($track);
				my $kbps = ($pi->{length} && $secs) ? int($pi->{length} * 8 / 1000 / $secs) : undef;
				# 0.11.51：**交付重定向链的最终 URL**（探测时已跟到底并嗅过魔数，所以校验结论对最终 URL 同样成立）。
				# 现场判据：会 302 的聚合中转链交给 LMS 的开流路径 ⇒ LMS 挂死（30s 零日志，
				# 看门狗判 crashed）；换成最终直链后同一实验存活。原始 URL 仍留在 tries 里备查。
				my $deliver = $url;
				if ($pi->{effective}) {
					$deliver = $pi->{effective};
					# 最终 URL 往往才是有音频后缀的那个（如 …/xxx.mp3）⇒ 顺便把 friendly 重算一遍
					$friendly = 1 if !$friendly && $class->streamFriendly($deliver);
					$log->warn("LxMusic resolve: following redirect -> "
						. ($deliver =~ m{^https?://([^/]+)} ? $1 : $deliver));
				}
				return $finish->($src, $q, $deliver, $tm, $friendly, 1, $kbps, $pi->{magic}, $pi->{length});
			}
			push @tries, { source => $src->{name}, quality => $q, why => 'verify: ' . ($pi->{error} // '?'), %$tm };
			$log->warn("LxMusic resolve: verify rejected [" . $src->{name} . "] $q: " . ($pi->{error} // '?'));
			$settle->();
		});
		return;
	};

	# 派发器：窗口未满就继续启动候选；某个候选结算（成功/失败/挂起/校验被拒）时补位。
	# 候选耗尽且没有"在飞"的之后，才走"兜底中转链 → 全失败"的收尾。
	$dispatch = sub {
		return if $done;

		while ($inflight < $K) {
			my $cand = shift @cand;
			last unless $cand;

			my ($q, $src) = @$cand;
			my $path = Plugins::LxMusic::Sources->pathFor($src->{id});
			unless ($path && -f $path) {
				push @tries, { source => $src->{name}, quality => $q, why => 'file missing' };
				next;                       # 不占窗口，继续取下一个候选
			}

			$inflight++;
			my $settled = 0;
			my $settle = sub {              # 每个候选只结算一次，并立刻补位
				return if $settled;
				$settled = 1;
				$inflight--;
				$dispatch->();
			};

			$log->warn("LxMusic resolve: try [" . $src->{name} . "] type=$q");
			# 计时用 HiRes：页面上的 1.04s 级精度就靠它；这里记「宿主墙钟」与「源内 handler 耗时」
			# 两个数（后者只有常驻 worker 能报，因为它由 shim 在源内自测）。
			my $t0 = Time::HiRes::time();
			$class->request(
				source   => $path,
				action   => 'musicUrl',
				sourceId => ($a{src} // ''),
				info     => { musicInfo => $track, type => $q },
				timeout  => ($a{timeout} || 20),
				cb       => sub {
					my ($res) = @_;
					my $el = Time::HiRes::time() - $t0;
					my %tm = (ms => int($el * 1000 + 0.5), path => ($res->{why} // 'fork'));
					$tm{handler} = int($res->{ms} + 0.5) if defined $res->{ms};
					my $url = $res->{data};
					unless ($res->{ok} && defined $url && !ref($url) && $url =~ m{^https?://}) {
						# 把子进程日志尾部并进 why：否则像 "no RESULT line" 这种失败在现场完全无痕
						# （qjs 子进程最后几行才是真正原因，M0.9 现场吃了这个亏）
						my @tail = grep { defined && length } @{ $res->{logs} || [] };
						@tail = @tail[ -2 .. -1 ] if @tail > 2;
						my $why = ($res->{error} // 'no url')
							. (@tail ? ' {' . join(' | ', map { substr($_, 0, 100) } @tail) . '}' : '');
						push @tries, { source => $src->{name}, quality => $q, why => $why, %tm };
						return $settle->();
					}
					my $friendly = $class->streamFriendly($url) ? 1 : 0;
					# 不友好的候选先挂起，不当场花一次 HEAD 校验：只有确实找不到友好直链时才回头用它
					if ($preferFriendly && !$friendly) {
						my $tmr = { %tm };
						push @tries, { source => $src->{name}, quality => $q, ok => 1, deferred => 1,
							friendly => 0, why => 'no audio suffix (script relay), deferred', %tm };
						$log->warn("LxMusic resolve: [" . $src->{name} . "] $q 直链无音频后缀（脚本中转链），暂缓");
						push @deferred, { src => $src, q => $q, url => $url, tm => $tmr, t0 => $t0 };
						return $settle->();
					}
					return $verifyThenFinish->($src, $q, $url, \%tm, $friendly, $settle);
				},
			);
		}

		return if $done || $inflight > 0;    # 还有在飞的候选 ⇒ 等它结算

		# 没有"播放器友好"的直链 ⇒ 退而求其次，用兜底的中转链（先校验一次再交付）
		if (@deferred) {
			my $d = shift @deferred;
			$log->warn('LxMusic resolve: 没有"播放器友好"直链，改用兜底中转链 ['
				. ($d->{src}{name} // '?') . '] ' . substr($d->{url}, 0, 80));
			$inflight++;
			my $settled = 0;
			my $settle = sub { return if $settled; $settled = 1; $inflight--; $dispatch->(); };
			return $verifyThenFinish->($d->{src}, $d->{q}, $d->{url}, $d->{tm}, 0, $settle);
		}

		my @last = @tries > 3 ? @tries[ -3 .. -1 ] : @tries;
		my $why = join('; ', map {
			($_->{source} // '?') . '@' . ($_->{quality} // '?') . ': ' . ($_->{why} // '?')
		} @last);
		$why = '无候选' unless length $why;
		$log->warn('LxMusic resolve FAILED after ' . scalar(@tries) . " tries: $why");
		return $cb->({ ok => 0, error => "全部订阅源都取不到直链（$why）", tries => \@tries });
	};
	$dispatch->();
	return;
}

# ---------- init ----------
sub init {
	my ($class) = @_;

	my $pluginDir = _pluginDir() or do {
		$log->error('LxMusic Helper: cannot locate plugin dir');
		return 0;
	};
	my $qjsSrc  = File::Spec->catfile($pluginDir, 'Bin', _arch(), 'qjs');
	my $shimSrc = File::Spec->catfile($pluginDir, 'engine', 'shim.mjs');

	-f $qjsSrc && -f $shimSrc or do {
		$log->error("LxMusic Helper: missing engine files ($qjsSrc / $shimSrc)");
		return 0;
	};

	rmtree($TMPDIR) if -d $TMPDIR;          # tmpfs 一般已空，保守清理
	mkpath($TMPDIR) or do { $log->error("LxMusic Helper: mkpath $TMPDIR: $!"); return 0 };
	mkpath($SOURCES);

	# shim/sdk 先拷（纯文本不会被 EBUSY 卡住）；qjs 最后、失败仅降级保留旧二进制，
	# 绝不因 qjs 占用而 return 0 —— 那会让 shim 停在旧版（0.3.6 现场）
	copy($shimSrc, $SHIM) or do { $log->error("LxMusic Helper: copy shim: $!"); return 0 };
	my $sdkSrc = File::Spec->catfile($pluginDir, 'engine', 'sdk', 'sdk.bundle.js');
	if (-f $sdkSrc) {
		copy($sdkSrc, $SDK) or $log->warn("LxMusic Helper: copy sdk bundle: $!");
	}
	else {
		$log->warn('LxMusic Helper: sdk bundle missing in plugin dir — search/browse disabled');
	}
	if (copy($qjsSrc, $QJS)) {
		chmod(0755, $QJS);                   # 关键：解压丢 +x，/tmp 里修复
	}
	else {
		# 旧 qjs 仍可执行（二进制兼容）；仅告警不失败
		$log->warn('LxMusic Helper: copy qjs failed (busy?): ' . $! . ' — keeping existing binary');
		-f $QJS && -x $QJS or do { $log->error('LxMusic Helper: no usable qjs in tmp'); return 0 };
	}

	# 引擎自检（阻塞但 <100ms，仅 init 一次）
	my $out = _qx([$QJS, '-e', 'print("lx-engine-ok:"+(1+1))']);
	if ($out && $out =~ /lx-engine-ok:2/) {
		$log->info('LxMusic Helper: engine ready at ' . $QJS);
		return 1;
	}
	$log->error('LxMusic Helper: engine self-test failed: ' . ($out // '<no output>'));
	return 0;
}

# ---------- 订阅源安装 ----------
my $CURRENT_SOURCE = File::Spec->catfile($SOURCES, 'current.js');

# 当前生效的订阅源路径 = 注册表里第一个"已启用"的源（M0.6 起多源，顺序即优先级）
# 保留本方法名：工具页/试听/预取等"单源"调用点继续可用
sub currentSourcePath {
	my ($class) = @_;
	return Plugins::LxMusic::Sources->firstEnabledPath;
}

sub sourceInfo {
	my ($class) = @_;
	my $st = Plugins::LxMusic::Sources->status;
	return {
		installed => ($st->{enabled} ? 1 : 0),
		path      => $class->currentSourcePath,
		total     => $st->{total},
		enabled   => $st->{enabled},
		dir       => $st->{dir},
	};
}

# 兼容入口：M0.6 起"导入源"= 往多订阅源注册表加一条记录
# （元数据落 prefs `sourcesJson`，正文落持久目录 <prefsdir>/lxmusic/sources/<id>.js）。
# 旧语义是"写 /tmp 的 current.js"，现在多源并存，current.js 概念取消。
# 返回落盘路径（老调用点按 "path or undef" 判定成功）。
sub installSource {
	my ($class, $name, $content) = @_;
	my ($rec, $err) = Plugins::LxMusic::Sources->addContent(
		content => $content,
		name    => $name,
		origin  => 'import',
	);
	unless ($rec) {
		$log->error("LxMusic Helper: installSource failed: $err");
		return undef;
	}
	return Plugins::LxMusic::Sources->pathFor($rec->{id});
}

# ---------- 异步请求 ----------
# request(source => $path, action => 'musicUrl', sourceId => 'kw',
#         info => {...}, cb => sub { my $res = shift; }, timeout => 20)
# res = { ok=>1/0, data=>..., error=>..., logs=>[], alerts=>[], why=>... }
sub request {
	my ($class, %args) = @_;

	my $cb = $args{cb} or return;

	my $source = $args{source};
	my $action = $args{action};
	$action or do { $cb->(_err('action required')); return };

	# sdk 模式（vendored musicSdk）：第一个参数是 sdk.bundle.js，无需订阅源
	# probe 模式：只需要 shim + 系统 curl（探测直链是否真的可播），也不需要源
	if ($action eq 'probe') {
		$source = $SHIM;
	}
	elsif ($action eq 'search' || $action eq 'boards' || $action eq 'boardlist'
		|| $action eq 'songlist' || $action eq 'songlistdetail' || $action eq 'songlistbytag'
		# 0.11.36：歌单 PC 对齐的两个新元数据动作（排序 tab / 分类标签）也走 sdk.bundle.js
		|| $action eq 'songlistsorts' || $action eq 'songlisttags') {
		-f $SDK or do { $cb->(_err('sdk bundle not installed (search/browse disabled)')); return };
		$source = $SDK;
	}
	else {
		$source && -f $source or do { $cb->(_err('source missing: ' . ($source // '<undef>'))); return };
	}
	-f $QJS && -x _ or do { $cb->(_err('engine not initialised (call init)')); return };

	my $timeout = $args{timeout} || 20;
	$timeout = 60 if $timeout > 60;          # lx 宿主 20s 硬超时同量级，上限 60

	# 常驻 worker 路径（M0.10）：
	#  · 「订阅源取链」(musicUrl) 与「可播校验」(probe)：固定开销最大。
	#  · 0.11.43 起 **sdk 动作也常驻**（source=$SDK，shim 侧 argv[1] 认 sdk.bundle.js 当 worker）：
	#    设备是 i386（Atom 级），每请求 fork+解析 700KB bundle ≈0.5s，而歌单下钻一次要问好几层。
	# 返回 0 = worker 不可用（起不来/写失败/积压），落回下面的 fork 路径。
	my %SDK_WORKER_ACTIONS = map { $_ => 1 }
		qw(search boards boardlist songlist songlistdetail songlistbytag songlistsorts songlisttags);
	if (workerEnabled()) {
		if ($action eq 'musicUrl' && $source && $source ne $SHIM && $source ne $SDK) {
			return if $class->_worker_submit(
				source   => $source,
				sourceId => $args{sourceId},
				action   => $action,
				info     => $args{info},
				cb       => $cb,
				timeout  => $timeout,
			);
		}
		elsif ($action eq 'probe') {
			return if $class->_worker_submit(
				probe   => 1,
				action  => $action,
				info    => $args{info},
				cb      => $cb,
				timeout => $timeout,
			);
		}
		elsif ($SDK_WORKER_ACTIONS{$action} && $source eq $SDK) {
			return if $class->_worker_submit(
				source   => $SDK,
				sourceId => $args{sourceId},
				action   => $action,
				info     => $args{info},
				cb       => $cb,
				timeout  => $timeout,
			);
		}
	}

	# 并发闸（M0.3）：整单 m3u 入队时 LMS 会并发解析几十个 lxm://，全 fork 会打满设备 CPU
	# 并拖垮上游（0.4.0 现场：全部 'timeout: no RESULT line'）。排队串行放行，max 2 并发。
	if (scalar(keys %JOBS) >= _maxChildren()) {
		push @WAITQ, sub { __PACKAGE__->request(%args) };
		$log->debug('LxMusic Helper: request queued (' . scalar(@WAITQ) . ' waiting)');
		return;
	}

	my $infoJson = eval {
		$JSON->encode({ source => ($args{sourceId} // ''), info => ($args{info} // {}) });
	} or do { $cb->(_err('bad info json')); return };

	# 子进程输出落盘（不走管道：达菲主循环不驱动 fd 事件）
	my $outfile = File::Spec->catfile($TMPDIR,
		'job.' . time() . '.' . $$ . '.' . int(rand(1_000_000)) . '.out');

	my $pid = fork();
	if (!defined $pid) { $cb->(_err("fork: $!")); return; }

	if ($pid == 0) {                         # ---- child ----
		# 达菲把 STDOUT/STDERR tie 成 Slim::Utils::Log::Trapper——
		# perl 层 open(STDOUT,...) 会在 tie 上调 OPEN 而死。改用 POSIX
		# dup2 直接替换 fd 1/2（纯 syscall，绕开 tie 与 OO 句柄层）。
		my $fd = POSIX::open($outfile,
			POSIX::O_WRONLY() | POSIX::O_CREAT() | POSIX::O_TRUNC(), 0644);
		if (defined $fd && $fd >= 0) {
			POSIX::dup2($fd, 1);
			POSIX::dup2(1, 2);
			POSIX::close($fd) if $fd > 2;
		}
		else {
			POSIX::_exit(127);
		}
		$ENV{PATH} = '/usr/bin:/bin:/usr/sbin:/sbin';   # curl 定位
		$ENV{LX_BRIDGE_TIMEOUT} = _bridgeTimeout();  # 设置页可调（shim 读它）
		chdir('/');
		exec($QJS, $SHIM, $source, $action, $infoJson);
		POSIX::_exit(127);
	}

	# ---- parent ----
	my $job = {
		pid     => $pid,
		cb      => $cb,
		out     => $outfile,
		started => time(),
		timeout => $timeout,
		done    => 0,
	};
	$JOBS{$pid} = $job;

	$log->warn("LxMusic Helper: job $pid ($action) started, timeout ${timeout}s");
	Slim::Utils::Timers::setTimer($job, time() + 0.25, \&_poll);

	return $pid;
}

# 0.25s 轮询：进程退出(或被系统回收)即收结果；超时 KILL
sub _poll {
	my ($job) = @_;
	return if $job->{done};

	my $gone = waitpid($job->{pid}, POSIX::WNOHANG());
	if ($gone == $job->{pid} || $gone == -1) {
		_finish($job, 'ok');
		return;
	}
	if (time() - $job->{started} >= $job->{timeout}) {
		$log->warn("LxMusic Helper: job $job->{pid} timed out after $job->{timeout}s, killing");
		kill 'KILL', $job->{pid};
		waitpid($job->{pid}, 0);
		_finish($job, 'timeout');
		return;
	}
	Slim::Utils::Timers::setTimer($job, time() + 0.25, \&_poll);
	return;
}

# ---------- shutdown ----------
sub shutdown {
	my ($class) = @_;
	for my $src (keys %WORKER) {
		$class->_worker_kill($WORKER{$src});
	}
	for my $pid (keys %JOBS) {
		my $job = $JOBS{$pid};
		Slim::Utils::Timers::killTimers($job, \&_poll);
		kill 'KILL', $pid;
		_finish($job, 'shutdown');
	}
	rmtree($TMPDIR);
	return 1;
}

# ---------- 常驻 qjs worker（M0.10）----------
# 动机：每请求 fork 一个 qjs 时，冷启动要付「qjs 起进程 + shim 解析 + 源脚本解析 + 源初始化
# （rconfig 握手等）」——设备实测 ~2.3s，而真正取链只占一小部分。常驻 worker 把这份成本
# 摊销到进程生命周期里：初始化一次，之后每请求只走 shim 的 serve 行协议。
#
# 通道：POSIX 双向管道（不用 Perl 的 open(STDOUT) —— 那会死在 Log::Trapper 的 tie 上，
# 见 §5.2.6）。父进程：写 stdin、用 Timers 轮询 sysread 读 stdout(+stderr)。
# 协议：stdin 一行 {"id":N,"action":"musicUrl","source":"kw","info":{...}}
#       stdout 行 READY {...} / RESULT <id> {json} / LOG ...
# 兜底：worker 起不来、写失败、超时、进程死 —— 任一情况都 kill 掉并让该请求走原来的 fork 路径。
sub workerEnabled { my ($class) = @_; return _pref('workerEnable', 1) ? 1 : 0 }

sub workerStatus {
	my ($class) = @_;
	return [ map {
		my $w = $WORKER{$_};
		{ key => $_, src => $w->{src}, pid => $w->{pid}, ready => $w->{ready} ? 1 : 0,
		  jobs => scalar(keys %{ $w->{jobs} }), info => ($w->{info} // '') }
	} sort keys %WORKER ];
}

sub _worker_spawn {
	my ($class, $key, $arg1) = @_;
	-f $QJS && -x _ or return undef;
	$arg1 = $key unless defined $arg1;
	my $src = $arg1;
	pipe(my $rd, my $wr) or do { $log->warn("LxMusic worker: pipe: $!"); return undef };
	pipe(my $crd, my $cwr) or do { $log->warn("LxMusic worker: pipe2: $!"); return undef };

	my $pid = fork();
	if (!defined $pid) { $log->warn("LxMusic worker: fork: $!"); return undef }

	if ($pid == 0) {                                  # ---- child ----
		POSIX::dup2(fileno($crd), 0);                 # 请求来自父进程
		POSIX::dup2(fileno($wr),  1);                 # 结果回父进程
		POSIX::dup2(1, 2);                            # stderr 合流（LOG 行也能看到）
		close $rd; close $wr; close $crd; close $cwr;
		$ENV{PATH} = '/usr/bin:/bin:/usr/sbin:/sbin';
		$ENV{LX_BRIDGE_TIMEOUT} = _bridgeTimeout();
		chdir('/');
		exec($QJS, $SHIM, $src, 'serve', '{}');
		POSIX::_exit(127);
	}

	close $crd; close $wr;
	# 非阻塞读：主循环里绝不能阻塞在管道上（阻塞 sysread 空管道 = 整个 LMS 卡死）。
	# 若拿不到 O_NONBLOCK，宁可不启用 worker（退回 fork 路径），也不冒卡死主循环的险。
	my $fl = eval { fcntl($rd, F_GETFL, 0) };
	if (!defined $fl || !fcntl($rd, F_SETFL, $fl | O_NONBLOCK)) {
		$log->warn('LxMusic worker: cannot set O_NONBLOCK on read pipe, not using worker'
			. ' (' . ($@ || $!) . ')');
		kill 'KILL', $pid;
		waitpid($pid, 0);
		close $rd; close $cwr;
		return undef;
	}
	my $w = {
		key => $key, src => $src, pid => $pid, rd => $rd, wr => $cwr, buf => '', ready => 0,
		queue => [], jobs => {}, id => 0, last => time(), recent => [], info => '',
	};
	$WORKER{$key} = $w;
	$log->warn("LxMusic worker: spawned pid=$pid for $key (argv1=$src, warming)");
	$w->{due} = Time::HiRes::time() + 0.1;
	Slim::Utils::Timers::setTimer($w, $w->{due}, \&_worker_poll);
	return $w;
}

# 请求下发后把轮询"叫醒"：空闲时轮询间隔是 2s（省 CPU），但新请求不该等这个 tick
# ——设备实测：不叫醒会白等最多 ~2s（每次取链多花 1.5s）。
sub _worker_wake {
	my ($class, $w, $delay) = @_;
	$delay = 0.05 unless defined $delay;
	if ($w->{in_poll}) { $w->{wake} = 1; return; }   # 正在 poll 里：让收尾重排用短间隔
	my $due = Time::HiRes::time() + $delay;
	return if $w->{due} && $w->{due} <= $due + 0.001;
	Slim::Utils::Timers::killTimers($w, \&_worker_poll);
	Slim::Utils::Timers::setTimer($w, $due, \&_worker_poll);
	$w->{due} = $due;
	return;
}

sub _worker_send {
	my ($class, $w, $line) = @_;
	local $SIG{PIPE} = 'IGNORE';
	my $off = 0;
	my $len = length $line;
	while ($off < $len) {
		my $n = syswrite($w->{wr}, $line, $len - $off, $off);
		return 0 unless defined $n && $n > 0;
		$off += $n;
	}
	$w->{last} = time();
	return 1;
}

# 真正下发一个 job：超时计时从「下发」开始算（排队等待不该吃请求超时）
sub _worker_send_job {
	my ($class, $w, $job) = @_;
	return 0 unless $class->_worker_send($w, $job->{line});
	$job->{sent}     = time();
	$job->{deadline} = $job->{sent} + $job->{timeout};
	return 1;
}

sub _worker_fail_all {
	my ($class, $w, $why) = @_;
	for my $id (keys %{ $w->{jobs} }) {
		my $job = delete $w->{jobs}{$id};
		$job->{cb}->({ ok => 0, data => undef, error => $why, logs => $job->{logs}, alerts => [], why => 'worker' });
	}
	@{ $w->{queue} } = ();
	return;
}

sub _worker_kill {
	my ($class, $w) = @_;
	return unless $w;
	Slim::Utils::Timers::killTimers($w, \&_worker_poll);
	$class->_worker_fail_all($w, 'worker stopped');
	kill 'KILL', $w->{pid} if $w->{pid};
	waitpid($w->{pid}, POSIX::WNOHANG()) if $w->{pid};
	close $w->{rd}; close $w->{wr};
	delete $WORKER{ $w->{key} };
	return;
}

sub _worker_poll {
	my ($w) = @_;
	my $src = $w->{src};
	return if $w->{dead};
	local $w->{in_poll} = 1;    # 作用域退出自动复位（含各 return 分支）

	my $alive = kill(0, $w->{pid}) ? 1 : 0;
	if (!$alive) {
		$log->warn("LxMusic worker($src): process gone");
		$w->{dead} = 1;
		Plugins::LxMusic::Helper->_worker_fail_all($w, 'worker process gone');
		Plugins::LxMusic::Helper->_worker_kill($w);
		return;
	}

	while (1) {
		my $n = sysread($w->{rd}, my $chunk, 65536);
		last unless defined $n && $n > 0;
		$w->{buf} .= $chunk;
	}

	while ($w->{buf} =~ s/^([^\n]*)\n//) {
		my $line = $1;
		$line =~ s/\r$//;
		next unless length $line;
		$w->{last} = time();

		if ($line =~ /^READY (.*)$/) {
			$w->{ready} = 1;
			$w->{info} = $1;
			$log->warn("LxMusic worker($src): READY $1 (warm)");
			while (defined(my $qid = shift @{ $w->{queue} })) {
				my $qjob = $w->{jobs}{$qid} or next;
				last unless Plugins::LxMusic::Helper->_worker_send_job($w, $qjob);
			}
			next;
		}
		if ($line =~ /^RESULT (\d+) (.*)$/s) {
			my ($id, $json) = ($1, $2);
			my $job = delete $w->{jobs}{$id};
			next unless $job;
			my $dec = eval { $JSON->decode($json) };
			my ($ok, $data, $err);
			if ($dec && ref $dec) {
				if ($dec->{ok}) { $ok = 1; $data = $dec->{data} }
				else {
					$ok  = 0;
					$err = ($dec->{error} // 'worker error')
						. ((defined $dec->{stack} && length $dec->{stack}) ? ' || ' . $dec->{stack} : '');
				}
			}
			else { $err = 'bad worker RESULT json' }
			$log->warn(sprintf('LxMusic worker(%s): job %s done ok=%d%s', $src, $id, $ok ? 1 : 0,
				(defined $dec->{ms} ? " ms=$dec->{ms}" : '')));
			$job->{cb}->({
				ok => $ok ? 1 : 0, data => $data, error => $err,
				logs => [ @{ $w->{recent} }, @{ $job->{logs} || [] } ], alerts => [], why => 'worker',
				ms => $dec->{ms},
			});
			next;
		}
		if ($line =~ /^LOG (.*)$/s) {
			push @{ $w->{recent} }, substr($1, 0, 200);
			shift @{ $w->{recent} } while @{ $w->{recent} } > 20;
			next;
		}
		push @{ $w->{recent} }, substr($line, 0, 200);
		shift @{ $w->{recent} } while @{ $w->{recent} } > 20;
	}

	# 请求超时：worker 可能卡在源的上游；杀进程让后续请求重新起（并回一个明确错误）
	# 只算已下发的 job——排队等 worker 冷启动的 job 不该吃请求超时
	my $now = time();
	for my $id (keys %{ $w->{jobs} }) {
		my $job = $w->{jobs}{$id};
		next unless $job->{sent};
		if ($now - $job->{deadline} >= 0) {
			$log->warn("LxMusic worker($src): job $id timed out after " . ($now - $job->{started}) . 's, recycling worker');
			delete $w->{jobs}{$id};
			my $cb = $job->{cb};
			my @logs = @{ $w->{recent} };
			Plugins::LxMusic::Helper->_worker_kill($w);
			$cb->({ ok => 0, data => undef, error => 'timeout: worker request exceeded ' . ($job->{timeout} || '?') . 's',
				logs => \@logs, alerts => [], why => 'timeout' });
			return;
		}
	}

	# 空闲回收：没有在跑的请求且长时间没人用就退出（不要常驻占内存）
	# ⚠️ 判空必须用 scalar(keys %h)：Perl 里 %h 的标量值是 "used/allocated"（空时也是 "0/8"，为真）
	my $busy = scalar(keys %{ $w->{jobs} });
	my $idle = _pref('workerIdle', 600);
	if (!$busy && $idle && $now - $w->{last} > $idle) {
		$log->warn("LxMusic worker($src): idle > ${idle}s, exiting");
		Plugins::LxMusic::Helper->_worker_kill($w);
		return;
	}

	# 轮询节奏：有在跑的请求（或被叫醒）→ 50ms 细粒度；空闲 → 2s（只在回收计时上花力气）
	my $iv = ($busy || $w->{wake}) ? 0.05 : 2.0;
	$w->{wake} = 0;
	$w->{due}  = Time::HiRes::time() + $iv;
	Slim::Utils::Timers::setTimer($w, $w->{due}, \&_worker_poll);
	return;
}

# 把一个请求交给常驻 worker；返回 1 = 已接管，0 = 调用方应退回 fork 路径
sub _worker_submit {
	my ($class, %a) = @_;
	# 探测 worker：与取链 worker 分开（argv1='-'），长探测不会卡住取链
	my ($key, $arg1) = $a{probe} ? ($PROBE_KEY, '-') : ($a{source}, undef);
	my $w = $WORKER{$key};
	$w = $class->_worker_spawn($key, $arg1) unless $w && !$w->{dead} && kill(0, $w->{pid});
	return 0 unless $w;

	# 背压：worker 是串行的，堆积过多就让调用方退回 fork 路径（那边有并发闸）
	return 0 if scalar(keys %{ $w->{jobs} }) >= 24;

	my $id = ++$WID;
	my $timeout = $a{timeout} || 20;
	my $job = {
		id => $id, cb => $a{cb}, timeout => $timeout, logs => [],
		line => $JSON->encode({
			id => $id, action => $a{action}, source => ($a{sourceId} // ''), info => ($a{info} // {}),
		}) . "\n",
	};
	$w->{jobs}{$id} = $job;

	if ($w->{ready}) {
		unless ($class->_worker_send_job($w, $job)) {
			$log->warn('LxMusic worker: write failed, recycling');
			delete $w->{jobs}{$id};
			$class->_worker_kill($w);
			return 0;
		}
		$log->debug("LxMusic worker($key): submitted job $id");
	}
	else {
		push @{ $w->{queue} }, $id;    # 冷启动中，等 READY 再灌
		$log->debug("LxMusic worker($key): queued job $id (warming)");
	}
	$class->_worker_wake($w);
	return 1;
}

# ---------- 内部 ----------
sub _finish {
	my ($job, $why) = @_;
	return if $job->{done}++;
	Slim::Utils::Timers::killTimers($job, \&_poll);
	delete $JOBS{$job->{pid}};
	waitpid($job->{pid}, 0) if $job->{pid};   # 已回收时返回 -1，无害

	my $buf = '';
	if (open(my $fh, '<', $job->{out})) {
		local $/;
		$buf = <$fh> // '';
		close $fh;
	}
	unlink($job->{out});

	# 注意：_parse 是类方法（单测以 Helper->_parse 调用）——这里必须同样以类方法
	# 调用；裸 _parse($buf) 会让 $class 吃掉 $buf、$text=undef，RESULT 永远解析失败。
	my ($ok, $data, $err, $logs, $alerts) = __PACKAGE__->_parse($buf);

	if ($why ne 'ok') {
		$ok   = 0;
		$err  = defined $err ? "$why: $err" : $why;
		$data = undef;
	}

	# 诊断增强：失败时回显子进程原始输出尾部（页面 logs 区直接可见）
	if (!$ok) {
		# 达菲 server.log 过滤 info 级——失败现场用 warn 级落盘，远程可抓
		my $flat = $buf;
		$flat =~ s/\s+/ /g;
		$log->warn("LxMusic Helper: job $job->{pid} failed ($why), raw: " . substr($flat, 0, 2500));
		my @raw = grep { defined && length } split(/\r?\n/, $buf);
		push @$logs, '--- child stdout tail ---';
		if (@raw) {
			push @$logs, @raw > 10 ? @raw[-10 .. -1] : @raw;
		}
		else {
			push @$logs, '(empty - child produced no output at all)';
		}
	}
	$job->{cb}->({
		ok     => $ok ? 1 : 0,
		data   => $data,
		error  => $err,
		logs   => $logs,
		alerts => $alerts,
		why    => $why,
	});

	# 并发闸放行：m3u 整单入队会瞬间排起几十个解析，串行小并发保护设备 CPU 与上游
	while (@WAITQ && scalar(keys %JOBS) < _maxChildren()) {
		my $next = shift @WAITQ;
		$next->();
	}
	return;
}

# stdout 协议解析（纯函数，便于单测）
sub _parse {
	my ($class, $text) = @_;
	my (@logs, @alerts, $result);
	for my $line (split(/\r?\n/, $text // '')) {
		if    ($line =~ /^RESULT (.*)$/s) { $result = $1 }
		elsif ($line =~ /^LOG (.*)$/s)    { push @logs, $1 }
		elsif ($line =~ /^ALERT (.*)$/s)  { push @alerts, $1 }
		# 其他行（引擎噪音）忽略
	}
	return (0, undef, 'no RESULT line', \@logs, \@alerts) unless defined $result;

	my $dec = eval { $JSON->decode($result) };
	return (0, undef, 'bad RESULT json: ' . ($@ || '??'), \@logs, \@alerts) unless $dec && ref $dec;

	return (
		$dec->{ok} ? 1 : 0,
		$dec->{ok} ? $dec->{data} : $dec->{error},
		# 失败时把子进程给的堆栈拼进 error：'not a function' 这类错误只有栈能定位到源的第几行，
		# 而父进程的页面日志块不总是可达（M0.9 现场：只能靠判决行带出来）
		$dec->{ok} ? undef
			: ($dec->{error} . ((defined $dec->{stack} && length $dec->{stack}) ? ' || ' . substr($dec->{stack}, 0, 200) : '')),
		\@logs, \@alerts,
	);
}

sub _err {
	my ($msg) = @_;
	return { ok => 0, data => undef, error => $msg, logs => [], alerts => [], why => 'local' };
}

sub _pluginDir {
	my $inc = $INC{'Plugins/LxMusic/Helper.pm'};
	if (!$inc) {
		# 测试场景：require 文件路径加载，%INC 键为原始路径——按文件名回溯
		for (values %INC) {
			if (m{/LxMusic/Helper\.pm$}) { $inc = $_; last }
		}
	}
	$inc or return undef;
	my ($vol, $dirs, undef) = File::Spec->splitpath($inc);
	return File::Spec->catpath($vol, $dirs, '');
}

sub _arch {
	my $a = $Config::Config{archname} || 'x86_64-linux';
	$a =~ s/-thread.*//;
	$a =~ s/-multi.*//;
	$a =~ s/-gnu.*//;        # ubuntu: x86_64-linux-gnu -> x86_64-linux（与达菲一致）
	return $a;
}

# 受控同步执行（仅 init 自检用）：设置 PATH，读 stdout+stderr
sub _qx {
	my ($cmd) = @_;
	local $ENV{PATH} = '/usr/bin:/bin:/usr/sbin:/sbin';
	my $out = eval {
		open(my $fh, '-|', @{$cmd}) or die "open: $!";
		local $/;
		my $s = <$fh>;
		close $fh;
		$s;
	};
	return $out;
}

1;
