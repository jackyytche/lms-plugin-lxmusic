# Plugins::LxMusic::Settings — 正式设置页（设置 → 插件 → LX Music）
#
# M0.6 信息架构（解决"订阅方式令人迷惑"）：
#   ① 订阅源 · 在线订阅   —— 只收 http(s) 源地址，插件下载后登记为一条源
#   ② 订阅源 · 本地导入   —— 读服务器上的文件/目录（LMS 自带 selectFile/selectFolder 文件选择器，
#                            不需要也不存在 multipart 上传通道）
#   ③ 订阅源列表         —— 两种来源混排：启用/排序/更新/删除（多源并存 = 聚合兜底顺序）
#   ④ 音质               —— 上限档位 + 自动降级 + 取链校验（对齐 PC 端 getPlayQuality 语义）
#   ⑤⑥ 桥接/并发/缓存、封面代理、榜单源
#   ⑦ 诊断               —— 版本/引擎/日志级别/源目录/注册表统计
#
# prefs 命名空间 plugin.lxmusic，保存后立即生效（Helper/ProtocolHandler 每次请求读 prefs）。

package Plugins::LxMusic::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Encode ();
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::LxMusic::Helper;
use Plugins::LxMusic::Sources;

my $log   = Slim::Utils::Log->logger('plugin.lxmusic');
my $prefs = preferences('plugin.lxmusic');

# 必须是 strings.txt 的 token（LMS 的 `name` 契约就是"字符串 token"）：设置下拉/
# 页面标题都用 `| string` 渲染它，返回显示串会渲染成空白行（0.6.3 现场踩到）。
sub name { 'PLUGIN_LXMUSIC' }

sub page { 'plugins/LxMusic/settings/basic.html' }

# 设置页模板是「纯 ASCII + 数字实体」（见 basic.html 头注，由 tmp/mk_settings_template.py 生成）：
# LMS 的 Template 对象没有 ENCODING（Slim/Web/Template/SkinManager.pm 的 Template->new），
# 传进模板的 UTF-8 字节串会被当 latin-1 再编码 ⇒ 浏览器双重编码乱码（设备实测）。
# 这里把非 ASCII 与 HTML 敏感字符一次转成数字实体，输出纯 ASCII —— 管道里任何
# 编码环节都改不坏，也不依赖服务器语言（EN 的达菲同样显示中文）。
sub _ent {
	my ($s) = @_;
	return '' unless defined $s;
	my $u = _chars($s);
	my $out = '';
	for my $c (split //, $u) {
		my $o = ord $c;
		$out .= ($o > 127 || $c eq '&' || $c eq '<' || $c eq '>' || $c eq '"' || $c eq "'")
			? '&#' . $o . ';'
			: $c;
	}
	return $out;
}

# 统一把"原始 UTF-8 字节串"变成旗标字符串（已是字符则原样）。
sub _chars {
	my ($s) = @_;
	return $s if !defined $s || utf8::is_utf8($s);
	my $u = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK()) };
	return defined $u ? $u : $s;    # 非法 UTF-8 字节：原样处理，至少不崩
}

# 拼接"人看的字符串"专用：把每个片段先归一成字符再拼。
# ⚠️ 不能直接用 `.`：本文件的中文字面量是**字节串**，而 JSON 解出的值/源名是**旗标串**，
# 两者一拼就得到"混旗标串"——旗标一开，字面量的每个字节被当成一个字符，_ent 于是把
# 每个字节单独转义 ⇒ 页面出现双重编码乱码（设备实测：已添加在线订阅 → å·²æ·»å ）。
# 同族坑见 HANDOFF §5.3.19（join 混用旗标/未旗标串）。
sub _m { return join('', map { my $x = _chars($_); defined $x ? $x : '' } @_) }

# 由 Slim::Web::Settings 基类负责存取；表单字段名 = pref_<name>
sub prefs {
	return ($prefs, qw(
		quality bridgeTimeout helperConcurrency resolveTtl coverProxy
		boardsKw boardsKg boardsTx boardsWy boardsMg qualityFallback verifyUrl autoSkipOnError
		workerEnable workerIdle preferStreamable
		warmEnable warmMax resolveBudget sdkWorkers coverThumb
	));
}

my @BOOL_PREFS = qw(coverProxy boardsKw boardsKg boardsTx boardsWy boardsMg qualityFallback verifyUrl autoSkipOnError workerEnable preferStreamable warmEnable);

sub handler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	# 复选框未勾选 ⇒ 表单根本不带该字段 ⇒ 基类会 set($pref, undef)。
	# 而 Prefs::Base::init 在下次重启时把 undef 当"未初始化"重新灌默认值(1)，
	# 开关会自己弹回（LMS 经典坑）。这里显式落 0，让"关"成为持久值。
	if ($params->{saveSettings}) {
		for my $b (@BOOL_PREFS) {
			$params->{"pref_$b"} = 0 unless defined $params->{"pref_$b"};
		}
	}

	my $action = $params->{lxAction} || '';
	my @messages;

	if ($params->{saveSettings}) {

		# ---- 源列表：启用开关（行内 checkbox：src_enabled_<id>）----
		# 表单是权威：勾选=启用、未勾选（字段缺失）=停用。必须无条件同步，
		# 否则"取消勾选后点保存"会因为字段不存在而被当成"没动过"。
		my %known = map { ($_->{id} => 1) } @{ Plugins::LxMusic::Sources->list };
		for my $id (keys %known) {
			Plugins::LxMusic::Sources->setEnabled($id, $params->{'src_enabled_' . $id} ? 1 : 0);
		}

		# ---- 行内按钮：lxUp:<id> / lxDown:<id> / lxDel:<id> / lxRefresh:<id> ----
		for my $k (keys %$params) {
			next unless $k =~ /^lx(Up|Down|Del|Refresh):([A-Za-z0-9_-]+)$/;
			my ($what, $id) = ($1, $2);
			next unless $params->{$k};
			if ($what eq 'Del') {
				push @messages, Plugins::LxMusic::Sources->remove($id)
					? _m('已删除订阅源')
					: _m('删除失败（未找到该源）');
			}
			elsif ($what eq 'Up' || $what eq 'Down') {
				Plugins::LxMusic::Sources->move($id, $what eq 'Up' ? -1 : 1);
				push @messages, _m('已调整顺序');
			}
			elsif ($what eq 'Refresh') {
				my ($r, $err) = Plugins::LxMusic::Sources->refresh($id);
				push @messages, $err ? _m('更新失败：', $err)
					: ($r->{unchanged} ? _m('在线订阅已是最新（内容未变）')
						: _m('已更新：', $r->{name}, '（', $r->{bytes}, ' 字节）'));
			}
		}

		# ---- 导入 ----
		if ($action eq 'add_url') {
			my ($rec, $err) = Plugins::LxMusic::Sources->addUrl($params->{sourceUrl});
			push @messages, $err ? _m('在线订阅失败：', $err)
				: _m('已添加在线订阅：', $rec->{name}, '（', $rec->{bytes}, ' 字节）');
		}
		elsif ($action eq 'add_file') {
			my ($rec, $err) = Plugins::LxMusic::Sources->addFile($params->{sourceFile});
			push @messages, $err ? _m('本地导入失败：', $err)
				: _m('已从文件导入：', $rec->{name}, '（', $rec->{bytes}, ' 字节）');
		}
		elsif ($action eq 'add_dir') {
			my ($r, $err) = Plugins::LxMusic::Sources->addDir($params->{sourceDir});
			if ($err) { push @messages, _m('目录导入失败：', $err) }
			else {
				push @messages, _m('目录导入：成功 ', scalar(@{ $r->{ok} }),
					(@{ $r->{ok} } ? _m('（', join(_chars('、'), map { _chars($_) } @{ $r->{ok} }), '）') : ''));
				push @messages, _m('跳过 ', scalar(@{ $r->{bad} }), ' 个：',
					join(_chars('；'), map { _chars($_) } @{ $r->{bad} }))
					if @{ $r->{bad} };
			}
		}
	}

	# ---- 模板数据 ----
	$params->{lxMessage} = @messages ? _ent(join(_chars(' ｜ '), @messages)) : '';

	my $st  = Plugins::LxMusic::Sources->status;
	my $src = Plugins::LxMusic::Helper->sourceInfo;
	my @rows;
	for my $rec (@{ Plugins::LxMusic::Sources->list }) {
		my $path = Plugins::LxMusic::Sources->pathFor($rec->{id});
		my $meta = $rec->{meta} || {};
		my $detail = $rec->{origin} eq 'url' ? _m('在线 · ', $rec->{url})
			: $rec->{origin} eq 'legacy' ? _m('本地 · 由旧版单源迁移')
			: _m('本地 · ', $rec->{url});
		push @rows, {
			id      => $rec->{id},
			name    => _ent($rec->{name}),
			detail  => _ent($detail),
			enabled => $rec->{enabled} ? 1 : 0,
			isUrl   => ($rec->{origin} eq 'url' && $rec->{url}) ? 1 : 0,
			bytes   => ($rec->{bytes} // 0),
			metaLine => _ent(join(_chars(' · '), grep { length }
				(($meta->{version} ? _m('v', $meta->{version}) : ''),
				 _chars($meta->{author} // ''), _chars($meta->{description} // '')))),
			missing => ($path && -f $path) ? 0 : 1,
		};
	}

	$params->{lxSources}     = \@rows;
	$params->{lxSourceDir}   = _ent(Plugins::LxMusic::Sources->dir);
	$params->{lxSourceStats} = _ent(sprintf('%d 个源，%d 个启用（按列表顺序依次尝试）', $st->{total}, $st->{enabled}));
	$params->{lxVersion}     = _ent(Plugins::LxMusic::Helper->pluginVersion);
	$params->{lxEngine}      = _ent(Plugins::LxMusic::Helper->engineStatus);
	$params->{lxHasSource}   = $st->{enabled} ? 1 : 0;

	my $logLevel = eval { Slim::Utils::Log->allCategories()->{'plugin.lxmusic'} }
		|| '默认 ERROR（可在「高级 → 日志」调整）';
	$params->{lxLogLevel} = _ent($logLevel);

	# M0.10：常驻 worker 现场（有则显示：在服务哪个源 / pid / 就绪状态 / 在跑请求数）
	if (Plugins::LxMusic::Helper->workerEnabled) {
		my @w = @{ Plugins::LxMusic::Helper->workerStatus };
		unless (@w) {
			$params->{lxWorkers} = _ent('未启动（首个取链请求时预热）');
		}
		else {
			# 源文件路径 -> 源名（给现场看得懂的标签）
			my %byPath;
			for my $rec (@{ Plugins::LxMusic::Sources->list }) {
				my $p = Plugins::LxMusic::Sources->pathFor($rec->{id});
				$byPath{$p} = $rec->{name} if $p;
			}
			my @lbl;
			for my $w (@w) {
				my $who = $w->{key} eq '__probe' ? _chars('可播校验')
					: ($byPath{ $w->{src} } ? _chars($byPath{ $w->{src} })
						: ($w->{src} && $w->{src} ne '-' ? _chars($w->{src}) : _chars('未知源')));
				push @lbl, _m($who, ' pid ', $w->{pid}, ' ',
					($w->{ready} ? _chars('已预热') : _chars('预热中')),
					($w->{jobs} ? _m(' 在跑 ', $w->{jobs}, ' 个请求') : ()));
			}
			$params->{lxWorkers} = _ent(join(_chars('；'), @lbl));
		}
	}
	else {
		$params->{lxWorkers} = _ent('已关闭（每请求现起 qjs 进程）');
	}

	return $class->SUPER::handler($client, $params, $callback, $httpClient, $response);
}

1;

__END__

=head1 NAME

Plugins::LxMusic::Settings - LX Music 设置页

=cut
