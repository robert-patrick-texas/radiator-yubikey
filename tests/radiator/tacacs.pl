#!/usr/bin/perl
#
# tacacs.pl - A small TACACS+ client for the tests, on Radiator's own modules
# (Radius::TacacsClient and Radius::Tacacsplus). Unlike Radiator's
# goodies/tacacsplustest, it prints the arguments of an authorization reply,
# can log in to the enable service, and reports a reply of the wrong type.
#
#   tacacs.pl SERVER KEY FROM authen USER PASSWORD [login|enable]
#       -> PASS | FAIL | ERROR
#   tacacs.pl SERVER KEY FROM author USER ARG,ARG,...
#       -> PASS_ADD ARGS... | PASS_REPL ARGS... | FAIL | ERROR | BADTYPE N
#   tacacs.pl SERVER KEY FROM acct USER start|stop
#       -> SUCCESS | ERROR
#
# FROM is the local address to connect from (the device's address). Each
# request uses a new connection, as most devices do.

use lib '/opt/radiator/radiator', '/opt/radiator/radiator-radius-utilxs';
use strict;
use warnings;
use Radius::TacacsClient;
use Radius::Tacacsplus;
use IO::Socket::IP;

# Radius::TacacsClient connects to an IPv6 server with IO::Socket::INET6
# (libio-socket-inet6-perl), which the test image doesn't have; Perl's own
# IO::Socket::IP takes the same arguments.
unless (eval { require IO::Socket::INET6 }) {
    $INC{'IO/Socket/INET6.pm'} = __FILE__;
    @IO::Socket::INET6::ISA = ('IO::Socket::IP');
}

# Radiator's modules log through these; the tests want only the answers.
no warnings 'redefine';
sub main::log {}
sub main::willLog { 0 }

my ($server, $key, $from, $op, $user, @rest) = @ARGV;
die "usage: $0 SERVER KEY FROM authen|author|acct USER ...\n" unless defined $user;
my $c = Radius::TacacsClient->new(Host => $server, Port => 49, Key => $key,
                                  LocalAddr => $from, Timeout => 5)
    or die "cannot connect to $server: $!\n";
my %rem = (Userport => 'tty1', RemoteAddress => '198.51.100.7', Username => $user);

if ($op eq 'authen') {
    my ($pw, $svc) = @rest;
    my $enable = ($svc // 'login') eq 'enable';
    my @r = $c->authentication(%rem, SessionId => int(rand(1e9)), Password => $pw,
        Service => $enable ? $Radius::Tacacsplus::TAC_PLUS_AUTHEN_SVC_ENABLE
                           : $Radius::Tacacsplus::TAC_PLUS_AUTHEN_SVC_LOGIN,
        PrivLevel => $enable ? 15 : 1);
    my $st = $r[5];
    print !defined $st ? "ERROR\n"
        : $st == $Radius::Tacacsplus::TAC_PLUS_AUTHEN_STATUS_PASS ? "PASS\n"
        : $st == $Radius::Tacacsplus::TAC_PLUS_AUTHEN_STATUS_FAIL ? "FAIL\n" : "ERROR $st\n";
} elsif ($op eq 'author') {
    $c->reconnect() or do { print "ERROR\n"; exit };
    my $req = Radius::Tacacsplus::pack_authorization_request(1, 0, int(rand(1e9)),
        $Radius::Tacacsplus::TAC_PLUS_AUTHEN_METH_TACACSPLUS, 1, $Radius::Tacacsplus::TAC_PLUS_AUTHEN_TYPE_ASCII,
        $Radius::Tacacsplus::TAC_PLUS_AUTHEN_SVC_LOGIN, $user, $rem{Userport}, $rem{RemoteAddress}, $key,
        split(/,/, $rest[0] // ''));
    $c->{_socket}->send($req);
    my ($v, $type, undef, undef, undef, $body) = Radius::Tacacsplus::recv_response($c->{_socket}, $key);
    if (!defined $v) { print "ERROR\n"; exit }
    if ($type != $Radius::Tacacsplus::TAC_PLUS_AUTHOR) { print "BADTYPE $type\n"; exit }
    my ($st, undef, undef, @args) = Radius::Tacacsplus::unpack_authorization_response($body);
    my %name = ($Radius::Tacacsplus::TAC_PLUS_AUTHOR_STATUS_PASS_ADD  => 'PASS_ADD',
                $Radius::Tacacsplus::TAC_PLUS_AUTHOR_STATUS_PASS_REPL => 'PASS_REPL',
                $Radius::Tacacsplus::TAC_PLUS_AUTHOR_STATUS_FAIL      => 'FAIL');
    print join(' ', $name{$st} // 'ERROR', @args), "\n";
} elsif ($op eq 'acct') {
    my @r = $c->accounting(%rem, SessionId => 77, AcctArgs => ['task_id=7', 'service=shell'],
        AFlags => ($rest[0] // '') eq 'stop' ? $Radius::Tacacsplus::TAC_PLUS_ACCT_STOP
                                             : $Radius::Tacacsplus::TAC_PLUS_ACCT_START);
    print defined $r[5] && $r[5] == $Radius::Tacacsplus::TAC_PLUS_ACCT_STATUS_SUCCESS ? "SUCCESS\n" : "ERROR\n";
} else {
    die "unknown operation '$op'\n";
}
