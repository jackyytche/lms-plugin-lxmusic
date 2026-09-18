# t/Slim/Player/ProtocolHandlers.pm — 存根
package Slim::Player::ProtocolHandlers;

use strict;
use warnings;

my %HANDLERS;
sub registerHandler { my ($c, $scheme, $pkg) = @_; $HANDLERS{$scheme} = $pkg }
sub handlers        { return \%HANDLERS }

1;
