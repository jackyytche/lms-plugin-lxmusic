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

1;
