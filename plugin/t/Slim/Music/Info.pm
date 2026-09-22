# t/Slim/Music/Info.pm — 存根
package Slim::Music::Info;

use strict;
use warnings;

our $CALLS = 0;      # 0.11.49：记账——republish-loop-test.pl 靠它数"到底写了几行"
our @URLS;

sub setRemoteMetadata {
	my ($url, $meta) = @_;
	$CALLS++;
	push @URLS, $url;
	return 1;
}

sub setContentType { return 1 }
sub isRemoteURL   { return 1 }

sub resetForTest { $CALLS = 0; @URLS = (); return }

1;
