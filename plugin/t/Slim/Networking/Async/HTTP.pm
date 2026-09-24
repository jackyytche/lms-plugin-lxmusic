# t/Slim/Networking/Async/HTTP.pm — 存根：本机默认"有 SSL"（真身探测 IO::Socket::SSL）
package Slim::Networking::Async::HTTP;

use strict;
use warnings;

sub new     { my $c = shift; return bless {@_}, $c }
sub hasSSL  { 1 }

1;
