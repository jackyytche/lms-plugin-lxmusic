# Plugins/LxMusic/Plugin.pm
# ============================================================
# v0.1.0-alpha1: engine bootstrap, Web import/diag page,
# XMLBrowser feed (play-test), lxm:// protocol handler wired.
# NOTE: no "use utf8" on purpose - CJK text lives as raw UTF-8
# bytes (page output and log lines are byte-safe as-is).
# ============================================================

package Plugins::LxMusic::Plugin;

use strict;
use warnings;

# 基类必须是 OPMLBased（不是 Base）：feed/tag/menu 参数、CLI 'lxmusic items'
# dispatch、Jive/player 菜单注册、setMode(xmlbrowser push) 全在 OPMLBased——
# 0.1~0.3.0 误继承 Base，XMLBrowser 菜单从未注册过（latent bug，设备无入口）。
# webPages 不冲突：OPMLBased 注册小写 plugins/lxmusic/index.html（浏览 UI），
# 本插件自注册大写 plugins/LxMusic/index.html（设置/导入/搜索页，正则大小写敏感）。
use base qw(Slim::Plugin::OPMLBased);

use HTML::Entities qw(encode_entities);
use Encode ();
use JSON::XS ();
use MIME::Base64 qw(encode_base64url decode_base64url);
use Time::HiRes qw(time);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;     # 0.11.30：建队后补发队列元数据（见 _trackItems 末尾）
use Slim::Utils::Network;
use Slim::Web::Pages;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Control::Request;
use Slim::Player::Client;

use Plugins::LxMusic::Helper;
use Plugins::LxMusic::ProtocolHandler;
use Plugins::LxMusic::Sources;

# 注册日志分类（LMS 调试页才会列出并可调级别；不注册则 warn/info 静默丢失——排障断腿）
my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.lxmusic',
	'defaultLevel' => 'ERROR',
	'description'  => 'LX Music',
});

my $prefs = preferences('plugin.lxmusic');

sub getDisplayName { 'LX Music' }

sub initPlugin {
	my ($class) = @_;

	$prefs->init({
		sourceContent  => '',
		sourceName     => '',
		quality        => '320k',
		# ---- 0.6.x 设置页 ----
		bridgeTimeout  => 7,     # 桥级 per-request 超时（秒；migu 内部再打 3 折）
		helperConcurrency => 2,  # Helper 并发子进程上限（整单入队风暴防护）
		resolveTtl     => 600,   # 解析缓存 TTL（秒）
		coverProxy     => 1,     # 封面代理（kg/kw 需经插件中转，设备侧才出图）
		boardsKg       => 1,
		boardsTx       => 1,
		boardsWy       => 1,
		boardsMg       => 1,
		boardsKw       => 1,     # 0.11.0 kw 榜单改走 kbangserver（免签名）后解禁
		# ---- M0.6 多订阅源 / 音质 ----
		sourcesJson    => '',    # 多订阅源注册表（JSON：顺序/启用/来源/元数据）
		qualityFallback => 1,    # 源没有所选档位时自动降档（对齐 PC getPlayQuality）
		verifyUrl      => 1,     # 取链后 HEAD 校验可播（挡掉 403/HTML 错误页 = 防"无声"）
		# ---- M0.7 ----
		autoSkipOnError => 1,    # 全源失败后交给 LMS 跳下一曲（对齐 PC player.autoSkipOnError）
		# ---- M0.10 常驻 worker ----
		workerEnable   => 1,     # 常驻 qjs worker（取链/校验复用同一进程，省掉每请求的进程启动与源解析）
		workerIdle     => 600,   # worker 空闲多久退出（秒；0 = 不退常驻）
		# ---- M0.10 播放兼容 ----
		preferStreamable => 1,   # 优先选带音频后缀的直链（无后缀脚本中转链在达菲上会无声/卡死）
		# ---- M0.15（0.11.58/0.11.59）按需解析与预算 ----
		# 起因：0.11.57 实测"纯浏览 15 页就让串行 worker 恒温在跑 22 个请求"（每页预热 3 首 ×
		# 档位 × 全部启用源 × 带 verify），用户点歌排在这些无用功后面 = 解析慢、越用越卡。
		warmEnable     => 1,     # 渲染期预热总开关（关掉：点哪首都现取链，设备更清闲）
		warmMax        => 1,     # 每页预热几首（0-5）；预热请求是 bg 优先级，设备忙时会被直接丢弃
		# 0.11.69：**默认预算 10 → 20**。mg 逐曲实测：预算 10s ⇒ 4/6 有声；预算 25s ⇒ **6/6**。
		# ⇒ 慢平台是被预算卡住的，不是源做不到；用户明确"音质优先、起播慢可忍"（设置页可调）。
		resolveBudget  => 20,    # 播放路径整体预算（秒，0=不限）：超预算明确失败并放人（LMS 约 4~8s 就放弃）
		sdkWorkers     => 2,     # 浏览（SDK）常驻进程池大小（1-4）：>1 时"列表/详情"下钻不再互相排队
		# ---- 0.11.61 封面提速 ----
		# 实测：wy 原图 4.81MB/张、kw 108KB、tx 55KB，而达菲每一行都要经 LMS 图像代理取一次
		# ⇒ 一页 50 行就是几百 MB 代理流量。这里把列表/队列封面统一降到缩略尺寸（0 = 用原图）。
		coverThumb     => 300,
		# 0.11.62：大图档（队列行/正在播放面板会请求 300~500px，用 300 会发虚）
		coverThumbBig  => 500,
	});

	unless (Plugins::LxMusic::Helper->init) {
		$log->error('LxMusic: engine init FAILED, check server.log');
	}

	# 老版本（<=0.6.4）的单订阅源迁移到多源注册表（幂等，只在有老数据且注册表为空时动作）
	if (Plugins::LxMusic::Sources->migrateLegacy) {
		$log->warn('LxMusic: legacy single source migrated into the source registry');
	}

	if (main::WEBUI) {
		Slim::Web::Pages->addPageFunction(
			'plugins/LxMusic/index\.html',
			sub { $class->webHandler(@_) },
		);
		Slim::Web::Pages->addPageFunction(
			'plugins/LxMusic/playlist\.m3u',
			sub { $class->webHandler(@_) },
		);
		Slim::Web::Pages->addPageFunction(
			'plugins/LxMusic/cover',
			sub { $class->webHandler(@_) },
		);

		# M0.5: 正式设置页（设置 → 插件 → LX Music）
		require Plugins::LxMusic::Settings;
		Plugins::LxMusic::Settings->new();
	}

	$class->SUPER::initPlugin(
		feed => \&handleFeed,
		tag  => 'lxmusic',
		menu => 'apps',
	);

	$log->info('LxMusic: ready');
	return;
}

sub shutdownPlugin {
	my ($class) = @_;
	Plugins::LxMusic::Helper->shutdown;
	return;
}

# ================================================== feed menu

sub handleFeed {
	my ($client, $cb, $params, $args) = @_;

	my $src    = Plugins::LxMusic::Helper->sourceInfo;
	my $status = $src->{installed}
		? 'source: ' . ($prefs->get('sourceName') || 'current.js')
		: 'source: none (import via web page)';

	my @items = (
		{
			name        => _u('搜索歌曲'),
			type        => 'search',
			url         => \&sdkSearchHandler,
			passthrough => ['search'],
		},
		{
			name        => _u('搜索歌单'),
			type        => 'search',
			url         => \&sdkSonglistSearchHandler,
			passthrough => ['search'],
		},
		# kw 榜单 0.11.0 复活：wbd 签名失效后改走免签名 kbangserver（sdk 内已切换）
		(
			map { {
				name        => _u($_ . '榜单'),
				type        => 'link',
				url         => \&sdkBoardsHandler,
				passthrough => [ 'boards', $_ ],
			} } grep { _boardEnabled($_) } qw(kw kg tx wy mg)
		),
		# 歌单（0.11.36 起与 PC 端分类对齐）：平台 → 排序 tab（各平台自己的 sortList）→
		# 分类标签（getTags 动态）→ 歌单列表 → 曲目。
		# ⚠️ 旧的「推荐/最热/最新歌单」三个入口已由这条取代（它们是插件自己发明的档位，
		# 而 PC 端根本没有这三个顶层项；三个档位对应的 sortId 现在都在各平台的排序 tab 里）。
		{
			name        => _u('歌单'),
			type        => 'link',
			url         => \&sdkPlPlatformsHandler,
			passthrough => ['plplat'],
		},
		{
			name        => 'Play test (enter song id)',
			type        => 'search',
			url         => \&testHandler,
			passthrough => ['test'],
		},
		{
			name => $status,
			type => 'text',
		},
	);

	# 榜单源全关时给一行提示，避免"菜单像坏了"的错觉（设置页可重新打开）
	if (!grep { _boardEnabled($_) } qw(kw kg tx wy mg)) {
		splice(@items, 2, 0, { name => _u('（榜单源已在设置页全部关闭）'), type => 'text' });
	}

	$cb->({ items => \@items });
	return;
}

# 榜单源开关（设置页 0.6.0）：每次渲染读 prefs，改完立即生效
sub _boardEnabled {
	my ($src) = @_;
	my %pref = (kw => 'boardsKw', kg => 'boardsKg', tx => 'boardsTx', wy => 'boardsWy', mg => 'boardsMg');
	my $p = $pref{$src} or return 0;
	return $prefs->get($p) ? 1 : 0;
}

# kw numeric song id -> musicUrl play item
sub testHandler {
	my ($client, $cb, $args) = @_;
	my $input = $args->{search} || '';

	unless ($input =~ /^\s*(\d{4,20})\s*$/) {
		$cb->({ items => [ {
			name => 'enter a numeric kw song id (see web page howto)',
			type => 'text',
		} ] });
		return;
	}
	my $mid = $1;

	my $url = Plugins::LxMusic::ProtocolHandler->buildUrl(
		music => { songmid => $mid },
		src   => 'kw',
		type  => ($prefs->get('quality') || '320k'),
		name  => ('kw #' . $mid),
	);

	$cb->({ items => [ {
		name => 'kw #' . $mid . ' - tap to play',
		type => 'audio',
		url  => $url,
	} ] });
	return;
}

# ================================================== M0.2: 搜索/榜单（vendored musicSdk）

# 本插件刻意不用 use utf8（字节安全，见文件头注）——字符串字面量是 raw UTF-8
# 字节串。XMLBrowser/CLI 通道会对未打旗标的字节串按 latin1 再编码（设备实证：
# 菜单名双重编码乱码）。此 helper 把字节串解码成字符旗标串；JSON::XS 解出来的
# 数据本身就是旗标串，直接透传。
sub _u {
	my ($s) = @_;
	return $s if !defined $s || utf8::is_utf8($s);
	# FB_CROAK + 回退原值：非法 UTF-8 字节宁可原样传递，也不要被替换成 U+FFFD（丢内容）
	my $u = eval { Encode::decode('UTF-8', $s, Encode::FB_CROAK()) };
	return defined $u ? $u : $s;
}

# XMLBrowser passthrough 语义（slimserver XMLBrowser.pm L521）：
#   coderef->($client, $cb, \%args, @passthrough_flat)

# ---------- M0.7 聚合搜索 + 相似度重排 ----------
# 对齐 PC 端：
#   · 相似度 = 归一化编辑距离（refs/lx-music-desktop src/common/utils/common.ts:137 similar()：
#     把短串当 a、长串当 b，返回 1 - 距离/长串长度）
#   · 聚合 = 各源结果合并后去重（PC store/search/music/action.ts:48 deduplicationList 按 id，
#     跨平台不合并），再按 "与关键词的相似度" 降序（同文件:23-32 handleSortList）
sub _sim {
	my ($a, $b) = @_;
	$a = _u($a // '');
	$b = _u($b // '');
	return 0 unless length($a) && length($b);
	($a, $b) = ($b, $a) if length($a) > length($b);      # 保证 a 更短（PC 同款）
	my @a = split //, $a;
	my @b = split //, $b;
	my @prev = (0 .. scalar @b);
	for my $i (1 .. scalar @a) {
		my @cur = ($i);
		my $ai  = $a[ $i - 1 ];
		for my $j (1 .. scalar @b) {
			my $cost = ($ai eq $b[ $j - 1 ]) ? 0 : 1;
			my $ins  = $cur[ $j - 1 ] + 1;
			my $del  = $prev[$j] + 1;
			my $sub  = $prev[ $j - 1 ] + $cost;
			my $min  = $ins < $del ? $ins : $del;
			$min = $sub if $sub < $min;
			$cur[$j] = $min;
		}
		@prev = @cur;
	}
	return 1 - ($prev[ scalar @b ] / scalar @b);
}

# 多源结果 -> 去重 -> 相似度降序；顺带把来源写回 track 的 `_src`
sub _mergeRank {
	my ($groups, $q, $limit) = @_;
	my (@all, %seen);
	my $i = 0;
	for my $grp (@$groups) {
		next unless $grp && ref $grp eq 'HASH' && $grp->{list};
		my $src = $grp->{source} || '?';
		for my $t (@{ $grp->{list} }) {
			next unless ref $t eq 'HASH';
			my $key = join('|', $src, ($t->{id} // ''), ($t->{songmid} // ''), ($t->{hash} // ''), ($t->{name} // ''));
			next if $seen{$key}++;
			$t->{_src}  = $src;
			$t->{_tot}  = $grp->{total};
			push @all, {
				t     => $t,
				src   => $src,
				score => _sim($q, _u(($t->{name} // '') . ' ' . ($t->{singer} // ''))),
				ord   => $i++,
			};
		}
	}
	@all = sort { $b->{score} <=> $a->{score} || $a->{ord} <=> $b->{ord} } @all;
	splice(@all, $limit) if $limit && @all > $limit;
	return \@all;
}

my %BOARDS_CACHE;    # source => [ {id,name,bangid,...} ]

# 搜索入口：XMLBrowser type=search → $args->{search}
sub sdkSearchHandler {
	my ($client, $cb, $args) = @_;
	my $q = $args->{search} || '';
	$q =~ s/^\s+|\s+$//g;

	unless (length $q) {
		$cb->({ items => [ { name => _u('输入搜索词'), type => 'text' } ] });
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'search',
		info    => { query => $q },   # 无 source = searchMusic 跨源聚合
		timeout => 45,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data}) {
				$cb->({ items => [ { name => _u('搜索失败: ') . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}
			# 跨源聚合：合并去重 + 相似度降序（PC store/search/music/action.ts 语义），来源标在每行前缀
			my $ranked = _mergeRank($res->{data}, $q, 80);
			my @items = @$ranked
				? @{ _trackItems([ map { $_->{t} } @$ranked ], '',
					sub { '[' . ($_[0]{_src} // '?') . '] ' }) }
				: ();
			@items = @items[ 0 .. 79 ] if @items > 80;
			$cb->({ items => @items ? \@items : [ { name => _u('无结果'), type => 'text' } ] });
		},
	);
	return;
}

# 榜单目录（source 由 passthrough 传入）
sub sdkBoardsHandler {
	my ($client, $cb, $args, $mode, $src) = @_;
	$src ||= 'kg';

	# 防御：设置页关掉某源后，旧菜单项/已下钻的链接仍可能带该源进来
	if (!_boardEnabled($src)) {
		$cb->({ items => [ { name => _u('该榜单源已在设置页关闭'), type => 'text' } ] });
		return;
	}

	if (my $cached = $BOARDS_CACHE{$src}) {
		$cb->({ items => _boardItems($src, $cached) });
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'boards',
		info    => { source => $src },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data} && $res->{data}{list}) {
				$cb->({ items => [ { name => '榜单获取失败: ' . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}
			$BOARDS_CACHE{$src} = $res->{data}{list};
			$cb->({ items => _boardItems($src, $res->{data}{list}) });
		},
	);
	return;
}

sub _boardItems {
	my ($src, $boards) = @_;
	return [ map { {
		name        => _u($_->{name} || '?'),
		type        => 'link',
		url         => \&sdkBoardTracksHandler,
		passthrough => [ 'tracks', $src, ($_->{bangid} || $_->{id} || ''), ($_->{name} || '') ],
	} } @$boards ];
}

# 榜单曲目（source/bangid/榜单名 由 passthrough 传入）。
# 原生翻页（0.11.4，喜马拉雅 albumHandler 0.1.10 + 0.1.51 WINDOW FILLING 同款）：
# 达菲 Web/jive 回取 coderef feed 时带 index（窗口首曲绝对下标）和 quantity
# （= itemsPerPage，达菲 50），feed 回 { items: 该窗口, offset: index, total: 全榜数 }
# 让 UI 渲染自己的页码——0.11.3 的 feed 内嵌翻页行方案废弃（用户指正：那不是达菲
# 原生翻页体系）。窗口宽于上游页宽(50)时按页顺序补取，绝不吐空行。
sub sdkBoardTracksHandler {
	my ($client, $cb, $args, $mode, $src, $bangid, $bname) = @_;
	$src    ||= 'kg';
	$bangid ||= '';

	if (!_boardEnabled($src)) {
		$cb->({ items => [ { name => _u('该榜单源已在设置页关闭'), type => 'text' } ] });
		return;
	}

	my $window = $args->{quantity} || 50;
	$window = 1   if $window < 1;
	$window = 300 if $window > 300;     # fan-out 上限（300 首 = 至多 6 个上游页）
	my $index      = $args->{index} || 0;

	# ⚠️ 上游页宽不是固定的 50：各源 SDK 的 getList 自带 limit —— kw=100、kg=100、
	# tx=300、mg=200、wy=100000（整榜一次给）。旧代码硬编码 50 ⇒ 第 2 页起取到的
	# 曲目整体错位（页宽 100 时 start=50 取到第 101-150 首），越界页直接上游报错
	# （2026-09-21 设备实测：kw 热歌榜 start=250 渲染出「获取失败: try max num」）。
	# 真实页宽由响应里的 limit 告知；下表只是让首次请求的页号就落在正确页上——
	# 否则猜错页号会越界报错、响应里没有 limit，就永远学不到真实宽度（0.11.6 现场：
	# start ≥ 150 全部失败，正是因为第 4 个上游页不存在）。
	my %UPW_DEFAULT = ( kw => 100, kg => 100, tx => 300, mg => 200, wy => 100000 );
	my $upw        = $UPW_DEFAULT{$src} || 50;
	my $first_page = int($index / $upw) + 1;
	my $skip       = $index % $upw;
	my $max_pages  = 8;
	my $retuned    = 0;    # 是否已按响应 limit 校正过页宽
	my $probed     = 0;    # 是否已为学 limit 探过第 1 页

	# ---- WINDOW FILLING（喜马拉雅 0.1.51）：顺序取上游页，攒够 [skip, skip+window)
	# 才切——窗口比上游页宽时绝不吐空行（0.11.3 前身曾把窗口夹到 50 导致缺位空行）----
	my ($acc, $info, $total, $lastErr) = ([], undef, undef, undef);
	my $slice = sub {
		my $last = $skip + $window - 1;
		$last = $#$acc if $last > $#$acc;
		return $last >= $skip ? [ @$acc[ $skip .. $last ] ] : [];
	};
	my $page = $first_page;
	my $pages_fetched = 0;
	my $again;
	$again = sub {
		Plugins::LxMusic::Helper->request(
			action  => 'boardlist',
			info    => { source => $src, bangid => $bangid, page => $page },
			timeout => 45,
			cb      => sub {
				my ($res) = @_;
				$pages_fetched++;

				# 页宽校正（见 handler 顶部注释）：首响应给出 limit 就据此重算重取；
				# 若首个请求本身就失败（页号猜错越界），先探第 1 页把 limit 学回来
				if (!$retuned) {
					my $limit = ($res->{ok} && $res->{data}) ? $res->{data}{limit} : undef;
					if (defined $limit && $limit > 0) {
						$retuned = 1;
						if ($limit != $upw) {
							$upw        = $limit;
							$first_page = int($index / $upw) + 1;
							$skip       = $index % $upw;
							$max_pages  = int(($skip + $window) / $upw) + 2;
							$max_pages  = 8 if $max_pages > 8;
							$page          = $first_page;
							$pages_fetched = 0;
							@$acc    = ();
							$info    = undef;
							$total   = undef;
							$lastErr = undef;
							$again->();
							return;
						}
					}
					elsif (!$probed) {
						my $has = ($res->{data} && $res->{data}{list}
							&& @{ $res->{data}{list} }) ? 1 : 0;
						if (!$has) {
							$probed        = 1;
							$page          = 1;
							$pages_fetched = 0;
							$again->();
							return;
						}
					}
				}

				my $up = ($res->{ok} && $res->{data} && $res->{data}{list})
					? $res->{data}{list} : [];
				if (@$up) {
					push @$acc, @$up;
					$info = $res->{data}{info} if $pages_fetched == 1;
					$total = $res->{data}{total}
						if !defined $total && defined $res->{data}{total};
				}
				else {
					$lastErr = $res->{error} || 'unknown';
				}
				my $enough = @$acc >= $skip + $window;
				if (!$enough && @$up && $pages_fetched < $max_pages) {
					$page++;
					$again->();
					return;
				}
				my $list = $slice->();
				unless (@$list) {
					$cb->({ items => [ { name => _u('获取失败: ') . ($lastErr || '无数据'), type => 'text' } ] });
					return;
				}
				board_render($cb, $src, $bangid, $bname, $info, $acc, $list, $total, $index);
			},
		);
	};
	$again->();
	return;
}

# 渲染榜单窗口（0.11.4 从 handler 拆出）：页头 + items + 原生翻页契约
sub board_render {
	my ($cb, $src, $bangid, $bname, $info, $acc, $list, $total, $index) = @_;

	# ---- 榜单页头（喜马拉雅 0.1.40-0.1.54 同款，达菲实测过的组合）----
	#   feed 级 image    -> Slim::Web::XMLBrowser stash -> Web 页顶部大封面
	#   feed 级 play     -> stash playUrl -> 页头 play/add 按钮（songinfo 页头，
	#                       它一出现模板就不再渲染自动的 "All Songs" 行）
	#   feed 级 actions  -> 页头 playall/addall/insert 命令（经 lxm://b/ 整榜展开）
	#   albumData        -> 页头 details 行（榜单名 / 来源·总数）
	# 封面优先级：榜单自带封面（kw kbangserver v9_pic2）→ 第一首的封面兜底。
	my $cover;
	if ($info && $info->{img} && $info->{img} =~ m{^https?://}) {
		$cover = $prefs->get('coverProxy') ? _coverProxyUrl($info->{img}) : $info->{img};
	}
	elsif (@$acc && $acc->[0]) {
		$cover = _coverOf($acc->[0]);
	}
	my $title = ($bname && length $bname) ? $bname : (($info && $info->{name}) || (_u($src) . _u('榜单')));

	# _trackItems 返回数组引用（勿再套 @ 展开成单元素列表——0.11.1 首版
	# 曾写成 my @items = _trackItems(...)，items 变成 [[...]]，CLI 路径炸
	# "Not a HASH reference"（XMLBrowser.pm L1012），榜单 feed 全空）
	my $tracks = _trackItems($list, _u("[$src] "), undef, $index);

	# 原生翻页契约：offset=窗口首曲绝对下标，total=全榜数（Slim/Control/XMLBrowser
	# L787 count=total、L1002 start-=offset、L1009 按其切窗）。UI 自己渲染页码，
	# feed 不掺导航行（0.11.3 方案废弃）。
	$cb->({
		items    => $tracks,
		offset   => $index,
		(defined $total ? (total => $total) : ()),
		($cover        ? (image => $cover) : ()),
		($bangid ne '' ? (play => "lxm://b/$src/$bangid") : ()),
		($bangid ne '' ? (actions => _board_play_actions($src, $bangid)) : ()),
		(albumData => [
			{ name => $title, type => 'text', label => 'ALBUM' },
			((defined $total && $total)
				? { name => _u('[' . $src . '] · ' . int($total) . ' 首'), type => 'text', label => 'ARTIST' }
				: { name => _u('[' . $src . ']'), type => 'text', label => 'ARTIST' }),
		]),
	});
	# 诊断（warn 级，需 plugin.lxmusic=DEBUG/WARN 才落盘）：页头按钮依赖 feed 级 play/actions
	$log->warn(sprintf('LxMusic board_render: src=%s bangid=%s play=%s total=%s rows=%d',
		$src, (length $bangid ? $bangid : '<empty>'),
		(length $bangid ? "lxm://b/$src/$bangid" : '<none>'),
		(defined $total ? $total : '?'), scalar(@$tracks)));
}

# 页头播放按钮命令（喜马拉雅 _album_play_actions 同形，只留 *all 键——
# 普通 play/add 留在 feed 级会把整榜命令盖到每一行的行内按钮上）。
# 命中 lxm://b/<src>/<bangid>，由 ProtocolHandler::explodePlaylist 展开整榜。
sub _all_actions {
	my ($u) = @_;
	return {
		playall => { command => [ 'playlist', 'play',   $u ], fixedParams => {} },
		addall  => { command => [ 'playlist', 'add',    $u ], fixedParams => {} },
		insert  => { command => [ 'playlist', 'insert', $u ], fixedParams => {} },
	};
}

sub _board_play_actions {
	my ($src, $bangid) = @_;
	return _all_actions("lxm://b/$src/$bangid");
}

# track(search/boardlist 产出) -> lxm:// audio 项（$prefixOf 可按曲给不同前缀，如聚合搜索的来源标签）
# $offset：列表在整榜中的绝对起始下标（原生翻页时传窗口 index），让编号跨页连续
# （0.11.5 前按页内 1 起编，翻到第 2 页仍显示 001-050，肉眼像"没翻页"）
# types[].size（"34.63 MiB"）-> 字节数
sub _bytesOf {
	my ($s) = @_;
	return undef unless defined $s && $s ne '';
	return int($1 * 1024)        if $s =~ /^\s*([\d.]+)\s*KiB/i;
	return int($1 * 1048576)     if $s =~ /^\s*([\d.]+)\s*MiB/i;
	return int($1 * 1073741824)  if $s =~ /^\s*([\d.]+)\s*GiB/i;
	return int($1)               if $s =~ /^\s*(\d+)\s*B\s*$/i;
	return undef;
}

sub _trackItems {
	my ($list, $prefix, $prefixOf, $offset) = @_;
	$prefix ||= '';
	$offset ||= 0;
	my $q     = $prefs->get('quality') || '320k';
	my @items;
	my @pub;          # 0.11.30：稍后给"真的进了队列"的那些行补发
	my $n = 0;
	for my $t (@$list) {
		next unless $t && ref($t) eq 'HASH';
		$n++;
		my $pfx    = $prefixOf ? ($prefixOf->($t) // '') : $prefix;
		my $name   = _u($t->{name}   || '?');
		my $singer = _u($t->{singer} || '');
		my $url = Plugins::LxMusic::ProtocolHandler->buildUrl(
			music => $t,
			src   => ($t->{source} || 'kw'),
			type  => $q,
			name  => ($singer ne '' ? "$singer - $name" : $name),
		);
		next unless $url;
		my ($secs, $cover) = (_secsOf($t), _coverOf($t));

		# 0.11.56：**列表期也别乱报档位**。此前一律拿"请求档位"（pref，常见 flac24bit）当显示值，
		# 于是上游只给到 flac/320k 的曲目也写着 "FLAC 24bit" —— 与 LMS 从真实流里读出的
		# "44.1kHz 16bit" 直接矛盾（用户报的现象）。
		# 这里按上游 `types[]` 求交：请求档位在 → 用它；不在 → 用该曲**实际最好的**档位；
		# 都读不到才退回请求档位（播放后 _finish_resolve 还会用真实探测值覆盖一次）。
		my $rowq = $q;
		if (ref($t->{types}) eq 'ARRAY' && @{ $t->{types} }) {
			my %has = map { (ref($_) eq 'HASH' && defined $_->{type}) ? ($_->{type} => 1) : () } @{ $t->{types} };
			if (!$has{$q}) {
				for my $cand (qw(flac24bit flac 320k 128k hires)) {
					if ($has{$cand}) { $rowq = $cand; last; }
				}
			}
		}

		# 队列行的码率估算（0.11.11）：SDK 的 types[].size 给了各档位文件体积，
		# 体积 ÷ 时长 = 估算码率。播放后再由真实探测值覆盖（_finish_resolve）。
		# kw 的 types 没有 size ⇒ 估不出来（播放后仍有真值），不硬造。
		my $est_kbps;
		if ($secs && ref($t->{types}) eq 'ARRAY') {
			my ($exact, $biggest);
			for my $ty (@{ $t->{types} }) {
				next unless ref $ty eq 'HASH';
				my $b = _bytesOf($ty->{size});
				next unless $b;
				$exact   = $b if defined $ty->{type} && $ty->{type} eq $rowq;
				$biggest = $b if !defined $biggest || $b > $biggest;
			}
			my $bytes = $exact || $biggest;
			$est_kbps = int($bytes * 8 / 1000 / $secs) if $bytes;
		}

		# 渲染期发布队列元数据（喜马拉雅 0.1.47 同款）：队列行才有歌名/时长/码率
		Plugins::LxMusic::ProtocolHandler->publishQueueMetadata($url, {
			title   => ($singer ne '' ? "$singer - $name" : $name),
			secs    => $secs,
			kbps    => $est_kbps,
			cover   => $cover,
			quality => $rowq,
		});
		# 0.11.30：记下来，稍后**对真的进了队列的行**再发一遍（见文件末尾 Timer 的注释）
		push @pub, {
			url     => $url,
			title   => ($singer ne '' ? "$singer - $name" : $name),
			secs    => $secs,
			kbps    => $est_kbps,
			cover   => $cover,
			quality => $rowq,
		};
		push @items, {
			name => sprintf('%03d %s%s%s', $n + $offset, $pfx, $name, ($singer ne '' ? " - $singer" : '')),
			type => 'audio',
			url  => $url,
			(length $cover ? (image => $cover) : ()),
			(defined $secs ? (duration => $secs) : ()),
			__rowq => $rowq,      # 仅供上面那行 debug 统计（LMS 不认这个键，无害）
		};
		last if $n >= 1000;   # 安全上限（真分页见 handler 的 index/quantity 处理）
	}
	$log->debug('LxMusic: rows=' . scalar(@items) . ' without-cover='
		. scalar(grep { !$_->{image} } @items)
		. ' without-duration=' . scalar(grep { !defined $_->{duration} } @items)
		# 0.11.56：把"这一页各行实际会显示的档位"打出来（诊断"档位显示矛盾"用）。
		# 期望：请求档位若该曲不支持，应落到该曲最好的档位（如 mg 常见 flac / 320k），
		# 而不是清一色 flac24bit。
		. ' rowq=' . do {
			my %c;
			$c{ $_->{__rowq} }++ for grep { $_->{__rowq} } @items;
			join(',', map { "$_×$c{$_}" } sort keys %c) || '-';
		});

	# 0.11.30：**建队之后再补发一次封面/元数据**。
	# 现场（用户 2026-09-21）：页首"全部播放/添加"一次入队整榜时，**除正在播/预读的一两首外，队列行全没封面**；
	# 实测（kw 榜单 100 首）"整榜入队 0/100 有图，事后重渲染榜单页 50/100 有图" ⇒
	# **建队之前发布的封面不会被新建的队列行采用**。而这个 300 首的队列走的是"浏览 feed + 批量加入"
	# （explode 有 100 上限，所以队列 >100 必然是这条路），所以补发也必须挂在 feed 这里。
	# 4 秒后只对**真的进了某个播放器队列**的 URL 重发（遍历 `Slim::Player::Client::clients()`），
	# 于是单纯浏览页面时不会白干。
	if (@pub) {
		my @snapshot = @pub;
		Slim::Utils::Timers::setTimer(__PACKAGE__, time() + 4, sub {
			Plugins::LxMusic::ProtocolHandler->republish_queued_rows(\@snapshot);
		});
	}

	# 渲染期预热**只热 1 首**（0.11.58）：预热是后台行为，Helper 侧标 bg、设备一忙就丢弃。
	# 从前热 3 首 × 多源 × 全档位，纯浏览就能把串行 worker 堆到 22 个在跑请求（实测）。
	Plugins::LxMusic::ProtocolHandler->warmTracks([ map { $_->{url} } @items ], 1) if @items;
	return \@items;
}

# 'mm:ss' / 'hh:mm:ss' -> 秒
sub _secsOf {
	my ($t) = @_;
	my $iv = $t->{interval} || $t->{duration};
	return undef unless defined $iv && $iv ne '';
	return int($iv) if $iv =~ /^\d+$/;
	my @p = split(/:/, $iv);
	return undef unless @p;
	my $s = 0;
	$s = $s * 60 + ($_ || 0) for @p;
	return $s > 0 ? $s : undef;
}

# 曲目封面：各源 musicInfo 字段不一（wy/tx/mg 有 img；kg/kw 常为 null）
# - kg：albumId 可直出 stdmusic 封面（实测 https://imge.kugou.com/stdmusic/240/966846.jpg -> 200/17.8KB）
# - tx：img 缺失时用 albumMid 推导 T002 封面
# - kw：PC 端 getPic = pic.web?rid=<songmid>，其响应体才是图片 URL（纯文本）——
#       列表行改指插件自己的封面代理（懒加载 + LMS 图像缓存 30 天，不阻塞列表）
sub _coverOf {
	my ($t) = @_;
	my $src = $t->{source} || '';

	# 设置页「封面代理」开关（0.6.0）：关掉后 kg/kw 列表行不再经插件中转 ——
	# 代价是这两源无图（kg 的 CDN 设备侧直连不出图；kw 的图 URL 必须由代理解析
	# pic.web 才能拿到），换来少一次中转。mg 本来就是直取，不受开关影响。
	my $proxy = $prefs->get('coverProxy') ? 1 : 0;

	if ($src eq 'kg' && ($t->{hash} || '') =~ /^[0-9A-Fa-f]{16,}$/) {
		# ⚠️ kg 专辑图**不能**用 albumId 拼 URL：实测不同 albumId 的
		# https://imge.kugou.com/stdmusic/240/<id>.jpg 返回**同一张占位图**
		# （0.11.13 现场：5 个不同 id → 同一 md5 2882B；PC 端也是这样拿到占位图，
		# 它靠 getPic 现取）。官方 kg/pic.js 是 POST media.store.kugou.com/v1/
		# get_res_privilege 换取真图 URL ⇒ 交给封面代理按 'kg:<aaid>:<albumId>:<hash>' 解析。
		my $aaid = (($t->{albumAudioId} || $t->{songmid} || '') =~ /^\d+$/)
			? ($t->{albumAudioId} || $t->{songmid}) : '';
		return $proxy
			? _coverProxyUrl('kg:' . $aaid . ':' . ($t->{albumId} || 0) . ':' . $t->{hash})
			: '';
	}
	if ($src eq 'kg' && ($t->{albumId} || '') =~ /^\d+$/) {
		my $direct = 'https://imge.kugou.com/stdmusic/240/' . $t->{albumId} . '.jpg';
		return $proxy ? _coverProxyUrl($direct) : $direct;
	}
	if ($src eq 'mg') {
		# mg 直连本来就可用（用户实测：走代理前有图）——保持直取，不中转。
		# ⚠️ 0.11.52：mg 的 `img` **两种形态都有**，必须都认：
		#   · 榜单/搜索（musicSearch.js 已归一）→ `https://d.musicapp.migu.cn/…`
		#   · **歌单详情**（songlistdetail）→ **相对路径** `/data/oss/resource/…webp`
		#     （本地实测 mg 歌单 id=233274165 的 50 首全是相对路径）
		# 旧代码只认 `^https?://` ⇒ **mg 歌单的曲目全部无封面**（用户报的第 2 个问题）。
		# 相对路径补上 mg 官方图片域即可；`.webp`→`.jpg` 的改写保平安（实测同一路径
		# .webp=104KB image/webp、.jpg=214KB image/jpeg，两者都 200，LMS 图片代理更爱 jpeg）。
		my $img = $t->{img} || '';
		$img = 'https://d.musicapp.migu.cn' . $img if $img =~ m{^/};
		if ($img =~ m{^https?://}) {
			$img =~ s/\.webp$/.jpg/i;
			return _u(_coverThumb($img));
		}
	}
	if ($src eq 'kw' && ($t->{songmid} || '') =~ /^\d+$/) {
		# 代理内解析 pic.web 再取图；关掉代理则无图可给（pic.web 返回的是文本 URL）
		# 0.11.61：把缩略尺寸一起交给代理（`pictype/size` 决定 kwcdn 路径里的尺寸段）
		my $s = _coverThumbSize();
		return $proxy ? _coverProxyUrl('kw:' . $t->{songmid} . ($s ? ":$s" : '')) : '';
	}

	for my $k (qw(img pic albumPic picUrl cover)) {
		my $v = $t->{$k};
		if (defined $v && $v ne '' && $v =~ m{^https?://}) {
			$v =~ s/\.webp$/.jpg/i;
			return _u(_coverThumb($v));
		}
	}
	if ($src eq 'tx' && ($t->{albumMid} || '') =~ /^[A-Za-z0-9]+$/) {
		my $s = _coverThumbSize() || 500;
		return 'https://y.gtimg.cn/music/photo_new/T002R' . $s . 'x' . $s
			. 'M000' . $t->{albumMid} . '.jpg';
	}
	return '';
}

# 封面代理 URL（懒加载 + LMS 图像缓存；设备侧不可直连的 CDN 由此中转并补 Referer/UA）
sub _coverProxyUrl {
	my ($target) = @_;
	my $srv  = eval { Slim::Utils::Network::serverAddr() } || '127.0.0.1';
	my $port = $prefs->get('httpPort') || 9000;
	return "http://$srv:$port/plugins/LxMusic/cover?u=" . encode_base64url($target);
}

# ---------- 0.11.61 封面提速：缩略尺寸（实现搬到了 Helper，Plugin/ProtocolHandler 共用） ----------
sub _coverThumbSize { return Plugins::LxMusic::Helper->coverThumbSize(@_) }
sub _coverThumb     { return Plugins::LxMusic::Helper->coverThumb(@_) }

# ---------- M0.3 歌单：搜索 -> 详情 -> 播放/整单 ----------

my $TRACK_JSON = JSON::XS->new->utf8->canonical;   # track/playlist hash -> compact JSON

sub sdkSonglistSearchHandler {
	my ($client, $cb, $args) = @_;
	my $q = $args->{search} || '';
	$q =~ s/^\s+|\s+$//g;

	unless (length $q) {
		$cb->({ items => [ { name => _u('输入歌单关键词'), type => 'text' } ] });
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'songlist',
		info    => { query => $q },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data}) {
				$cb->({ items => [ { name => _u('歌单搜索失败: ') . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}
			# 歌单搜索是跨源聚合（数组）→ 逐组渲染，总计上限 40
			my @items;
			for my $grp (@{ $res->{data} }) {
				next unless $grp && $grp->{list} && @{ $grp->{list} };
				my $src = $grp->{source} || '?';
				push @items, @{ _plItems($src, $grp->{list}, 40 - scalar(@items)) };
				last if @items >= 40;
			}
			$cb->({ items => @items ? \@items : [ { name => _u('无歌单结果'), type => 'text' } ] });
		},
	);
	return;
}

# 歌单条目渲染（歌单搜索 / 推荐·最热·最新 共用）：名称 +（来源 · N首 · 作者）+ 封面
sub _plItems {
	my ($src, $list, $max) = @_;
	$max ||= 40;
	my @items;
	for my $pl (@$list) {
		next unless ref($pl) eq 'HASH' && $pl->{id};
		my $name = _u($pl->{name} || '?');
		# 分隔符也必须走 _u()：join 混用旗标/未旗标串会把 '·' 的字节按 latin1 再编码（Â·）
		my $meta = join(_u(' · '), grep { $_ ne '' } (
			_u($src),
			($pl->{total} ? _u($pl->{total}) . _u('首') : ''),
			($pl->{author} ? _u($pl->{author}) : ''),
		));
		my $img = $pl->{img};
		# 歌单封面也走插件代理（kw/kg 的图 CDN 需要 UA/Referer，设备直连不出图）
		# 0.11.61：同样降到缩略尺寸（一页 30 个歌单 × 上游原图是另一处大流量）
		$img = _coverThumb($img) if $img;
		$img = _coverProxyUrl($img) if $img && $img =~ m{^https?://} && $prefs->get('coverProxy');
		# 0.11.33：整单播放靠 LMS 的 **`playlist`** 属性（playall/addall/insert/remove 专用，
		# Slim/Web/XMLBrowser.pm:336-344 → type=playlist → Slim/Formats/XML.pm:93 → 我们的 explodePlaylist）。
		# 只给 feed 级 `play` 不行：Web 侧 `play` 只认 action=play/add/insert（:325-333），
		# 而 action=playall 会退化成"把详情 feed 当前这一页（quantity=itemsPerPage=50）当播放列表入队"
		# ⇒ 用户报的「歌单播放队列只有 50 首」。id 只允许 [A-Za-z0-9_-]（explodePlaylist 的 URL 正则）。
		my $plurl = ($pl->{id} =~ /^[A-Za-z0-9_-]+$/) ? "lxm://l/$src/$pl->{id}" : undef;
		push @items, {
			name        => _u('🎼 ') . $name . ($meta ne '' ? "  ($meta)" : ''),
			type        => 'link',
			url         => \&sdkSonglistDetailHandler,
			passthrough => [ 'songlistdetail', $src, $pl->{id} ],
			($plurl ? (playlist => $plurl) : ()),
			(($img && $img =~ m{^https?://}) ? (image => _u($img)) : ()),
		};
		last if @items >= $max;
	}
	return \@items;
}

# ---------- 歌单：平台 → 排序 tab → 分类标签 → 列表（0.11.36，与 PC 端对齐） ----------
#
# PC 落雪的歌单页 = 「平台选择器 × 排序 tab × 分类标签下拉」三个并列控件：
#   · **排序 tab**  = 各平台内置 SDK 的 `songList.sortList`（客户端硬编码，
#                     `refs/lx-music-desktop/src/renderer/utils/musicSdk/<平台>/songList.js`）
#   · **分类标签**  = `songList.getTags()` 运行时从平台 API 拉（热门标签 + 分组标签：语种/风格/场景…）
#   · **请求**      = `getList(sortId, tagId, page)`
# tagId 的形状各平台不同（shim 里原样透传，别做归一化）：
#   kw = `"<id>-<digest>"`（sdk 内部 `split('-')`）、kg/tx/mg = 数字串、**wy = 中文分类名本身**。
# 我们的菜单没有"选择器"，只能把这三个维度摊成三层下钻（PC 的 tab 文案/顺序取自 sortList 原文）。
my @PL_PLATFORMS = qw(kw kg tx wy mg);

my %PL_META;                # src => { sorts_at, sorts => [...], tags_at, tags => {tags,hotTag} }
my $PL_SORTS_TTL = 86400;   # sortList 是静态数组（客户端硬编码），缓存一天足够
my $PL_TAGS_TTL  = 21600;   # 分类标签来自平台 API（会变、且慢），缓存 6 小时

sub _pl_meta {
	my ($src) = @_;
	$PL_META{$src} ||= {};
	return $PL_META{$src};
}

# ---------- feed 结果缓存（0.11.40）----------
# 为什么必须有：Daphile 皮肤的下钻链接**不带 session sid**（`index=7.0.1.1.0&sess=`），
# 所以 LMS 的 feed 会话缓存从不生效 ⇒ **每次点一个歌单，LMS 都会把父层列表重新问一遍**
# （"点歌单进曲目列表"实测 2.0~4.4s，其中约 0.9s 是父层那次重取），而我们这边每次都是
# fork 一个 qjs + 打一次平台 API。插件侧缓存这两层就能把重复开销压掉。
my %FEED_CACHE;
my $FEED_CACHE_MAX  = 300;
my $PL_LIST_TTL     = 120;   # 分类 → 歌单列表（会变，短 TTL）
my $PL_DETAIL_TTL   = 600;   # 歌单 → 曲目页（整单内容基本不变）

# ⚠️ 缓存里存的 feed 必须**拷贝后再交出去**：LMS 会往返回的 feed/item 上写 `fetched`/`items`
# 等内部状态（Slim/Control/XMLBrowser.pm `_cliQuerySubFeed_done`、Web 版 `handleSubFeed`），
# 直接复用同一个 hashref 会把 LMS 的内部状态带进缓存，下一次命中就"看起来已经取过了"。
sub _feed_copy {
	my ($f) = @_;
	return $f unless ref $f eq 'HASH';
	my %c = %$f;
	if (ref $f->{items} eq 'ARRAY') {
		$c{items} = [ map { ref $_ eq 'HASH' ? { %$_ } : $_ } @{ $f->{items} } ];
	}
	return \%c;
}

# ⚠️ **缓存键不含 window**（0.11.41）：同一次点击里，LMS 会用 `quantity=1` 把父层重新问一遍
# （拿单个条目做面包屑解析），而展示那一次是 `quantity=50`。键里带 window 就永远错开 ⇒
# 实测点一次歌单要多付约 1s 的重复列表请求（日志 `pl-list MISS … win=1`）。
# 现在按"最大窗口已缓存"存，小窗口命中时就地切片。
sub _feed_cache_get {
	my ($k, $ttl, $window) = @_;
	my $e = $FEED_CACHE{$k} or return undef;
	return undef if (time() - ($e->{at} || 0)) >= $ttl;
	return undef if defined $window && defined $e->{win} && $e->{win} < $window;
	my $f = _feed_copy($e->{feed});
	if (defined $window && ref $f->{items} eq 'ARRAY' && @{ $f->{items} } > $window) {
		$f->{items} = [ @{ $f->{items} }[ 0 .. $window - 1 ] ];
	}
	return $f;
}

sub _feed_cache_put {
	my ($k, $feed, $win) = @_;
	if (scalar(keys %FEED_CACHE) >= $FEED_CACHE_MAX) {
		my ($old) = sort { ($FEED_CACHE{$a}{at} || 0) <=> ($FEED_CACHE{$b}{at} || 0) } keys %FEED_CACHE;
		delete $FEED_CACHE{$old} if defined $old;
	}
	$FEED_CACHE{$k} = { at => time(), feed => _feed_copy($feed), win => $win };
	return;
}

# shim 子进程的 LOG 行平时只放在 $res->{logs}（页面 logs 区可见，server.log 看不到）。
# 排查性能时（plugin.lxmusic = INFO/DEBUG）把带耗时的 binHttp 行透到 server.log，
# 这样"慢在上游"和"慢在本机解析"能一眼分开（shim 的 binHttp 现在带 Nms）。
sub _log_shim_http {
	my ($what, $res) = @_;
	return unless $log->is_info;
	for my $l (@{ $res->{logs} || [] }) {
		next unless $l =~ /binHttp \d+ \d+B \d+ms/;
		$log->warn("LxMusic $what shim " . substr($l, 0, 190));
	}
	return;
}

# 覆盖式命中（0.11.42）：LMS 解析父层面包屑时用的是**被点的那一行的绝对下标**
# （`index=N, quantity=1`），而展示那一层缓存的是 `index=0, quantity=50` ⇒ 只有第 1 行能命中。
# 这里允许"已缓存的窗口覆盖住目标下标"就切片返回：列表看过一次之后，点任意一行都不再打上游。
sub _feed_cache_cover {
	my ($kind, $a, $b, $index, $window, $ttl) = @_;
	my $prefix = join('|', $kind, $a, $b, '');
	for my $k (keys %FEED_CACHE) {
		next unless index($k, $prefix) == 0;
		my ($start) = $k =~ m{\|(\d+)$};
		next unless defined $start;
		my $e = $FEED_CACHE{$k} or next;
		next if (time() - ($e->{at} || 0)) >= $ttl;
		my $win = $e->{win} || 0;
		next unless $start <= $index && ($index + $window) <= ($start + $win);
		next unless ref $e->{feed}{items} eq 'ARRAY';
		my $off   = $index - $start;
		my $avail = scalar(@{ $e->{feed}{items} }) - $off;
		next if $avail <= 0;
		my $take = $window < $avail ? $window : $avail;
		my $f = _feed_copy($e->{feed});
		$f->{items}  = [ @{ $f->{items} }[ $off .. $off + $take - 1 ] ];
		$f->{offset} = $index;
		return $f;
	}
	return undef;
}

# 平台层
sub sdkPlPlatformsHandler {
	my ($client, $cb, $args, $mode) = @_;
	my @items = map { {
		name        => _u('歌单 · ') . _u($_),
		type        => 'link',
		url         => \&sdkPlSortsHandler,
		passthrough => [ 'plsort', $_ ],
	} } @PL_PLATFORMS;
	$cb->({ items => \@items });
	return;
}

# 排序 tab 层：条目完全来自该平台 sortList（不再有插件自造的"推荐/最热/最新"档位映射）
sub sdkPlSortsHandler {
	my ($client, $cb, $args, $mode, $src) = @_;
	$src ||= 'kw';
	my $t0 = time();
	my $c = _pl_meta($src);

	my $render = sub {
		my @items = map { {
			name        => _u($_->{name}),
			type        => 'link',
			url         => \&sdkPlTagsHandler,
			passthrough => [ 'pltag', $src, $_->{id} ],
		} } @{ $c->{sorts} || [] };
		$log->warn(sprintf('LxMusic pl-sorts src=%s rows=%d ms=%d', $src, scalar(@items), int((time() - $t0) * 1000)));
		$cb->({ items => @items ? \@items : [ { name => _u('该平台没有可用的排序'), type => 'text' } ] });
	};

	if ($c->{sorts} && @{ $c->{sorts} } && (time() - ($c->{sorts_at} || 0)) < $PL_SORTS_TTL) {
		$log->warn(sprintf('LxMusic pl-sorts src=%s CACHE-HIT age=%ds ms=%d',
			$src, int(time() - $c->{sorts_at}), int((time() - $t0) * 1000)));
		$render->();
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'songlistsorts',
		info    => { source => $src },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			if ($res->{ok} && $res->{data} && ref $res->{data}{sorts} eq 'ARRAY' && @{ $res->{data}{sorts} }) {
				$c->{sorts}    = $res->{data}{sorts};
				$c->{sorts_at} = time();
				$render->();
			}
			else {
				$cb->({ items => [ { name => _u('排序获取失败: ') . _u($res->{error} || 'unknown'), type => 'text' } ] });
			}
		},
	);
	return;
}

# 分类标签层：第一行「全部（不分分类）」，其后是热门标签 + 各分组（行名带 `[分组]` 前缀，
# 摊平一层——菜单没法像 PC 那样在同一个下拉里画分组标题）。
sub sdkPlTagsHandler {
	my ($client, $cb, $args, $mode, $src, $sort) = @_;
	$src  ||= 'kw';
	$sort = '' unless defined $sort;
	my $t0 = time();
	my $c = _pl_meta($src);

	my $mk = sub {
		my ($label, $tag) = @_;
		return {
			name        => _u($label),
			type        => 'link',
			url         => \&sdkPlListHandler,
			passthrough => [ 'pllist', $src, $sort, $tag ],
		};
	};

	# ⚠️ 行名一律用 `_u()` 逐段拼（§5.3.19）：本文件里的中文**字面量是未打旗标的 UTF-8 字节**，
	# 一旦和 JSON 解出来的旗标串（分组名/标签名，都是字符串）直接 join，字面量会被按 latin-1
	# 解释 ⇒ 设备上渲染成 `[ç«é¨]`（0.11.37 现场，仅 `热门` 这一处中招，因为其它前缀恰好是 ASCII）。
	my $mkname = sub {
		my ($prefix, $name) = @_;
		return _u('[') . _u($prefix) . _u('] ') . _u($name);
	};

	my $render = sub {
		my @items = ($mk->('全部（不分分类）', ''));
		push @items, map {
			$mk->($mkname->('热门', $_->{name}), $_->{id})
		} @{ $c->{tags}{hotTag} || [] };
		for my $grp (@{ $c->{tags}{tags} || [] }) {
			my $gname = defined $grp->{name} ? $grp->{name} : '';
			push @items, map {
				$mk->($mkname->($gname, $_->{name}), $_->{id})
			} @{ $grp->{list} || [] };
		}
		$cb->({ items => \@items });
		$log->warn(sprintf('LxMusic pl-tags src=%s sort=%s rows=%d ms=%d',
			$src, $sort, scalar(@items), int((time() - $t0) * 1000)));
	};

	if ($c->{tags} && (time() - ($c->{tags_at} || 0)) < $PL_TAGS_TTL) {
		$log->warn(sprintf('LxMusic pl-tags src=%s CACHE-HIT age=%ds ms=%d',
			$src, int(time() - $c->{tags_at}), int((time() - $t0) * 1000)));
		$render->();
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'songlisttags',
		info    => { source => $src },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			if ($res->{ok} && $res->{data} && ref $res->{data}{tags} eq 'ARRAY') {
				$c->{tags}    = { tags => $res->{data}{tags}, hotTag => ($res->{data}{hotTag} || []) };
				$c->{tags_at} = time();
				$render->();
			}
			else {
				# 标签拿不到也不能把这条路堵死：至少给一行"全部"
				$c->{tags} = { tags => [], hotTag => [] };
				$render->();
			}
		},
	);
	return;
}

# 某平台 + 某排序 + 某分类下的歌单列表（支持 XMLBrowser 的 index/quantity 分页）
# 0.11.36：sortId 来自该平台自己的 sortList，tagId 来自 getTags()（''=全部），不再查 %PL_SORTS
sub sdkPlListHandler {
	my ($client, $cb, $args, $mode, $src, $sort, $tag) = @_;
	$src  ||= 'kw';
	$src  = 'kw' unless grep { $_ eq $src } @PL_PLATFORMS;
	$sort = '' unless defined $sort;
	$tag  = '' unless defined $tag;
	$tag  = '' if ref $tag;   # 防御：passthrough 被 LMS 解析成数组时（同 0.7.38 的坑）

	my $index  = $args->{index} || 0;
	my $window = $args->{quantity} || 50;
	$window = 50 if $window < 1 || $window > 300;

	my $ckey = join('|', 'pl', $src, $sort, $tag, $index);
	my $t0   = time();
	if (my $hit = _feed_cache_get($ckey, $PL_LIST_TTL, $window)) {
		$log->warn(sprintf('LxMusic pl-list CACHE-HIT src=%s sort=%s tag=%s idx=%d win=%d ms=%d',
			$src, $sort, $tag, $index, $window, int((time() - $t0) * 1000)));
		$cb->($hit);
		return;
	}
	if (my $hit = _feed_cache_cover('pl', $src, join('|', $sort, $tag), $index, $window, $PL_LIST_TTL)) {
		$log->warn(sprintf('LxMusic pl-list CACHE-COVER src=%s sort=%s tag=%s idx=%d win=%d ms=%d',
			$src, $sort, $tag, $index, $window, int((time() - $t0) * 1000)));
		$cb->($hit);
		return;
	}

	# 上游页宽各源不同（vendored limit_list：kw 36 / kg 20 / tx 36 / wy 30；mg 未定），
	# 先按 30 猜，拿到首响应的 limit 再重算重取一次（同榜单 0.11.5 与歌单详情 0.11.13 的教训）。
	# 0.11.33 之前这里硬编码 30 ⇒ 第 2 页起窗口错位。
	my $upw  = 30;
	my $page = int($index / $upw) + 1;
	my $skip = $index % $upw;
	my $retuned = 0;
	my $want = $index;

	my $fetch;
	$fetch = sub {
	Plugins::LxMusic::Helper->request(
		action  => 'songlistbytag',
		info    => { source => $src, sortId => $sort, tagId => $tag, page => $page },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data} && $res->{data}{list}) {
				$cb->({ items => [ { name => _u('歌单获取失败: ') . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}

			# 首响应校正页宽
			if (!$retuned) {
				my $lim = $res->{data}{limit};
				if (defined $lim && $lim > 0) {
					$retuned = 1;
					if ($lim != $upw) {
						$upw  = $lim;
						$page = int($want / $upw) + 1;
						$skip = $want % $upw;
						$fetch->();
						return;
					}
				}
			}

			my $raw  = $res->{data}{list};
			my @list = @$raw;
			@list = @list[ $skip .. $#list ] if $skip && @list > $skip;
			@list = @list[ 0 .. $window - 1 ] if @list > $window;
			my $items = _plItems($src, \@list, 60);

			# total 让列表页长出页码条。真实值：kw 9080/1754、kg 2000、tx 11619/30758、wy 真值；
			# mg 的上游是**硬编码哨兵 99999**（vendored mg/songList.js:210 `total: 99999`）⇒ 视为未知，
			# 用"本页上游已满 ⇒ 至少还有一页"合成一个保守值，否则 mg 永远翻不了页（用户报的现象之一）。
			my $total = $res->{data}{total};
			$total = undef if !defined $total || $total !~ /^\d+$/ || $total >= 99999;
			if (!defined $total) {
				my $end = ($page - 1) * $upw + scalar(@$raw);   # 本页最后一个绝对下标 + 1
				if ($upw && scalar(@$raw) >= $upw) {
					# 上游本页是满的 ⇒ 后面大概率还有：合成一个**至少能长出"下一页"**的 total
					# （0.11.39：从前只 +1，`end+1` 往往 ≤ itemsPerPage ⇒ 页码条压根不出现，
					#  实测 tx/mg 的分类列表就卡在这一条上）
					my $need = $index + $window + 1;
					$total = $end > $need ? $end : $need;
				}
				else {
					$total = $end;   # 上游本页没满 ⇒ 这就是最后一页
				}
			}

			my $feed = {
				items  => @$items ? $items : [ { name => _u('该平台没有返回歌单'), type => 'text' } ],
				# ⚠️ 0.11.33：`offset` 是**必须**的。LMS 下钻第 N 项时用父层返回的
				# items[N - offset] 取条目（Slim/Control/XMLBrowser.pm:386、Slim/Web/XMLBrowser.pm:285、
				# 子 feed 合并处 :1530 / :1137），而本层是"开窗返回"的；从前不报 offset ⇒
				# items[N] 直接越界 ⇒ **只有列表第 1 个歌单点得进去，其余全是空页**（Q2）。
				offset => $index,
				(defined $total ? (total => $total) : ()),
			};
			_feed_cache_put($ckey, $feed, $window);
			$log->warn(sprintf('LxMusic pl-list MISS src=%s sort=%s tag=%s idx=%d win=%d rows=%d total=%s shim_ms=%s ms=%d',
				$src, $sort, $tag, $index, $window, scalar(@$items), (defined $total ? $total : '?'),
				(defined $res->{ms} ? $res->{ms} : '?'), int((time() - $t0) * 1000)));
			$cb->($feed);
		},
	);
	};
	$fetch->();
	return;
}

sub sdkSonglistDetailHandler {
	my ($client, $cb, $args, $mode, $src, $plid) = @_;
	$src  ||= 'kg';
	$plid ||= '';

	unless (length $plid) {
		$cb->({ items => [ { name => _u('歌单 id 缺失'), type => 'text' } ] });
		return;
	}

	my $index  = $args->{index} || 0;
	my $window = $args->{quantity} || 50;
	$window = 50 if $window < 1 || $window > 300;

	my $ckey = join('|', 'pd', $src, $plid, $index);
	my $t0   = time();
	if (my $hit = _feed_cache_get($ckey, $PL_DETAIL_TTL, $window)) {
		$log->warn(sprintf('LxMusic pl-detail CACHE-HIT src=%s id=%s idx=%d win=%d ms=%d',
			$src, $plid, $index, $window, int((time() - $t0) * 1000)));
		$cb->($hit);
		return;
	}
	# 覆盖式命中：看过一次整页后，**点这一页里的任意一首**（LMS 用 index=N, quantity=1 再取一次）不再打上游
	if (my $hit = _feed_cache_cover('pd', $src, $plid, $index, $window, $PL_DETAIL_TTL)) {
		$log->warn(sprintf('LxMusic pl-detail CACHE-COVER src=%s id=%s idx=%d win=%d ms=%d',
			$src, $plid, $index, $window, int((time() - $t0) * 1000)));
		$cb->($hit);
		return;
	}

	# 歌单详情的上游页宽同样不固定（kw 1000 / kg 10000 / tx 100000 / wy 1000…），先按 50 猜，
	# 拿到响应的 limit 再重算重取一次（同榜单 0.11.5 的教训）。
	# ⚠️ 0.11.40：**重算后 page/skip 没变就别重取**——index=0（"点进歌单"的绝大多数情况）时
	# 猜 50 与真页宽算出来的都是 page=1/skip=0，从前照样再打一次平台 API，白等一次往返。
	my $upw   = 50;
	my $page  = int($index / $upw) + 1;
	my $skip  = $index % $upw;
	my $retuned = 0;
	my $want  = $index;

	my $fetch;
	$fetch = sub {
	Plugins::LxMusic::Helper->request(
		action  => 'songlistdetail',
		info    => { source => $src, id => $plid, page => $page },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data} && $res->{data}{list}) {
				$cb->({ items => [ { name => _u('歌单详情失败: ') . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}
			_log_shim_http('pl-detail', $res);

			# 首响应校正页宽（与榜单 handler 同款）
			if (!$retuned) {
				my $lim = $res->{data}{limit};
				if (defined $lim && $lim > 0) {
					$retuned = 1;
					my $np = int($want / $lim) + 1;
					my $ns = $want % $lim;
					if ($np != $page || $ns != $skip) {
						$upw  = $lim;
						$page = $np;
						$skip = $ns;
						$fetch->();
						return;
					}
					$upw = $lim;   # 窗口数学沿用真页宽（合成 total 时要用）
				}
			}

			my $info = $res->{data}{info} || {};
			my $all  = $res->{data}{list};

			# 页头配方（§5.11.69 同款）：feed 级 image/play/actions/albumData。
			# play 一出现，模板就不再渲染自动的 "All Songs" 行；整单播放改由页头
			# 按钮走 lxm://l/ 展开 ⇒ 不再需要列表里的「歌单名」「播放整个歌单」两行。
			my $cover;
			if ($info->{img} && $info->{img} =~ m{^https?://}) {
				$cover = $prefs->get('coverProxy') ? _coverProxyUrl($info->{img}) : $info->{img};
			}
			elsif (@$all && $all->[0]) {
				$cover = _coverOf($all->[0]);
			}

			my @list = @$all;
			@list = @list[ $skip .. $#list ] if $skip && @list > $skip;
			@list = @list[ 0 .. $window - 1 ] if @list > $window;
			my $tracks = _trackItems(\@list, undef, undef, $index);

			my $total = $info->{count} || $res->{data}{total} || scalar @$all;
			my $plname = $info->{name} || $plid;

			my $feed = {
				items  => $tracks,
				offset => $index,
				(total => $total),
				($cover ? (image => $cover) : ()),
				(play    => "lxm://l/$src/$plid"),
				(actions => _all_actions("lxm://l/$src/$plid")),
				(albumData => [
					{ name => _u('🎼 ') . _u($plname), type => 'text', label => 'ALBUM' },
					{ name => _u('[' . $src . ']')
						. ($info->{author} ? _u(' · ') . _u($info->{author}) : '')
						. _u(' · ') . int($total) . _u(' 首'),
					  type => 'text', label => 'ARTIST' },
				]),
			};
			_feed_cache_put($ckey, $feed, $window);
			$log->warn(sprintf('LxMusic pl-detail MISS src=%s id=%s idx=%d win=%d tracks=%d total=%d shim_ms=%s ms=%d',
				$src, $plid, $index, $window, scalar(@$tracks), int($total),
				(defined $res->{ms} ? $res->{ms} : '?'), int((time() - $t0) * 1000)));
			$cb->($feed);
		},
	);
	};
	$fetch->();
	return;
}

# 整单入队：插件侧展开（LMS 对远程 m3u 只当单条链式流，队列里看不到整单）
sub sdkSonglistPlayAllHandler {
	my ($client, $cb, $args, $mode, $src, $plid) = @_;
	$src  ||= 'kg';
	$plid ||= '';

	unless (length $plid) {
		$cb->({ items => [ { name => _u('歌单 id 缺失'), type => 'text' } ] });
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'songlistdetail',
		info    => { source => $src, id => $plid },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			unless ($res->{ok} && $res->{data} && $res->{data}{list} && @{ $res->{data}{list} }) {
				$cb->({ items => [ { name => _u('整单入队失败: ') . ($res->{error} || 'unknown'), type => 'text' } ] });
				return;
			}

			my @list = @{ $res->{data}{list} };
			@list = @list[ 0 .. 99 ] if @list > 100;   # 入队上限 100，防超长单拖慢解析
			my $tracks = _trackItems(\@list);

			my @urls = map { $_->{url} } grep { $_ && $_->{url} } @$tracks;
			my $n = scalar @urls;
			my $queued = 0;

			if ($n) {
				# 目标播放器：优先请求自身的 client（Web/kiosk 页带 ?player=），否则第一个已连接播放器
				my $player = $client;
				unless (ref($player) && $player->can('id') && $player->id && $player->can('power')) {
					my @clients = Slim::Player::Client::clients();
					($player) = grep { $_->can('power') } @clients;
				}
				if ($player) {
					eval {
						Slim::Control::Request::executeRequest($player, [ 'playlist', 'clear' ]);
						Slim::Control::Request::executeRequest($player, [ 'playlist', 'play', $urls[0] ]);
						for my $u (@urls[ 1 .. $#urls ]) {
							Slim::Control::Request::executeRequest($player, [ 'playlist', 'add', $u ]);
						}
						$queued = $n;
					};
					if ($@) {
						$log->error('LxMusic: play-all enqueue failed: ' . $@);
					}
				}
				else {
					$log->warn('LxMusic: play-all has no target player (client=' . (ref($client) || 'undef') . ')');
				}
			}

			my $info = $res->{data}{info} || {};
			my @items;
			push @items, {
				name => _u('🎼 ') . _u($info->{name} || $plid)
					. _u('  · 已入队 ') . $queued . _u(' 首'),
				type => 'text',
			};
			push @items, @$tracks;
			$cb->({ items => \@items });
		},
	);
	return;
}

# ================================================== web page

sub webHandler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	my $msg       = '';
	my $testHtml  = '';

	if ($params->{import} && ($params->{source} || $params->{sourceurl})) {
		($msg) = _handleImport($params);
	}

	if (my $mid = $params->{testmid}) {
		if ($mid =~ /^(\d{4,20})$/) {
			return _testMusicUrl($1, $client, $params, $callback, $httpClient, $response);
		}
		$msg = 'bad test id format';
	}

	# M0.2: web 搜索 + 单曲直链试听
	if (defined $params->{q} && length $params->{q}) {
		return _webPlSearch($params->{q}, $client, $params, $callback, $httpClient, $response)
			if ($params->{type} || '') eq 'pl';
		return _webSearch($params->{q}, ($params->{src} || ''), $client, $params, $callback, $httpClient, $response);
	}
	if (my $trackB64 = $params->{track}) {
		return _webPreview($trackB64, $client, $params, $callback, $httpClient, $response);
	}
	# M0.4: 封面代理（列表行图懒加载入口；设备侧不可直连的 CDN 由此中转）
	if (defined $params->{u}) {
		return _coverProxy($params->{u}, $client, $params, $callback, $httpClient, $response);
	}
	if (defined $params->{kw}) {   # 兼容旧链接
		return _coverProxy(encode_base64url('kw:' . $params->{kw}), $client, $params, $callback, $httpClient, $response);
	}
	# M0.3: 整单 m3u（XMLBrowser '播放整个歌单' 项与页面共用）
	if (my $plref = $params->{pl}) {
		return _playlistM3u($plref, $client, $params, $callback, $httpClient, $response);
	}
	# M0.3: 歌单详情页
	if (my $plid = $params->{plid}) {
		return _webPlDetail($plid, ($params->{plsrc} || 'kg'), $client, $params, $callback, $httpClient, $response);
	}

	my $src    = Plugins::LxMusic::Helper->sourceInfo;
	my $status = $src->{enabled}
		? 'sources: ' . $src->{enabled} . '/' . $src->{total} . ' enabled ('
			. encode_entities(join(', ', @{ Plugins::LxMusic::Sources->status->{names} })) . ')'
		: 'no source imported (' . $src->{total} . ' registered, none enabled)';

	my $msgBlock = $msg ? '<div class="msg">' . $msg . '</div>' : '';
	my $testBlock = $testHtml ? '<div class="msg">' . $testHtml . '</div>' : '';

	my $body = _page($status, $msgBlock, $testBlock);
	$response->code(200);
	$response->header('Content-Type' => 'text/html; charset=utf-8');
	$callback->($client, $params, \$body, $httpClient, $response);
	return;
}

sub _handleImport {
	my ($params) = @_;

	my ($content, $name, $err);

	if ($params->{source}) {
		$content = $params->{source};
		$name    = 'pasted';
	}
	else {
		my $u = $params->{sourceurl};
		$u = 'http://' . $u unless $u =~ m{^https?://}i;
		($content, $err) = _fetch($u);
		$name = ($u =~ m{([^/]+)$})[0] || 'downloaded';
	}

	return ('import failed: ' . encode_entities($err)) if $err;
	return 'import failed: empty content'
		unless $content && $content =~ /\S/ && length($content) > 50;

	# URL 下载拿到的是原始字节；prefs 与 installSource 都要求"字符"串，
	# 不解码就会被二次编码（源文件被改坏）。粘贴路径 LMS 已解码，_u 是幂等的。
	$content = _u($content);

	# v6 源多为混淆版，明文特征有限：认 SERVER_SCRIPT_CONFIG / @name 头 / 通用挂载
	my $looksOk = ($content =~ /SERVER_SCRIPT_CONFIG/
		|| $content =~ /\@name/
		|| $content =~ /EVENT_NAMES/
		|| $content =~ /lx\s*\.\s*on/);
	my $safe = _safeName($name);
	# M0.6：走多源注册表（installSource 已改为登记一条源；prefs 的 sourceContent/sourceName 退役）
	my $path = Plugins::LxMusic::Helper->installSource($safe, $content);
	return 'import failed: write error (see server.log)' unless $path;

	my $st = Plugins::LxMusic::Sources->status;
	return 'imported ' . ($looksOk ? '' : '(WARNING: does not look like an lx source) ')
		. ($st->{names}[-1] // $safe) . ', ' . length($content) . ' bytes'
		. "  [sources: $st->{enabled}/$st->{total} enabled]";
}

sub _testMusicUrl {
	my ($mid, $client, $params, $callback, $httpClient, $response) = @_;

	my $started = time();
	Plugins::LxMusic::Helper->resolveTrack(
		music    => { songmid => $mid },
		src      => 'kw',
		type     => ($prefs->get('quality') || '320k'),
		timeout  => 20,
		cb       => sub {
			my ($res) = @_;
			my $elapsed = sprintf('%.2f', time() - $started);
			my $text;
			if ($res->{ok} && $res->{url}) {
				$text = 'OK (' . $elapsed . 's) via [' . encode_entities($res->{source} // '?') . '] '
					. encode_entities($res->{quality} // '?')
					. (defined $res->{actualKbps} ? ' ~' . $res->{actualKbps} . 'kbps' : '')
					. ($res->{verified} ? ' verified' : ' (未校验)')
					. ': <a href="' . encode_entities($res->{url}) . '">'
					. encode_entities(substr($res->{url}, 0, 120)) . '</a>';
			}
			else {
				$text = 'FAIL (' . $elapsed . 's): ' . encode_entities($res->{error} || 'unknown');
				my $logs = join("\n", map { encode_entities($_) } @{ $res->{logs} || [] });
				$text .= '<pre>' . $logs . '</pre>' if $logs;
			}
			my $body = _page('', '', '<div class="msg">' . $text . '</div>');
			$response->code(200);
			$response->header('Content-Type' => 'text/html; charset=utf-8');
			$callback->($client, $params, \$body, $httpClient, $response);
		},
	);
	return;
}

# server-side blocking fetch of a subscription url (low frequency op)
sub _fetch {
	my ($url) = @_;
	return (undef, 'url too long') if length($url) > 500;
	return (undef, 'only http/https allowed') unless $url =~ m{^https?://}i;

	my $out = eval {
		local $ENV{PATH} = '/usr/bin:/bin';
		open(my $fh, '-|', '/usr/bin/curl', '-sS', '-L', '--max-time', '30', $url) or die "curl: $!";
		local $/;
		my $s = <$fh>;
		close $fh;
		$s;
	};
	return (undef, "download failed: $@") if $@ || !defined $out;
	return (undef, 'empty download') unless $out =~ /\S/;
	return ($out, undef);
}

sub _safeName {
	my ($name) = @_;
	$name ||= 'source';
	$name =~ s/\.{2,}/_/g;
	$name =~ s/[^\w.-]/_/g;
	$name =~ s/^[.\-]+//;
	$name = 'source' if $name eq '';
	return $name;
}

# ---------- M0.2 web: 搜索 + 试听 ----------

sub _respondPage {
	my ($client, $params, $callback, $httpClient, $response, $body, $code) = @_;
	$response->code($code || 200);
	$response->header('Content-Type' => 'text/html; charset=utf-8');
	$callback->($client, $params, \$body, $httpClient, $response);
	return;
}

sub _webSearch {
	my ($q, $src, $client, $params, $callback, $httpClient, $response) = @_;
	$q =~ s/^\s+|\s+$//g;

	my $started = time();
	Plugins::LxMusic::Helper->request(
		action  => 'search',
		info    => (length $src ? { query => $q, source => $src } : { query => $q }),
		timeout => 45,
		cb      => sub {
			my ($res) = @_;
			my $elapsed = sprintf('%.2f', time() - $started);
			# 诊断：无论成败都渲染 logs 尾部（0.3.3 现场定位通道）
			my $logTail = '';
			{
				my @lg = @{ $res->{logs} || [] };
				@lg = @lg[ $#lg - 39 .. $#lg ] if @lg > 40;
				$logTail = @lg ? '<details open><summary style="cursor:pointer">logs</summary><pre>'
					. join("\n", map { encode_entities($_) } @lg) . '</pre></details>' : '';
			}
			my $html;
			if ($res->{ok} && $res->{data}) {
				my @rows;
				# 单一源：保持原顺序（PC 端单源列表也不重排）；跨源：合并去重 + 相似度降序
				# ⚠️ 单源时 shim 返回的是 **hashref**（一个分组），跨源才是 arrayref——
				#    直接 @{$res->{data}} 会把单源路径打死（"Not an ARRAY reference" ⇒ 页面挂死）
				my @groups = length $src ? ($res->{data}) : @{ $res->{data} };
				my @flat;
				if (length $src) {
					for my $grp (@groups) {
						next unless $grp && $grp->{list};
						push @flat, map { { t => $_, src => ($grp->{source} || $src), tot => $grp->{total} } }
							grep { ref($_) eq 'HASH' } @{ $grp->{list} };
					}
				}
				else {
					@flat = map { { t => $_->{t}, src => $_->{src}, tot => $_->{t}{_tot} } }
						@{ _mergeRank(\@groups, $q, 120) };
				}
				for my $row (@flat) {
					my $t = $row->{t};
					my $mj = encodeTrackJson($t);
					next unless $mj;
					my $types = join('/', map { $_->{type} || '' } @{ $t->{types} || [] });
					my $link = '?track=' . encode_base64url($mj) . '&q=' . encode_entities($q)
						. (length $src ? '&src=' . encode_entities($src) : '');
					push @rows, sprintf(
						'<li><a href="%s">%s</a> <span style="color:#888">%s · %s%s</span></li>',
						$link,
						encode_entities(($t->{name} || '?') . ($t->{singer} ? ' - ' . $t->{singer} : '')),
						encode_entities($types),
						encode_entities($row->{src} || '?'),
						($row->{tot} ? ' · ' . encode_entities($row->{tot}) : ''),
					);
				}
				$html = @rows
					? '<p class="status">"' . encode_entities($q) . '" ' . $elapsed . 's, '
						. scalar(@rows) . ' results (tap title to resolve &amp; preview)</p><ul>' . join('', @rows) . '</ul>'
					: '<p class="status">no results (' . $elapsed . 's)</p>';
			}
			else {
				my $logs = join("\n", map { encode_entities($_) } @{ $res->{logs} || [] });
				$html = '<div class="msg">search FAIL: ' . encode_entities($res->{error} || 'unknown')
					. ($logs ? "<pre>$logs</pre>" : '') . '</div>';
			}
			$html .= $logTail if $logTail;
			_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', $html));
		},
	);
	return;
}

# ---------- M0.3 web: 歌单搜索 / 详情 / 整单 m3u ----------

sub _webPlSearch {
	my ($q, $client, $params, $callback, $httpClient, $response) = @_;
	$q =~ s/^\s+|\s+$//g;

	my $started = time();
	Plugins::LxMusic::Helper->request(
		action  => 'songlist',
		info    => { query => $q },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			my $elapsed = sprintf('%.2f', time() - $started);
			my $logTail = '';
			{
				my @lg = @{ $res->{logs} || [] };
				@lg = @lg[ $#lg - 39 .. $#lg ] if @lg > 40;
				$logTail = @lg ? '<details open><summary style="cursor:pointer">logs</summary><pre>'
					. join("\n", map { encode_entities($_) } @lg) . '</pre></details>' : '';
			}
			my $html;
			if ($res->{ok} && $res->{data}) {
				my @rows;
				for my $grp (@{ $res->{data} }) {
					next unless $grp && $grp->{list} && @{ $grp->{list} };
					my $src = $grp->{source} || '?';
					for my $pl (@{ $grp->{list} }) {
						next unless $pl && $pl->{id};
						my $pid = encode_base64url($pl->{id});
						push @rows, sprintf(
							'<li><a href="?plid=%s&plsrc=%s">%s</a> <span style="color:#888">%s · %s首 · %s</span></li>',
							$pid, encode_entities($src),
							encode_entities($pl->{name} || '?'),
							encode_entities($src),
							encode_entities($pl->{total} || '?'),
							encode_entities($pl->{author} || ''),
						);
					}
				}
				$html = @rows
					? '<p class="status">歌单 "' . encode_entities($q) . '" ' . $elapsed . 's, '
						. scalar(@rows) . ' 个 (点歌单名看曲目)</p><ul>' . join('', @rows) . '</ul>'
					: '<p class="status">no playlist results (' . $elapsed . 's)</p>';
			}
			else {
				my $logs = join("\n", map { encode_entities($_) } @{ $res->{logs} || [] });
				$html = '<div class="msg">songlist FAIL: ' . encode_entities($res->{error} || 'unknown')
					. ($logs ? "<pre>$logs</pre>" : '') . '</div>';
			}
			$html .= $logTail if $logTail;
			_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', $html));
		},
	);
	return;
}

sub _webPlDetail {
	my ($plidB64, $src, $client, $params, $callback, $httpClient, $response) = @_;
	my $plid = eval { decode_base64url($plidB64) };
	unless ($plid) {
		_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', '<div class="msg">bad plid</div>'));
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'songlistdetail',
		info    => { source => $src, id => $plid },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			my $html;
			if ($res->{ok} && $res->{data} && $res->{data}{list}) {
				my $info = $res->{data}{info} || {};
				my $plRef = encode_base64url($TRACK_JSON->encode({ source => $src, id => $plid }));
				my @rows;
				my $n = 0;
				for my $t (@{ $res->{data}{list} }) {
					$n++;
					push @rows, sprintf('<li>%03d %s <span style="color:#888">%s</span></li>',
						$n,
						encode_entities(($t->{name} || '?') . ($t->{singer} ? ' - ' . $t->{singer} : '')),
						encode_entities($t->{source} || $src),
					);
				}
				$html = '<p class="status">' . encode_entities($info->{name} || $plid)
					. ($info->{author} ? ' · ' . encode_entities($info->{author}) : '')
					. ' · ' . scalar(@rows) . ' tracks</p>'
					. '<p><a href="/plugins/LxMusic/playlist.m3u?pl=' . $plRef . '">整单 m3u (给设备/播放器用)</a></p><ul>'
					. join('', @rows) . '</ul>';
			}
			else {
				$html = '<div class="msg">songlist detail FAIL: ' . encode_entities($res->{error} || 'unknown') . '</div>';
			}
			_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', $html));
		},
	);
	return;
}

sub _playlistM3u {
	my ($plref, $client, $params, $callback, $httpClient, $response) = @_;
	my $meta = eval { $TRACK_JSON->decode(decode_base64url($plref)) };
	unless ($meta && ref($meta) eq 'HASH' && $meta->{id}) {
		$response->code(400);
		$response->header('Content-Type' => 'text/plain; charset=utf-8');
		$callback->($client, $params, \('bad pl param'), $httpClient, $response);
		return;
	}

	Plugins::LxMusic::Helper->request(
		action  => 'songlistdetail',
		info    => { source => ($meta->{source} || 'kg'), id => $meta->{id} },
		timeout => 30,
		cb      => sub {
			my ($res) = @_;
			my $q     = $prefs->get('quality') || '320k';
			# m3u 是字节流：EXTINF 标题与 #PLAYLIST 名都显式按 UTF-8 落字节，防乱码
			my $plName = ($res->{ok} && $res->{data}{info}{name}) ? _u($res->{data}{info}{name}) : 'LX Music playlist';
			my @lines = ('#EXTM3U', '#PLAYLIST:' . Encode::encode('UTF-8', $plName));
			if ($res->{ok} && $res->{data} && $res->{data}{list}) {
				# 0.11.35：m3u 截断 30 → 300，与「整单入队」(explodePlaylist) 和歌单详情窗口上限对齐。
				# 从前三个上限互不一致（30 / 100 / 300），同一个歌单走不同入口拿到的长度不一样。
				my $cap = 300;
				for my $t (@{ $res->{data}{list} }) {
					last if $cap-- <= 0;
					next unless $t && ref($t) eq 'HASH';
					my $name = _u(($t->{singer} ? $t->{singer} . ' - ' : '') . ($t->{name} || '?'));
					my $url = Plugins::LxMusic::ProtocolHandler->buildUrl(
						music => $t,
						src   => ($t->{source} || $meta->{source} || 'kg'),
						type  => $q,
						name  => $name,
					);
					push @lines, '#EXTINF:-1,' . Encode::encode('UTF-8', $name), $url if $url;
				}
			}
			my $body = join("\n", @lines) . "\n";
			$response->code(200);
			$response->header('Content-Type' => 'audio/x-mpegurl');
			$callback->($client, $params, \$body, $httpClient, $response);
			return;
		},
	);
	return;
}

# ---------- M0.4 web: 封面代理（懒加载；设备侧不可直连的 CDN 由此中转） ----------

my %COVER_CACHE;   # target => 图片 URL（kw 的 pic.web 解析结果）

sub _respondImage {
	my ($ct, $body, $client, $params, $callback, $httpClient, $response) = @_;
	$response->code(200);
	$response->header('Content-Type' => ($ct && $ct =~ m{^image/} ? $ct : 'image/jpeg'));
	$response->header('Cache-Control' => 'max-age=86400');
	$callback->($client, $params, \$body, $httpClient, $response);
	return;
}

sub _respondCoverFail {
	my ($why, $client, $params, $callback, $httpClient, $response) = @_;
	$response->code(404);
	$response->header('Content-Type' => 'text/plain; charset=utf-8');
	$callback->($client, $params, \($why), $httpClient, $response);
	return;
}

# 来源 Referer/UA：kg/mg 等 CDN 常按来源校验，设备侧直连不出图多半是这个原因
sub _refererFor {
	my ($url) = @_;
	return 'https://music.migu.cn/'    if $url =~ /migu\.cn/i;
	return 'https://www.kugou.com/'    if $url =~ /kugou\.com/i;
	return 'https://www.kuwo.cn/'      if $url =~ /kuwo\.cn|kwcdn/i;
	return 'https://y.qq.com/'         if $url =~ /gtimg\.cn|qq\.com/i;
	return 'https://music.163.com/'    if $url =~ /126\.net|163\.com/i;
	return '';
}

sub _streamImage {
	my ($imgUrl, $client, $params, $callback, $httpClient, $response) = @_;

	my $ua = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36';
	# ⚠️ SimpleAsyncHTTP 没有 ->request()；header 是作为 get() 的额外参数传给
	# Net::HTTP::NB::formatRequest（LMS 源码 L49-53 注释明示）。用错方法会让
	# 页面处理器崩溃，端点对任何 URL 都返回连接失败（0.5.8 现场）
	my @hdr = ('User-Agent' => $ua, 'Accept' => 'image/*,*/*;q=0.8');
	if (my $ref = _refererFor($imgUrl)) {
		push @hdr, 'Referer' => $ref;
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $res  = shift;
			my $code = ($res && $res->can('code')) ? $res->code : 0;
			my $ct   = ($res && $res->can('header')) ? ($res->header('Content-Type') || '') : '';
			my $body = $res ? $res->content : '';
			$body = '' unless defined $body;
			if ($code == 200 && length $body) {
				return _respondImage($ct, $body, $client, $params, $callback, $httpClient, $response);
			}
			$log->warn("LxMusic: cover upstream $code ct=$ct url=" . substr($imgUrl, 0, 90));
			return _respondCoverFail("upstream $code", $client, $params, $callback, $httpClient, $response);
		},
		# ⚠️ 0.11.47：SimpleAsyncHTTP->new 的签名是 (成功回调, **错误回调**, 参数)。
		# 从前这里只传了 (回调, {timeout}) ⇒ hashref 落到 ecb 槽位：timeout 从未生效，
		# 且**每次封面请求失败**都会在 LMS 的 Select 循环里抛 `Not a CODE reference
		# at Slim/Networking/SimpleAsyncHTTP.pm line 96`（2026-09-22 设备 crash 前现场）。
		sub {
			my ($http, $error) = @_;
			$log->warn('LxMusic: cover upstream error: ' . ($error || '?') . ' url=' . substr($imgUrl, 0, 90));
			return _respondCoverFail('upstream error', $client, $params, $callback, $httpClient, $response);
		},
		{ timeout => 12 },
	)->get($imgUrl, @hdr);
	return;
}

sub _coverProxy {
	my ($uParam, $client, $params, $callback, $httpClient, $response) = @_;

	my $target = eval { decode_base64url($uParam) };
	unless (defined $target && length $target) {
		return _respondCoverFail('bad cover param', $client, $params, $callback, $httpClient, $response);
	}

	# kw：先解析 pic.web（响应体是图片 URL 纯文本，落雪 PC 端 getPic 同款），再取图
	# 0.11.61：目标可带缩略尺寸 `kw:<songmid>:<size>`（pictype/size 决定 kwcdn 路径里的尺寸段；
	# 实测 500→108KB / 300→44.6KB / 240→30KB / 150→14.4KB）
	if ($target =~ /^kw:(\d+)(?::(\d+))?$/) {
		my ($songmid, $size) = ($1, $2);
		$size = _coverThumbSize($size);
		my $ckey = "kw:$songmid" . ($size ? ":$size" : '');
		if (my $cached = $COVER_CACHE{$ckey}) {
			return _streamImage($cached, $client, $params, $callback, $httpClient, $response);
		}
		my $api = 'http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype='
			. ($size || 500) . '&size=' . ($size || 500) . '&rid=' . $songmid;
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $res = shift;
				my $img = $res ? $res->content : '';
				$img = '' unless defined $img;
				$img =~ s/^\s+|\s+$//g;
				if ($img =~ m{^https?://\S+$}) {
					%COVER_CACHE = () if keys %COVER_CACHE > 300;
					# pic.web 偶尔忽略 pictype，返回的仍是 500 尺寸 ⇒ 再改写一次兜底
					$COVER_CACHE{$ckey} = _coverThumb($img);
					return _streamImage($COVER_CACHE{$ckey}, $client, $params, $callback, $httpClient, $response);
				}
				$log->debug('LxMusic: kw pic.web miss for ' . $songmid);
				return _respondCoverFail('no cover', $client, $params, $callback, $httpClient, $response);
			},
			# 0.11.47：补错误回调（见上面 SimpleAsyncHTTP 的签名说明）
			sub {
				my ($http, $error) = @_;
				$log->warn('LxMusic: kw pic.web error: ' . ($error || '?'));
				return _respondCoverFail('kw pic.web error', $client, $params, $callback, $httpClient, $response);
			},
			{ timeout => 8 },
		)->get($api);
		return;
	}

	# kg：POST get_res_privilege 换真图 URL（官方 kg/pic.js 同款）。
	# 参数格式 'kg:<albumAudioId>:<albumId>:<hash>'（hash 必需）
	if ($target =~ /^kg:(\d*):(\d+):([0-9A-Fa-f]+)$/) {
		my ($aaid, $albumid, $hash) = ($1, $2, $3);
		my $key = "kg:$aaid:$albumid:$hash";
		if (my $cached = $COVER_CACHE{$key}) {
			return _streamImage($cached, $client, $params, $callback, $httpClient, $response);
		}
		my $api = 'http://media.store.kugou.com/v1/get_res_privilege';
		my $body = $TRACK_JSON->encode({
			appid => 1001, area_code => '1', behavior => 'play', clientver => '9020',
			need_hash_offset => 1, relate => 1,
			resource => [ {
				album_audio_id => $aaid eq '' ? 0 : $aaid,
				album_id       => $albumid,
				hash           => $hash,
				id             => 0,
				name           => 'lxmusic.mp3',
				type           => 'audio',
			} ],
			token => '', userid => 2626431536, vip => 1,
		});
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $res = shift;
				my $img = '';
				eval {
					my $d = JSON::XS->new->utf8->decode($res ? $res->content : '');
					my $info = $d->{data}[0]{info} || {};
					$img = $info->{image} || '';
					if ($img && $info->{imgsize} && ref($info->{imgsize}) eq 'ARRAY' && @{ $info->{imgsize} }) {
						my $sz = $info->{imgsize}[0];
						$img =~ s/\{size\}/$sz/;
					}
				};
				if ($img && $img =~ m{^https?://}) {
					%COVER_CACHE = () if keys %COVER_CACHE > 300;
					$COVER_CACHE{$key} = $img;
					return _streamImage($img, $client, $params, $callback, $httpClient, $response);
				}
				$log->debug("LxMusic: kg get_res_privilege miss for $key");
				return _respondCoverFail('no cover', $client, $params, $callback, $httpClient, $response);
			},
			# 0.11.47：补错误回调（见上面 SimpleAsyncHTTP 的签名说明）
			sub {
				my ($http, $error) = @_;
				$log->warn('LxMusic: kg pic error: ' . ($error || '?'));
				return _respondCoverFail('kg pic error', $client, $params, $callback, $httpClient, $response);
			},
			{ timeout => 8 },
		)->post($api,
			'KG-RC'        => 1,
			'KG-THash'     => 'expand_search_manager.cpp:852736169:451',
			'User-Agent'   => 'KuGou2012-9020-ExpandSearchManager',
			'Content-Type' => 'application/json',
			$body);
		return;
	}

	unless ($target =~ m{^https?://}i) {
		return _respondCoverFail('bad cover url', $client, $params, $callback, $httpClient, $response);
	}

	return _streamImage($target, $client, $params, $callback, $httpClient, $response);
}

# track hash -> compact JSON（web 链接用；与 XMLBrowser 的 lxm:// 同一 musicInfo 形状）
sub encodeTrackJson {	my ($t) = @_;
	return eval { $TRACK_JSON->encode($t) } || '';
}

sub _webPreview {
	my ($trackB64, $client, $params, $callback, $httpClient, $response) = @_;

	my $mj  = eval { decode_base64url($trackB64) };
	my $track = eval { JSON::XS->new->utf8->decode($mj) };
	unless ($track && ref($track) eq 'HASH' && ($track->{source} || $track->{songmid} || $track->{hash})) {
		_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', '<div class="msg">bad track param</div>'));
		return;
	}

	my $src     = $track->{source} || 'kw';
	my $started = time();
	Plugins::LxMusic::Helper->resolveTrack(
		music    => $track,
		src      => $src,
		type     => ($prefs->get('quality') || '320k'),
		# 0.11.60：工具页也给整体预算（页面能等，但别无限等——mg 那条实测 19.6s 才失败）
		timeout  => 14,
		budget   => 20,
		cb       => sub {
			my ($res) = @_;
			my $elapsed = sprintf('%.2f', time() - $started);
			my $title = encode_entities(($track->{name} || '?') . ($track->{singer} ? ' - ' . $track->{singer} : ''));
			# 每次候选尝试的耗时拆解（ms=宿主墙钟, handler=源内耗时, verify=HEAD 校验, path=worker/fork）
			my $tries = join('; ', map {
				my $t = ($_->{source} // '?') . '@' . ($_->{quality} // '?') . ': ' . ($_->{why} // 'ok');
				$t .= sprintf(' %dms', $_->{ms}) if defined $_->{ms};
				$t .= sprintf('(handler %dms)', $_->{handler}) if defined $_->{handler};
				$t .= sprintf('(verify %dms)', $_->{verify}) if defined $_->{verify};
				$t .= ' friendly=0' if $_->{ok} && defined $_->{friendly} && !$_->{friendly};
				$t .= ' [' . $_->{path} . ']' if $_->{path};
				encode_entities($t);
			} @{ $res->{tries} || [] });
			my $html;
			if ($res->{ok} && $res->{url}) {
				my $u = encode_entities($res->{url});
				# 0.11.60（A0）：显示**真实档位**（交付物反推 + 上游 types[] 封顶），请求档位不同则括注。
				# 现场：wy 行请求 flac、实际交付 ~128kbps 的流，旧代码在这行写 "[全豆要] flac ~128kbps"
				# —— 同一行里"flac"和"128kbps"自相矛盾，用户看到的正是这种。
				my $realTier = Plugins::LxMusic::ProtocolHandler->_actualTier(
					$res->{format}, $res->{actualKbps}, $res->{bits}, $res->{declared});
				my $shown = $realTier || $res->{quality} || '?';
				my $req = (defined $realTier && defined $res->{quality} && $realTier ne $res->{quality})
					? " (requested $res->{quality})" : '';
				my $via = encode_entities(sprintf('[%s] %s%s%s', $res->{source} // '?', $shown, $req,
					(defined $res->{actualKbps} ? " ~$res->{actualKbps}kbps" : '')
					. ($res->{verified} ? ' verified' : '')
					. ($res->{suspect} ? ' ⚠ 码率异常低，疑似试听片段' : '')));
				$html = '<div class="msg">OK (' . $elapsed . 's) ' . $title . ' — ' . $via
					. ($tries ? "<br><b>tries:</b> " . $tries : '')
					. '</div><p><audio controls src="' . $u . '" style="width:100%"></audio></p>'
					. '<p><a href="' . $u . '">direct link</a> · <a href="?q=' . encode_entities($params->{q} || $track->{name} || '') . '">back to search</a></p>';
			}
			else {
				my $logs = join("\n", map { encode_entities($_) } @{ $res->{logs} || [] });
				$html = '<div class="msg">FAIL (' . $elapsed . 's) ' . $title . ': '
					. encode_entities($res->{error} || 'unknown')
					. ($tries ? "<br><b>tries:</b> " . $tries : '')
					. '<br><b>note:</b> 取直链需已导入并启用至少一个订阅源'
					. ($logs ? "<pre>$logs</pre>" : '') . '</div>';
			}
			_respondPage($client, $params, $callback, $httpClient, $response, _page('', '', $html));
		},
	);
	return;
}

# static page assembled from byte lines (no heredoc)
sub _page {
	my ($status, $msgBlock, $testBlock) = @_;

	my @l = (
		'<!DOCTYPE html><html><head><meta charset="utf-8">',
		'<meta name="viewport" content="width=device-width, initial-scale=1">',
		'<title>LX Music - settings</title>',
		'<style>',
		'body { font-family: sans-serif; margin: 2em auto; max-width: 52em; padding: 0 1em; color: #222; }',
		'h1 { font-size: 1.4em; } h2 { font-size: 1.1em; margin-top: 1.6em; }',
		'textarea { width: 100%; height: 10em; font-family: monospace; font-size: 12px; }',
		'input[type=text] { width: 60%; }',
		'.msg { padding: .6em 1em; background: #eef; border: 1px solid #ccd; border-radius: 6px; margin: .8em 0; }',
		'.status { color: #555; } pre { background: #f6f6f6; padding: .6em; overflow: auto; max-height: 14em; }',
		'.box { border: 1px solid #ddd; border-radius: 8px; padding: 1em; margin: 1em 0; }',
		'</style></head><body>',
		'<h1>LX Music <span style="font-size:.6em;color:#888">v'
			. encode_entities(Plugins::LxMusic::Helper->pluginVersion) . '</span></h1>',
		'<div class="box"><h2>Source status</h2><p class="status">' . $status . '</p>',
		'<p>quality: ' . encode_entities($prefs->get('quality') || '320k')
			. '（设置页可改） · 封面代理: '
			. ($prefs->get('coverProxy') ? 'on' : 'off') . '</p></div>',
		'<h2>Import source</h2>',
		'<form method="post">',
		'<p>Option 1: paste the lx custom-source script (.js) below</p>',
		'<textarea name="source" placeholder="paste source script here"></textarea>',
		'<p>Option 2: subscription URL (http/https)</p>',
		'<p><input type="text" name="sourceurl" placeholder="https://.../source.js"></p>',
		'<p><button type="submit" name="import" value="1">Import &amp; enable</button></p>',
		'</form>',
		$msgBlock,
		'<h2>Play test (M0.1)</h2>',
		'<form method="get">',
		'<p>Enter a numeric Kuwo song id to test the musicUrl chain:</p>',
		'<p><input type="text" name="testmid" placeholder="e.g. 128908374">',
		'<button type="submit">Run test</button></p>',
		'</form>',
		$testBlock,
		'<p style="color:#999;font-size:.85em">Hint: the numeric id in the Kuwo web-player URL is the song id.</p>',
		'<h2>Search (M0.2)</h2>',
		'<form method="get">',
		'<p><input type="text" name="q" placeholder="song / artist keyword"> ',
		'<select name="src"><option value="">all sources</option><option>kw</option><option>kg</option><option>tx</option><option>wy</option><option>mg</option></select> ',
		'<button type="submit">Search</button></p>',
		'</form>',
		'</body></html>',
	);

	return join('', @l);
}

1;
