# t/Slim/Player/Protocols/HTTP.pm — 存根（base 类）
package Slim::Player::Protocols::HTTP;

use strict;
use warnings;

sub new     { my $c = shift; return bless {@_}, $c }
sub scanUrl { }

1;
