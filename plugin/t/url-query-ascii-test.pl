#!/usr/bin/perl
# url-query-ascii-test.pl - URL query 必须纯 ASCII 的回归（0.11.97）
# 用法：perl plugin/t/url-query-ascii-test.pl
#
# 背景（设备 A/B 实测，见 HANDOFF §九 第三十轮 ①）：
#   歌单/列表曲目行内「播放」按钮点了**没反应、队列不加、无声**。
#   判据（同一首歌 A/B，极干净）：`?n=王菲 - 如愿` ⇒ `playlist add` 后
#   **LMS 的 JSONRPC 连接被直接关闭**（`Remote end closed connection without response`）、
#   队列 0 行；把 `n=` 整段去掉 ⇒ `mode=play`、播放位置正常推进。
#   两边 b64 里的 musicInfo 字段逐项一致 ⇒ 与音频/解析无关，**就是 URL 里的中文**。
#
#   机理：`n=` 经 uri_escape_utf8 出来是 `%E7%8E%8B%E8%8F%B2…`（本身是 ASCII、安全），
#   但这条 URL 走 XMLBrowser 的 `anyurl?p2=` 时会被**解回真中文**再交给 LMS；
#   LMS 把它交给 `Slim::Schema->updateOrCreate` / `URI->new` 时，**字符旗标串
#   （wide character）** 就把那条请求打崩。同族：UPnPBridge 的
#   `Wide character in subroutine entry`（那条还会连带打死 JSONRPC）。
#
# 修法：URL query 只留 `s=`/`t=`（纯 ASCII）；显示名塞进 musicInfo 的 `_title`
#   （整块走 base64url）⇒ 最终 URL 里一个非 ASCII 字节都没有。
#
# 本套件钉死（防回归）：
#   · 带中文标题时 buildUrl 产出的 URL **整串纯 ASCII**，且 query 里没有 `n=`；
#   · 不再出现 percent-encoded 的中文（那正是会被 XMLBrowser 解回真中文的形态）；
#   · parseUrl 能把显示名原样读回，且返回的是**字符旗标串**（不是 raw 字节）；
#   · `_title` 取出后被**删掉**，不混进 music 对象流向下游；
#   · 调用方传进来的 music 哈希**不被改写**（浅拷贝）；
#   · 老 URL（带 `n=`）仍能读回显示名（向后兼容，历史队列里的 URL 就是这形态）；
#   · 空标题不炸。
use strict;
use warnings;

use FindBin;
use File::Spec;

BEGIN {
	my $root  = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
	my $build = File::Spec->catdir($root, 't_build', 'Plugins', 'LxMusic');
	unshift @INC, sub {
		my ($self, $file) = @_;
		return unless $file =~ m{^Plugins/LxMusic/([^/]+\.pm)$};
		my @cand = grep { -f $_ } map { File::Spec->catfile($_, $1) }
			($build, File::Spec->catdir($root, 'LxMusic'));
		return unless @cand;
		my ($newest) = sort { (stat($b))[9] <=> (stat($a))[9] } @cand;
		open my $fh, '<', $newest or return;
		return $fh;
	};
	my $helper = File::Spec->catfile($FindBin::Bin, '..', 'LxMusic', 'Helper.pm');
	require $helper;
	$INC{'Plugins/LxMusic/Helper.pm'} = $helper;
	require Plugins::LxMusic::ProtocolHandler;
}

use MIME::Base64 ();
use Encode ();

my $failed = 0;
sub check {
	my ($name, $cond, $detail) = @_;
	if ($cond) { print "ok - $name\n" }
	else { $failed++; print "NOT OK - $name" . ($detail ? " : $detail" : '') . "\n" }
}

my $PH = 'Plugins::LxMusic::ProtocolHandler';

# 王菲 - 如愿（raw UTF-8 字节串，模拟 .pm 里的中文字面量）
my $CJK = "\xe7\x8e\x8b\xe8\x8f\xb2 - \xe5\xa6\x82\xe6\x84\xbf";

# ---------- 1. 中文标题：URL 必须整串纯 ASCII ----------
{
	my $url = $PH->buildUrl(
		music => { songmid => '123456', name => "\xe5\xa6\x82\xe6\x84\xbf", singer => "\xe7\x8e\x8b\xe8\x8f\xb2" },
		src   => 'kw',
		type  => 'flac',
		name  => $CJK,
	);
	check('buildUrl returns a url', defined $url && $url ne '', $url);

	my $non_ascii = () = $url =~ /([^\x00-\x7F])/g;
	check('url is pure ASCII even with a CJK title', $non_ascii == 0,
		"$non_ascii non-ASCII bytes in $url");

	# 这一条是根因本身：query 里绝不能有 n=（哪怕是 percent-encoded 的）
	check('query no longer carries n=', $url !~ /[?&]n=/, $url);
	check('query carries s=kw',   $url =~ /[?&]s=kw(?:&|$)/);
	check('query carries t=flac', $url =~ /[?&]t=flac(?:&|$)/);

	# 旧形态会把中文 percent-encode 进 query；那里会被 XMLBrowser 解回真中文
	check('no percent-encoded CJK left in the url', $url !~ /%E7%8E%8B/, $url);

	# ---------- 2. 往返：显示名走 musicInfo _title ----------
	my $info = $PH->parseUrl($url);
	check('parseUrl round-trips', defined $info && ref($info) eq 'HASH');

	my $want = Encode::decode('UTF-8', $CJK);   # parseUrl 契约：字符旗标串
	check('name round-trips through musicInfo _title',
		$info && $info->{name} eq $want,
		$info ? '<' . Encode::encode('UTF-8', $info->{name}) . '>' : 'undef');
	check('returned name is a character string (not raw bytes)',
		$info && utf8::is_utf8($info->{name}));

	check('src/type round-trip', $info && $info->{src} eq 'kw' && $info->{type} eq 'flac');
	check('music payload survives', $info && $info->{music}{songmid} eq '123456');

	# ⚠️ 上游字段按原字节透传：musicInfo 的**非 ASCII 字段**必须传**字符旗标串**。
	# 传 raw UTF-8 字节串时 JSON::XS->utf8 会把它当 latin-1 逐字符再编码一次
	# （`王菲` 的 6 个字节 → 6 个 latin-1 字符 → 每个再编成 2 字节）⇒ 双重编码。
	# 这是 **0.11.96 就有的既有行为，不是本次改动引入**（`$music` 一直是原样 encode 的），
	# 且与本期修的 `n=` 打崩无关——所以本用例只**钉住现状**，不主张它是正确行为。
	# 显示名 `name` 走的是 **`_title` 且已被规范化成字符串** ⇒ 不受这条影响（见上一断言）。
	my $singer_raw = $info ? $info->{music}{singer} : undef;
	# 期望值 = 原字节被当成 latin-1 逐字节再编一次 UTF-8 的结果
	# 王菲(6B) → U+00E7 U+008E U+008B U+00E8 U+008F U+00B2
	my $double_encoded = Encode::decode('UTF-8',
		"\xc3\xa7\xc2\x8e\xc2\x8b\xc3\xa8\xc2\x8f\xc2\xb2");
	check('non-ASCII upstream fields are passed through as-is (byte strings double-encode)',
		$singer_raw eq $double_encoded,
		$singer_raw ? '<' . Encode::encode('UTF-8', $singer_raw) . '>' : 'undef');
	# 反面：传**已解码的字符旗标串**（正常运行时上游 JSON 解出来的形态）就没有这个问题
	my $singer_chars = Encode::decode('UTF-8', "\xe7\x8e\x8b\xe8\x8f\xb2");
	my $u2 = $PH->buildUrl(
		music => { songmid => '1', singer => $singer_chars },
		src => 'kw', type => '320k', name => $CJK);
	my $i2 = $PH->parseUrl($u2);
	check('character-string upstream fields survive (no double encoding)',
		$i2 && $i2->{music}{singer} eq $singer_chars,
		$i2 ? '<' . Encode::encode('UTF-8', $i2->{music}{singer}) . '>' : 'undef');

	# _title 是我们搭的顺风车，不该流进下游（resolve/cache_metadata 会当上游字段看）
	check('_title is stripped out of music (no leak downstream)',
		$info && !exists $info->{music}{_title});

	# ---------- 3. 调用方的 music 哈希不能被改坏 ----------
	my $orig = { songmid => '999', name => 'x' };
	$PH->buildUrl(music => $orig, src => 'kw', type => '320k', name => "\xe6\xb5\x8b\xe8\xaf\x95");
	check('caller music hash is not mutated', !exists $orig->{_title},
		join(',', sort keys %$orig));
}

# ---------- 4. 老 URL（带 n=）向后兼容 ----------
{
	# 造一条 0.11.96 形态的 URL：?s=kw&t=320k&n=<title>
	# 这里用**纯 ASCII 的标题**造老 URL：真中文塞回 query 正是被修的形态，
	# 本用例要验的是"老形态还能被读懂"，不是"中文还能用"。
	my $json = '{"songmid":"555"}';
	my $b64  = MIME::Base64::encode_base64url($json);
	my $old  = "lxm://m/$b64?s=kw&t=320k&n=A%20-%20B";

	my $info = $PH->parseUrl($old);
	check('legacy n= url still parses', defined $info && ref($info) eq 'HASH');
	check('legacy n= still provides the display name',
		$info && $info->{name} eq 'A - B', $info ? $info->{name} : 'undef');
	check('legacy url keeps music payload', $info && $info->{music}{songmid} eq '555');
	check('legacy url has no _title and no leftover keys',
		$info && !exists $info->{music}{_title});
}

# ---------- 5. _title 优先于老 n= ----------
{
	# 万一同一条 URL 两个都有（不该发生），musicInfo 里的 _title 是权威
	my $json = MIME::Base64::encode_base64url(
		'{"songmid":"7","_title":"new form"}');
	my $info = $PH->parseUrl("lxm://m/$json?s=kw&t=320k&n=old%20form");
	check('_title wins over legacy n= when both present',
		$info && $info->{name} eq 'new form', $info ? $info->{name} : 'undef');
}

# ---------- 6. 空标题 / 无标题：不炸 ----------
{
	my $url = $PH->buildUrl(music => { songmid => '1' }, src => 'kg', type => '320k', name => '');
	check('empty name still builds a url', defined $url && $url ne '');
	my $info = $PH->parseUrl($url);
	check('empty name parses back as empty', $info && $info->{name} eq '',
		$info ? "<$info->{name}>" : 'undef');

	my $u2 = $PH->buildUrl(music => { songmid => '1' }, src => 'kg', type => '320k');
	check('omitted name still builds a url', defined $u2 && $u2 ne '');
}

# ---------- 7. 畸形输入不炸（防御性） ----------
{
	check('garbage url returns undef', !defined $PH->parseUrl('not-a-lxm-url'));
	check('bad base64 returns undef',  !defined $PH->parseUrl('lxm://m/!!!not-base64!!!?s=kw'));
	check('buildUrl without music returns undef', !defined $PH->buildUrl(src => 'kw'));
}

print $failed ? "\nFAILED ($failed)\n" : "\nALL PASS\n";
exit($failed ? 1 : 0);
