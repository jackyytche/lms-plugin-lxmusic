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
# 0.11.54：worker 超时过的**源路径** => 打标记时间（TTL 600s）。见 `request()` 里的说明：
# 慢源（mg 的 3 连上游）用串行 worker 会互相拖死，标记后改走 fork（每单一进程，超时只杀自己）。
my %WORKER_BAD;
my $WORKER_BAD_TTL = 600;

# 0.11.57：**死源熔断**（用户要求）。粒度 = **源 × 平台 × 档位**：
#   · 太粗（只按源）会误伤——玉宁熙的 mg 有些档位会 500，但 320k/128k 是好的，kw/tx 也好；
#   · 太细正合适：坏三元组不再重复尝试，同源其它档位/平台照旧。
# 现场依据（2026-09-23 实测）：把三个**已死**的旧源（独家/星海/裤佬）勾回来，mg/tx 取链被拖到 39s，
# LMS `mode=play` 却拿不到流（pos 恒 0＝无声）；关掉它们同一条曲目立刻 pos 16.96s 正常。
# 语义：同一三元组**连续 2 次失败** ⇒ 10 分钟内不再为它生成候选（只报一条 warn）。
my %SRC_FAIL;      # key => 连续失败次数
my %SRC_BAD;       # key => 熔断时间
my $SRC_BAD_N   = 2;
my $SRC_BAD_TTL = 600;

# 0.11.58：**源能力表**（源文件路径 => { 平台 => { name, qualitys=>{...}, actions=>{...} } }）。
# 权威来源：源自己在 `lx.send('inited', {sources:{kw:{qualitys:[...]}}})` 里声明（PC 端
# `preload.js:146-167` 就靠它生成 userApi.apis/qualityList 并裁剪请求）。我们从前把它丢掉
# ⇒ 只能"所有源 × 所有档位"盲打：慢源上每次取链白跑若干轮，还把上游错误放大成超时/熔断。
# 采集口：shim 的 `CAPS {json}` 行（fork 与 worker 两条路径都打）与 worker 的 `READY {...caps}`。
my %CAPS;          # path => { plat => { name => '', qualitys => { q => 1 }, actions => { a => 1 } } }
my %CAPS_AT;       # path => 采集时间

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
	my ($class, $url, $cb, $prio) = @_;
	$class->request(
		action   => 'probe',
		info     => { url => $url, timeout => 8 },
		timeout  => 15,
		priority => $prio,
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
				# 0.11.52：FLAC 位深（探测时从 STREAMINFO 读出来的）——用于"真实档位"标签
				bits   => ($d->{bits} || 0),
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

# 0.11.57：死源熔断——key = 源 × 平台 × 档位
sub _src_key {
	my ($src, $plat, $q) = @_;
	return ($src->{id} // $src->{name} // '?') . '|' . ($plat || '?') . '|' . ($q || '?');
}

sub _src_tripped {
	my $k = shift;
	my $t = $SRC_BAD{$k} or return 0;
	return (time() - $t) < $SRC_BAD_TTL ? 1 : 0;
}

# 记一次失败：连续 $SRC_BAD_N 次就给这个三元组上闸（只在"刚上闸"那一次告警）
sub _src_failed {
	my ($k, $label) = @_;
	my $n = ++$SRC_FAIL{$k};
	return if $n < $SRC_BAD_N;
	my $fresh = !$SRC_BAD{$k};
	$SRC_BAD{$k} = time();
	$log->warn('LxMusic resolve: breaker tripped for ' . ($label // $k)
		. " after $n consecutive failures -> skipping for ${SRC_BAD_TTL}s") if $fresh;
	return;
}

# 成功即清零（失败是"连续的"才算）
sub _src_ok {
	my $k = shift;
	delete $SRC_FAIL{$k};
	delete $SRC_BAD{$k};
	return;
}

# 0.11.57：熔断状态的**测试/诊断**口（回归用例每个新场景先清一次；
# 设置页/日志排查也用它看"现在哪些三元组被闸住了"）
sub _breaker_reset { %SRC_FAIL = (); %SRC_BAD = (); return 1 }

sub _breaker_state {
	return +{ fail => { %SRC_FAIL }, bad => { %SRC_BAD }, n => $SRC_BAD_N, ttl => $SRC_BAD_TTL };
}

# ---------- 0.11.58：源能力表 ----------
# 记下某个源文件声明的能力（同一路径重复声明则覆盖：源热更新后能力表跟着更新）
sub _caps_note {
	my ($class, $path, $caps) = @_;
	return 0 unless $path && ref($caps) eq 'HASH';
	my $src = $caps->{sources};
	return 0 unless ref($src) eq 'HASH' && %$src;
	my %m;
	for my $plat (keys %$src) {
		my $d = $src->{$plat};
		next unless ref($d) eq 'HASH';
		my %q = map { ($_ => 1) } grep { defined && length } @{
			(ref($d->{qualitys}) eq 'ARRAY') ? $d->{qualitys} : [] };
		my %ac = map { ($_ => 1) } grep { defined && length } @{
			(ref($d->{actions}) eq 'ARRAY') ? $d->{actions} : [] };
		$m{lc $plat} = { name => ($d->{name} // ''), qualitys => \%q, actions => \%ac };
	}
	return 0 unless %m;
	$CAPS{$path}    = \%m;
	$CAPS_AT{$path} = time();
	$log->warn('LxMusic caps: [' . ($path =~ m{([^/]+)$} ? $1 : $path) . '] declares '
		. join(', ', map { $_ . '(' . join('/', sort keys %{ $m{$_}{qualitys} }) . ')' } sort keys %m));
	return 1;
}

# 该源**是否声明支持**某平台：1=支持 / 0=不支持 / undef=未知（未知按老行为放行，绝不误杀）
sub _caps_platform {
	my ($class, $path, $plat) = @_;
	my $c = $CAPS{$path} or return undef;
	$plat = lc($plat // '');
	return $c->{$plat} ? 1 : 0;
}

# 该源在该平台声明的档位集合（undef = 未知）
sub _caps_qualitys {
	my ($class, $path, $plat) = @_;
	my $c = $CAPS{$path} or return undef;
	my $d = $c->{lc($plat // '')} or return undef;
	my $q = $d->{qualitys} or return undef;
	return %$q ? $q : undef;
}

sub caps_state { return { map { $_ => [ sort keys %{ $CAPS{$_} } ] } keys %CAPS } }
sub _caps_reset { %CAPS = (); %CAPS_AT = (); return 1 }

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
	my $plat = $a{src} || ($track->{source}) || '';
	my $prio = (defined $a{priority} && $a{priority} eq 'bg') ? 'bg' : 'user';
	my @cand;
	my @tripped;
	my @nocap;      # 被能力表裁掉的源（只报一次，便于现场判断"是源不支持这个平台"）
	my @noqual;     # 被能力表裁掉的 (源, 档位)
	my $build = sub {
		my ($useCaps) = @_;
		my (@c, @t);
		for my $q (@ladder) {
			for my $s (@$sources) {
				my $k = _src_key($s, $plat, $q);
				if (_src_tripped($k)) { push @t, ($s->{name} // '?') . "\@$q"; next; }
				if ($useCaps) {
					my $path = Plugins::LxMusic::Sources->pathFor($s->{id});
					if (defined $path) {
						my $sup = $class->_caps_platform($path, $plat);
						if (defined $sup && !$sup) { push @nocap, ($s->{name} // '?'); next; }
						my $qs = $class->_caps_qualitys($path, $plat);
						if ($qs && !$qs->{$q}) { push @noqual, ($s->{name} // '?') . "\@$q"; next; }
					}
				}
				push @c, [ $q, $s ];
			}
		}
		return (\@c, \@t);
	};
	# 0.11.58：**先按源声明的能力表裁剪**（PC 端 preload 的做法）。若裁剪后一个候选都不剩
	# （源没声明该平台 / 声明与实际不符 / 完全没有能力表），退回不做能力裁剪的旧行为——
	# 「宁可慢，也不能因为一张表点了没声」。
	my ($c1, $t1) = $build->(1);
	if (@$c1 || !(@nocap || @noqual)) {
		@cand = @$c1; @tripped = @$t1;
	}
	else {
		my ($c2, $t2) = $build->(0);
		@cand = @$c2; @tripped = @$t2;
		$log->warn('LxMusic resolve: capability table would leave no candidate for '
			. ($plat || '?') . ' -> ignoring it (nocap=' . join(',', @nocap)
			. ' noqual=' . join(',', @noqual) . ')');
	}
	$log->info('LxMusic resolve: candidates=' . scalar(@cand) . ' (ladder=' . join('/', @ladder)
		. ' platform=' . ($plat || '?') . ')'
		. (@nocap ? ' caps-pruned-platform=' . join(',', @nocap) : '')
		. (@noqual ? ' caps-pruned-tier=' . join(',', @noqual) : ''));

	# 0.11.57：**全被熔断时不许静音**——清掉这个平台的所有熔断（宁可慢，也不能"点了没声"）
	if (!@cand && @tripped) {
		for my $q (@ladder) {
			for my $s (@$sources) {
				delete $SRC_BAD{ _src_key($s, $plat, $q) };
				delete $SRC_FAIL{ _src_key($s, $plat, $q) };
				push @cand, [ $q, $s ];
			}
		}
		$log->warn('LxMusic resolve: all candidates were breaker-tripped for '
			. ($plat || '?') . ' -> breakers cleared (' . join(', ', @tripped) . ')');
	}
	elsif (@tripped) {
		$log->info('LxMusic resolve: breaker skipping ' . join(', ', @tripped) . ' for ' . ($plat || '?'));
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
		my ($src, $q, $url, $tm, $friendly, $verified, $kbps, $magic, $len, $bits) = @_;
		return if $done;                 # 并行窗口下只交付一次
		$done = 1;
		_src_ok(_src_key($src, $plat, $q));   # 0.11.57：成功即清零该三元组的失败计数
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
			bits       => $bits,          # 0.11.52：FLAC 位深（真实档位标签用）
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
				return $finish->($src, $q, $deliver, $tm, $friendly, 1, $kbps, $pi->{magic}, $pi->{length}, $pi->{bits});
			}
			push @tries, { source => $src->{name}, quality => $q, why => 'verify: ' . ($pi->{error} // '?'), %$tm };
			$log->warn("LxMusic resolve: verify rejected [" . $src->{name} . "] $q: " . ($pi->{error} // '?'));
			_src_failed(_src_key($src, $plat, $q), ($src->{name} // '?') . "\@$q");   # 0.11.57 熔断计数
			$settle->();
		}, $prio);
		return;
	};

	# 0.11.58：**整体预算**（秒，0 = 不限）。LMS 的播放路径等不了——它大约 4~8s 就放弃这次取链，
	# 而 0.11.54 把 worker 超时放大到 35s ⇒ 用户看到"点了半天没声"，设备却还在为一次注定失败的
	# 取链空转（这正是"解析慢 + 越用越卡"的体感来源）。超预算就**明确失败**并把结论交给调用方，
	# 在飞的候选留给后台跑完（下次点同一首就是缓存命中）。
	my $budget = $a{budget} || 0;
	if ($budget > 0) {
		my $owner = {};
		Slim::Utils::Timers::setTimer($owner, time() + $budget, sub {
			return if $done;
			$done = 1;
			my $why = "resolve budget ${budget}s exceeded";
			$log->warn("LxMusic resolve: $why (queued=" . scalar(@cand) . " inflight=$inflight)");
			eval { $cb->({ ok => 0, timeout => 1, error => $why, tries => \@tries }); };
		});
	}

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
				priority => $prio,
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
						_src_failed(_src_key($src, $plat, $q), ($src->{name} // '?') . "\@$q");   # 0.11.57 熔断计数
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

	# 0.11.58：**请求分级**。'user' = 用户动作（点播/取链/校验，必须做完）；'bg' = 后台行为
	# （渲染期预热等）。bg 在"设备已经忙"时**直接丢弃**而不排队：
	# 现场实测（0.11.57，纯浏览 15 页 soak）恒温在 diagno 里看到"可播校验 在跑 22 个请求 /
	# 全豆要 在跑 22 个请求"——浏览一页就预热 3 首 × 多源 × 全档位，全排进串行 worker，
	# 用户真正点歌时排在这些无用功后面 ⇒ 越用越卡、最后像"插件失去响应"。
	my $prio = defined $args{priority} && $args{priority} eq 'bg' ? 'bg' : 'user';
	if ($prio eq 'bg' && $class->_load_busy) {
		$log->info('LxMusic Helper: background request dropped (device busy): ' . ($action // '?'));
		return $cb->(_err('background request skipped: device busy'));
	}

	# 常驻 worker 路径（M0.10）：
	#  · 「订阅源取链」(musicUrl) 与「可播校验」(probe)：固定开销最大。
	#  · 0.11.43 起 **sdk 动作也常驻**（source=$SDK，shim 侧 argv[1] 认 sdk.bundle.js 当 worker）：
	#    设备是 i386（Atom 级），每请求 fork+解析 700KB bundle ≈0.5s，而歌单下钻一次要问好几层。
	# 返回 0 = worker 不可用（起不来/写失败/积压），落回下面的 fork 路径。
	my %SDK_WORKER_ACTIONS = map { $_ => 1 }
		qw(search boards boardlist songlist songlistdetail songlistbytag songlistsorts songlisttags);
	if (workerEnabled()) {
		# 0.11.54：**慢源改走 fork**。现场（用户报"mg 几乎没有一首有声"）：
		#   玉宁熙的 mg 取链要串行打 3 次上游（单次响应 60~250KB），单曲 20~40s；
		#   我们 20s 一到就 `_worker_kill`，而 kill 会把**同源其他在飞 job 一起判失败**
		#   （日志里成片 `lx-玉宁熙-Pro@320k: worker stopped`）⇒ 该源几乎每首都失败。
		#   worker 是**串行**的（慢候选会把后面的候选全堵住），而 fork 路径**每单一进程**、
		#   超时只杀自己（`_poll`）⇒ 慢源走 fork 更稳。这里只给"超时过的源"打 10 分钟标记，
		#   其他源照旧享受常驻加速，worker 的通用语义不变。
		if ($action eq 'musicUrl' && $source && $source ne $SHIM && $source ne $SDK) {
			return if !_worker_hostile($source) && $class->_worker_submit(
				source   => $source,
				sourceId => $args{sourceId},
				action   => $action,
				info     => $args{info},
				cb       => $cb,
				timeout  => $timeout,
				priority => $prio,
			);
		}
		elsif ($action eq 'probe') {
			return if $class->_worker_submit(
				probe    => 1,
				action   => $action,
				info     => $args{info},
				cb       => $cb,
				timeout  => $timeout,
				priority => $prio,
			);
		}
		elsif ($SDK_WORKER_ACTIONS{$action} && $source eq $SDK) {
			# 0.11.59：**sdk 动作走 worker 池**（默认 2 个）。0.11.43 把它们塞进**同一个**串行 worker
			# ⇒ 设备实测（突发 8 并发 × 4 轮）：p50 84ms 但 p90 6960ms —— 排队排出来的。池化后
			# 下钻一层（列表→详情）不再互相堵；池位用"负载最小者"，没起的池位优先。
			return if $class->_worker_submit(
				source   => $class->_sdk_slot,
				sdkArg   => $SDK,          # argv[1] 必须是真 bundle 路径（shim 用它判定 worker 形态）
				sourceId => $args{sourceId},
				action   => $action,
				info     => $args{info},
				cb       => $cb,
				timeout  => $timeout,
				priority => $prio,
			);
		}
	}

	# 并发闸（M0.3）：整单 m3u 入队时 LMS 会并发解析几十个 lxm://，全 fork 会打满设备 CPU
	# 并拖垮上游（0.4.0 现场：全部 'timeout: no RESULT line'）。排队串行放行，max 2 并发。
	# 0.11.58：后台请求**不排队**（排队 = 用户点歌时前面还压着一串预热）——直接丢弃。
	if (scalar(keys %JOBS) >= _maxChildren()) {
		if ($prio eq 'bg') {
			$log->info('LxMusic Helper: background request dropped at the gate: ' . ($action // '?'));
			return $cb->(_err('background request skipped: gate full'));
		}
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
		src     => $source,     # 0.11.58：CAPS 行要按"哪个源"归档
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
	# 0.11.54：`$why` 以 'retry:' 开头 ⇒ **这些 job 改走 fork 重试一次**，而不是直接判失败。
	# 为什么需要：worker 是串行的，一个慢 job 超时会导致 `_worker_kill`，而 kill 会把**同源
	# 正在飞的兄弟候选一起判失败**——现场就是 `lx-玉宁熙-Pro@320k: worker stopped` 雪崩
	# （mg 一张歌单几乎全无声）。fork 路径每单一进程、超时只杀自己，正适合接手。
	my $retry = ($why =~ s/^retry://) ? 1 : 0;
	# 0.11.58：要重试就先标死——否则同步重入 `request()` 时会**复用这个正在死的 worker**
	# （`_worker_submit` 判的是 `!$w->{dead} && kill(0,pid)`），新 job 又被塞进一个即将被 kill 的进程。
	$w->{dead} = 1 if $retry;
	for my $id (keys %{ $w->{jobs} }) {
		my $job = delete $w->{jobs}{$id};
		if ($retry && !$job->{forked}) {
			$job->{forked} = 1;
			my $req = eval { $JSON->decode($job->{line}) } || {};
			$log->warn("LxMusic worker: job $id re-dispatched via fork after worker recycle");
			__PACKAGE__->request(
				source   => $w->{key},
				sourceId => $req->{source},
				action   => $req->{action},
				info     => $req->{info},
				timeout  => $job->{timeout},
				cb       => $job->{cb},
			);
			next;
		}
		# 0.11.58：回调包 eval（同 `_worker_poll` 的理由：回调抛异常会打断调用链/状态收尾）
		eval { $job->{cb}->({ ok => 0, data => undef, error => $why, logs => $job->{logs}, alerts => [], why => 'worker' }); };
	}
	@{ $w->{queue} } = ();
	return;
}

sub _worker_kill {
	my ($class, $w, $why) = @_;
	return unless $w;
	Slim::Utils::Timers::killTimers($w, \&_worker_poll);
	$class->_worker_fail_all($w, $why || 'worker stopped');
	kill 'KILL', $w->{pid} if $w->{pid};
	waitpid($w->{pid}, POSIX::WNOHANG()) if $w->{pid};
	close $w->{rd} if $w->{rd};
	close $w->{wr} if $w->{wr};
	# ⚠️ 0.11.58：**只删自己那一格**。`_worker_fail_all` 的 retry 分支会**同步重入 `request()`**，
	# 而旧 worker 此刻还没标死（非超时路径）⇒ 那里可能已经 spawn 出一个**新** worker 放进
	# `$WORKER{同一个 key}`。旧代码无条件 `delete $WORKER{$w->{key}}` 会把**新 worker 的登记**删掉：
	# 新进程成了孤儿（不在 %WORKER 里 ⇒ 诊断看不到、`_worker_submit` 下次又 spawn 一个），
	# 同一个源上叠出两个 qjs + 两套管道，越用越多。
	delete $WORKER{ $w->{key} } if $WORKER{ $w->{key} } == $w;
	$w->{dead} = 1;
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
			# 0.11.58：READY 里带源声明的能力表 ⇒ 立即可用（无需再等一次 CAPS 行）
			# 0.11.59：按 `$w->{src}`（真 argv1 路径）归档，别用 key——sdk 池的 key 是 `$SDK#0`
			my $info = eval { $JSON->decode($1) };
			Plugins::LxMusic::Helper->_caps_note($w->{src}, $info->{caps})
				if ref($info) eq 'HASH' && $info->{caps};
			while (defined(my $qid = shift @{ $w->{queue} })) {
				my $qjob = $w->{jobs}{$qid} or next;
				last unless Plugins::LxMusic::Helper->_worker_send_job($w, $qjob);
			}
			next;
		}
		# 0.11.58：源在 inited 时声明的能力表（fork 与 worker 两条路径都会打这一行）
		if ($line =~ /^CAPS (.*)$/s) {
			my $c = eval { $JSON->decode($1) };
			Plugins::LxMusic::Helper->_caps_note($w->{src}, $c) if ref($c) eq 'HASH';
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
			# ⚠️ 0.11.58：**回调必须包 eval**。LMS 的 `Slim::Utils::Timers` 在
			# `eval { $subptr->(...) }` 里调用我们（Timers.pm:266），异常会被它吞掉——
			# 而我们的重排定时器在本函数**末尾**：回调一抛异常，这个 worker 就再也不会被
			# poll（进程活着、jobs 挂着、回调永不来）= "插件失去响应但 LMS 正常"。
			eval { $job->{cb}->({
				ok => $ok ? 1 : 0, data => $data, error => $err,
				logs => [ @{ $w->{recent} }, @{ $job->{logs} || [] } ], alerts => [], why => 'worker',
				ms => $dec->{ms},
			}); };
			$log->warn("LxMusic worker($src): job $id callback threw: $@") if $@;
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
			# 0.11.54：这个源已经证明"串行 worker 扛不住" ⇒ 接下来 10 分钟让它走 fork，
			# 免得 kill 把同源其他在飞 job 一起带走（"worker stopped" 雪崩）。
			$WORKER_BAD{ $w->{key} } = time();
			delete $w->{jobs}{$id};
			my $cb = $job->{cb};
			my @logs = @{ $w->{recent} };
			$w->{dead} = 1;      # 0.11.54：先标死，重试的请求才会去起新 worker / 走 fork
			Plugins::LxMusic::Helper->_worker_kill($w, 'retry:worker timed out');
			eval { $cb->({ ok => 0, data => undef, error => 'timeout: worker request exceeded ' . ($job->{timeout} || '?') . 's',
				logs => \@logs, alerts => [], why => 'timeout' }); };
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

# 0.11.58：设备是否已经"忙"（后台请求据此自我放弃，而不是排到用户前面）
sub _load_busy {
	my ($class) = @_;
	return 1 if scalar(keys %JOBS) >= _maxChildren();
	for my $k (keys %WORKER) {
		my $w = $WORKER{$k} or next;
		return 1 if $w->{jobs} && scalar(keys %{ $w->{jobs} }) >= 4;
	}
	return 0;
}

# 0.11.59：sdk worker 池——挑一个负载最小的池位（没起过的池位优先，冷启动只需一次）。
# 池大小 `sdkWorkers`（默认 2，范围 1~4）：设备是双核 i386，2 个足以让"列表→详情"不互相排队。
sub _sdk_slot {
	my ($class) = @_;
	my $n = _pref('sdkWorkers', 2);
	$n = 1 if !$n || $n < 1;
	$n = 4 if $n > 4;
	my ($best, $bestload);
	for my $i (0 .. $n - 1) {
		my $k = $SDK . '#' . $i;
		my $w = $WORKER{$k};
		my $load = ($w && !$w->{dead} && $w->{pid} && kill(0, $w->{pid}))
			? scalar(keys %{ $w->{jobs} }) : -1;      # -1 = 没起/已死 ⇒ 最优先
		if (!defined $bestload || $load < $bestload) { $bestload = $load; $best = $k }
		last if defined $bestload && $bestload <= 0;
	}
	return $best // ($SDK . '#0');
}

# 把一个请求交给常驻 worker；返回 1 = 已接管，0 = 调用方应退回 fork 路径
sub _worker_submit {
	my ($class, %a) = @_;
	# 探测 worker：与取链 worker 分开（argv1='-'），长探测不会卡住取链
	# sdk worker 池（0.11.59）：key 是 `$SDK#<池位>`，argv1 仍是真 bundle 路径
	my ($key, $arg1) = $a{probe} ? ($PROBE_KEY, '-')
		: defined $a{sdkArg} ? ($a{source}, $a{sdkArg})
		: ($a{source}, undef);
	my $w = $WORKER{$key};
	$w = $class->_worker_spawn($key, $arg1) unless $w && !$w->{dead} && kill(0, $w->{pid});
	return 0 unless $w;

	# 0.11.58：**后台（预热）请求绝不跟用户抢同一个串行 worker**——worker 里已经有活就直接放弃。
	# 这一条是"点歌慢/越用越卡"的关键闸门：从前浏览一页就塞进 3~9 个预热取链+校验 job，
	# 用户真正点歌时它们全排在前面（现场 diag 恒温 "在跑 22 个请求"）。
	if ((($a{priority} // 'user') eq 'bg') && $w->{jobs} && scalar(keys %{ $w->{jobs} }) >= 1) {
		$log->info('LxMusic worker: background job dropped (worker busy)');
		$a{cb}->(_err('background request skipped: worker busy'));
		return 1;   # 已接管（错误已回复），不要退回 fork
	}

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

# 0.11.54：这个源最近是否被判定"worker 不适合"（超时过）——是则改走 fork 路径
sub _worker_hostile {
	my $src = shift;
	my $t = $WORKER_BAD{$src} or return 0;
	return (time() - $t < $WORKER_BAD_TTL) ? 1 : 0;
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

	# 0.11.58：fork 路径也要归档源能力表（shim 在 inited 时会打一行 `CAPS {json}`）
	if ($job->{src} && $buf =~ /^CAPS (.*)$/m) {
		my $c = eval { $JSON->decode($1) };
		__PACKAGE__->_caps_note($job->{src}, $c) if ref($c) eq 'HASH';
	}

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
	# 0.11.58：回调包 eval，且**无论回调是否抛异常都要放行并发闸**——否则 `@WAITQ` 里排队的
	# 请求会永远等不到放行（表现为"整插件不再响应新请求"）。
	eval { $job->{cb}->({
		ok     => $ok ? 1 : 0,
		data   => $data,
		error  => $err,
		logs   => $logs,
		alerts => $alerts,
		why    => $why,
	}); };
	$log->warn("LxMusic Helper: job $job->{pid} callback threw: $@") if $@;

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
