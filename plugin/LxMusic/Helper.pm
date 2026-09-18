# Plugins/LxMusic/Helper.pm — 洛雪音乐引擎宿主
# ============================================================
# 职责：
#   1) init：把插件自带的 qjs 引擎 + shim.mjs 复制到 tmpfs（达菲 /tmp），
#      修复可执行位（LMS 解压丢 +x），并做一次引擎自检。
#   2) request：以「每 action 一个进程」模型运行
#         qjs shim.mjs <source.js> <action> <infoJSON>
#      异步（fork/exec + AnyEvent::Handle 读管道），超时 KILL，
#      stdout 按行解析：RESULT 行=结果协议，LOG/ALERT 行=诊断分流。
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
use Symbol qw(qualify_to_ref);

use Slim::Utils::Log;

my $log = Slim::Utils::Log->logger('plugin.lxmusic');

# AnyEvent 为 LMS 内置（ImageResizer 先例）；延迟加载以便存根测试。
my ($AnyEvent, $AnyEventHandle);

my $TMPDIR  = File::Spec->catdir(File::Spec->tmpdir(), 'LXMusic');
my $QJS     = File::Spec->catfile($TMPDIR, 'qjs');
my $SHIM    = File::Spec->catfile($TMPDIR, 'shim.mjs');
my $SOURCES = File::Spec->catdir($TMPDIR, 'sources');

my $JSON = JSON::XS->new->utf8->allow_nonref;

my %JOBS;    # pid => job

sub _loadAE {
	return 1 if $AnyEvent;
	$AnyEvent       = _load('AnyEvent');
	$AnyEventHandle = _load('AnyEvent::Handle');
	return $AnyEvent && $AnyEventHandle;
}

sub _load {
	my ($mod) = @_;
	my $file = $mod;
	$file =~ s{::}{/}g;
	eval { require "$file.pm"; 1 } or do {
		$log->error("LxMusic Helper: cannot load $mod: $@");
		return undef;
	};
	return $mod;
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

	copy($qjsSrc, $QJS)   or do { $log->error("LxMusic Helper: copy qjs: $!"); return 0 };
	copy($shimSrc, $SHIM) or do { $log->error("LxMusic Helper: copy shim: $!"); return 0 };
	chmod(0755, $QJS);                       # 关键：解压丢 +x，/tmp 里修复

	# 引擎自检（阻塞但 <100ms，仅 init 一次）
	my $out = _qx([$QJS, '-e', 'print("lx-engine-ok:"+("abc"==String.fromCharCode(97,98,99)))']);
	if ($out && $out =~ /lx-engine-ok:1/) {
		$log->info('LxMusic Helper: engine ready at ' . $QJS);
		return 1;
	}
	$log->error('LxMusic Helper: engine self-test failed: ' . ($out // '<no output>'));
	return 0;
}

# ---------- 订阅源安装 ----------
sub installSource {
	my ($class, $name, $content) = @_;
	$name =~ s/[^\w.-]/_/g;                  # 防路径穿越
	mkpath($SOURCES);
	my $path = File::Spec->catfile($SOURCES, $name);
	open(my $fh, '>:encoding(UTF-8)', $path) or do {
		$log->error("LxMusic Helper: write source $path: $!");
		return undef;
	};
	print {$fh} $content;
	close $fh;
	return $path;
}

# ---------- 异步请求 ----------
# request(source => $path, action => 'musicUrl', sourceId => 'kw',
#         info => {...}, cb => sub { my $res = shift; }, timeout => 20)
# res = { ok=>1/0, data=>..., error=>..., logs=>[], alerts=>[], why=>... }
sub request {
	my ($class, %args) = @_;

	my $cb = $args{cb} or return;
	_loadAE() or do { $cb->(_err('AnyEvent unavailable')); return };

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

	pipe(my $rh, my $wh) or do { $cb->(_err("pipe: $!")); return };
	$wh->autoflush(1);

	my $pid = fork();
	if (!defined $pid) { close $rh; close $wh; $cb->(_err("fork: $!")); return; }

	if ($pid == 0) {                         # ---- child ----
		close $rh;
		open(STDOUT, '>&', POSIX::fileno(qualify_to_ref($wh))) or POSIX::_exit(127);
		open(STDERR, '>&', POSIX::fileno(qualify_to_ref($wh)));   # stderr 并入 stdout（按前缀过滤）
		close $wh;
		$ENV{PATH} = '/usr/bin:/bin:/usr/sbin:/sbin';   # curl 定位
		chdir('/');
		exec($QJS, $SHIM, $source, $action, $infoJson);
		POSIX::_exit(127);
	}

	# ---- parent ----
	close $wh;

	my $job = {
		pid => $pid, cb => $cb, buf => '', done => 0,
		started => time(), timeout => $timeout,
	};
	$JOBS{$pid} = $job;

	$job->{timer} = AnyEvent->timer(after => $timeout, cb => sub {
		$log->warn("LxMusic Helper: job $pid ($action) timed out after ${timeout}s");
		kill 'KILL', $pid;
		_finish($job, 'timeout');
	});

	$job->{h} = AnyEvent::Handle->new(
		fh      => $rh,
		on_read => sub {
			my ($h) = @_;
			$job->{buf} .= $h->{rbuf};
			$h->{rbuf} = '';
		},
		on_eof   => sub { _finish($job, 'ok') },
		on_error => sub { _finish($job, 'io') },
	);

	return $pid;
}

# ---------- shutdown ----------
sub shutdown {
	my ($class) = @_;
	for my $pid (keys %JOBS) {
		kill 'KILL', $pid;
		_finish($JOBS{$pid}, 'shutdown');
	}
	rmtree($TMPDIR);
	return 1;
}

# ---------- 内部 ----------
sub _finish {
	my ($job, $why) = @_;
	return if $job->{done}++;
	$job->{timer} = undef;                   # AE watcher 解引用即取消
	delete $JOBS{$job->{pid}};
	waitpid($job->{pid}, 0) if $job->{pid};
	my ($ok, $data, $err, $logs, $alerts) = _parse($job->{buf});

	if ($why ne 'ok') {
		$ok   = 0;
		$err  = defined $err ? "$why: $err" : $why;
		$data = undef;
	}
	$job->{cb}->({
		ok     => $ok ? 1 : 0,
		data   => $data,
		error  => $err,
		logs   => $logs,
		alerts => $alerts,
		why    => $why,
	});
}

# stdout 协议解析（纯函数，便于单测）
sub _parse {
	my ($text) = @_;
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
	my $inc = $INC{'Plugins/LxMusic/Helper.pm'} or return undef;
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
