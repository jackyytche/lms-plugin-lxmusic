# t/Slim/Utils/Prefs.pm — 存根
package Slim::Utils::Prefs;

use strict;
use warnings;
use base 'Exporter';

our @EXPORT = qw(preferences);

sub preferences {
	my ($name) = @_;
	return Slim::Utils::Prefs::Stub->new;
}

package Slim::Utils::Prefs::Stub;

sub new   { my $c = shift; return bless {}, $c }
sub init  { my $s = shift; $s->{defaults} = \@_ }
sub get   { my ($s, $k) = @_; return $s->{vals}{$k} }
sub set   { my ($s, $k, $v) = @_; $s->{vals}{$k} = $v; return $v }

1;
