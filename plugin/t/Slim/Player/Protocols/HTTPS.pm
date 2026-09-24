# t/Slim/Player/Protocols/HTTPS.pm — 存根：模拟 LMS 的 HTTPS 处理器
# 真身 = IO::Socket::SSL + HTTP，new() 按 URL 协议分流（http: 走 HTTP，https: 走 SSL）。
# 本机没有 IO::Socket::SSL，所以这里只保留"分流 + 继承"的形状，用于编译期/ISA 检查。
package Slim::Player::Protocols::HTTPS;

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

sub new {
	my $class = shift;
	my $args  = shift;
	return $class->SUPER::new($args);      # 真身：http 走 HTTP；https 走 SSL 握手
}

sub canDirectStream     { shift->SUPER::canDirectStream(@_) }
sub canDirectStreamSong { shift->SUPER::canDirectStreamSong(@_) }

1;
