# t/Slim/Utils/Log.pm — 存根：脱离 LMS 环境编译/测试（导出 logger，供裸调用）
package Slim::Utils::Log;

use strict;
use warnings;
use base 'Exporter';

our @EXPORT = qw(logger logWarning logError);

# LMS main 包常量桩（真环境由 slimserver.pl 定义）
sub main::WEBUI   { 0 }
sub main::SCHEMA  { 0 }
sub main::INFOLOG { 0 }
sub main::DEBUGLOG { 0 }

sub logger    { return Slim::Utils::Log::Stub->new(@_) }
sub logWarning { my $c = shift; Slim::Utils::Log::Stub->new->warn(@_) }
sub logError   { my $c = shift; Slim::Utils::Log::Stub->new->error(@_) }
# 0.11.76：Plugin.pm 在 initPlugin 里会调 `Slim::Utils::Log->addLogCategory(...)`，
# 缺了它整个 Plugin 包 require 不起来（cover-tier-test.pl 现场）
# 0.11.78：返回值必须是**带 warn/info/error 的对象**（真环境是 Log4perl logger）。
# 从前返回 1 ⇒ 测试里只要走到 `$log->warn(...)` 就 `Can't locate object method "warn"
# via package "1"`（歌单搜索分页的用例现场）。存根要照抄契约，别只求"能编译"。
sub addLogCategory  { return Slim::Utils::Log::Stub->new(@_) }
sub setDefaultLevel { return 1 }

package Slim::Utils::Log::Stub;

sub new   { my $c = shift; my %o = (@_ % 2 == 0) ? @_ : (); return bless \%o, $c }
sub info  { my $s = shift; CORE::warn "LOG-INFO: @_\n" if $ENV{LX_TEST_VERBOSE} }
# 调用方可临时静音 warn（LX_TEST_QUIET_WARN=1）：用来压掉**内容可变**的日志行，
# 让 CI 回写的回归日志逐字节稳定（否则每次运行都多一条 ci: regression log 提交）
sub warn  { my $s = shift; CORE::warn "LOG-WARN: @_\n" unless $ENV{LX_TEST_QUIET_WARN} }
sub error { my $s = shift; CORE::warn "LOG-ERROR: @_\n" }
sub debug { my $s = shift; CORE::warn "LOG-DEBUG: @_\n" if $ENV{LX_TEST_VERBOSE} }
# 0.11.49：真环境（Log4perl）的 logger 有 is_debug/is_info —— ProtocolHandler 用它决定要不要记通知原文
sub is_debug { return $ENV{LX_TEST_VERBOSE} ? 1 : 0 }
sub is_info  { return 0 }

1;
