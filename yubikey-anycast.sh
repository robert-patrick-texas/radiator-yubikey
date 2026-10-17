#!/usr/bin/env bash
#
# yubikey-anycast.sh - Advertise Radiator's anycast addresses from this server
#                      only while its Radiator accepts logins.
#
# VERSION
#   In the file VERSION, next to this script; -V shows it.
#
# HOW IT WORKS
#   Every Radiator server has the same anycast addresses (one IPv4, one IPv6),
#   and FRR advertises them to the site's router with BGP while they are on
#   this server's loopback interface (lo). This script puts them there and
#   takes them away:
#     - Every INTERVAL seconds it logs in to the local Radiator (127.0.0.1)
#       as anycast-HOSTNAME, with a PIN and an OTP made from its own YubiKey
#       key, and checks that Radiator listens on the anycast addresses.
#     - With TACACS_KEY set, it also logs in over TACACS+ at the same time,
#       as the service account svc.anycast-HOSTNAME with its password, asks
#       for the session's authorization, as a network device does, and
#       checks that Radiator listens on TCP port TACACS_PORT on the anycast
#       addresses.
#     - After RISE good checks in a row it adds the addresses to lo, and FRR
#       advertises them. After FALL failed checks in a row it removes them;
#       FRR withdraws them, and the routers send RADIUS to another site.
#     - When it stops, it removes them.
#   A good check is an accepted login: Radiator works, it reaches the
#   database's primary, and the primary saved the OTP's counter. With
#   TACACS+, both logins must pass: the TACACS+ one also proves Radiator's
#   TACACS+ service, and its password and group checks.
#
#   Like a YubiKey, the check counts its OTPs with a usage counter, saved on
#   disk and raised by one each time the check starts, and a session counter
#   (0-255) kept in memory. Radiator accepts usage counters up to 32767, so
#   one key makes about 8.4 million OTPs: 485 days at one check every 5 s.
#   'status' shows how many are left; 'enroll' makes a new key.
#
#   The running check renews its key by itself every RENEW_DAYS days (or
#   sooner, when fewer than 30 days of OTPs are left), after a good check:
#   it gives the key a new private ID and AES key, in the database and in
#   its key file, and starts its counters again. It writes to the database
#   with Radiator's own login (from yubikey-cluster.conf, or yubikey.conf),
#   through the function anycast_renew, which changes only the keys of
#   anycast-* users ('yubikey-db.sh -b pg init' makes it). PostgreSQL only;
#   never in partition mode.
#
# COMMANDS
#   enroll         Make a new key for the check, and print it as CSV for
#                  'yubikey-db.sh import --replace -' (stop the check first)
#   enroll-tacacs  Make a new password for the TACACS+ login's service
#                  account, svc.anycast-HOSTNAME, and print it for
#                  'yubikey-db.sh service add' (stop the check first)
#   check          Log in once and print the result (not while the check
#                  runs)
#   renew          Renew the key now, as the running check does every
#                  RENEW_DAYS days (not while the check runs)
#   run            Run the check (yubikey-anycast.service does this)
#   status         Show whether the addresses are on lo, and the last check;
#                  exits 0 only while they are
#   withdraw       Remove the addresses from lo
#
# OPTIONS
#   -c FILE   The settings (default /etc/radiator/anycast.conf)
#
# FILES
#   /etc/radiator/anycast.conf        settings: see yubikey-anycast.example.conf
#   /var/lib/yubikey-anycast/key      the check's user name, PIN and YubiKey
#                                     values (mode 0600)
#   /var/lib/yubikey-anycast/counter  the last usage counter used
#   /var/lib/yubikey-anycast/key.next a renewed key whose renewal didn't
#                                     finish (the database's answer was lost)
#   /var/lib/yubikey-anycast/tacacs   the TACACS+ login's service account and
#                                     password (mode 0600)
#   /run/yubikey-anycast/status       the last check, written by 'run'
#
# PREREQUISITES
#   Ubuntu 26.04 LTS, as root. perl with Crypt::Rijndael (which Radiator's
#   YubiKey support needs too), iproute2 (ip, ss) and util-linux (flock).
#   net.ipv4.ip_nonlocal_bind=1 and net.ipv6.ip_nonlocal_bind=1, so that
#   Radiator can listen on the anycast addresses while they are not on lo.
#   Radiator's <Client 127.0.0.1>, and its Handler for anycast-* users from
#   radiator.example.conf. For TACACS+: radiator-groups.example.conf (its
#   <ServerTACACSPLUS>, and its Handlers for anycast-* and svc.anycast-*
#   users), the TACACSPLUSKey of <Client 127.0.0.1>, and a group that the
#   service account is in, with access to device group localhost. To renew
#   the key: PostgreSQL, psql (postgresql-client), and Radiator's login with
#   a password in its clause (as from another host).
#
# EXIT STATUS
#   0 success; 1 the check failed (check), or the addresses are not
#   advertised (status); 3 a problem with the settings, the key or the
#   system, which a restart won't fix.
#
# ENVIRONMENT (for tests)
#   ANYCAST_STATE_DIR  instead of /var/lib/yubikey-anycast
#   ANYCAST_RUN_DIR    instead of /run/yubikey-anycast
#   PROC_SYS           instead of /proc/sys
#   ANYCAST_CONF_D     instead of /etc/radiator/conf.d
#   IP, SS, PSQL       the ip, ss and psql commands to use

set -uo pipefail
shopt -s extglob
umask 077   # the key file holds the AES key and the PIN, the tacacs file a password

PROG=${0##*/}
# The version is in the file VERSION, next to this script (the package has it
# written here instead).
VERSION=$(cat -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/VERSION" 2>/dev/null) || VERSION=unknown
CONF=/etc/radiator/anycast.conf
STATE_DIR=${ANYCAST_STATE_DIR:-/var/lib/yubikey-anycast}
RUN_DIR=${ANYCAST_RUN_DIR:-/run/yubikey-anycast}
PROC_SYS=${PROC_SYS:-/proc/sys}
CONF_D=${ANYCAST_CONF_D:-/etc/radiator/conf.d}
IP=${IP:-ip}
SS=${SS:-ss}
PSQL=${PSQL:-psql}
MAX_COUNTER=32767   # Radiator ignores the usage counter's top bit

# Settings, from the settings file
ADDRESSES='' SECRET='' PORT=1812 INTERVAL=5 TIMEOUT=3 FALL=3 RISE=2
TACACS_KEY='' TACACS_PORT=49 RENEW_DAYS=365
ADDR4=() ADDR6=()   # the anycast addresses, checked and written the way ip shows them
# The check's key, from the key file
K_USER='' K_PIN='' K_PUBLIC='' K_PRIVATE='' K_AES='' K_MADE=''
# The TACACS+ login's service account, from the tacacs file
T_USER='' T_PASSWORD=''

die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 3; }
log()  { printf '%s\n' "$*"; }

usage() {
    cat <<EOF
Usage: $PROG [-c FILE] COMMAND

Commands:
  enroll         Make a new key for the check, and print it as CSV for
                 'yubikey-db.sh import --replace -' (stop the check first)
  enroll-tacacs  Make a new password for the TACACS+ login's service
                 account, svc.anycast-HOSTNAME, and print it for
                 'yubikey-db.sh service add' (stop the check first)
  check          Log in once and print the result (not while the check
                 runs)
  renew          Renew the key now, as the running check does every
                 RENEW_DAYS days (not while the check runs)
  run            Run the check (yubikey-anycast.service does this)
  status         Show whether the addresses are on lo, and the last check;
                 exits 0 only while they are
  withdraw       Remove the addresses from lo

Options:
  -c FILE   The settings (default $CONF)
  -h        Show this help
  -V        Show the version

Example:
  sudo systemctl stop yubikey-anycast
  sudo $PROG enroll | ./yubikey-db.sh -b pg import --replace -
  sudo $PROG enroll-tacacs | ./yubikey-db.sh -b pg service add svc.anycast-\$(hostname -s)
  sudo $PROG check
  sudo systemctl start yubikey-anycast
EOF
}

# --------------------------------------------------------------------------
# Settings and key
# --------------------------------------------------------------------------

# read_pairs FILE CALLBACK: call CALLBACK NAME VALUE LINE for each NAME=value
# line of FILE. Blank lines and lines starting with # are skipped; a value may
# be in single or double quotes. The file is never run as shell code.
read_pairs() {
    local file=$1 callback=$2 line n=0 name value
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line =~ ^[[:space:]]*([A-Za-z_]+)[[:space:]]*=(.*)$ ]] || die "$file line $n: expected NAME=value"
        name=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        value=${value#"${value%%[![:space:]]*}"} value=${value%"${value##*[![:space:]]}"}
        if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
        "$callback" "$name" "$value" "$n"
    done <"$file"
}

conf_pair() {
    case $1 in
        ADDRESSES|SECRET|PORT|INTERVAL|TIMEOUT|FALL|RISE|TACACS_KEY|TACACS_PORT|RENEW_DAYS) printf -v "$1" '%s' "$2" ;;
        *) die "$CONF line $3: unknown setting '$1'" ;;
    esac
}

# number NAME MIN MAX: check the setting NAME.
number() {
    local v=${!1}
    if ! [[ $v =~ ^[0-9]{1,5}$ ]] || ((10#$v < $2 || 10#$v > $3)); then
        die "$CONF: $1 must be a number from $2 to $3"
    fi
    printf -v "$1" '%d' "$((10#$v))"
}

load_conf() {
    [[ -f $CONF && -r $CONF ]] || die "cannot read $CONF"
    read_pairs "$CONF" conf_pair
    [[ -n $ADDRESSES ]] || die "$CONF: ADDRESSES is not set"
    [[ -n $SECRET ]] || die "$CONF: SECRET is not set"
    number PORT 1 65535
    number INTERVAL 1 3600
    number TIMEOUT 1 60
    ((TIMEOUT <= INTERVAL)) || die "$CONF: TIMEOUT must not be longer than INTERVAL"
    number FALL 1 100
    number RISE 1 100
    number TACACS_PORT 1 65535
    number RENEW_DAYS 0 3650
    # Check each address, and write it the way ip and ss show it.
    local family addr
    # shellcheck disable=SC2086  # ADDRESSES is a list
    while read -r family addr; do
        case $family in
            4) ADDR4+=("$addr") ;;
            6) ADDR6+=("$addr") ;;
            *) die "$CONF: '$addr' in ADDRESSES is not an IPv4 or IPv6 address" ;;
        esac
    done < <(perl -MSocket=inet_pton,inet_ntop,AF_INET,AF_INET6 -e '
        for (@ARGV) {
            if (defined(my $p = inet_pton(AF_INET, $_)))         { print "4 ", inet_ntop(AF_INET, $p), "\n" }
            elsif (/:/ && defined($p = inet_pton(AF_INET6, $_))) { print "6 ", inet_ntop(AF_INET6, $p), "\n" }
            else                                                 { print "? $_\n" }
        }' -- $ADDRESSES)
    ((${#ADDR4[@]} + ${#ADDR6[@]} > 0)) || die "$CONF: ADDRESSES has no address"
}

key_pair() {
    case $1 in
        user)       K_USER=$2 ;;
        pin)        K_PIN=$2 ;;
        public_id)  K_PUBLIC=$2 ;;
        private_id) K_PRIVATE=$2 ;;
        aes_key)    K_AES=$2 ;;
        made)       K_MADE=$2 ;;
        *) die "$STATE_DIR/key line $3: unknown name '$1'" ;;
    esac
}

load_key() {
    [[ -f $STATE_DIR/key ]] || die "no key in $STATE_DIR/key: run '$PROG enroll' first"
    read_pairs "$STATE_DIR/key" key_pair
    [[ $K_USER =~ ^anycast-[a-z0-9-]+$ && $K_PIN =~ ^[A-Za-z0-9]{8,}$ \
       && $K_PUBLIC =~ ^[cbdefghijklnrtuv]{12}$ && $K_PRIVATE =~ ^[0-9a-f]{12}$ \
       && $K_AES =~ ^[0-9a-f]{32}$ && $K_MADE =~ ^[0-9]{0,12}$ ]] || die "$STATE_DIR/key is damaged: run '$PROG enroll' again"
    # A key made before 1.10.0 has no made= line: it was made when its file
    # was written.
    [[ -n $K_MADE ]] || K_MADE=$(stat -c %Y "$STATE_DIR/key") || die "cannot read $STATE_DIR/key"
}

# write_key FILE PRIVATE_ID AES_KEY MADE: write a key with K_USER, K_PIN and
# K_PUBLIC to FILE, flushed to disk.
write_key() {
    if ! { printf '%s\n' "user=$K_USER" "pin=$K_PIN" "public_id=$K_PUBLIC" "private_id=$2" "aes_key=$3" "made=$4" \
               >"$1.new" && sync "$1.new" && mv -f "$1.new" "$1" && sync "$STATE_DIR"; }; then
        die "cannot write $1"
    fi
}

tacacs_pair() {
    case $1 in
        user)     T_USER=$2 ;;
        password) T_PASSWORD=$2 ;;
        *) die "$STATE_DIR/tacacs line $3: unknown name '$1'" ;;
    esac
}

# load_tacacs: with TACACS_KEY set, read the TACACS+ login's account.
load_tacacs() {
    [[ -n $TACACS_KEY ]] || return 0
    [[ -f $STATE_DIR/tacacs ]] || die "no $STATE_DIR/tacacs (TACACS_KEY is set): run '$PROG enroll-tacacs' first"
    read_pairs "$STATE_DIR/tacacs" tacacs_pair
    [[ $T_USER =~ ^svc\.anycast-[a-z0-9-]+$ && $T_PASSWORD =~ ^[[:graph:]]{12,}$ ]] \
        || die "$STATE_DIR/tacacs is damaged: run '$PROG enroll-tacacs' again"
}

# read_counter: set COUNTER to the last usage counter used, from its file.
COUNTER=0
read_counter() {
    [[ -f $STATE_DIR/counter ]] || die "no $STATE_DIR/counter: run '$PROG enroll' first"
    COUNTER=$(<"$STATE_DIR/counter")
    [[ $COUNTER =~ ^[0-9]{1,5}$ ]] || die "$STATE_DIR/counter is damaged: run '$PROG enroll' again"
    COUNTER=$((10#$COUNTER))
}

# save_counter N: write the usage counter, and flush it to disk before it is
# used, so that no OTP is made twice even after a power loss.
save_counter() {
    if ! { printf '%d\n' "$1" >"$STATE_DIR/counter.new" && sync "$STATE_DIR/counter.new" \
           && mv -f "$STATE_DIR/counter.new" "$STATE_DIR/counter" && sync "$STATE_DIR"; }; then
        die "cannot write $STATE_DIR/counter"
    fi
}

# lock: hold the lock on the check's files until this script ends, or fail.
lock() {
    install -d -m 0700 "$STATE_DIR" || die "cannot create $STATE_DIR"
    exec 9>>"$STATE_DIR/lock" || die "cannot open $STATE_DIR/lock"
    flock -n 9 || die "the check is running (systemctl stop yubikey-anycast first)"
}

# running: whether 'run' holds the lock.
running() { [[ -f $STATE_DIR/lock ]] && ! flock -n "$STATE_DIR/lock" true 2>/dev/null; }

# --------------------------------------------------------------------------
# The addresses on lo
# --------------------------------------------------------------------------

# The anycast addresses that are on lo now.
on_lo() {
    local have a
    have=" $("$IP" -o addr show dev lo 2>/dev/null | awk '{print $4}' | tr '\n' ' ') "
    for a in "${ADDR4[@]}"; do [[ $have == *" $a/32 "* ]] && printf '%s\n' "$a"; done
    for a in "${ADDR6[@]}"; do [[ $have == *" $a/128 "* ]] && printf '%s\n' "$a"; done
    return 0
}

# put_on_lo / take_off_lo: add or remove the addresses that are missing or
# still there. Prints an error for each that fails.
put_on_lo() {
    local have a
    have=" $(on_lo | tr '\n' ' ') "
    for a in "${ADDR4[@]}"; do
        [[ $have == *" $a "* ]] || "$IP" -4 addr add "$a/32" dev lo || log "error: cannot add $a to lo"
    done
    for a in "${ADDR6[@]}"; do
        [[ $have == *" $a "* ]] || "$IP" -6 addr add "$a/128" dev lo nodad || log "error: cannot add $a to lo"
    done
}
take_off_lo() {
    local a
    while read -r a; do
        if [[ $a == *:* ]]; then "$IP" -6 addr del "$a/128" dev lo; else "$IP" -4 addr del "$a/32" dev lo; fi \
            || log "error: cannot remove $a from lo"
    done < <(on_lo)
}

# not_listening u|t PORT: the anycast addresses Radiator doesn't listen on,
# over UDP (u) or TCP (t), at PORT.
not_listening() {
    local have a
    have=" $("$SS" "-Hl${1}n" 2>/dev/null | awk '{print $4}' | tr '\n' ' ') "
    for a in "${ADDR4[@]}"; do [[ $have == *" $a:$2 "* ]] || printf '%s\n' "$a"; done
    for a in "${ADDR6[@]}"; do [[ $have == *" [$a]:$2 "* ]] || printf '%s\n' "$a"; done
    return 0
}

# --------------------------------------------------------------------------
# One login
# --------------------------------------------------------------------------

# The login, in Perl: makes the OTP, sends an Access-Request to Radiator on
# 127.0.0.1, and prints one line: "ACCEPT in N ms", "REJECT in N ms: REASON",
# "NO REPLY within N s" or "NO REPLY: ERROR". Its input, on standard input
# (never on a command line), is NAME=value lines.
# shellcheck disable=SC2016  # Perl code, not shell
LOGIN_PL='
use strict;
use warnings;
use Socket qw(PF_INET SOCK_DGRAM inet_aton pack_sockaddr_in);
use Digest::MD5 qw(md5);
use Time::HiRes qw(time);

my %a;
while (<STDIN>) { chomp; my ($k, $v) = split /=/, $_, 2; $a{$k} = $v }
eval { require Crypt::Rijndael; 1 }
    or do { print "ERROR: the Perl module Crypt::Rijndael is missing (libcrypt-rijndael-perl)\n"; exit };
open my $ur, "<:raw", "/dev/urandom" or die "/dev/urandom: $!\n";
read($ur, my $rnd, 22) == 22 or die "/dev/urandom: short read\n";

# The OTP, as a YubiKey makes it: private ID, usage counter, timestamp
# (3 bytes), session counter, random (2 bytes), CRC-16; AES-encrypted, in
# modhex, after the public ID.
my $token = pack("H12 v a3 C a2", $a{private_id}, $a{counter}, substr($rnd, 0, 3),
                 $a{session}, substr($rnd, 3, 2));
my $crc = 0xffff;
for my $b (unpack "C*", $token) {
    $crc ^= $b;
    for (1 .. 8) { my $lsb = $crc & 1; $crc >>= 1; $crc ^= 0x8408 if $lsb }
}
$token .= pack("v", ~$crc & 0xffff);
my $aes = Crypt::Rijndael->new(pack("H32", $a{aes_key}), Crypt::Rijndael::MODE_ECB());
(my $otp = unpack("H*", $aes->encrypt($token))) =~ tr/0-9a-f/cbdefghijklnrtuv/;
my $password = "$a{pin}:$a{public_id}$otp";

# The Access-Request (RFC 2865), with a Message-Authenticator (RFC 3579)
# first.
sub attr { pack("C C", $_[0], 2 + length $_[1]) . $_[1] }
sub hmac_md5 {
    my ($k, $m) = @_;
    $k = md5($k) if length $k > 64;
    $k .= "\0" x (64 - length $k);
    md5(($k ^ ("\x5c" x 64)) . md5(($k ^ ("\x36" x 64)) . $m));
}
my $id = ord substr($rnd, 5, 1);
my $auth = substr($rnd, 6, 16);
my $pw = $password . ("\0" x ((16 - length($password) % 16) % 16));
my ($hidden, $prev) = ("", $auth);
for (my $i = 0; $i < length $pw; $i += 16) {
    $prev = substr($pw, $i, 16) ^ md5($a{secret} . $prev);
    $hidden .= $prev;
}
my $attrs = attr(80, "\0" x 16) . attr(1, $a{user}) . attr(2, $hidden)
          . attr(4, inet_aton("127.0.0.1")) . attr(32, "yubikey-anycast");
my $req = pack("C C n", 1, $id, 20 + length $attrs) . $auth . $attrs;
substr($req, 22, 16) = hmac_md5($a{secret}, $req);

socket(my $s, PF_INET, SOCK_DGRAM, 0) or die "socket: $!\n";
connect($s, pack_sockaddr_in($a{port}, inet_aton("127.0.0.1"))) or die "connect: $!\n";
my $start = time;
send($s, $req, 0) or do { print "NO REPLY: $!\n"; exit };
my $rin = "";
vec($rin, fileno $s, 1) = 1;
while ((my $left = $start + $a{timeout} - time) > 0) {
    select(my $rout = $rin, undef, undef, $left) > 0 or last;
    # Nothing listening on the port: "Connection refused".
    defined recv($s, my $rep, 4096, 0) or do { print "NO REPLY: $!\n"; exit };
    next if length $rep < 20;
    my ($code, $rid, $len) = unpack "C C n", $rep;
    next if $rid != $id || $len < 20 || $len > length $rep;
    $rep = substr($rep, 0, $len);
    # Only a reply signed with the same secret counts.
    next if md5(substr($rep, 0, 4) . $auth . substr($rep, 20) . $a{secret}) ne substr($rep, 4, 16);
    my $ms = int((time - $start) * 1000 + 0.5);
    my @msg;
    for (my $i = 20; $i + 2 <= $len; ) {
        my ($t, $l) = unpack "C C", substr($rep, $i, 2);
        last if $l < 2;
        push @msg, substr($rep, $i + 2, $l - 2) if $t == 18;   # Reply-Message
        $i += $l;
    }
    if    ($code == 2) { print "ACCEPT in $ms ms\n" }
    elsif ($code == 3) { print "REJECT in $ms ms", (@msg ? ": " . join(" ", @msg) : ""), "\n" }
    else               { print "UNEXPECTED REPLY (code $code) in $ms ms\n" }
    exit;
}
print "NO REPLY within $a{timeout} s\n";
'

# The TACACS+ login, in Perl, as a network device makes one (RFC 8907): an
# ASCII login (the user name, then the password when Radiator asks for it),
# then, on a new connection, the authorization of the session (service=shell
# cmd*). It prints one line: "PASS in N ms" (both passed), "FAIL in N ms",
# "authorization FAIL in N ms" (each with Radiator's message, if any),
# "ERROR ...", "NO REPLY within N s", "NO REPLY: ERROR", "CLOSED in N ms"
# (Radiator closed the connection) or "BAD REPLY in N ms (wrong
# TACACS_KEY?)". Its input, on standard input, is NAME=value lines.
# shellcheck disable=SC2016  # Perl code, not shell
TACACS_PL='
use strict;
use warnings;
use IO::Socket::INET;
use Digest::MD5 qw(md5);
use Time::HiRes qw(time);

my %a;
while (<STDIN>) { chomp; my ($k, $v) = split /=/, $_, 2; $a{$k} = $v }
open my $ur, "<:raw", "/dev/urandom" or die "/dev/urandom: $!\n";
my $start = time;
my $deadline = $start + $a{timeout};
my ($port, $rem) = ("yubikey-anycast", "127.0.0.1");

sub done { print @_, "\n"; exit }
sub ms { int((time - $start) * 1000 + 0.5) . " ms" }
sub no_reply { done(!defined $_[0] || time >= $deadline ? "NO REPLY within $a{timeout} s" : "NO REPLY: $_[0]") }
sub bad { done("BAD REPLY in ", ms(), " (wrong TACACS_KEY?)") }

# A packet body is hidden by XOR with MD5 hashes of the session ID, the
# key, the version, the sequence number and the hash before.
sub hide {
    my ($sid, $ver, $seq, $body) = @_;
    my ($out, $pad) = ("", "");
    for (my $i = 0; $i < length $body; $i += 16) {
        $pad = md5(pack("N", $sid) . $a{key} . pack("C C", $ver, $seq) . $pad);
        $out .= substr($body, $i, 16) ^ $pad;
    }
    substr($out, 0, length $body);
}

# A new connection, with a new session ID.
sub session {
    my $left = $deadline - time;
    $left > 0 or no_reply();
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1", PeerPort => $a{port}, Proto => "tcp",
                                  Timeout => $left) or no_reply($!);
    read($ur, my $r, 4) == 4 or die "/dev/urandom: short read\n";
    { s => $s, sid => unpack("N", $r) };
}

# request SESSION TYPE SEQ BODY: send a packet (version 12.0), and return
# the body of the reply, SEQ + 1.
sub request {
    my ($c, $type, $seq, $body) = @_;
    my $ver = 0xc0;
    defined syswrite($c->{s}, pack("C C C C N N", $ver, $type, $seq, 0, $c->{sid}, length $body)
                              . hide($c->{sid}, $ver, $seq, $body)) or no_reply($!);
    my $buf = "";
    while (1) {
        if (length $buf >= 12) {
            my ($v, $t, $sq, undef, $sid, $len) = unpack "C C C C N N", $buf;
            bad() if $v >> 4 != 0xc || $t != $type || $sq != $seq + 1 || $sid != $c->{sid} || $len > 65535;
            return hide($sid, $v, $sq, substr($buf, 12, $len)) if length $buf >= 12 + $len;
        }
        my $left = $deadline - time;
        my $rin = "";
        vec($rin, fileno $c->{s}, 1) = 1;
        $left > 0 && select(my $rout = $rin, undef, undef, $left) > 0 or no_reply();
        my $n = sysread($c->{s}, $buf, 4096, length $buf);
        defined $n or no_reply($!);
        $n or done("CLOSED in ", ms());
    }
}

# The status and message of an authentication reply.
sub authen_reply {
    my $b = shift;
    length $b >= 6 or bad();
    my ($st, undef, $ml, $dl) = unpack "C C n n", $b;
    6 + $ml + $dl == length $b or bad();
    ($st, substr($b, 6, $ml));
}
sub with_msg { length $_[0] ? ": $_[0]" : "" }

# The login: START (action login, privilege level 1, ASCII, service login),
# then the password in a CONTINUE when Radiator asks for it (GETPASS).
my $c = session();
my ($st, $msg) = authen_reply(request($c, 1, 1, pack("C8", 1, 1, 1, 1, length $a{user}, length $port, length $rem, 0)
                                                . $a{user} . $port . $rem));
($st, $msg) = authen_reply(request($c, 1, 3, pack("n n C", length $a{password}, 0, 0) . $a{password})) if $st == 5;
close $c->{s};
$st == 1 or done($st == 2 ? "FAIL" : $st == 7 ? "ERROR" : "UNEXPECTED REPLY (status $st)", " in ", ms(), with_msg($msg));

# The authorization of the session, by TACACS+ (method 6), on a new
# connection.
$c = session();
my @args = ("service=shell", "cmd*");
my $b = request($c, 2, 1, pack("C8", 6, 1, 1, 1, length $a{user}, length $port, length $rem, scalar @args)
                          . pack("C*", map { length } @args) . $a{user} . $port . $rem . join("", @args));
close $c->{s};
length $b >= 6 or bad();
my ($ast, $n, $ml, $dl) = unpack "C C n n", $b;
my $total = 6 + $n + $ml + $dl;
$total += $_ for unpack "C*", substr($b, 6, $n);
$total == length $b or bad();
$msg = substr($b, 6 + $n, $ml);
# PASS_ADD (1) or PASS_REPL (2): the session may start.
done("PASS in ", ms()) if $ast == 1 || $ast == 2;
done($ast == 0x10 ? "authorization FAIL" : $ast == 0x11 ? "authorization ERROR" : "UNEXPECTED authorization REPLY (status $ast)",
     " in ", ms(), with_msg($msg));
'

# attempt COUNTER SESSION: one login with that OTP, and with TACACS_KEY set,
# the TACACS+ login at the same time; then, for each one that passed, check
# that Radiator listens on the anycast addresses. Sets RESULT, one line for
# both ("ACCEPT in 12 ms; TACACS+ PASS in 9 ms"), RADIUS_RESULT, and GOOD,
# 1 when both passed.
RESULT='' RADIUS_RESULT='' GOOD=0
attempt() {
    local out tacacs='' fd missing
    if [[ -n $TACACS_KEY ]]; then
        exec {fd}< <(printf '%s\n' "key=$TACACS_KEY" "port=$TACACS_PORT" "timeout=$TIMEOUT" \
                         "user=$T_USER" "password=$T_PASSWORD" | perl -e "$TACACS_PL" 2>&1)
    fi
    out=$(printf '%s\n' "secret=$SECRET" "port=$PORT" "timeout=$TIMEOUT" "user=$K_USER" \
              "pin=$K_PIN" "public_id=$K_PUBLIC" "private_id=$K_PRIVATE" "aes_key=$K_AES" \
              "counter=$1" "session=$2" | perl -e "$LOGIN_PL" 2>&1)
    out=${out:-ERROR: no result}
    out=${out%%$'\n'*}
    GOOD=0
    if [[ $out == ACCEPT* ]]; then
        missing=$(not_listening u "$PORT" | paste -sd' ')
        if [[ -n $missing ]]; then out="$out, but Radiator does not listen on $missing port $PORT"; else GOOD=1; fi
    fi
    RADIUS_RESULT=$out
    if [[ -n $TACACS_KEY ]]; then
        tacacs=$(cat <&"$fd")
        exec {fd}<&-
        tacacs=${tacacs:-ERROR: no result}
        tacacs=${tacacs%%$'\n'*}
        if [[ $tacacs == PASS* ]]; then
            missing=$(not_listening t "$TACACS_PORT" | paste -sd' ')
            [[ -z $missing ]] || tacacs="$tacacs, but Radiator does not listen on $missing TCP port $TACACS_PORT"
        fi
        [[ $tacacs == PASS* && $tacacs != *", but "* ]] || GOOD=0
        out="$out; TACACS+ $tacacs"
    fi
    RESULT=$out
}

# otps_left COUNTER SESSION: how many OTPs this key has left after that one.
otps_left() { echo $(((MAX_COUNTER - $1) * 256 + 255 - $2)); }

days() { echo $(($1 * INTERVAL / 86400)); }

# --------------------------------------------------------------------------
# Renewing the key
# --------------------------------------------------------------------------

# The clause with Radiator's database login: yubikey-cluster.conf when
# partition mode is set up (yubikey.conf is then a link to it, or to the
# copy's clause), else yubikey.conf.
radiator_clause() {
    if [[ -f $CONF_D/yubikey-cluster.conf ]]; then
        printf '%s\n' "$CONF_D/yubikey-cluster.conf"
    else
        printf '%s\n' "$CONF_D/yubikey.conf"
    fi
}

partition_mode() { [[ $(readlink "$CONF_D/yubikey.conf" 2>/dev/null) == yubikey-partition.conf ]]; }

# db_query SQL: run SQL in Radiator's database, logged in as Radiator is
# (the DBSource, DBUsername and DBAuth of its clause), and print the answer,
# or the first line of the error. Returns 1 when it failed (try again
# later), 2 when it can't work here. The password goes through a password
# file, never a command line. HOME is RUN_DIR: in yubikey-anycast.service,
# root's home can't be read (ProtectHome, and no CAP_DAC_OVERRIDE), and
# libpq refuses to connect over TLS when it can't tell whether
# ~/.postgresql/postgresql.crt exists.
db_query() {
    local file dsn user pass conninfo pf out rc
    file=$(radiator_clause)
    [[ -r $file ]] || { echo "cannot read $file"; return 2; }
    dsn=$(sed -n 's/^[[:space:]]*DBSource[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$file" | head -1)
    [[ $dsn == dbi:Pg:* ]] || { echo "Radiator's database (DBSource in $file) isn't PostgreSQL"; return 2; }
    command -v "$PSQL" >/dev/null || { echo "psql is missing (sudo apt install postgresql-client)"; return 2; }
    user=$(sed -n 's/^[[:space:]]*DBUsername[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$file" | head -1)
    pass=$(sed -n 's/^[[:space:]]*DBAuth[[:space:]]\{1,\}\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$file" | head -1)
    conninfo=${dsn#dbi:Pg:}
    conninfo=${conninfo//;/ }
    [[ -n $user ]] && conninfo+=" user=$user"
    mkdir -p "$RUN_DIR" || { echo "cannot create $RUN_DIR"; return 2; }
    pf=$RUN_DIR/pgpass
    pass=${pass//\\/\\\\}
    printf '*:*:*:*:%s\n' "${pass//:/\\:}" >"$pf" || { echo "cannot write $pf"; return 2; }
    out=$(HOME=$RUN_DIR PGPASSFILE=$pf PGAPPNAME=$PROG PGOPTIONS='-c statement_timeout=10s' "$PSQL" -X -q -At \
              -v ON_ERROR_STOP=1 -v VERBOSITY=terse -d "$conninfo" -c "$1" 2>&1)
    rc=$?
    rm -f "$pf"
    printf '%s\n' "${out%%$'\n'*}"
    return $((rc ? 1 : 0))
}

# renew: give the key a new private ID and AES key, in the database (with
# anycast_renew, which keeps the user, PIN and public ID, and starts the
# counters again) and then in the key file, and start the counter file
# again. Until the database has it, the new key waits in key.next: a renewal
# whose answer was lost is finished with the same values, which
# anycast_renew accepts again. Sets MSG; returns 0 when renewed, 1 when it
# failed (try again later), 2 when it can't work here.
MSG=''
renew() {
    local priv='' aes='' made='' out rc
    if partition_mode; then
        MSG="this server is in partition mode (Radiator uses the copy)"
        return 1
    fi
    if [[ -f $STATE_DIR/key.next ]]; then
        priv=$(sed -n 's/^private_id=\([0-9a-f]\{12\}\)$/\1/p' "$STATE_DIR/key.next")
        aes=$(sed -n 's/^aes_key=\([0-9a-f]\{32\}\)$/\1/p' "$STATE_DIR/key.next")
        made=$(sed -n 's/^made=\([0-9]\{1,12\}\)$/\1/p' "$STATE_DIR/key.next")
    fi
    if [[ -z $priv || -z $aes || -z $made ]]; then
        read -r priv aes < <(perl -e 'open my $u, "<:raw", "/dev/urandom" or die; read($u, my $b, 22) == 22 or die;
                                      my $h = unpack "H*", $b; print substr($h, 0, 12), " ", substr($h, 12), "\n"')
        [[ $priv =~ ^[0-9a-f]{12}$ && $aes =~ ^[0-9a-f]{32}$ ]] || { MSG="cannot make a key"; return 1; }
        made=$(date +%s)
        write_key "$STATE_DIR/key.next" "$priv" "$aes" "$made"
    fi
    out=$(db_query "SELECT anycast_renew('$K_PUBLIC', '$K_PRIVATE', '$priv', '$aes')")
    rc=$?
    if ((rc == 2)); then
        rm -f "$STATE_DIR/key.next"
        MSG=$out
        return 2
    elif ((rc)); then
        if [[ $out == *"function anycast_renew"*"does not exist"* ]]; then
            out="the database has no function anycast_renew: run 'yubikey-db.sh -b pg init' (once)"
        fi
        MSG=$out
        return 1
    fi
    case $out in
        t) ;;
        f) rm -f "$STATE_DIR/key.next"
           MSG="the database has no key for $K_USER with public ID $K_PUBLIC and this key file's private ID (was it replaced with 'enroll'?)"
           return 1 ;;
        *) MSG="unexpected answer from the database: $out"
           return 1 ;;
    esac
    # The database has the new key: start its counter again, then use it.
    save_counter 0
    { mv -f "$STATE_DIR/key.next" "$STATE_DIR/key" && sync "$STATE_DIR"; } || die "cannot write $STATE_DIR/key"
    K_PRIVATE=$priv K_AES=$aes K_MADE=$made
    MSG="renewed the key of $K_USER (public ID $K_PUBLIC): a new private ID and AES key"
    return 0
}

# renew_at LEFT: when the key is due for renewal, with LEFT OTPs left:
# RENEW_DAYS after it was made, or sooner, when only 30 days of OTPs are
# left.
renew_at() {
    local at=$((K_MADE + RENEW_DAYS * 86400)) soon
    soon=$(($(date +%s) + $1 * INTERVAL - 30 * 86400))
    echo $((soon < at ? soon : at))
}

# renewal LEFT: what the check will do about renewing the key.
renewal() {
    if [[ -f $STATE_DIR/key.next ]]; then
        echo "a renewal isn't finished (it will be, or run 'renew')"
    elif ((RENEW_DAYS == 0)); then
        echo "no automatic renewal (RENEW_DAYS=0)"
    else
        echo "next renewal on $(date -d "@$(renew_at "$1")" +%F)"
    fi
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

# short_host: this server's short name, in lower case, for the check's users.
short_host() {
    local host
    host=$(hostname -s 2>/dev/null) || die "cannot read the host name"
    host=${host,,}
    [[ $host =~ ^[a-z0-9-]+$ ]] || die "host name '$host' must be letters, digits and '-'"
    printf '%s\n' "$host"
}

cmd_enroll() {
    local host pub priv aes pin old
    lock
    host=$(short_host) || exit
    read -r pub priv aes pin < <(perl -e '
        open my $u, "<:raw", "/dev/urandom" or die; read($u, my $b, 40) == 40 or die;
        my $h = unpack "H*", $b;
        (my $pub = substr($h, 0, 10)) =~ tr/0-9a-f/cbdefghijklnrtuv/;
        my @c = ("A" .. "Z", "a" .. "z", 0 .. 9);
        print join(" ", "vv$pub", substr($h, 10, 12), substr($h, 22, 32),
                   join("", map { $c[$_ % 62] } unpack "C20", substr($b, 20, 20))), "\n"')
    [[ -n $pin ]] || die "cannot make a key"
    # A new key keeps the public ID, so that importing it replaces the old one.
    if [[ -f $STATE_DIR/key ]]; then
        old=$(sed -n 's/^public_id=\([cbdefghijklnrtuv]\{12\}\)$/\1/p' "$STATE_DIR/key")
        if [[ -n $old ]]; then pub=$old; fi
    fi
    K_USER=anycast-$host K_PIN=$pin K_PUBLIC=$pub
    write_key "$STATE_DIR/key" "$priv" "$aes" "$(date +%s)"
    rm -f "$STATE_DIR/key.next"
    save_counter 0
    printf 'username,public_id,private_id,aes_key,password,active\n'
    printf 'anycast-%s,%s,%s,%s,%s,1\n' "$host" "$pub" "$priv" "$aes" "$pin"
    printf '%s: a new key for anycast-%s is in %s/key; load it into the database with: yubikey-db.sh import --replace -\n' \
        "$PROG" "$host" "$STATE_DIR" >&2
}

# A new password for the TACACS+ login's service account: 32 letters and
# digits, kept in the tacacs file and printed once, for 'yubikey-db.sh
# service add' (or 'service password') to read from standard input.
cmd_enroll_tacacs() {
    local host pw
    lock
    host=$(short_host) || exit
    pw=$(perl -e '
        open my $u, "<:raw", "/dev/urandom" or die;
        my @c = ("A" .. "Z", "a" .. "z", 0 .. 9);
        my $pw = "";
        while (length $pw < 32) {
            read($u, my $b, 1) == 1 or die;
            $pw .= $c[ord($b) % 62] if ord($b) < 248;
        }
        print $pw') && [[ ${#pw} == 32 ]] || die "cannot make a password"
    if ! { printf '%s\n' "user=svc.anycast-$host" "password=$pw" >"$STATE_DIR/tacacs.new" \
           && sync "$STATE_DIR/tacacs.new" && mv -f "$STATE_DIR/tacacs.new" "$STATE_DIR/tacacs"; }; then
        die "cannot write $STATE_DIR/tacacs"
    fi
    printf '%s\n' "$pw"
    printf '%s: a new password for svc.anycast-%s is in %s/tacacs; load it into the database with: yubikey-db.sh service add svc.anycast-%s (or service password svc.anycast-%s)\n' \
        "$PROG" "$host" "$STATE_DIR" "$host" "$host" >&2
}

cmd_check() {
    local counter
    load_conf
    lock
    load_key
    load_tacacs
    read_counter
    counter=$((COUNTER + 1))
    ((counter <= MAX_COUNTER)) || die "this key has no OTPs left: run '$PROG enroll'"
    save_counter "$counter"
    if [[ -f $STATE_DIR/key.next ]]; then
        printf '%s: a renewal of the key isn'"'"'t finished: run '"'"'%s renew'"'"'\n' "$PROG" "$PROG" >&2
    fi
    attempt "$counter" 0
    printf '%s\n' "$RESULT"
    ((GOOD))
}

cmd_renew() {
    local rc
    load_conf
    lock
    load_key
    renew
    rc=$?
    if ((rc)); then
        printf '%s: cannot renew the key: %s\n' "$PROG" "$MSG" >&2
        ((rc == 1)) || exit 3
        return 1
    fi
    printf '%s; %s\n' "$MSG" "$(renewal "$(otps_left 1 0)")"
}

cmd_withdraw() {
    local gone
    load_conf
    gone=$(on_lo | paste -sd' ')
    take_off_lo
    if [[ -n $gone ]]; then log "removed $gone from lo"; fi
}

cmd_status() {
    local -A st=()
    local on name value left='' renew=''
    load_conf
    on=$(on_lo | paste -sd' ')
    if [[ -f $RUN_DIR/status ]] && running; then
        while IFS='=' read -r name value; do st[$name]=$value; done <"$RUN_DIR/status"
        printf '%s since %s\n' "${st[state]}" "$(date -d "@${st[since]}" '+%F %T %Z')"
        printf 'last check: %s, %d s ago\n' "${st[last]}" "$(($(date +%s) - st[last_at]))"
        left=${st[left]} renew=${st[renew]-}
    else
        printf 'not running\n'
        if [[ -f $STATE_DIR/counter && -f $STATE_DIR/key ]]; then
            read_counter
            load_key
            left=$(otps_left "$COUNTER" 255)
            renew=$(renewal "$left")
        fi
    fi
    printf 'on lo: %s\n' "${on:-none}"
    if [[ -n $left ]]; then
        printf 'OTPs left: %d (%d days at one check every %d s)\n' "$left" "$(days "$left")" "$INTERVAL"
    fi
    if [[ -n $renew ]]; then
        printf 'key: %s\n' "$renew"
    fi
    [[ ${st[state]-} == advertised && -n $on ]]
}

cmd_run() {
    local counter session=0 skip=0 good_n=0 bad_n=0 state=withdrawn since last='' result kind
    local start now elapsed left pause sleeper='' all next_try=0 last_try=0 renew_off='' due rc
    load_conf
    lock
    load_key
    load_tacacs
    if ((${#ADDR4[@]})) && [[ $(cat "$PROC_SYS/net/ipv4/ip_nonlocal_bind" 2>/dev/null) != 1 ]]; then
        die "net.ipv4.ip_nonlocal_bind is not 1: Radiator could not listen on ${ADDR4[*]} while it is not on lo"
    fi
    if ((${#ADDR6[@]})) && [[ $(cat "$PROC_SYS/net/ipv6/ip_nonlocal_bind" 2>/dev/null) != 1 ]]; then
        die "net.ipv6.ip_nonlocal_bind is not 1: Radiator could not listen on ${ADDR6[*]} while it is not on lo"
    fi
    mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
    # In this shell only: bash also runs it in a child that gets TERM while
    # it still expands its words (as stop's kill of the sleep can find it).
    trap '((BASHPID == $$)) && take_off_lo' EXIT
    read_counter
    counter=$((COUNTER + 1))
    ((counter <= MAX_COUNTER)) || die "this key has no OTPs left: run '$PROG enroll'"
    save_counter "$counter"
    all="${ADDR4[*]} ${ADDR6[*]}"
    all=${all# }; all=${all% }

    # The state, the last check and the renewal, for 'status'.
    write_status() {
        printf '%s\n' "state=$state" "since=$since" "last=$result" "last_at=$(date +%s)" "left=$left" \
            "renew=${renew_off:-$(renewal "$left")}" >"$RUN_DIR/status.new" && mv -f "$RUN_DIR/status.new" "$RUN_DIR/status"
    }

    stop() {
        [[ -n $sleeper ]] && kill "$sleeper" 2>/dev/null
        take_off_lo
        rm -f "$RUN_DIR/status" "$RUN_DIR/status.new"
        log "stopped; $all removed from lo"
        exit 0
    }
    trap stop TERM INT HUP

    take_off_lo
    since=$(date +%s)
    left=$(otps_left "$counter" 0)
    log "started: $K_USER logs in every $INTERVAL s${TACACS_KEY:+, and $T_USER over TACACS+}; $all on lo after $RISE good checks, off after $FALL failed; $left OTPs left ($(days "$left") days); key made $(date -d "@$K_MADE" +%F), $(renewal "$left")"
    while :; do
        start=${EPOCHREALTIME/[.,]/}
        attempt "$counter" "$session"
        result=$RESULT
        left=$(otps_left "$counter" "$session")
        kind=${result// in +([0-9]) ms/}
        [[ $kind == "$last" ]] || log "check: $result"
        last=$kind
        if ((GOOD)); then
            good_n=$((good_n + 1)) bad_n=0 skip=0
        else
            bad_n=$((bad_n + 1)) good_n=0
        fi
        if [[ $state == withdrawn ]] && ((good_n >= RISE)); then
            state=advertised since=$(date +%s)
            put_on_lo
            log "advertising $all: $good_n good checks"
        elif [[ $state == advertised ]] && ((bad_n >= FALL)); then
            state=withdrawn since=$(date +%s)
            take_off_lo
            log "withdrawing $all: $bad_n failed checks"
        elif [[ $state == advertised ]]; then
            put_on_lo       # in case someone removed one
        else
            take_off_lo
        fi
        write_status

        # The next OTP. Radiator rejects one whose counters are not above the
        # last ones it saw ("Replay attack detected"), which happens only if
        # the counter file went back (restored from a backup, say): then skip
        # ahead, twice as far each time.
        session=$((session + 1))
        if [[ $RADIUS_RESULT == *"Replay attack detected"* ]]; then
            skip=$((skip ? skip * 2 : 1))
            counter=$((counter + skip)) session=0
            ((counter <= MAX_COUNTER)) && log "usage counter moved ahead to $counter"
        elif ((session > 255)); then
            counter=$((counter + 1)) session=0
        fi
        if ((session == 0)); then
            if ((counter > MAX_COUNTER)); then
                rm -f "$RUN_DIR/status" "$RUN_DIR/status.new"
                die "this key has no OTPs left: run '$PROG enroll'; $all removed from lo"
            fi
            save_counter "$counter"
            left=$(otps_left "$counter" 0)
            (($(days "$left") < 30)) && log "warning: $left OTPs left ($(days "$left") days): run '$PROG enroll' soon"
        fi

        # Renew the key when it is due, after a good check; after a failure,
        # try again an hour later. A renewal that didn't finish (its answer
        # was lost) is tried again too, every 6 checks (30 s) while the old
        # key's logins fail: the database may have the new key.
        now=$(date +%s) due=0
        if [[ -n $renew_off ]]; then
            :
        elif [[ -f $STATE_DIR/key.next ]]; then
            if ((GOOD ? now >= next_try : now >= last_try + 6 * INTERVAL)); then due=1; fi
        elif ((RENEW_DAYS && GOOD && now >= next_try)) && ((now >= $(renew_at "$left"))); then
            due=1
            log "renewing the key (made $(date -d "@$K_MADE" +%F))"
        fi
        if ((due)); then
            last_try=$now
            renew
            rc=$?
            if ((rc == 0)); then
                counter=1 session=0
                save_counter 1
                left=$(otps_left 1 0)
                log "$MSG; $(renewal "$(otps_left 1 0)")"
            elif ((rc == 1)); then
                next_try=$((now + 3600))
                log "cannot renew the key: $MSG; trying again in 1 hour, or sooner if the check's logins fail"
            else
                renew_off="no automatic renewal: $MSG"
                log "cannot renew the key: $MSG; renew it by hand ('$PROG enroll')"
            fi
            write_status
        fi

        now=${EPOCHREALTIME/[.,]/}
        elapsed=$((now - start))
        if ((elapsed < INTERVAL * 1000000)); then
            printf -v pause '%d.%06d' $(((INTERVAL * 1000000 - elapsed) / 1000000)) $(((INTERVAL * 1000000 - elapsed) % 1000000))
            sleep "$pause" 9>&- &
            sleeper=$!
            wait "$sleeper"
            sleeper=
        fi
    done
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        -c)                   CONF=${2:?-c needs a file}; shift 2 ;;
        -h|--help|help)       usage; exit 0 ;;
        -V|--version|version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
        -*)                   die "unknown option '$1' (see '$PROG help')" ;;
        *)                    break ;;
    esac
done
[[ $# -eq 1 ]] || { usage >&2; exit 3; }

case $1 in
    enroll)        cmd_enroll ;;
    enroll-tacacs) cmd_enroll_tacacs ;;
    check)         cmd_check ;;
    renew)         cmd_renew ;;
    run)           cmd_run ;;
    status)        cmd_status ;;
    withdraw)      cmd_withdraw ;;
    *)             die "unknown command '$1' (see '$PROG help')" ;;
esac
