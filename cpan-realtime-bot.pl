#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use AnyEvent::HTTP;
use LWP::Simple;
use MIME::Base64;
use URI::Escape;
use Parse::CPAN::Authors;
use CPAN::DistnameInfo;
use Parse::CPAN::Authors;
use YAML;

our $VERSION = "0.1";

my($username, $password) = @ARGV;

my $stat_file = "$FindBin::Bin/lastmod.touch";
my $mailrc    = "$FindBin::Bin/01mailrc.txt.gz";
my $base_uri  = "http://cpan.cpantesters.org/authors";
my $uri       = "$base_uri/RECENT-1h.yaml";

LWP::Simple::mirror("$base_uri/01mailrc.txt.gz", $mailrc);
my $authors = Parse::CPAN::Authors->new($mailrc);

my $last_mod;
my $last_event = (stat($stat_file))[9] || time;
my %done;

unless (-e $stat_file) {
    open my $out, ">", $stat_file or die $!;
}

my $t = AE::timer 0, 30, sub {
    my $hdr = {
        'if-modified-since' => $last_mod,
        'user-agent' => "CPAN-Realtime-Bot/$VERSION (http://friendfeed.com/cpan)",
    };
    http_get $uri, headers => $hdr, sub {
        my($body, $hdr) = @_;
        if ($hdr->{Status} == 200) {
            parse_recent($body);
            $last_mod = $hdr->{'last-modified'};
        } elsif ($hdr->{Status} == 304) {
            #
        } elsif ($hdr->{Status} =~ /^4/) {
            warn "ERROR: $hdr->{Status} $hdr->{Reason}\n";
        }
    };
};

AE::cv->recv;

sub parse_recent {
    my $body = shift;
    my $data = YAML::Load($body);

    my $found = 0;
    for my $item (sort { $a->{epoch} <=> $b->{epoch} } @{$data->{recent}}) {
        if ($item->{epoch} > $last_event) {
            $last_event = $item->{epoch};
            if ($item->{type} eq 'new' && $item->{path} =~ /\.tar\.gz$/ && !$done{$item->{path}}++) {
                got_new_file($item->{path});
                $found++;
            }
        }
    }

    publish_pings() if $found;

    utime $last_event, $last_event, $stat_file;
}

sub got_new_file {
    my $path = shift;
    warn "Got $base_uri/$path\n";

    my $dist = CPAN::DistnameInfo->new("authors/$path");
    my $author = $authors->author($dist->cpanid);
    my $text = sprintf "%s %s by %s", $dist->dist, $dist->version, ($author ? $author->name : $dist->cpanid);

    my $headers = {
        Authorization => "Basic " . MIME::Base64::encode("$username:$password", ""),
        'Content-Type' => 'application/x-www-form-urlencoded',
    };

    my %form = (body => $text, link => "$base_uri/$path", to => 'cpan');
    my $body = join "&", map { "$_=" . URI::Escape::uri_escape($form{$_}) } keys %form;

    http_post "http://friendfeed-api.com/v2/entry", $body, headers => $headers, sub {
        warn $_[0];
    };
}

sub publish_pings {
    my %form = ("hub.mode" => 'publish', "hub.url" => "http://friendfeed.com/cpan?format=atom");
    my $body = join "&", map { "$_=" . URI::Escape::uri_escape($form{$_}) } keys %form;
    for my $hub (qw( http://pubsubhubbub.appspot.com/ http://superfeedr.com/hubbub )) {
        http_post $hub, $body, sub {
            warn "$hub:$_[1]->{Status}";
        }
    }
}
