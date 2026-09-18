# t/Slim/Utils/Log.pm — 存根：脱离 LMS 环境编译/测试 Helper.pm
package Slim::Utils::Log;

use strict;
use warnings;

sub logger { return Slim::Utils::Log::Stub->new(@_) }

package Slim::Utils::Log::Stub;

sub new  { my $c = shift; return bless {@_}, $c }
sub info { my $s = shift; warn "LOG-INFO: @_\n" if $ENV{LX_TEST_VERBOSE} }
sub warn { my $s = shift; warn "LOG-WARN: @_\n" }
sub error { my $s = shift; warn "LOG-ERROR: @_\n" }
sub debug { my $s = shift; warn "LOG-DEBUG: @_\n" if $ENV{LX_TEST_VERBOSE} }

1;
