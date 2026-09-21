# t/Slim/Control/Request.pm — 存根（本地 perl -c 用；设备上用真模块）
package Slim::Control::Request;

use strict;
use warnings;

sub executeRequest { }
sub addDispatch    { }
sub subscribe      { }      # 0.11.31：队列通知订阅（LxMusic 用它做"建队后补发封面"）
sub notifyFromArray { }

1;
