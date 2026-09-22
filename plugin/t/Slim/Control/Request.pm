# t/Slim/Control/Request.pm — 存根（本地 perl -c 用；设备上用真模块）
package Slim::Control::Request;

use strict;
use warnings;

sub executeRequest { }
sub addDispatch    { }
# 0.11.31：队列通知订阅（LxMusic 用它做"建队后补发封面"）
# 0.11.49：**记下来**，供 republish-loop-test.pl 直接调用订阅者回调（验证"哪些通知才排补发"）
our @SUBS;
sub subscribe      { my ($cb, $filter) = @_; push @SUBS, { cb => $cb, filter => $filter }; return }
sub lastSubscribe  { return $SUBS[-1] }
sub resetForTest   { @SUBS = (); return }
sub notifyFromArray { }

1;
