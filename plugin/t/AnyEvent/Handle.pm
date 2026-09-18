# t/AnyEvent/Handle.pm — 存根：记录 fh 与回调，测试中手动注入数据
package AnyEvent::Handle;

use strict;
use warnings;

sub new {
	my ($class, %args) = @_;
	my $h = bless \%args, $class;
	$MAIN{$h} = $h;
	return $h;
}

our %MAIN;

sub feed {    # 测试辅助：模拟进程输出
	my ($h, $data) = @_;
	$h->{on_read}->($h) if $h->{on_read};
	$h->{on_eof}->($h) if $h->{on_eof};
}

1;
