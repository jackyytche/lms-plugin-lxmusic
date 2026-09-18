# Plugins/LxMusic/ProtocolHandler — lxm:// 协议
# ============================================================
# 播放时把 lxm:// 伪 URL 解析为真实音频直链：
#   lxm://m/<base64url(musicInfo JSON)>?s=<platform>&t=<quality>&n=<title>
# 取链走 Plugins::LxMusic::Helper（qjs + 订阅源脚本，musicUrl action），
# 直链交给 Slim::Player::Protocols::HTTP 流播。
# 模式跟随 Plugins::Ximalaya::ProtocolHandler（含达菲 canTranscodeSeek 修正）。
# ============================================================

package Plugins::LxMusic::ProtocolHandler;

use strict;
use warnings;

BEGIN { print STDERR "PH-A\n"; }
use base qw(Slim::Player::Protocols::HTTP);

BEGIN { print STDERR "PH-B\n"; }
use MIME::Base64 qw(encode_base64url decode_base64url);
use URI::Escape qw(uri_escape_utf8 uri_unescape);

BEGIN { print STDERR "PH-C\n"; }
use Slim::Music::Info;
use Slim::Utils::Log;

BEGIN { print STDERR "PH-D\n"; }
use Plugins::LxMusic::Helper;

BEGIN { print STDERR "PH-E\n"; }
my $log = logger('plugin.lxmusic');
BEGIN { print STDERR "PH-F\n"; }
Slim::Player::ProtocolHandlers->registerHandler('lxm', __PACKAGE__);
BEGIN { print STDERR "PH-G\n"; }
my $JSON = JSON::XS->new->utf8->canonical;
sub canTranscodeSeek { 1 }

sub isRemote { 1 }

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
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

# ---------- 播放解析 ----------
1;
