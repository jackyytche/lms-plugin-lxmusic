# t/Slim/Player/Playlist.pm — 存根（本地 perl -c 用；设备上用真模块）
package Slim::Player::Playlist;

use strict;
use warnings;

our @PLAYLIST;   # 0.11.49：假队列（字符串 URL 即可，真代码两种形态都吃）

sub playList { return \@PLAYLIST }
sub tracks   { }
sub add      { }
sub resetForTest { @PLAYLIST = (); return }

1;
