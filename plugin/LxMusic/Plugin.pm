# Plugins/LxMusic/Plugin.pm
# ============================================================
# v0.1.0-alpha1: engine bootstrap, Web import/diag page,
# XMLBrowser feed (play-test), lxm:// protocol handler wired.
# NOTE: no "use utf8" on purpose - CJK text lives as raw UTF-8
# bytes (page output and log lines are byte-safe as-is).
# ============================================================

package Plugins::LxMusic::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use HTML::Entities qw(encode_entities);
use Time::HiRes qw(time);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::Pages;

use Plugins::LxMusic::Helper;
use Plugins::LxMusic::ProtocolHandler;

my $log = logger('plugin.lxmusic');

my $prefs = preferences('plugin.lxmusic');

sub getDisplayName { 'LX Music' }

sub initPlugin {
	my ($class) = @_;

	$prefs->init({
		sourceContent => '',
		sourceName    => '',
		quality       => '320k',
	});

	unless (Plugins::LxMusic::Helper->init) {
		$log->error('LxMusic: engine init FAILED, check server.log');
	}

	if (my $content = $prefs->get('sourceContent')) {
		my $name = $prefs->get('sourceName') || 'current';
		my $path = Plugins::LxMusic::Helper->installSource($name . '.js', $content);
		$log->info('LxMusic: source restored: ' . ($path || 'FAILED'));
	}

	if (main::WEBUI) {
		Slim::Web::Pages->addPageFunction(
			'plugins/LxMusic/index\.html',
			sub { $class->webHandler(@_) },
		);
	}

	$class->SUPER::initPlugin(
		feed => \&handleFeed,
		tag  => 'lxmusic',
		menu => 'apps',
	);

	$log->info('LxMusic: ready');
	return;
}

sub shutdownPlugin {
	my ($class) = @_;
	Plugins::LxMusic::Helper->shutdown;
	return;
}

# ================================================== feed menu

sub handleFeed {
	my ($client, $cb, $params, $args) = @_;

	my $src    = Plugins::LxMusic::Helper->sourceInfo;
	my $status = $src->{installed}
		? 'source: ' . ($prefs->get('sourceName') || 'current.js')
		: 'source: none (import via web page)';

	my @items = (
		{
			name        => 'Play test (enter song id)',
			type        => 'search',
			url         => \&testHandler,
			passthrough => ['test'],
		},
		{
			name => $status,
			type => 'text',
		},
	);

	$cb->({ items => \@items });
	return;
}

# kw numeric song id -> musicUrl play item
sub testHandler {
	my ($client, $cb, $args) = @_;
	my $input = $args->{search} || '';

	unless ($input =~ /^\s*(\d{4,20})\s*$/) {
		$cb->({ items => [ {
			name => 'enter a numeric kw song id (see web page howto)',
			type => 'text',
		} ] });
		return;
	}
	my $mid = $1;

	my $url = Plugins::LxMusic::ProtocolHandler->buildUrl(
		music => { songmid => $mid },
		src   => 'kw',
		type  => ($prefs->get('quality') || '320k'),
		name  => ('kw #' . $mid),
	);

	$cb->({ items => [ {
		name => 'kw #' . $mid . ' - tap to play',
		type => 'audio',
		url  => $url,
	} ] });
	return;
}

# ================================================== web page

sub webHandler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	my $msg       = '';
	my $testHtml  = '';

	if ($params->{import} && ($params->{source} || $params->{sourceurl})) {
		($msg) = _handleImport($params);
	}

	if (my $mid = $params->{testmid}) {
		if ($mid =~ /^(\d{4,20})$/) {
			return _testMusicUrl($1, $client, $params, $callback, $httpClient, $response);
		}
		$msg = 'bad test id format';
	}

	my $src    = Plugins::LxMusic::Helper->sourceInfo;
	my $status = $src->{installed}
		? 'installed: ' . encode_entities($prefs->get('sourceName') || 'current.js')
		  . ' (' . length($prefs->get('sourceContent') || '') . ' bytes)'
		: 'no source imported';

	my $msgBlock = $msg ? '<div class="msg">' . $msg . '</div>' : '';
	my $testBlock = $testHtml ? '<div class="msg">' . $testHtml . '</div>' : '';

	my $body = _page($status, $msgBlock, $testBlock);
	$response->code(200);
	$response->header('Content-Type' => 'text/html; charset=utf-8');
	$callback->($client, $params, \$body, $httpClient, $response);
	return;
}

sub _handleImport {
	my ($params) = @_;

	my ($content, $name, $err);

	if ($params->{source}) {
		$content = $params->{source};
		$name    = 'pasted';
	}
	else {
		my $u = $params->{sourceurl};
		$u = 'http://' . $u unless $u =~ m{^https?://}i;
		($content, $err) = _fetch($u);
		$name = ($u =~ m{([^/]+)$})[0] || 'downloaded';
	}

	return ('import failed: ' . encode_entities($err)) if $err;
	return 'import failed: empty content'
		unless $content && $content =~ /\S/ && length($content) > 50;

	my $looksOk = $content =~ /(lx\s*\.\s*on|EVENT_NAMES|on\s*\(\s*['"]?request)/;
	my $safe = _safeName($name);
	$prefs->set('sourceContent', $content);
	$prefs->set('sourceName', $safe);
	Plugins::LxMusic::Helper->installSource($safe . '.js', $content);

	return 'imported ' . ($looksOk ? '' : '(WARNING: does not look like an lx source) ')
		. $safe . '.js, ' . length($content) . ' bytes';
}

sub _testMusicUrl {
	my ($mid, $client, $params, $callback, $httpClient, $response) = @_;

	my $sourcePath = Plugins::LxMusic::Helper->currentSourcePath();
	unless ($sourcePath) {
		my $body = _page('no source imported', '', '');
		$response->code(200);
		$response->header('Content-Type' => 'text/html; charset=utf-8');
		$callback->($client, $params, \$body, $httpClient, $response);
		return;
	}

	my $started = time();
	Plugins::LxMusic::Helper->request(
		source   => $sourcePath,
		action   => 'musicUrl',
		sourceId => 'kw',
		info     => {
			musicInfo => { songmid => $mid },
			type      => ($prefs->get('quality') || '320k'),
		},
		timeout  => 20,
		cb       => sub {
			my ($res) = @_;
			my $elapsed = sprintf('%.2f', time() - $started);
			my $text;
			if ($res->{ok} && $res->{data} && !ref($res->{data})) {
				$text = 'OK (' . $elapsed . 's): <a href="'
					. encode_entities($res->{data}) . '">'
					. encode_entities(substr($res->{data}, 0, 120)) . '</a>';
			}
			else {
				$text = 'FAIL (' . $elapsed . 's): '
					. encode_entities($res->{error} || 'unknown');
				my $logs = join("\n", map { encode_entities($_) } @{ $res->{logs} || [] });
				$text .= '<pre>' . $logs . '</pre>' if $logs;
			}
			my $body = _page('', '', '<div class="msg">' . $text . '</div>');
			$response->code(200);
			$response->header('Content-Type' => 'text/html; charset=utf-8');
			$callback->($client, $params, \$body, $httpClient, $response);
		},
	);
	return;
}

# server-side blocking fetch of a subscription url (low frequency op)
sub _fetch {
	my ($url) = @_;
	return (undef, 'url too long') if length($url) > 500;
	return (undef, 'only http/https allowed') unless $url =~ m{^https?://}i;

	my $out = eval {
		local $ENV{PATH} = '/usr/bin:/bin';
		open(my $fh, '-|', '/usr/bin/curl', '-sS', '-L', '--max-time', '30', $url) or die "curl: $!";
		local $/;
		my $s = <$fh>;
		close $fh;
		$s;
	};
	return (undef, "download failed: $@") if $@ || !defined $out;
	return (undef, 'empty download') unless $out =~ /\S/;
	return ($out, undef);
}

sub _safeName {
	my ($name) = @_;
	$name ||= 'source';
	$name =~ s/\.{2,}/_/g;
	$name =~ s/[^\w.-]/_/g;
	$name =~ s/^[.\-]+//;
	$name = 'source' if $name eq '';
	return $name;
}

# static page assembled from byte lines (no heredoc)
sub _page {
	my ($status, $msgBlock, $testBlock) = @_;

	my @l = (
		'<!DOCTYPE html><html><head><meta charset="utf-8">',
		'<meta name="viewport" content="width=device-width, initial-scale=1">',
		'<title>LX Music - settings</title>',
		'<style>',
		'body { font-family: sans-serif; margin: 2em auto; max-width: 52em; padding: 0 1em; color: #222; }',
		'h1 { font-size: 1.4em; } h2 { font-size: 1.1em; margin-top: 1.6em; }',
		'textarea { width: 100%; height: 10em; font-family: monospace; font-size: 12px; }',
		'input[type=text] { width: 60%; }',
		'.msg { padding: .6em 1em; background: #eef; border: 1px solid #ccd; border-radius: 6px; margin: .8em 0; }',
		'.status { color: #555; } pre { background: #f6f6f6; padding: .6em; overflow: auto; max-height: 14em; }',
		'.box { border: 1px solid #ddd; border-radius: 8px; padding: 1em; margin: 1em 0; }',
		'</style></head><body>',
		'<h1>LX Music <span style="font-size:.6em;color:#888">v0.1.0-alpha1</span></h1>',
		'<div class="box"><h2>Source status</h2><p class="status">' . $status . '</p>',
		'<p>quality: 320k (default)</p></div>',
		'<h2>Import source</h2>',
		'<form method="post">',
		'<p>Option 1: paste the lx custom-source script (.js) below</p>',
		'<textarea name="source" placeholder="paste source script here"></textarea>',
		'<p>Option 2: subscription URL (http/https)</p>',
		'<p><input type="text" name="sourceurl" placeholder="https://.../source.js"></p>',
		'<p><button type="submit" name="import" value="1">Import &amp; enable</button></p>',
		'</form>',
		$msgBlock,
		'<h2>Play test (M0.1)</h2>',
		'<form method="get">',
		'<p>Enter a numeric Kuwo song id to test the musicUrl chain:</p>',
		'<p><input type="text" name="testmid" placeholder="e.g. 128908374">',
		'<button type="submit">Run test</button></p>',
		'</form>',
		$testBlock,
		'<p style="color:#999;font-size:.85em">Hint: the numeric id in the Kuwo web-player URL is the song id.</p>',
		'</body></html>',
	);

	return join('', @l);
}

1;
