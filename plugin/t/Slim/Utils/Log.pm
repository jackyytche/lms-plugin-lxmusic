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

package Slim::Utils::Log::Stub;

sub new   { my $c = shift; my %o = (@_ % 2 == 0) ? @_ : (); return bless \%o, $c }
sub info  { my $s = shift; warn "LOG-INFO: @_\n" if $ENV{LX_TEST_VERBOSE} }
sub warn  { my $s = shift; warn "LOG-WARN: @_\n" }
sub error { my $s = shift; warn "LOG-ERROR: @_\n" }
sub debug { my $s = shift; warn "LOG-DEBUG: @_\n" if $ENV{LX_TEST_VERBOSE} }

1;
