# t/Slim/Utils/Prefs.pm — 存根
package Slim::Utils::Prefs;

use strict;
use warnings;
use base 'Exporter';

our @EXPORT = qw(preferences);
# 0.11.76：**按名字记忆**同一个对象。从前每次都 new 一个新的 ⇒ 测试里
# `preferences('plugin')->set(...)` 设的值，被测代码（它自己 new 了一个）根本看不到。
our %INSTANCE;

sub preferences {
	my ($name) = @_;
	$name = '' unless defined $name;
	$INSTANCE{$name} ||= Slim::Utils::Prefs::Stub->new($name);
	return $INSTANCE{$name};
}

package Slim::Utils::Prefs::Stub;

# 只给"被测代码在没有设置时也会读、且缺省必须非 0"的键兜底；其余仍返回 undef，
# 免得改变既有用例对"未设置"的预期。
my %DEFAULTS = (
	coverProxy    => 1,
	coverThumb    => 300,
	coverThumbBig => 500,
);

sub new   { my ($c, $name) = @_; return bless { name => $name, vals => {} }, $c }
sub init  { my $s = shift; $s->{defaults} = \@_ }
sub get   { my ($s, $k) = @_; return $s->{vals}{$k} if exists $s->{vals}{$k}; return $DEFAULTS{$k} }
sub set   { my ($s, $k, $v) = @_; $s->{vals}{$k} = $v; return $v }

1;
