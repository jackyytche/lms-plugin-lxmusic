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
sub __dummy { 1 }

# 达菲 seek 修正（Ximalaya 0.1.26 同款）：声明转码级 seek，
# daphile Decode 管道的 $START$ 才会拿到时间偏移。
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
sub scanUrl {
	my ($class, $url, $args) = @_;

	my $song = $args->{song};
	my $cb   = $args->{cb};

	my $info = $class->parseUrl($url);
	unless ($info) {
		$log->error("LxMusic: cannot parse $url");
		$cb->(undef);
		return;
	}

	my $sourcePath = Plugins::LxMusic::Helper->currentSourcePath();
	unless ($sourcePath) {
		$log->error('LxMusic: no source imported — import a subscription first');
		$cb->(undef);
		return;
	}

	main::INFOLOG && $log->info('LxMusic: resolving musicUrl src=' . $info->{src} . ' type=' . $info->{type});

	Plugins::LxMusic::Helper->request(
		source   => $sourcePath,
		action   => 'musicUrl',
		sourceId => $info->{src},
		info     => { musicInfo => $info->{music}, type => $info->{type} },
		timeout  => 20,
		cb       => sub {
			my ($res) = @_;

			my $direct = $res->{data};
			unless ($res->{ok} && $direct && !ref($direct) && $direct =~ /^https?:/) {
				my $why = $res->{error} || ($res->{ok} ? 'handler returned no url' : 'unknown');
				$log->error("LxMusic: musicUrl failed: $why");
				$class->cache_metadata($url, { title => $info->{name}, error => $why });
				$cb->(undef);
				return;
			}

			main::INFOLOG && $log->info("LxMusic: resolved => $direct");

			# now-playing 元数据：标题 + 音质（如实显示）
			my $qLabel = $class->qualityLabel($info->{type});
			if ($info->{name}) {
				Slim::Music::Info::setRemoteMetadata($url, {
					title => $info->{name},
					ct    => ($qLabel =~ /FLAC/i ? 'audio/flac' : 'audio/mpeg'),
					type  => $qLabel,
				});
			}
			$class->cache_metadata($url, { title => $info->{name}, quality => $qLabel });

			# 直链是实际流地址；playlist 里保持稳定的 lxm:// URL
			$song->streamUrl($direct);
			$args->{cb} = sub {
				my ($track) = @_;
				if ($track && $info->{name}) {
					$track->title($info->{name});
					$track->url($url);
				}
				$cb->($track, @_);
			};
			$class->SUPER::scanUrl($direct, $args);
		},
	);

	return;
}

# resolve 直链的真实连接（避免重定向循环）
sub new {
	my ($class, $args) = @_;
	$args->{url} = $args->{song}->streamUrl unless $args->{redir};
	return $class->SUPER::new($args);
}

sub explodePlaylist {
	my ($class, $client, $url, $cb) = @_;
	$cb->([$url]);
	return;
}

# ---------- 元数据 ----------
my %METADATA;

sub cache_metadata {
	my ($class, $url, $info) = @_;

	%METADATA = () if keys %METADATA > 200;
	$METADATA{$url} = {
		title   => $info->{title}   || '',
		quality => $info->{quality} || '',
		error   => $info->{error}   || '',
	};

	return 1;
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;

	if (my $m = $METADATA{$url}) {
		my %meta;
		$meta{title} = $m->{title} if $m->{title};
		if ($m->{quality}) {
			$meta{type}    = $m->{quality};
			$meta{bitrate} = $m->{quality};
		}
		return %meta ? \%meta : {};
	}

	return {};
}

sub qualityLabel {
	my ($class, $type) = @_;
	return 'MP3 128kbps'  if ($type || '') eq '128k';
	return 'MP3 320kbps'  if ($type || '') eq '320k';
	return 'FLAC'         if ($type || '') eq 'flac';
	return 'FLAC 24bit'   if ($type || '') eq 'flac24bit';
	return 'Hi-Res'       if ($type || '') eq 'hires';
	return uc($type // '');
}

1;

__END__

=head1 NAME

Plugins::LxMusic::ProtocolHandler - lxm:// scheme handler

=cut
