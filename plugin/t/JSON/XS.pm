# t_local/JSON/XS.pm — 本地测试用的 JSON::XS 替身：**薄封装 JSON::PP**（核心模块，一定有）
#
# 语义对齐真实 JSON::XS：
#   - 默认（无 utf8）：encode 返回"字符"串（非 ASCII 转义成 \uXXXX）；decode 接受字符/字节
#   - ->utf8：encode 返回 UTF-8 字节串；decode 接受 UTF-8 字节串
# 之前这里是个手写假实现（encode 不转义非 ASCII、decode 直接喂 decode_json），
# 导致"存进去再读出来"在本地测试里静默失败（Sources.pm 单测 count 恒 0）。
package JSON::XS;

use strict;
use warnings;

use Encode ();
use JSON::PP ();

sub new {
	my ($class, %args) = @_;
	return bless { %args }, $class;
}

sub utf8         { $_[0]->{utf8} = 1;         return $_[0] }
sub canonical    { $_[0]->{canonical} = 1;    return $_[0] }
sub allow_nonref { $_[0]->{allow_nonref} = 1; return $_[0] }
sub pretty       { $_[0]->{pretty} = 1;       return $_[0] }

sub _pp {
	my ($self) = @_;
	my $pp = JSON::PP->new->allow_nonref;
	$pp = $pp->canonical  if $self->{canonical};
	$pp = $pp->utf8       if $self->{utf8};
	$pp = $pp->pretty     if $self->{pretty};
	return $pp;
}

sub encode {
	my ($self, $data) = @_;
	my $out = $self->_pp->encode($data);
	# JSON::PP 的 utf8 模式已经产出字节；非 utf8 模式产出字符（\u 转义），两者都对
	return $out;
}

sub decode {
	my ($self, $json) = @_;
	# 非 utf8 模式下 JSON::PP 也接受字节串：若是字节串先解码成字符再做 \u 展开
	if (!$self->{utf8} && defined $json && !utf8::is_utf8($json)) {
		my $decoded = eval { Encode::decode('UTF-8', $json, Encode::FB_CROAK()) };
		$json = $decoded if defined $decoded;
	}
	return $self->_pp->decode($json);
}

1;
