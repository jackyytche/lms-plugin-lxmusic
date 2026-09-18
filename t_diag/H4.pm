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

1;
