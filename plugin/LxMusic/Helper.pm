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
use File::Copy qw(copy);
use File::Path qw(mkpath rmtree);
use File::Spec;
use JSON::XS ();
use POSIX ();

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
			# 只要不是 text/*（HTML 错误页）就放行：CDN 常用 octet-stream / 空 type
			my $ok = $res->{ok} && $code >= 200 && $code < 300
				&& ($type eq '' || $type =~ m{^(?:audio/|video/|application/(?:octet-stream|x-))});
			$cb->({
				ok     => $ok ? 1 : 0,
				status => $code,
				type   => $d->{type},
				length => $d->{length},
				method => $d->{method},
				error  => $ok ? undef : ($code ? "HTTP $code" : ($res->{error} // 'no response'))
					. ($type ne '' ? " type=$type" : ''),
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
	my $next;
	$next = sub {
		my $cand = shift @cand;
		unless ($cand) {
			my @last = @tries > 3 ? @tries[ -3 .. -1 ] : @tries;
			my $why = join('; ', map {
				($_->{source} // '?') . '@' . ($_->{quality} // '?') . ': ' . ($_->{why} // '?')
			} @last);
			$why = '无候选' unless length $why;
			$log->warn('LxMusic resolve FAILED after ' . scalar(@tries) . " tries: $why");
			return $cb->({ ok => 0, error => "全部订阅源都取不到直链（$why）", tries => \@tries });
		}
		my ($q, $src) = @$cand;
		my $path = Plugins::LxMusic::Sources->pathFor($src->{id});
		unless ($path && -f $path) {
			push @tries, { source => $src->{name}, quality => $q, why => 'file missing' };
			return $next->();
		}
		$log->warn("LxMusic resolve: try [" . $src->{name} . "] type=$q");
		$class->request(
			source   => $path,
			action   => 'musicUrl',
			sourceId => ($a{src} // ''),
			info     => { musicInfo => $track, type => $q },
			timeout  => ($a{timeout} || 20),
			cb       => sub {
				my ($res) = @_;
				my $url = $res->{data};
				unless ($res->{ok} && defined $url && !ref($url) && $url =~ m{^https?://}) {
					# 把子进程日志尾部并进 why：否则像 "no RESULT line" 这种失败在现场完全无痕
					# （qjs 子进程最后几行才是真正原因，M0.9 现场吃了这个亏）
					my @tail = grep { defined && length } @{ $res->{logs} || [] };
					@tail = @tail[ -2 .. -1 ] if @tail > 2;
					my $why = ($res->{error} // 'no url')
						. (@tail ? ' {' . join(' | ', map { substr($_, 0, 100) } @tail) . '}' : '');
					push @tries, { source => $src->{name}, quality => $q, why => $why };
					return $next->();
				}
				my $done = sub {
					my ($verified, $kbps) = @_;
					# 码率异常低 ⇒ 很可能是试听片段/残缺文件（实测：长青 kg flac24bit 只有 ~48kbps）
					my $suspect = ($kbps && $kbps < 64) ? 1 : 0;
					if ($suspect) {
						$log->warn("LxMusic resolve: SUSPECT short/preview file ([" . ($src->{name} // '?')
							. "] type=$q -> ~${kbps}kbps) — 可能是试听片段或残缺文件");
					}
					push @tries, { source => $src->{name}, quality => $q, ok => 1, verified => $verified,
						kbps => $kbps, suspect => $suspect };
					$log->warn("LxMusic resolve OK: [" . $src->{name} . "] type=$q verified=$verified"
						. (defined $kbps ? " ~${kbps}kbps" : '') . ($suspect ? ' (SUSPECT)' : ''));
					$cb->({
						ok         => 1,
						url        => $url,
						source     => $src->{name},
						sourceId   => $src->{id},
						quality    => $q,
						verified   => $verified,
						actualKbps => $kbps,
						suspect    => $suspect,
						tries      => \@tries,
					});
				};
				return $done->(0) unless $wantVerify;
				$class->probeUrl($url, sub {
					my ($pi) = @_;
					if ($pi->{ok}) {
						my $secs = _secsOf($track);
						my $kbps = ($pi->{length} && $secs) ? int($pi->{length} * 8 / 1000 / $secs) : undef;
						return $done->(1, $kbps);
					}
					push @tries, { source => $src->{name}, quality => $q, why => 'verify: ' . ($pi->{error} // '?') };
					$log->warn("LxMusic resolve: verify rejected [" . $src->{name} . "] $q: " . ($pi->{error} // '?'));
					$next->();
				});
			},
		);
	};
	$next->();
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
		|| $action eq 'songlist' || $action eq 'songlistdetail' || $action eq 'songlistbytag') {
		-f $SDK or do { $cb->(_err('sdk bundle not installed (search/browse disabled)')); return };
		$source = $SDK;
	}
	else {
		$source && -f $source or do { $cb->(_err('source missing: ' . ($source // '<undef>'))); return };
	}
	-f $QJS && -x _ or do { $cb->(_err('engine not initialised (call init)')); return };

	# 并发闸（M0.3）：整单 m3u 入队时 LMS 会并发解析几十个 lxm://，全 fork 会打满设备 CPU
	# 并拖垮上游（0.4.0 现场：全部 'timeout: no RESULT line'）。排队串行放行，max 2 并发。
	if (scalar(keys %JOBS) >= _maxChildren()) {
		push @WAITQ, sub { __PACKAGE__->request(%args) };
		$log->debug('LxMusic Helper: request queued (' . scalar(@WAITQ) . ' waiting)');
		return;
	}

	my $timeout = $args{timeout} || 20;
	$timeout = 60 if $timeout > 60;          # lx 宿主 20s 硬超时同量级，上限 60
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
	for my $pid (keys %JOBS) {
		my $job = $JOBS{$pid};
		Slim::Utils::Timers::killTimers($job, \&_poll);
		kill 'KILL', $pid;
		_finish($job, 'shutdown');
	}
	rmtree($TMPDIR);
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
