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
use File::Copy qw(copy);
use File::Path qw(mkpath rmtree);
use File::Spec;
use JSON::XS ();
use POSIX ();

use Slim::Utils::Log;
use Slim::Utils::Timers;

my $log = Slim::Utils::Log->logger('plugin.lxmusic');

my $TMPDIR  = File::Spec->catdir(File::Spec->tmpdir(), 'LXMusic');
my $QJS     = File::Spec->catfile($TMPDIR, 'qjs');
my $SHIM    = File::Spec->catfile($TMPDIR, 'shim.mjs');
my $SOURCES = File::Spec->catdir($TMPDIR, 'sources');

my $JSON = JSON::XS->new->utf8->allow_nonref;

my %JOBS;    # pid => job

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

	copy($qjsSrc, $QJS)   or do { $log->error("LxMusic Helper: copy qjs: $!"); return 0 };
	copy($shimSrc, $SHIM) or do { $log->error("LxMusic Helper: copy shim: $!"); return 0 };
	chmod(0755, $QJS);                       # 关键：解压丢 +x，/tmp 里修复

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
	$source && $action or do { $cb->(_err('source/action required')); return };
	-f $source or do { $cb->(_err("source missing: $source")); return };
	-f $QJS && -x _ or do { $cb->(_err('engine not initialised (call init)')); return };

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

	my ($ok, $data, $err, $logs, $alerts) = _parse($buf);

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
