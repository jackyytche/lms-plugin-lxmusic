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
1;
