# t/Slim/Plugin/Base.pm — 存根（插件基类）
package Slim::Plugin::Base;

use strict;
use warnings;

sub initPlugin     { my $c = shift; $c->{feed_args} = {@_} }
sub shutdownPlugin { }

1;
