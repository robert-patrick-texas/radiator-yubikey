#!/usr/bin/env bash
#
# yubikey-anycast.sh - Advertise Radiator's anycast addresses from this server
#                      only while its Radiator accepts YubiKey logins.
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
#     - After RISE good checks in a row it adds the addresses to lo, and FRR
#       advertises them. After FALL failed checks in a row it removes them;
#       FRR withdraws them, and the routers send RADIUS to another site.
#     - When it stops, it removes them.
#   A good check is an accepted login: Radiator works, it reaches the
#   database's primary, and the primary saved the OTP's counter.
#
#   Like a YubiKey, the check counts its OTPs with a usage counter, saved on
#   disk and raised by one each time the check starts, and a session counter
#   (0-255) kept in memory. Radiator accepts usage counters up to 32767, so
#   one key makes about 8.4 million OTPs: 485 days at one check every 5 s.
#   'status' shows how many are left; 'enroll' makes a new key.
#
# COMMANDS
#   enroll    Make a new key for the check, and print it as CSV for
#             'yubikey-db.sh import --replace -' (stop the check first)
#   check     Log in once and print the result (not while the check runs)
#   run       Run the check (yubikey-anycast.service does this)
#   status    Show whether the addresses are on lo, and the last check;
#             exits 0 only while they are
#   withdraw  Remove the addresses from lo
#
# OPTIONS
#   -c FILE   The settings (default /etc/radiator/anycast.conf)
#
# FILES
#   /etc/radiator/anycast.conf        settings: see yubikey-anycast.example.conf
#   /var/lib/yubikey-anycast/key      the check's user name, PIN and YubiKey
#                                     values (mode 0600)
#   /var/lib/yubikey-anycast/counter  the last usage counter used
#   /run/yubikey-anycast/status       the last check, written by 'run'
#
# PREREQUISITES
#   Ubuntu 26.04 LTS, as root. perl with Crypt::Rijndael (which Radiator's
#   YubiKey support needs too), iproute2 (ip, ss) and util-linux (flock).
#   net.ipv4.ip_nonlocal_bind=1 and net.ipv6.ip_nonlocal_bind=1, so that
#   Radiator can listen on the anycast addresses while they are not on lo.
#   Radiator's <Client 127.0.0.1>, and its Handler for anycast-* users from
#   radiator.example.conf.
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
#   IP, SS             the ip and ss commands to use

set -uo pipefail
umask 077   # the key file holds the AES key and the PIN

PROG=${0##*/}
# The version is in the file VERSION, next to this script (the package has it
# written here instead).
VERSION=$(cat -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/VERSION" 2>/dev/null) || VERSION=unknown
CONF=/etc/radiator/anycast.conf
STATE_DIR=${ANYCAST_STATE_DIR:-/var/lib/yubikey-anycast}
RUN_DIR=${ANYCAST_RUN_DIR:-/run/yubikey-anycast}
PROC_SYS=${PROC_SYS:-/proc/sys}
IP=${IP:-ip}
SS=${SS:-ss}
MAX_COUNTER=32767   # Radiator ignores the usage counter's top bit

# Settings, from the settings file
ADDRESSES='' SECRET='' PORT=1812 INTERVAL=5 TIMEOUT=3 FALL=3 RISE=2
ADDR4=() ADDR6=()   # the anycast addresses, checked and written the way ip shows them
# The check's key, from the key file
K_USER='' K_PIN='' K_PUBLIC='' K_PRIVATE='' K_AES=''

die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 3; }
log()  { printf '%s\n' "$*"; }

usage() {
    cat <<EOF
Usage: $PROG [-c FILE] COMMAND

Commands:
  enroll    Make a new key for the check, and print it as CSV for
            'yubikey-db.sh import --replace -' (stop the check first)
  check     Log in once and print the result (not while the check runs)
  run       Run the check (yubikey-anycast.service does this)
  status    Show whether the addresses are on lo, and the last check;
            exits 0 only while they are
  withdraw  Remove the addresses from lo

Options:
  -c FILE   The settings (default $CONF)
  -h        Show this help
  -V        Show the version

Example:
  sudo systemctl stop yubikey-anycast
  sudo $PROG enroll | ./yubikey-db.sh -b pg import --replace -
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
        ADDRESSES|SECRET|PORT|INTERVAL|TIMEOUT|FALL|RISE) printf -v "$1" '%s' "$2" ;;
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
        *) die "$STATE_DIR/key line $3: unknown name '$1'" ;;
    esac
}

load_key() {
    [[ -f $STATE_DIR/key ]] || die "no key in $STATE_DIR/key: run '$PROG enroll' first"
    read_pairs "$STATE_DIR/key" key_pair
    [[ $K_USER =~ ^anycast-[a-z0-9-]+$ && $K_PIN =~ ^[A-Za-z0-9]{8,}$ \
       && $K_PUBLIC =~ ^[cbdefghijklnrtuv]{12}$ && $K_PRIVATE =~ ^[0-9a-f]{12}$ \
       && $K_AES =~ ^[0-9a-f]{32}$ ]] || die "$STATE_DIR/key is damaged: run '$PROG enroll' again"
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

# The anycast addresses Radiator doesn't listen on (UDP, PORT).
not_listening() {
    local have a
    have=" $("$SS" -Hlun 2>/dev/null | awk '{print $4}' | tr '\n' ' ') "
    for a in "${ADDR4[@]}"; do [[ $have == *" $a:$PORT "* ]] || printf '%s\n' "$a"; done
    for a in "${ADDR6[@]}"; do [[ $have == *" [$a]:$PORT "* ]] || printf '%s\n' "$a"; done
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

# attempt COUNTER SESSION: one login with that OTP, then, if it was accepted,
# check that Radiator listens on the anycast addresses. Prints the result.
attempt() {
    local out missing
    out=$(printf '%s\n' "secret=$SECRET" "port=$PORT" "timeout=$TIMEOUT" "user=$K_USER" \
              "pin=$K_PIN" "public_id=$K_PUBLIC" "private_id=$K_PRIVATE" "aes_key=$K_AES" \
              "counter=$1" "session=$2" | perl -e "$LOGIN_PL" 2>&1)
    out=${out:-ERROR: no result}
    if [[ $out == ACCEPT* ]]; then
        missing=$(not_listening | paste -sd' ')
        [[ -z $missing ]] || out="$out, but Radiator does not listen on $missing port $PORT"
    fi
    printf '%s\n' "${out%%$'\n'*}"
}

good() { [[ $1 == ACCEPT* && $1 != *", but "* ]]; }

# otps_left COUNTER SESSION: how many OTPs this key has left after that one.
otps_left() { echo $(((MAX_COUNTER - $1) * 256 + 255 - $2)); }

days() { echo $(($1 * INTERVAL / 86400)); }

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

cmd_enroll() {
    local host pub priv aes pin old
    lock
    host=$(hostname -s 2>/dev/null) || die "cannot read the host name"
    host=${host,,}
    [[ $host =~ ^[a-z0-9-]+$ ]] || die "host name '$host' must be letters, digits and '-'"
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
    if ! { printf '%s\n' "user=anycast-$host" "pin=$pin" "public_id=$pub" "private_id=$priv" "aes_key=$aes" \
               >"$STATE_DIR/key.new" && sync "$STATE_DIR/key.new" && mv -f "$STATE_DIR/key.new" "$STATE_DIR/key"; }; then
        die "cannot write $STATE_DIR/key"
    fi
    save_counter 0
    printf 'username,public_id,private_id,aes_key,password,active\n'
    printf 'anycast-%s,%s,%s,%s,%s,1\n' "$host" "$pub" "$priv" "$aes" "$pin"
    printf '%s: a new key for anycast-%s is in %s/key; load it into the database with: yubikey-db.sh import --replace -\n' \
        "$PROG" "$host" "$STATE_DIR" >&2
}

cmd_check() {
    local counter result
    load_conf
    lock
    load_key
    read_counter
    counter=$((COUNTER + 1))
    ((counter <= MAX_COUNTER)) || die "this key has no OTPs left: run '$PROG enroll'"
    save_counter "$counter"
    result=$(attempt "$counter" 0)
    printf '%s\n' "$result"
    good "$result"
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
    local on name value left=
    load_conf
    on=$(on_lo | paste -sd' ')
    if [[ -f $RUN_DIR/status ]] && running; then
        while IFS='=' read -r name value; do st[$name]=$value; done <"$RUN_DIR/status"
        printf '%s since %s\n' "${st[state]}" "$(date -d "@${st[since]}" '+%F %T %Z')"
        printf 'last check: %s, %d s ago\n' "${st[last]}" "$(($(date +%s) - st[last_at]))"
        left=${st[left]}
    else
        printf 'not running\n'
        if [[ -f $STATE_DIR/counter ]]; then
            read_counter
            left=$(otps_left "$COUNTER" 255)
        fi
    fi
    printf 'on lo: %s\n' "${on:-none}"
    if [[ -n $left ]]; then
        printf 'OTPs left: %d (%d days at one check every %d s)\n' "$left" "$(days "$left")" "$INTERVAL"
    fi
    [[ ${st[state]-} == advertised && -n $on ]]
}

cmd_run() {
    local counter session=0 skip=0 good_n=0 bad_n=0 state=withdrawn since last='' result kind
    local start now elapsed left sleeper='' all
    load_conf
    lock
    load_key
    if ((${#ADDR4[@]})) && [[ $(cat "$PROC_SYS/net/ipv4/ip_nonlocal_bind" 2>/dev/null) != 1 ]]; then
        die "net.ipv4.ip_nonlocal_bind is not 1: Radiator could not listen on ${ADDR4[*]} while it is not on lo"
    fi
    if ((${#ADDR6[@]})) && [[ $(cat "$PROC_SYS/net/ipv6/ip_nonlocal_bind" 2>/dev/null) != 1 ]]; then
        die "net.ipv6.ip_nonlocal_bind is not 1: Radiator could not listen on ${ADDR6[*]} while it is not on lo"
    fi
    mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
    trap take_off_lo EXIT
    read_counter
    counter=$((COUNTER + 1))
    ((counter <= MAX_COUNTER)) || die "this key has no OTPs left: run '$PROG enroll'"
    save_counter "$counter"
    all="${ADDR4[*]} ${ADDR6[*]}"
    all=${all# }; all=${all% }

    stop() {
        [[ -n $sleeper ]] && kill "$sleeper" 2>/dev/null
        take_off_lo
        rm -f "$RUN_DIR/status"
        log "stopped; $all removed from lo"
        exit 0
    }
    trap stop TERM INT HUP

    take_off_lo
    since=$(date +%s)
    left=$(otps_left "$counter" 0)
    log "started: $K_USER logs in every $INTERVAL s; $all on lo after $RISE good checks, off after $FALL failed; $left OTPs left ($(days "$left") days)"
    while :; do
        start=${EPOCHREALTIME/[.,]/}
        result=$(attempt "$counter" "$session")
        left=$(otps_left "$counter" "$session")
        kind=${result/ in [0-9]* ms/}
        [[ $kind == "$last" ]] || log "check: $result"
        last=$kind
        if good "$result"; then
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
        printf '%s\n' "state=$state" "since=$since" "last=$result" "last_at=$(date +%s)" "left=$left" \
            >"$RUN_DIR/status.new" && mv -f "$RUN_DIR/status.new" "$RUN_DIR/status"

        # The next OTP. Radiator rejects one whose counters are not above the
        # last ones it saw ("Replay attack detected"), which happens only if
        # the counter file went back (restored from a backup, say): then skip
        # ahead, twice as far each time.
        session=$((session + 1))
        if [[ $result == *"Replay attack detected"* ]]; then
            skip=$((skip ? skip * 2 : 1))
            counter=$((counter + skip)) session=0
            ((counter <= MAX_COUNTER)) && log "usage counter moved ahead to $counter"
        elif ((session > 255)); then
            counter=$((counter + 1)) session=0
        fi
        if ((session == 0)); then
            if ((counter > MAX_COUNTER)); then
                rm -f "$RUN_DIR/status"
                die "this key has no OTPs left: run '$PROG enroll'; $all removed from lo"
            fi
            save_counter "$counter"
            left=$(otps_left "$counter" 0)
            (($(days "$left") < 30)) && log "warning: $left OTPs left ($(days "$left") days): run '$PROG enroll' soon"
        fi

        now=${EPOCHREALTIME/[.,]/}
        elapsed=$((now - start))
        if ((elapsed < INTERVAL * 1000000)); then
            sleep "$(printf '%d.%06d' $(((INTERVAL * 1000000 - elapsed) / 1000000)) $(((INTERVAL * 1000000 - elapsed) % 1000000)))" 9>&- &
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
    enroll)   cmd_enroll ;;
    check)    cmd_check ;;
    run)      cmd_run ;;
    status)   cmd_status ;;
    withdraw) cmd_withdraw ;;
    *)        die "unknown command '$1' (see '$PROG help')" ;;
esac
