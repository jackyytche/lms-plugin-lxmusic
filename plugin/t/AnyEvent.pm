# t/AnyEvent.pm — 存根：捕获 timer 创建，不进入事件循环
package AnyEvent;

use strict;
use warnings;

my @TIMERS;
sub timers { return @TIMERS }

sub timer {
	my ($class, %args) = @_;
	my $t = bless { after => $args{after}, cb => $args{cb} }, 'AnyEvent::Timer::Stub';
	push @TIMERS, $t;
	return $t;
}

package AnyEvent::Timer::Stub;

sub cancel { $_[0]->{cancelled} = 1 }

1;
