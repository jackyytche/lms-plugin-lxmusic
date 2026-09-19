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

# 当前生效的订阅源路径（导入/启动时装好；无源返回 undef）
sub currentSourcePath {
	my ($class) = @_;
	return (-f $CURRENT_SOURCE) ? $CURRENT_SOURCE : undef;
}

sub sourceInfo {
	my ($class) = @_;
	return { installed => -f $CURRENT_SOURCE ? 1 : 0, path => $CURRENT_SOURCE };
}

sub installSource {
	my ($class, $name, $content) = @_;
	# 浏览器 textarea 提交把换行规范成 CRLF；lx 源的完整性签名基于原版 LF 内容，
	# 必须在落盘前统一回 LF，否则 qjs 端 rawScript hash 与官方不一致（服务端 403）。
	$content =~ s/\r\n/\n/g;

	# 落盘统一用 :encoding(UTF-8)，所以这里必须是"字符"串：
	#   - 浏览器粘贴路径：LMS 已 utf8decode（旗标串）→ 原样
	#   - URL 下载路径（_fetch/curl）：拿到的是原始 UTF-8 字节 → 必须解码，
	#     否则每个非 ASCII 字节被再编码一次（设备实测：64094 B 的源落盘成 72249 B，
	#     源文件被改坏 ⇒ 签名握手失败、取不到直链）
	#   - 非法 UTF-8 字节（二进制）：保留原值，尽量不改动用户给的内容
	if (!utf8::is_utf8($content)) {
		my $decoded = eval { Encode::decode('UTF-8', $content, Encode::FB_CROAK()) };
		$content = $decoded if defined $decoded;
	}

	$name =~ s/\.{2,}/_/g;                   # 收敛连续点（防穿越）
	$name =~ s/[^\w.-]/_/g;                  # 防非法字符
	$name =~ s/^[.\-]+//;                    # 首字符须为字母数字下划线
	mkpath($SOURCES);
	my $path = File::Spec->catfile($SOURCES, $name);
	open(my $fh, '>:encoding(UTF-8)', $path) or do {
		$log->error("LxMusic Helper: write source $path: $!");
		return undef;
	};
	print {$fh} $content;
	close $fh;
	# current.js = 当前生效源（request 固定用它，简化协议处理器）
	if ($path ne $CURRENT_SOURCE) {
		open(my $cf, '>:encoding(UTF-8)', $CURRENT_SOURCE) or do {
			$log->error("LxMusic Helper: write current source: $!");
			return undef;
		};
		print {$cf} $content;
		close $cf;
	}
	return $path;
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
	if ($action eq 'search' || $action eq 'boards' || $action eq 'boardlist'
		|| $action eq 'songlist' || $action eq 'songlistdetail') {
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
		$dec->{ok} ? undef : $dec->{error},
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
