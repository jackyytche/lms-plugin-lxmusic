# t/Slim/Player/Client.pm — 存根（本地 perl -c 用；设备上用真模块）
package Slim::Player::Client;

use strict;
use warnings;

our @CLIENTS;    # 0.11.49：republish-loop-test.pl 用假播放器填充它

sub clients  { return @CLIENTS }
sub getClient { return $CLIENTS[0] }
sub resetForTest { @CLIENTS = (); return }

1;
