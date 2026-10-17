#!/usr/bin/env bash
#
# setup.sh - Set up one server of a three-site deployment of Radiator with
#            the YubiKey database, from the folder that yubikey-turnkey made
#            for it. (In the radiator-yubikey package it is
#            yubikey-turnkey-setup.sh; yubikey-turnkey copies it.)
#
# WHAT IT DOES
#   Run it on each of the three servers, at about the same time. In order:
#     preflight  checks the server: Ubuntu 26.04, its host name and
#                addresses, the packages next to this script, the ports,
#                the other servers, and that loading the firewall can't
#                lock you out ('--check' stops here)
#     packages   PostgreSQL, Patroni, etcd, FRR and the rest from Ubuntu;
#                Radiator and radiator-yubikey from the packages here
#     system     /etc/hosts (the three servers, IPv4 only) and the kernel
#                settings for anycast
#     etcd       this server's member of the cluster's etcd; it waits until
#                two of the three servers run it
#     patroni    PostgreSQL under Patroni: the first server creates the
#                cluster, the others copy it from there
#     database   the primary (the first server, unless it failed over):
#                the yubikey database, its roles and passwords, the
#                anycast checks' keys and service accounts (those of
#                servers no longer listed removed), and the groups; the
#                others wait for their anycast check
#     radiator   Radiator's configuration (radiator-groups.example.conf with
#                this server's settings), its devices, and its database clause
#     partition  partition mode (when on in site.toml)
#     anycast    FRR, and the anycast check (yubikey-anycast.sh), with its
#                key and counter as the database has them
#     backup     the daily backup (yubikey-backup.sh), and the first one
#                (with [backup] in site.toml)
#     firewall   ufw off, and the iptables rules (when on in site.toml)
#     report     the cluster, the anycast check, the BGP sessions
#   It can be run again at any time: each step changes only what differs
#   from the folder, and restarts a service only when its files changed.
#   If it stops, fix the cause and run it again: it goes on where it
#   stopped. It never removes a database, an etcd cluster or a PostgreSQL
#   cluster that it didn't make, except with --reset.
#   On a server rebuilt with the same name and addresses (a new disk, or
#   --reset NAME on it alone) while the other two run, it joins them: it
#   adds the server's etcd member again, Patroni copies the database (the
#   first server's too, which then is a standby), and the anycast check
#   goes on with its key from the database (renewed since, perhaps).
#   While two servers' etcd is down, it stops at etcd: adding the member
#   again needs both. When two servers are lost for good, '--alone' on the
#   third makes it the cluster alone; then setup.sh on the other two, set
#   up again, joins them to it.
#   A server replaced, with a new name or addresses: setup.sh with the new
#   folders on the other two (on a member already, etcd needs only quorum;
#   the primary's run swaps the anycast checks), then on the new server,
#   which removes the old one's etcd member before adding its own.
#   '--status' shows whether the server works, for people and for
#   monitoring; it changes nothing.
#
# USAGE
#   sudo ./setup.sh [--check] [--no-firewall]
#   sudo ./setup.sh --status
#   sudo ./setup.sh --reset NAME
#   sudo ./setup.sh --alone [--yes]
#
# OPTIONS
#   -n, --check     Only the preflight checks: change nothing
#   --no-firewall   Leave the firewall alone this time
#   --status        Check this server's services, the cluster, the anycast
#                   check, partition mode, BGP, the backups, the firewall,
#                   the certificates, the disk and the clock, and whether
#                   setup.sh has made what its folder holds. Changes nothing.
#                   The first line sums it up (OK, WARNING or CRITICAL).
#                   Without the folder (as the package's
#                   yubikey-turnkey-setup.sh), it reads the copy of
#                   server.env in /etc/yubikey-turnkey.
#   --reset NAME    Start this server over (NAME: its host name): stop the
#                   services, and remove its etcd data, PostgreSQL cluster,
#                   anycast key and setup.sh's state. Then setup.sh: on this
#                   server alone, while the other two run, it joins them
#                   again; after --reset on all three, setup.sh on all three
#                   makes a new cluster. The copy of the settings and
#                   secrets in /etc/yubikey-turnkey stays, and so do the
#                   backups in /var/backups.
#   --alone         Only when the other two servers are lost for good: make
#                   this server the cluster alone (its etcd a cluster of
#                   one, with its data, and its PostgreSQL the primary). It
#                   refuses while one of them answers, and asks first.
#   --yes           --alone: don't ask
#
# FILES (next to this script, from yubikey-turnkey)
#   server.env, secrets.env   this server's settings, and the secrets that
#                             setup.sh uses itself
#   files/, files.list        the files it installs, with their modes
#   hosts                     the lines for /etc/hosts
#   db/                       the first server only: the database's first
#                             contents
#   *.deb, install.sh         Radiator's packages, radiator-yubikey's and its
#                             install.sh
# It keeps its state in /var/lib/yubikey-turnkey, a copy of server.env and
# secrets.env in /etc/yubikey-turnkey, and logs to
# /var/log/yubikey-turnkey.log.
#
# EXIT STATUS
#   0 done (--check: nothing to fix); 1 failed (--check: something to fix);
#   2 a usage error.
#   --status, as monitoring tools such as Nagios expect: 0 OK, 1 WARNING,
#   2 CRITICAL, 3 UNKNOWN (it couldn't check: not root, no server.env).
#
# ENVIRONMENT
#   TURNKEY_WAIT   seconds to wait for the other servers (default 1800)

# shellcheck disable=SC2329  # the functions that wait_for calls

set -uo pipefail
umask 022

PROG=setup.sh
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE=/var/lib/yubikey-turnkey
KEEP=/etc/yubikey-turnkey
LOG=/var/log/yubikey-turnkey.log
PKG=/opt/radiator-yubikey
PATRONI=/etc/patroni/18-main.yml
PATRONI_UNIT=patroni@18-main
RAD_LOG=/var/log/radiator/radiator.log
CONF_D=/etc/radiator/conf.d
WAIT=${TURNKEY_WAIT:-1800}
MARK="Made by yubikey-turnkey"

# From server.env
VERSION='' SITE_NAME='' NAME='' FQDN='' IPV4='' IPV6='' FIRST=''
SERVERS='' FQDNS='' IPV4S='' ANYCAST4='' ANYCAST6=''
ADMINS='' ADMIN_SUBNETS='' PARTITION='' FIREWALL='' BACKUP=''
# From secrets.env
RADIATOR_PASSWORD='' RADIATOR_SCRAM=''
declare -A ADMIN_SCRAM=()

CHECK=0 NO_FIREWALL=0 RESET='' STATUS=0 ALONE=0 YES=0
ENV_DIR=$HERE       # where server.env is (--status: or $KEEP)
PROBLEMS=0          # preflight: things to fix
REJOIN=0            # etcd: this server's member was added again
REMOVED=0           # etcd: refused, as a member the cluster had removed
LEARNER=''          # etcd: this server's member, while a learner
START=$EPOCHSECONDS
CHANGED=()          # install_files: the paths it changed

die() {
    if [[ $STATUS == 1 ]]; then printf 'UNKNOWN - %s\n' "$*"; exit 3; fi
    printf '%s: error: %s\n' "$PROG" "$*" >&2
    exit 1
}
step() { printf '\n== %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }

usage() {
    cat <<EOF
Usage: sudo ./$PROG [--check] [--no-firewall]
       sudo ./$PROG --status
       sudo ./$PROG --reset NAME
       sudo ./$PROG --alone [--yes]

Sets up this server from its folder, made by yubikey-turnkey. Run it on all
three servers at about the same time; run it again whenever the folder
changed. It goes on where it stopped.

Options:
  -n, --check     Only the preflight checks: change nothing
  --no-firewall   Leave the firewall alone this time
  --status        Show whether this server works (changes nothing); exits
                  0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
  --reset NAME    Start this server over (NAME: its host name)
  --alone         The other two servers are lost for good: make this one
                  the cluster alone (asks first; --yes: doesn't)
  -h, --help      Show this help
EOF
}

# read_env FILE: the NAME="value" lines of FILE, never run as shell code.
read_env() {
    local line name value n=0
    [[ -r $1 ]] || die "cannot read $1 (copy the whole folder that yubikey-turnkey made for this server)"
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=\"([^\"]*)\"$ ]] || die "$1 line $n: not NAME=\"value\""
        name=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        case $name in
            VERSION|SITE_NAME|NAME|FQDN|IPV4|IPV6|FIRST|SERVERS|FQDNS|IPV4S|ANYCAST4|ANYCAST6|\
            ADMINS|ADMIN_SUBNETS|PARTITION|FIREWALL|BACKUP|RADIATOR_PASSWORD|RADIATOR_SCRAM)
                printf -v "$name" '%s' "$value" ;;
            ADMIN_SCRAM_*) ADMIN_SCRAM[${name#ADMIN_SCRAM_}]=$value ;;
            *) die "$1 line $n: unknown name '$name'" ;;
        esac
    done <"$1"
}

# done_ STEP / mark STEP: whether a one-time step has been done, and record it.
done_() { [[ -f $STATE/$1 ]]; }
mark()  { mkdir -p "$STATE" && date -u '+%F %T UTC' >"$STATE/$1"; }

# wait_for WHAT SECONDS COMMAND...: run COMMAND every 2 s until it succeeds,
# saying after 10 s, and every 30 s, what it waits for. Fails after SECONDS.
wait_for() {
    local what=$1 secs=$2 start=$SECONDS next=$((SECONDS + 10))
    shift 2
    until "$@"; do
        if ((SECONDS - start >= secs)); then
            bad "gave up after $secs s waiting for $what"
            return 1
        fi
        if ((SECONDS >= next)); then
            info "waiting for $what ($((SECONDS - start)) s)"
            next=$((SECONDS + 30))
        fi
        sleep 2
    done
}

# in_subnets ADDRESS SUBNET...: whether ADDRESS is in one of the subnets.
in_subnets() {
    perl -MSocket=inet_pton,AF_INET,AF_INET6 -e '
        sub bits { my $a = shift; my $p = inet_pton($a =~ /:/ ? AF_INET6 : AF_INET, $a); defined $p ? unpack("B*", $p) : undef }
        my $a = bits(shift) // exit 1;
        for (@ARGV) {
            my ($n, $len) = split m{/}; my $b = bits($n) // next;
            $len //= length $b;
            exit 0 if length($a) == length($b) && substr($a, 0, $len) eq substr($b, 0, $len);
        }
        exit 1' "$@"
}

# quiet COMMAND...: run COMMAND with its output in the log only; when it
# fails, show the end of it too.
quiet() {
    local out rc=0
    out=$("$@" 2>&1) || rc=$?
    printf '%s\n' "$out" >>"$LOG"
    if [[ $rc != 0 ]]; then printf '%s\n' "$out" | tail -20 | sed 's/^/        /'; fi
    return $rc
}

pkg_installed() { [[ $(dpkg-query -W -f '${Status}' "$1" 2>/dev/null) == "install ok installed" ]]; }
pkg_version()   { dpkg-query -W -f '${Version}' "$1" 2>/dev/null; }
pg() { (cd / && runuser -u postgres -- psql -X -q -At "$@"); }
# pg_var DB VALUE SQL: run SQL, which names VALUE :'v', in DB (psql takes
# variables from standard input only).
pg_var() { printf '%s\n' "$3" | pg -d "$1" -v v="$2"; }
ydb() { (cd / && runuser -u postgres -- env -u PGHOST -u PGUSER "$PKG/yubikey-db.sh" -b pg "$@"); }

# install_files STEP: install the files of STEP from files/ whose content,
# mode or owner differ (those with policy keep only when missing). The
# paths it changed are in CHANGED.
install_files() {
    local s kind mode owner policy path src dst
    CHANGED=()
    while read -r s kind mode owner policy path; do
        [[ $s == "$1" ]] || continue
        dst=/$path
        if [[ $kind == dir ]]; then
            if [[ ! -d $dst || $(stat -c '%a %U:%G' "$dst") != "${mode#0} $owner" ]]; then
                install -d -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$dst" || die "cannot make $dst"
            fi
            continue
        fi
        src=$HERE/files/$path
        [[ -f $src ]] || die "$src is missing (copy the whole folder that yubikey-turnkey made)"
        if [[ -e $dst ]]; then
            [[ $policy == keep ]] && continue
            if cmp -s "$src" "$dst" && [[ $(stat -c '%a %U:%G' "$dst") == "${mode#0} $owner" ]]; then
                continue
            fi
        fi
        install -D -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$src" "$dst" || die "cannot install $dst"
        CHANGED+=("$dst")
    done < <(grep -v '^#' "$HERE/files.list")
    if [[ ${#CHANGED[@]} -gt 0 ]]; then info "installed ${CHANGED[*]}"; fi
}

changed() { local p; for p in "${CHANGED[@]}"; do [[ $p == "$1" ]] && return 0; done; return 1; }

# put FILE MODE OWNER:GROUP < CONTENT: write FILE when its content differs.
# Returns 0 when it wrote it, 1 when it was the same.
put() {
    local tmp
    tmp=$(mktemp) || die "cannot make a temporary file"
    cat >"$tmp"
    if [[ -f $1 ]] && cmp -s "$tmp" "$1" && [[ $(stat -c '%a %U:%G' "$1") == "${2#0} $3" ]]; then
        rm -f "$tmp"
        return 1
    fi
    install -m "$2" -o "${3%:*}" -g "${3#*:}" "$tmp" "$1" || { rm -f "$tmp"; die "cannot write $1"; }
    rm -f "$tmp"
    info "installed $1"
    return 0
}

# ssh_peers: the addresses of the SSH connections to this server.
ssh_peers() {
    ss -Htn state established '( sport = :22 )' 2>/dev/null \
        | awk '{ a = $NF; sub(/:[0-9]+$/, "", a); gsub(/^\[|\]$/, "", a); sub(/^::ffff:/, "", a); print a }' | sort -u
}

firewall_guard() {
    local peer
    for peer in $(ssh_peers); do
        # shellcheck disable=SC2086  # ADMIN_SUBNETS is a list
        in_subnets "$peer" $ADMIN_SUBNETS || { echo "$peer"; return 1; }
    done
    return 0
}

# --------------------------------------------------------------------------
# Steps
# --------------------------------------------------------------------------

# port_user PROTO PORT: the program listening on PORT, or nothing.
port_user() {
    ss -Hlnp"${1:0:1}" "( sport = :$2 )" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2
}

preflight() {
    local os p proto port want user peer avail addrs
    step preflight
    [[ $(id -u) == 0 ]] || die "run it as root (sudo ./$PROG)"
    # shellcheck source=/dev/null
    os=$(. /etc/os-release 2>/dev/null && echo "$ID $VERSION_ID")
    if [[ $os == "ubuntu 26.04" ]]; then ok "Ubuntu 26.04"; else bad "Ubuntu 26.04 LTS is needed, not '$os'"; fi
    if [[ $(hostname -s) == "$NAME" ]]; then
        ok "host name $NAME"
    else
        bad "this is $NAME's folder, but this server's host name is '$(hostname -s)': copy the right folder, or set the host name (hostnamectl hostname $NAME)"
    fi
    # (Never 'COMMAND | grep -q' here: with pipefail, grep's early exit can
    # fail COMMAND with SIGPIPE.)
    addrs=$(ip -o addr show)
    for p in "inet $IPV4/" "inet6 $IPV6/"; do
        if grep -qF " $p" <<<"$addrs"; then ok "address ${p#* }"; else bad "no interface has ${p#* } (${p% *})"; fi
    done
    case $(timedatectl show -p NTPSynchronized --value 2>/dev/null) in
        yes) ok "clock synchronized" ;;
        no)  warn "the clock isn't synchronized (NTP): the certificates and the logs need the right time" ;;
        *)   warn "cannot tell whether the clock is synchronized (timedatectl)" ;;
    esac
    avail=$(df -P -k /var/lib 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }')
    if [[ -n $avail && $avail -lt 10 ]]; then
        warn "/var/lib has $avail GiB free: PostgreSQL keeps up to 8 GB of WAL for a standby that is down"
    fi
    if pkg_installed radiator || pkg_installed radiator-locked; then
        ok "Radiator $(pkg_version radiator)$(pkg_version radiator-locked) installed"
    elif compgen -G "$HERE/radiator_*_all.deb" >/dev/null || compgen -G "$HERE/radiator-locked_*_all.deb" >/dev/null; then
        if compgen -G "$HERE/radiator-radius-utilxs_*.deb" >/dev/null; then
            ok "Radiator's packages are here"
        else
            bad "radiator-radius-utilxs_*.deb is missing next to $PROG (from Radiator Software, with Radiator)"
        fi
    else
        bad "Radiator isn't installed, and its packages aren't next to $PROG (radiator_*_all.deb and radiator-radius-utilxs_*.deb, from Radiator Software)"
    fi
    if [[ $(pkg_version radiator-yubikey) == "$VERSION" ]]; then
        ok "radiator-yubikey $VERSION installed"
    elif [[ -f $HERE/radiator-yubikey_${VERSION}_all.deb && -f $HERE/install.sh ]]; then
        ok "radiator-yubikey ${VERSION}'s package and install.sh are here"
    else
        bad "radiator-yubikey_${VERSION}_all.deb and its install.sh aren't next to $PROG (the release of radiator-yubikey $VERSION)"
    fi
    # Each port, and the programs that may listen on it already (from an
    # earlier run, or the packages).
    for p in tcp:2379:etcd tcp:2380:etcd tcp:5432:postgres tcp:8008:patroni,python3 udp:1812:radiusd,perl \
             udp:1813:radiusd,perl tcp:49:radiusd,perl tcp:179:bgpd; do
        IFS=: read -r proto port want <<<"$p"
        user=$(port_user "$proto" "$port")
        if [[ -n $user && ,$want, != *",$user,"* ]]; then
            bad "$proto port $port is taken by $user (it is for ${want%%,*})"
        fi
    done
    ok "ports"
    for p in $IPV4S; do
        [[ $p == "$IPV4" ]] && continue
        if timeout 3 bash -c "exec 3<>/dev/tcp/$p/2380" 2>/dev/null; then
            ok "$p answers (TCP 2380)"
        elif [[ $? == 124 ]]; then
            warn "no answer from $p on TCP 2380 within 3 s: the servers must reach each other on TCP 2379, 2380, 5432 and 8008"
        else
            ok "$p reachable"
        fi
    done
    if [[ $FIREWALL == 1 && $NO_FIREWALL == 0 ]]; then
        if peer=$(firewall_guard); then
            ok "SSH connections from the admin subnets only"
        else
            bad "an SSH connection comes from $peer, outside the admin subnets ($ADMIN_SUBNETS): the firewall would lock it out (add its subnet to [admin] in site.toml, or use --no-firewall)"
        fi
    fi
}

packages() {
    local -a want=(postgresql postgresql-client libdbd-pg-perl etcd-server etcd-client patroni python3-etcd
                   frr sqlite3 iproute2 curl openssl ca-certificates) missing=() debs=()
    local p
    step packages
    if [[ $FIREWALL == 1 && $NO_FIREWALL == 0 ]]; then want+=(iptables iptables-persistent); fi
    for p in "${want[@]}"; do pkg_installed "$p" || missing+=("$p"); done
    if ! pkg_installed radiator && ! pkg_installed radiator-locked; then
        debs=("$HERE"/radiator_*_all.deb "$HERE"/radiator-locked_*_all.deb "$HERE"/radiator-radius-utilxs_*.deb)
        mapfile -t debs < <(for p in "${debs[@]}"; do [[ -f $p ]] && echo "$p"; done)
    fi
    if [[ ${#missing[@]} -gt 0 || ${#debs[@]} -gt 0 ]]; then
        info "installing ${missing[*]} ${debs[*]##*/} (apt-get's output is in $LOG)"
        # iptables-persistent would save the rules loaded now; setup.sh
        # writes its own.
        printf '%s\n' 'iptables-persistent iptables-persistent/autosave_v4 boolean false' \
                      'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
        quiet env DEBIAN_FRONTEND=noninteractive apt-get -q update || die "apt-get update failed"
        quiet env DEBIAN_FRONTEND=noninteractive apt-get -q -y install "${missing[@]}" "${debs[@]}" \
            || die "apt-get install failed"
        # Radiator's sample configuration accepts logins without checking a
        # password: off until the radiator step installs this server's.
        if [[ ${#debs[@]} -gt 0 ]]; then systemctl disable --now radiator 2>/dev/null; fi
    fi
    if [[ $(pkg_version radiator-yubikey) != "$VERSION" ]]; then
        info "installing radiator-yubikey $VERSION with its install.sh (its output is in $LOG)"
        quiet bash "$HERE/install.sh" --yes "$HERE/radiator-yubikey_${VERSION}_all.deb" \
            || die "install.sh failed"
    fi
    for p in yubikey-db.sh yubikey-anycast.sh yubikey-partition.sh yubikey-backup.sh dictionary.yubikey; do
        [[ -f $PKG/$p ]] || die "$PKG/$p is missing (radiator-yubikey isn't installed properly)"
    done
    ok "packages: Radiator $(pkg_version radiator)$(pkg_version radiator-locked), radiator-yubikey $VERSION, PostgreSQL $(pkg_version postgresql), Patroni $(pkg_version patroni), etcd $(pkg_version etcd-server), FRR $(pkg_version frr)"
}

system_step() {
    local names
    step system
    # /etc/hosts: the three servers' names, IPv4 only, in a block of their
    # own; the names are taken out of other lines (such as 127.0.1.1), and
    # a line left without a name is commented out. In place, since it may
    # be a mount.
    names="$FQDNS $SERVERS"
    awk -v names="$names" -v block="$(cat "$HERE/hosts")" '
        BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) ours[a[i]] = 1 }
        /^# BEGIN yubikey-turnkey/ { skip = 1; next }
        /^# END yubikey-turnkey/   { skip = 0; next }
        skip { next }
        /^[[:space:]]*(#|$)/ { print; next }
        {
            dropped = 0; kept = 0; out = $1
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^#/) { for (j = i; j <= NF; j++) out = out " " $j; break }
                if ($i in ours) { dropped = 1; continue }
                out = out " " $i; kept++
            }
            if (!dropped) print
            else if (kept) print out
            else print "#" $0 "    # yubikey-turnkey: in the block below"
        }
        END { print "# BEGIN yubikey-turnkey: the three servers, IPv4 only"; print block; print "# END yubikey-turnkey" }
    ' /etc/hosts >"$STATE/hosts.new" || die "cannot read /etc/hosts"
    if ! cmp -s "$STATE/hosts.new" /etc/hosts; then
        cat "$STATE/hosts.new" >/etc/hosts || die "cannot write /etc/hosts"
        info "updated /etc/hosts"
    fi
    rm -f "$STATE/hosts.new"
    install_files system
    if [[ $(cat /proc/sys/net/ipv4/ip_nonlocal_bind /proc/sys/net/ipv6/ip_nonlocal_bind 2>/dev/null) != $'1\n1' ]]; then
        sysctl -q -p /etc/sysctl.d/60-radiator-anycast.conf || die "cannot set the kernel settings in /etc/sysctl.d/60-radiator-anycast.conf"
    fi
    install -d -m 0700 "$KEEP"
    put "$KEEP/server.env" 0600 root:root <"$HERE/server.env" || true
    put "$KEEP/secrets.env" 0600 root:root <"$HERE/secrets.env" || true
    ok "/etc/hosts, kernel settings"
}

etcdctl_() {
    etcdctl --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt --key /etc/etcd/tls/server.key \
        --endpoints "https://$IPV4:2379" --dial-timeout 2s --command-timeout 4s "$@"
}

# etcdctl_others ARGS...: etcdctl, at the other two servers' etcd.
etcdctl_others() {
    local ip eps=''
    for ip in $IPV4S; do [[ $ip == "$IPV4" ]] || eps+=${eps:+,}https://$ip:2379; done
    etcdctl --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt --key /etc/etcd/tls/server.key \
        --endpoints "$eps" --dial-timeout 2s --command-timeout 4s "$@"
}

etcd_ready() {
    [[ $(etcdctl_ endpoint health --cluster 2>/dev/null | grep -c 'is healthy') == 3 ]]
}

# etcd_quorum: this server's etcd answers, with quorum.
etcd_quorum() { etcdctl_ endpoint health >/dev/null 2>&1; }

# etcd_peer_members: the members as the other two's etcd has them, from the
# first that answers on its peer port, which needs no quorum: a line each,
# ID NAME PEER-URL CLIENT-URL, with - for no name or client URL. (Over
# HTTP/1.1: with HTTP/2, curl gets "Error in the HTTP2 framing layer".)
etcd_peer_members() {
    local ip
    for ip in $IPV4S; do
        [[ $ip == "$IPV4" ]] && continue
        curl -sf --http1.1 --max-time 3 --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt \
            --key /etc/etcd/tls/server.key "https://$ip:2380/members" 2>/dev/null | python3 -c '
import json, sys
for m in json.load(sys.stdin):
    print("%x" % m["id"], m.get("name") or "-", m["peerURLs"][0], (m.get("clientURLs") or ["-"])[0])
' 2>/dev/null && return 0
    done
    return 1
}

# etcd_members: the members, as the other two's etcd lists them (with
# quorum): a line each, as etcd_peer_members.
etcd_members() {
    local list
    list=$(etcdctl_others member list 2>/dev/null) || return 1
    awk -F', ' '{print $1, ($3 == "" ? "-" : $3), $4, ($5 == "" ? "-" : $5)}' <<<"$list"
}

# etcd_member ARGS...: etcdctl_others member ARGS; again, for up to 60 s,
# while etcd says "unhealthy cluster" (it takes no member changes until it
# has had quorum for 5 s, as when its servers have just started) or "too
# many learner members" (another server's, being added at the same time),
# or the change timed out (as when another server's member changes at the
# same time). One that timed out may have been made all the same: made
# again, etcd says so (the member exists already, or no more), and this
# returns 2.
etcd_member() {
    local out t=$SECONDS timed=0
    until out=$(etcdctl_others member "$@" 2>&1); do
        if [[ $timed == 1 && ( $out == *'member ID already exist'* || $out == *'Peer URLs already exists'*
                               || $out == *'member not found'* ) ]]; then
            printf '%s\n' "$out"
            return 2
        fi
        if [[ $out == *'context deadline exceeded'* || $out == *'request timed out'* ]]; then
            timed=1
        elif [[ $out != *'unhealthy cluster'* && $out != *'too many learner members'* ]]; then
            printf '%s\n' "$out"
            return 1
        fi
        if ((SECONDS - t >= 60)); then
            printf '%s\n' "$out"
            return 1
        fi
        sleep 2
    done
    printf '%s\n' "$out"
}

etcd_alone() {
    die "etcd: the cluster has this server's member from before, and fewer than two servers run etcd, which adding it again needs. Start etcd on the other two (see \"Rebuild a turn-key server\" in the guide)"
}

# etcd_up: etcd_ready. When this server's etcd, started as in a new
# cluster because the others answered nothing, stopped: the cluster has its
# member from before (etcd refuses), and setup.sh stops; or the cluster has
# it under another ID, having added it again before, and removed the one
# this etcd started as: once the others have quorum, it is added again
# (once). A member added again is a learner until it has caught up with
# the leader: then it is promoted (or no learner any more: promoted by a
# request that timed out).
etcd_up() {
    local log out
    etcd_ready && return 0
    if [[ -n $LEARNER ]]; then
        if out=$(etcdctl_others member promote "$LEARNER" 2>&1) \
            || [[ $(tail -1 <<<"$out") == *'can only promote a learner member' ]]; then
            info "etcd: promoted this server's member, which has caught up"
            LEARNER=''
        fi
    fi
    systemctl -q is-active etcd && return 1
    log=$(journalctl -u etcd --since "@$START" -o cat 2>/dev/null)
    grep -q 'has already been bootstrapped' <<<"$log" && etcd_alone
    if [[ $REMOVED == 0 ]] && grep -q 'permanently removed from the cluster' <<<"$log"; then
        etcdctl_others member list >/dev/null 2>&1 || return 1
        REMOVED=1
        info "etcd: the others refused this server's etcd, started as in a new cluster: they have its member under another ID"
        systemctl stop etcd 2>/dev/null
        rm -rf /var/lib/etcd/default
        etcd_rejoin
        systemctl start --no-block etcd
    fi
    return 1
}

# etcd_rejoin: on a server whose etcd has no WAL and never ran with
# setup.sh (new, rebuilt, or after --reset), whether the other two's
# cluster has this server's member from before. One that ran has a client
# URL: it is removed and added again, and this server's etcd joins the
# cluster that exists. While the cluster is being made, the others list
# this server's member by name, with no client URL; one added again but
# not started yet has no name either. Without quorum the others can't
# list, remove or add members, but their peer port says whether the
# cluster has run: if not (or nothing answers: they don't run etcd yet),
# etcd starts as in a new cluster; if so, a member that ran can't be added
# again, and setup.sh stops.
etcd_rejoin() {
    local list quorum=1 line id name client out cluster='' sid sname speer sclient ip
    if list=$(etcd_members); then
        quorum=1
    elif list=$(etcd_peer_members) && [[ -n $(awk '$4 != "-"' <<<"$list") ]]; then
        quorum=0
    else
        return 0
    fi
    if [[ $quorum == 1 ]]; then
        # The members of servers that aren't among the three now (replaced),
        # once they don't answer: before this server's is added.
        while read -r sid sname speer sclient; do
            ip=${speer#https://} ip=${ip%:2380}
            [[ -n $sid && " $IPV4S " != *" $ip "* ]] || continue
            if [[ $sclient != - ]] && etcdctl --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt \
                   --key /etc/etcd/tls/server.key --endpoints "$sclient" --dial-timeout 2s --command-timeout 4s \
                   endpoint health >/dev/null 2>&1; then
                die "etcd: the cluster has the member of $sname ($speer), which isn't one of the three servers in this folder, and it runs: stop it first ($PROG --reset $sname on it)"
            fi
            out=$(etcd_member remove "$sid") || [[ $? == 2 ]] \
                || die "etcd: cannot remove the member of $sname ($sid): $out"
            info "etcd: removed the member of $sname ($speer), which isn't one of the three servers now"
        done <<<"$list"
    fi
    line=$(awk -v u="https://$IPV4:2380" '$3 == u' <<<"$list")
    read -r id name _ client <<<"$line"
    [[ -n $line && $name != - && $client == - ]] && return 0
    [[ $quorum == 0 && ( -z $line || $client != - ) ]] && etcd_alone
    if [[ -n $line && $client != - ]]; then
        out=$(etcd_member remove "$id") || [[ $? == 2 ]] \
            || die "etcd: cannot remove this server's member from before ($id): $out"
        info "etcd: removed this server's member from before ($id), to add it again"
        line=''
    fi
    if [[ -z $line ]]; then
        # As a learner, which counts for no quorum, until it has caught up:
        # if it never joined, a cluster of one (see --alone) would have none.
        if out=$(etcd_member add "$NAME" --learner --peer-urls "https://$IPV4:2380"); then
            # (etcdctl pads the ID with spaces to 16 characters.)
            id=$(sed -n 's/^Member  *\([0-9a-f]*\) added.*/\1/p' <<<"$out")
            cluster=$(sed -n 's/^ETCD_INITIAL_CLUSTER="\(.*\)"$/\1/p' <<<"$out")
        elif [[ $? == 2 ]]; then
            # Added by the request that timed out: as the others list it.
            list=$(etcd_members) || die "etcd: cannot list the members"
            read -r id _ <<<"$(awk -v u="https://$IPV4:2380" '$3 == u' <<<"$list")"
        else
            die "etcd: cannot add this server's member: $out"
        fi
        info "etcd: added this server's member ($id), as a learner until it has caught up"
    fi
    if [[ -z $cluster ]]; then
        # Added before, not started yet (or by a request that timed out):
        # the members as the others list them.
        cluster=$(awk -v u="https://$IPV4:2380" -v n="$NAME" '{
            printf "%s%s=%s", (NR > 1 ? "," : ""), ($3 == u ? n : ($2 == "-" ? "unstarted" NR : $2)), $3 }' <<<"$list")
    fi
    [[ -n $id && -n $cluster ]] || die "etcd: cannot tell this server's member and the cluster's: $out"
    # Until it has joined, as a member of the cluster that exists, with its
    # members (etcd refuses to join with others).
    systemctl stop etcd 2>/dev/null
    rm -rf /var/lib/etcd/default
    sed -i -e 's/^ETCD_INITIAL_CLUSTER_STATE=new$/ETCD_INITIAL_CLUSTER_STATE=existing/' \
        -e "s|^ETCD_INITIAL_CLUSTER=.*|ETCD_INITIAL_CLUSTER=$cluster|" /etc/default/etcd \
        || die "cannot change /etc/default/etcd"
    REJOIN=1 LEARNER=$id
}

etcd_step() {
    local members before down=() ip i=0 names
    step etcd
    if ! done_ etcd-config; then
        # The package started a single-server etcd, with its default member;
        # only that may be removed.
        if [[ -d /var/lib/etcd/default/member ]]; then
            systemctl start etcd 2>/dev/null
            members=$(etcdctl --endpoints http://127.0.0.1:2379 --dial-timeout 2s member list 2>/dev/null)
            if [[ $members =~ ^[0-9a-f]+,\ started,\ [^,]*,\ http://localhost:2380,\ http://localhost:2379,\ false$ ]]; then
                systemctl stop etcd
                rm -rf /var/lib/etcd/default
                info "removed the package's single-server etcd"
            else
                die "etcd on this server holds data that $PROG didn't make (/var/lib/etcd/default): it won't remove it. To start this server over: $PROG --reset $NAME"
            fi
        fi
        mark etcd-config
    fi
    before=$(grep -Ev '^(#|ETCD_INITIAL_)' /etc/default/etcd 2>/dev/null)
    install_files etcd
    systemctl enable etcd 2>/dev/null
    REJOIN=0
    # (etcd itself takes a data directory without a WAL as none: a start it
    # refused leaves one.)
    if ! done_ etcd && [[ ! -d /var/lib/etcd/default/member/wal ]]; then etcd_rejoin; fi
    if [[ ${#CHANGED[@]} -gt 0 ]] && systemctl -q is-active etcd; then
        # Not for ETCD_INITIAL_* alone (another server's address, say):
        # they count only when the cluster is first made.
        if ! done_ etcd || [[ ${#CHANGED[@]} -gt 1 || ${CHANGED[0]} != /etc/default/etcd \
                               || $before != "$(grep -Ev '^(#|ETCD_INITIAL_)' /etc/default/etcd)" ]]; then
            systemctl restart --no-block etcd
        fi
    else
        systemctl start --no-block etcd
    fi
    if done_ etcd && [[ $REJOIN == 0 ]]; then
        # A member already: quorum is enough, with another server down, or
        # being replaced.
        wait_for "etcd, with quorum (run $PROG on the others)" "$WAIT" etcd_quorum || exit 1
        read -ra names <<<"$SERVERS"
        for ip in $IPV4S; do
            etcdctl --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt --key /etc/etcd/tls/server.key \
                --endpoints "https://$ip:2379" --dial-timeout 2s --command-timeout 4s endpoint health >/dev/null 2>&1 \
                || down+=("${names[i]}")
            i=$((i + 1))
        done
        if [[ ${#down[@]} -gt 0 ]]; then
            ok "etcd: $((3 - ${#down[@]})) of 3 members healthy (not ${down[*]}), with quorum"
        else
            ok "etcd: 3 members healthy"
        fi
        return
    fi
    wait_for "etcd on all three servers (run $PROG on the others)" "$WAIT" etcd_up || exit 1
    mark etcd
    if [[ $REJOIN == 1 ]]; then
        # The folder's file again: its ETCD_INITIAL_* settings count no more.
        install_files etcd >/dev/null
        ok "etcd: joined the cluster; 3 members healthy"
        return
    fi
    ok "etcd: 3 members healthy"
}

# members: each member's role, as NAME=ROLE/STATE.
members() {
    patronictl -c $PATRONI list -f json 2>/dev/null | python3 -c '
import json, sys
for m in json.load(sys.stdin):
    print("%s=%s/%s" % (m["Member"], m["Role"].replace(" ", "_"), m["State"]))' 2>/dev/null
}
has_leader()  { grep -q '=Leader/running$' <<<"$(members)"; }
leader()      { sed -n 's|=Leader/running$||p' <<<"$(members)"; }
streaming()   { grep -Eq "^$NAME=(Quorum_Standby|Sync_Standby|Replica)/streaming$" <<<"$(members)"; }
api() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 --cacert /etc/patroni/tls/ca.crt "https://$1:8008/$2"; }
local_primary() { [[ $(pg -c 'SELECT pg_is_in_recovery()' 2>/dev/null) == f ]]; }
leading() { [[ $(api "$FQDN" primary) == 200 ]] && local_primary; }

patroni_step() {
    local dbs lead
    step patroni
    if ! done_ patroni-config; then
        # The postgresql package made a cluster 18/main; Patroni makes its
        # own. Only an empty one may be removed.
        if grep -q '^18 main ' <<<"$(pg_lsclusters -h 2>/dev/null)"; then
            pg_ctlcluster 18 main start 2>/dev/null
            dbs=$(pg -c "SELECT string_agg(datname, ' ') FROM pg_database WHERE datname NOT IN ('postgres', 'template0', 'template1')" 2>/dev/null) \
                || die "cannot read PostgreSQL's cluster 18/main"
            [[ -z $dbs ]] || die "PostgreSQL's cluster 18/main has databases ($dbs): $PROG won't remove it. To start this server over: $PROG --reset $NAME"
            pg_dropcluster --stop 18 main || die "cannot remove the package's cluster 18/main"
            info "removed the postgresql package's empty cluster 18/main"
        fi
        mark patroni-config
    fi
    install_files patroni
    if changed /etc/systemd/system/patroni@18-main.service.d/restart.conf; then systemctl daemon-reload; fi
    systemctl enable "$PATRONI_UNIT" 2>/dev/null
    if done_ patroni; then
        if systemctl -q is-active "$PATRONI_UNIT"; then
            if [[ ${#CHANGED[@]} -gt 0 ]]; then
                # Patroni reads its settings and its REST API's certificate
                # again; PostgreSQL its certificate, on a reload of its own.
                systemctl reload "$PATRONI_UNIT"
                pg -c 'SELECT pg_reload_conf()' >/dev/null || warn "cannot reload PostgreSQL's settings"
            fi
        else
            systemctl start "$PATRONI_UNIT"
        fi
    elif [[ $NAME == "$FIRST" ]] && lead=$(leader) && [[ -z $lead || $lead == "$NAME" ]]; then
        systemctl start "$PATRONI_UNIT"
        wait_for "this server's Patroni to create the cluster" 600 leading || exit 1
    else
        if [[ $NAME == "$FIRST" ]]; then
            # Rebuilt: the cluster runs without it.
            info "the cluster exists, with $lead as its primary: this server copies it, as a standby"
        else
            wait_for "$FIRST's Patroni to create the cluster (run $PROG there)" "$WAIT" has_leader || exit 1
        fi
        systemctl start "$PATRONI_UNIT"
        wait_for "this server to copy the database and stream from the primary" 1800 streaming || exit 1
    fi
    mark patroni
    ok "Patroni: $(members | tr '\n' ' ')"
}

# exists TABLE COLUMN VALUE: whether the yubikey database has the row.
exists() {
    [[ $(pg_var yubikey "$3" "SELECT count(*) FROM $1 WHERE $2 = :'v';" 2>/dev/null) =~ ^[1-9] ]]
}

db_loaded() { exists yubikeys username "anycast-$NAME" && exists service_accounts username "svc.anycast-$NAME"; }

# database_step: on the primary (the first server, unless it failed over),
# the database as db/ has it: made if need be, the roles' passwords, the
# anycast checks of the three servers (each loaded once: a key the check
# renewed since stays; those of servers no longer listed removed), and
# the groups that aren't there. Elsewhere: wait until the database has
# this server's anycast check.
database_step() {
    local login user line kind group dev level reply new=() out skip='' csv lead
    step database
    if ! local_primary; then
        if db_loaded; then
            if [[ $NAME == "$FIRST" ]]; then
                # As after a failover, or on this server rebuilt.
                info "this server's PostgreSQL isn't the primary now: the database was made before; left as it is"
            fi
        elif [[ $NAME != "$FIRST" ]] && ! done_ database && ! exists yubikeys username "anycast-$FIRST"; then
            wait_for "$FIRST to create the database (its $PROG)" "$WAIT" db_loaded || exit 1
        else
            # A server replaced, with a new name: the primary adds its check.
            lead=$(leader)
            wait_for "the primary${lead:+, $lead,} to add this server's anycast check (run $PROG there, with its new folder)" \
                "$WAIT" db_loaded || exit 1
        fi
        ok "the database has this server's anycast check"
        mark database
        return
    fi
    # shellcheck disable=SC2046,SC2086  # one --admin per login
    out=$(ydb init-pg $(printf -- '--admin %s ' $ADMINS) 2>&1) || { printf '%s\n' "$out"; die "yubikey-db.sh init-pg failed"; }
    pg_var postgres "$RADIATOR_SCRAM" "ALTER ROLE radiator PASSWORD :'v';" || die "cannot set radiator's password"
    for login in $ADMINS; do
        [[ -n ${ADMIN_SCRAM[$login]-} ]] || die "secrets.env has no ADMIN_SCRAM_$login"
        pg_var postgres "${ADMIN_SCRAM[$login]}" "ALTER ROLE \"$login\" PASSWORD :'v';" \
            || die "cannot set $login's password"
    done
    ok "database yubikey; roles radiator and $ADMINS, with their passwords"

    # The anycast checks' keys and service accounts, each once: a key the
    # check renewed since must stay.
    while IFS= read -r line; do
        user=${line%%,*}
        [[ $user == username ]] && continue
        exists yubikeys username "$user" || new+=("$line")
    done <"$HERE/db/anycast.csv"
    if [[ ${#new[@]} -gt 0 ]]; then
        # A file of postgres's own: it can't open root's pipe as /dev/stdin.
        csv=$(mktemp) || die "cannot make a temporary file"
        { head -1 "$HERE/db/anycast.csv"; printf '%s\n' "${new[@]}"; } >"$csv" && chown postgres "$csv"
        out=$(ydb import "$csv" 2>&1) || { rm -f "$csv"; printf '%s\n' "$out"; die "cannot load the anycast checks' keys"; }
        rm -f "$csv"
    fi
    while IFS=$'\t' read -r user line; do
        exists service_accounts username "$user" && continue
        out=$(printf '%s\n' "$line" | ydb service add "$user" -l 'anycast check' 2>&1) \
            || { printf '%s\n' "$out"; die "cannot add $user"; }
    done <"$HERE/db/services"
    if ! exists user_groups name anycast-check; then
        out=$({ ydb group add anycast-check -l 'yubikey-anycast.sh over TACACS+' && ydb access set anycast-check localhost 1; } 2>&1) \
            || { printf '%s\n' "$out"; die "cannot make the group anycast-check"; }
    fi
    # shellcheck disable=SC2046,SC2086  # one member per server
    out=$(ydb member add anycast-check $(printf 'svc.anycast-%s ' $SERVERS) 2>&1) \
        || { printf '%s\n' "$out"; die "cannot put the anycast checks in anycast-check"; }
    # Those of servers no longer listed: replaced.
    while IFS= read -r user; do
        [[ -n $user && " $SERVERS " != *" ${user#anycast-} "* ]] || continue
        out=$(ydb delete "$user" 2>&1) || { printf '%s\n' "$out"; die "cannot remove $user"; }
        info "removed the anycast check of ${user#anycast-}, which isn't one of the servers now"
    done <<<"$(pg -d yubikey -c "SELECT DISTINCT username FROM yubikeys WHERE username LIKE 'anycast-%' ORDER BY 1")"
    while IFS= read -r user; do
        [[ -n $user && " $SERVERS " != *" ${user#svc.anycast-} "* ]] || continue
        out=$(ydb service delete "$user" 2>&1) || { printf '%s\n' "$out"; die "cannot remove $user"; }
        info "removed the service account $user"
    done <<<"$(pg -d yubikey -c "SELECT username FROM service_accounts WHERE username LIKE 'svc.anycast-%' ORDER BY 1")"
    ok "the anycast checks of $SERVERS: keys, service accounts, group anycast-check"

    # The groups from site.toml, each once.
    while IFS=$'\t' read -r kind group dev level reply; do
        case $kind in
            group)
                if exists user_groups name "$group"; then
                    skip=$group
                    info "group $group exists: left as it is (change it with yubikey-db.sh)"
                    continue
                fi
                skip=''
                out=$(ydb group add "$group" ${dev:+-l "$dev"} 2>&1) || { printf '%s\n' "$out"; die "cannot add group $group"; } ;;
            access)
                [[ $group == "$skip" ]] && continue
                out=$(ydb access set "$group" "$dev" "$level" ${reply:+-r "$reply"} 2>&1) \
                    || { printf '%s\n' "$out"; die "cannot give $group access to $dev"; } ;;
            rule)
                [[ $group == "$skip" ]] && continue
                # The rule is the fourth field (level).
                out=$(ydb rule add "$group" "$dev" "$level" 2>&1) \
                    || { printf '%s\n' "$out"; die "cannot add a rule for $group on $dev"; } ;;
            ''|'#'*) ;;
            *) die "$HERE/db/groups: unknown line '$kind'" ;;
        esac
        [[ $kind == group ]] && ok "group $group"
    done <"$HERE/db/groups"
    mark database
}

radiator_step() {
    local f clause target restart=0
    step radiator
    if put /etc/radiator/dictionary.yubikey 0644 root:root <"$PKG/dictionary.yubikey"; then restart=1; fi
    install_files radiator
    [[ ${#CHANGED[@]} -gt 0 ]] && restart=1
    # Devices that are no longer in site.toml.
    for f in /etc/radiator/clients.d/*.conf; do
        [[ -f $f ]] || continue
        [[ $(head -1 "$f") == *"$MARK"* ]] || continue
        grep -q " file [0-9]* [^ ]* [^ ]* ${f#/}\$" "$HERE/files.list" && continue
        rm -f "$f"
        info "removed $f"
        restart=1
    done
    # The database clause, from 'yubikey-db.sh config', with Radiator's
    # password. With partition mode, yubikey.conf is a link that
    # yubikey-partition.sh switches.
    target=$CONF_D/yubikey.conf
    [[ -L $target ]] && target=$CONF_D/yubikey-cluster.conf
    clause=$(PGHOST=${FQDNS// /,} PGSSLMODE=verify-full PGSSLROOTCERT=/etc/radiator/pg-ca.crt \
                 "$PKG/yubikey-db.sh" -b pg config) || die "yubikey-db.sh config failed"
    # shellcheck disable=SC2001  # a line at a time
    if sed "s/^\( *\)DBAuth *\$/\1DBAuth       $RADIATOR_PASSWORD/" <<<"$clause" | put "$target" 0640 root:radiator; then
        restart=1
    fi
    systemctl enable radiator 2>/dev/null
    if [[ $restart == 1 ]] || ! systemctl -q is-active radiator; then
        systemctl restart radiator || die "Radiator didn't start: journalctl -u radiator"
    fi
    wait_for "Radiator to listen on RADIUS and TACACS+" 60 radiator_listening || {
        tail -20 "$RAD_LOG" 2>/dev/null
        exit 1
    }
    ok "Radiator listens on UDP 1812 and TCP 49"
}

radiator_listening() {
    grep -qF "127.0.0.1:1812" <<<"$(ss -Hlun "( sport = :1812 )")" \
        && grep -qF "127.0.0.1:49" <<<"$(ss -Hltn "( sport = :49 )")"
}

partition_step() {
    [[ $PARTITION == 1 ]] || return 0
    step partition
    install_files partition
    if [[ ! -L $CONF_D/yubikey.conf ]]; then
        "$PKG/yubikey-partition.sh" setup | sed 's/^/  ..    /' || die "yubikey-partition.sh setup failed"
    fi
    systemctl enable yubikey-partition 2>/dev/null
    if [[ ${#CHANGED[@]} -gt 0 ]] && systemctl -q is-active yubikey-partition; then
        systemctl restart yubikey-partition
    else
        systemctl start yubikey-partition
    fi
    ok "partition mode: yubikey-partition runs; Radiator uses $(readlink "$CONF_D/yubikey.conf")"
}

# anycast_key: the check's key on a server that has none (new, rebuilt, or
# after --reset): the folder's, with the private ID and AES key that the
# database has, which differ once the check renewed them, and the
# database's counter, so that its first OTP is above the last one used.
anycast_key() {
    local dir=/var/lib/yubikey-anycast src=$HERE/files/var/lib/yubikey-anycast/key row pub priv aes made counter
    [[ -f $dir/key ]] && return 0
    row=$(pg_var yubikey "anycast-$NAME" \
              "SELECT tokenid, userid, secret, extract(epoch FROM created)::bigint, counter FROM yubikeys WHERE username = :'v';") \
        || die "cannot read anycast-$NAME's key in the database"
    IFS='|' read -r pub priv aes made counter <<<"$row"
    [[ -n $pub ]] || die "the database has no key for anycast-$NAME"
    if [[ $pub != "$(sed -n 's/^public_id=//p' "$src")" ]]; then
        bad "the database's key for anycast-$NAME (public ID $pub) isn't the one in the folder: make one again with yubikey-anycast.sh enroll"
        return 0
    fi
    install -d -m 0700 "$dir" || die "cannot make $dir"
    if [[ $priv == "$(sed -n 's/^private_id=//p' "$src")" ]]; then
        put "$dir/key" 0600 root:root <"$src"
    else
        # AES keys are hex, or base64 as some imports store them.
        [[ $aes =~ ^[0-9a-fA-F]{32}$ ]] || aes=$(perl -MMIME::Base64 -e 'print unpack("H*", decode_base64($ARGV[0]))' "$aes")
        [[ $aes =~ ^[0-9a-fA-F]{32}$ ]] || die "anycast-$NAME's AES key in the database is neither hex nor base64"
        sed -e "s/^private_id=.*/private_id=$priv/" -e "s/^aes_key=.*/aes_key=${aes,,}/" -e "s/^made=.*/made=$made/" "$src" \
            | put "$dir/key" 0600 root:root
        info "the anycast check's key from the database: renewed on $(date -u -d "@$made" +%F)"
    fi
    printf '%s\n' "$counter" | put "$dir/counter" 0600 root:root
}

anycast_step() {
    local restart_frr=0 out
    step anycast
    anycast_key
    install_files anycast
    changed /etc/frr/frr.conf && restart_frr=1
    if grep -Eq '^(bgpd|bfdd)=no' /etc/frr/daemons; then
        sed -i 's/^bgpd=no/bgpd=yes/; s/^bfdd=no/bfdd=yes/' /etc/frr/daemons
        restart_frr=1
    fi
    systemctl enable frr 2>/dev/null
    if [[ $restart_frr == 1 ]] || ! systemctl -q is-active frr; then systemctl restart frr || die "FRR didn't start"; fi
    systemctl enable yubikey-anycast 2>/dev/null
    if systemctl -q is-active yubikey-anycast; then
        if changed /etc/radiator/anycast.conf; then systemctl restart yubikey-anycast; fi
    else
        if out=$("$PKG/yubikey-anycast.sh" check 2>&1); then
            ok "the anycast check: $out"
        else
            bad "the anycast check: $out"
        fi
        systemctl start yubikey-anycast
    fi
}

backup_step() {
    local out
    step backup
    if [[ $BACKUP != 1 ]]; then
        if systemctl -q is-enabled yubikey-backup.timer 2>/dev/null; then
            systemctl disable --now yubikey-backup.timer 2>/dev/null
            info "turned the daily backup off (no [backup] in site.toml); the backups in /var/backups stay"
        else
            info "none (no [backup] in site.toml)"
        fi
        return
    fi
    install_files backup
    systemctl enable --now yubikey-backup.timer 2>/dev/null || die "cannot start yubikey-backup.timer"
    # The first backup, and the first to a new certificate, now.
    if [[ ! -e /var/backups/yubikey-db.cms.0 ]] || changed /etc/radiator/backup.crt; then
        if ! systemctl start yubikey-backup.service; then
            out=$("$PKG/yubikey-backup.sh" status 2>&1 | head -1)
            bad "the backup failed: ${out:-?} (journalctl -u yubikey-backup)"
            return
        fi
    fi
    out=$("$PKG/yubikey-backup.sh" status 2>&1 | head -1)
    ok "backups: every day at about 03:00, in /var/backups; ${out:-?}"
}

firewall_step() {
    local peer
    step firewall
    if [[ $FIREWALL != 1 ]]; then info "left alone (firewall disabled in site.toml)"; return; fi
    if [[ $NO_FIREWALL == 1 ]]; then info "left alone (--no-firewall)"; return; fi
    peer=$(firewall_guard) || die "an SSH connection comes from $peer, outside the admin subnets ($ADMIN_SUBNETS): the firewall would lock it out"
    if command -v ufw >/dev/null && grep -q 'Status: active' <<<"$(ufw status 2>/dev/null)"; then
        ufw disable >/dev/null && info "turned ufw off"
    fi
    systemctl disable --now ufw 2>/dev/null
    install_files firewall
    if [[ ${#CHANGED[@]} -gt 0 || $(iptables -S INPUT 2>/dev/null | head -1) != "-P INPUT DROP" ]]; then
        iptables-restore </etc/iptables/rules.v4 || die "iptables-restore failed"
        ip6tables-restore </etc/iptables/rules.v6 || die "ip6tables-restore failed"
    fi
    systemctl enable netfilter-persistent 2>/dev/null
    ok "firewall: $(($(iptables -S INPUT | wc -l) - 1)) IPv4 and $(($(ip6tables -S INPUT | wc -l) - 1)) IPv6 rules"
}

# bgp_sessions: the BGP sessions, as UP<tab>ALL<tab>"ADDRESS STATE, ...";
# nothing when FRR doesn't answer.
bgp_sessions() {
    timeout 10 vtysh -c 'show bgp summary json' 2>/dev/null | python3 -c '
import json, sys
peers = {}
for af in json.load(sys.stdin).values():
    for a, p in af.get("peers", {}).items():
        peers[a] = p.get("state", "?")
up = sum(s == "Established" for s in peers.values())
print("%d\t%d\t%s" % (up, len(peers), ", ".join("%s %s" % (a, s) for a, s in sorted(peers.items())) or "none"))' 2>/dev/null
}

report() {
    local status bgp
    step report
    printf '  Patroni:  %s\n' "$(members | tr '\n' ' ')"
    for _ in $(seq 15); do
        "$PKG/yubikey-anycast.sh" status >/dev/null 2>&1 && break
        sleep 2
    done
    status=$("$PKG/yubikey-anycast.sh" status 2>&1)
    printf '  anycast:  %s\n' "$(head -2 <<<"$status" | paste -sd';' | sed 's/;/; /')"
    bgp=$(bgp_sessions | cut -f3)
    printf '  BGP:      %s\n' "${bgp:-cannot ask FRR}"
    if ! grep -q '^advertised' <<<"$status"; then
        PROBLEMS=$((PROBLEMS + 1))
        printf '  The anycast addresses are not advertised yet: see yubikey-anycast.sh status, and journalctl -u yubikey-anycast\n'
    fi
    if [[ $bgp != *Established* ]]; then
        printf '  No BGP session is up yet: set up the routers (routers.md)\n'
    fi
}

# --------------------------------------------------------------------------
# --status
# --------------------------------------------------------------------------

LAG_MB=16           # a standby further behind (in MB) is a warning
S_LINES=() S_WARN=() S_FAIL=()
s_ok()   { S_LINES+=("  ok    $*"); }
s_warn() { S_LINES+=("  WARN  $*"); S_WARN+=("$*"); }
s_fail() { S_LINES+=("  FAIL  $*"); S_FAIL+=("$*"); }

# folder_sum: a checksum of this folder (of the packages, their names only).
folder_sum() {
    (cd "$HERE" && { find . -type f ! -name '*.deb' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; ls -1 -- *.deb 2>/dev/null; }) \
        | sha256sum | cut -d' ' -f1
}

# cert_end FILE: the day the certificate in FILE expires (YYYY-MM-DD).
cert_end() {
    openssl x509 -noout -enddate -dateopt iso_8601 -in "$1" 2>/dev/null | sed -n 's/^notAfter=\([0-9-]\{10\}\).*/\1/p'
}

status_services() {
    local u down=() units=(etcd "$PATRONI_UNIT" radiator frr yubikey-anycast)
    [[ $PARTITION == 1 ]] && units+=(yubikey-partition)
    for u in "${units[@]}"; do systemctl -q is-active "$u" || down+=("$u"); done
    if [[ ${#down[@]} -gt 0 ]]; then
        s_fail "not running: ${down[*]} (systemctl status ${down[0]})"
    else
        s_ok "running: ${units[*]}"
    fi
}

# The three members, at their own addresses: this server's may be the one
# that is down.
status_etcd() {
    local ip eps='' out n=0 i=0 down=() names
    read -ra names <<<"$SERVERS"
    for ip in $IPV4S; do eps+=${eps:+,}https://$ip:2379; done
    out=$(timeout 15 etcdctl --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt \
              --key /etc/etcd/tls/server.key --endpoints "$eps" --dial-timeout 2s --command-timeout 4s \
              endpoint health 2>&1)
    for ip in $IPV4S; do
        if grep -qF "https://$ip:2379 is healthy" <<<"$out"; then n=$((n + 1)); else down+=("${names[i]}"); fi
        i=$((i + 1))
    done
    case $n in
        3) s_ok "etcd: 3 members healthy" ;;
        2) s_warn "etcd: 2 of 3 members healthy (not ${down[*]})" ;;
        *) s_fail "etcd: no quorum ($n of 3 members healthy)" ;;
    esac
}

# The primary, each member's state and lag, and pending restarts.
status_patroni() {
    local out level='' text=''
    if ! out=$(timeout 15 patronictl -c $PATRONI list -e -f json 2>/dev/null); then
        s_fail "Patroni: cannot list the cluster (patronictl -c $PATRONI list)"
        return
    fi
    IFS=$'\t' read -r level text < <(python3 -c '
import json, sys
me, first, names, most = sys.argv[1], sys.argv[2], sys.argv[3].split(), int(sys.argv[4])
ms = {m["Member"]: m for m in json.load(sys.stdin)}
fail, warn, parts = [], [], []
leader = [n for n, m in ms.items() if m["Role"] == "Leader" and m["State"] == "running"]
if not leader:
    fail.append("no primary")
elif leader[0] != first:
    warn.append("the primary is %s, not %s (patronictl switchover --candidate %s)" % (leader[0], first, first))
for n in names:
    m = ms.get(n)
    if m is None:
        (fail if n == me else warn).append("%s is missing" % n)
        continue
    good = m["State"] == ("running" if m["Role"] == "Leader" else "streaming")
    lags = [v for v in (m.get("Receive Lag"), m.get("Replay Lag")) if isinstance(v, int)]
    lag = max(lags) if lags and m["Role"] != "Leader" else None
    parts.append("%s %s%s%s" % (n, m["Role"], "" if good else ", " + m["State"],
                                "" if lag is None else ", lag %d MB" % lag))
    if not good:
        (fail if n == me else warn).append("%s is %s" % (n, m["State"]))
    elif lag is not None and lag > most:
        warn.append("%s is %d MB behind" % (n, lag))
    if m.get("Pending restart"):
        why = str(m.get("Pending restart reason") or "").replace("\n", ", ")
        warn.append("%s needs a restart%s" % (n, " (%s)" % why if why else ""))
text = "; ".join(parts)
if fail or warn:
    text = "%s (%s)" % ("; ".join(fail + warn), text)
print("%s\tPatroni: %s" % ("fail" if fail else "warn" if warn else "ok", text))' "$NAME" "$FIRST" "$SERVERS" "$LAG_MB" <<<"$out" 2>/dev/null)
    case $level in
        ok|warn|fail) "s_$level" "$text" ;;
        *) s_fail "Patroni: cannot read patronictl's list" ;;
    esac
}

# UDP 1812 and 1813 and TCP 49, at 127.0.0.1 (the anycast check) and at the
# anycast addresses (the devices).
status_radiator() {
    local a p udp tcp miss=()
    udp=$(ss -Hlun 2>/dev/null | awk '{ print $4 }')
    tcp=$(ss -Hltn 2>/dev/null | awk '{ print $4 }')
    for a in 127.0.0.1 ${ANYCAST4:+"$ANYCAST4"} ${ANYCAST6:+"[$ANYCAST6]"}; do
        for p in 1812 1813; do grep -qxF "$a:$p" <<<"$udp" || miss+=("UDP $a:$p"); done
        grep -qxF "$a:49" <<<"$tcp" || miss+=("TCP $a:49")
    done
    if [[ ${#miss[@]} -gt 0 ]]; then
        s_fail "Radiator: not listening on $(printf '%s, ' "${miss[@]}" | sed 's/, $//') ($RAD_LOG)"
    else
        s_ok "Radiator: listening on UDP 1812 and 1813 and TCP 49, at 127.0.0.1 and the anycast addresses"
    fi
}

# Whether the anycast addresses are advertised, the last check, and the
# check's key.
status_anycast() {
    local out rc first last ago key days level=ok
    out=$("$PKG/yubikey-anycast.sh" status 2>&1); rc=$?
    first=$(head -1 <<<"$out")
    last=$(sed -n 's/^last check: //p' <<<"$out")
    ago=$(sed -nE 's/.*, ([0-9]+) s ago$/\1/p' <<<"$last")
    if [[ $rc != 0 ]]; then
        level=fail
    elif [[ -n $ago && $ago -gt 60 ]]; then
        level=warn
    fi
    "s_$level" "anycast: $first${last:+; last check: $last}"
    key=$(sed -n 's/^key: //p' <<<"$out")
    days=$(sed -nE 's/^OTPs left: [0-9]+ \(([0-9]+) days .*/\1/p' <<<"$out")
    if [[ -n $days && $days -lt 7 ]]; then
        s_fail "the check's key: OTPs for $days days left${key:+ ($key)}"
    elif [[ $key =~ ^next\ renewal\ on\ ([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then
        if [[ ${BASH_REMATCH[1]} < $(date +%F) ]]; then
            s_warn "the check's key: the renewal of ${BASH_REMATCH[1]} hasn't worked yet (journalctl -u yubikey-anycast)"
        else
            s_ok "the check's key: $key"
        fi
    elif [[ -n $key ]]; then
        s_warn "the check's key: $key"
    fi
}

status_partition() {
    local out rc first copy failed
    if [[ $PARTITION != 1 ]]; then s_ok "partition mode: off in site.toml"; return; fi
    out=$("$PKG/yubikey-partition.sh" status 2>&1); rc=$?
    first=$(head -1 <<<"$out")
    copy=$(sed -n 's/^copy: //p' <<<"$out")
    failed=$(sed -n 's/^copy not updated: //p' <<<"$out")
    if [[ $first == *'not running'* ]]; then
        s_fail "partition mode: $first"
    elif [[ $rc != 0 ]]; then
        s_warn "$first: Radiator uses this server's copy (${copy:-?}); journalctl -u yubikey-partition"
    else
        s_ok "$first; the copy for partition mode: ${copy:-?}"
    fi
    if [[ -n $failed ]]; then s_warn "partition mode: the copy isn't updated: $failed"; fi
}

status_bgp() {
    local up total text
    IFS=$'\t' read -r up total text <<<"$(bgp_sessions)"
    if [[ -z $up ]]; then
        s_fail "BGP: cannot ask FRR (vtysh -c 'show bgp summary')"
    elif [[ $up == "$total" && $total -gt 0 ]]; then
        s_ok "BGP: $text"
    elif [[ $up -gt 0 ]]; then
        s_warn "BGP: $text"
    else
        s_fail "BGP: no session up ($text): no router sends devices here"
    fi
}

status_backup() {
    local out rc first kept
    if [[ $BACKUP != 1 ]]; then s_ok "backups: none (no [backup] in site.toml)"; return; fi
    out=$("$PKG/yubikey-backup.sh" status 2>&1); rc=$?
    first=$(head -1 <<<"$out")
    kept=$(sed -n 's/^kept: \([0-9]* of [0-9]*\).*/\1 kept/p' <<<"$out")
    if ! systemctl -q is-active yubikey-backup.timer; then
        s_warn "backups: the daily timer is off (systemctl enable --now yubikey-backup.timer); $first"
    elif [[ $rc == 0 ]]; then
        s_ok "backups: $first${kept:+, $kept}"
    else
        s_warn "backups: $first (yubikey-backup.sh status; journalctl -u yubikey-backup)"
    fi
}

status_firewall() {
    if [[ $FIREWALL != 1 ]]; then s_ok "firewall: off in site.toml"; return; fi
    if [[ $(iptables -S INPUT 2>/dev/null | head -1) == "-P INPUT DROP" \
          && $(ip6tables -S INPUT 2>/dev/null | head -1) == "-P INPUT DROP" ]]; then
        s_ok "firewall: $(($(iptables -S INPUT | wc -l) - 1)) IPv4 and $(($(ip6tables -S INPUT | wc -l) - 1)) IPv6 rules"
    else
        s_warn "firewall: not loaded (setup.sh loads it)"
    fi
}

# The server's certificate (etcd, Patroni and PostgreSQL use the same) and
# the CA's.
status_certs() {
    local crt=/etc/patroni/tls/server.crt ca=/etc/patroni/tls/ca.crt end ca_end
    end=$(cert_end "$crt") ca_end=$(cert_end "$ca")
    if [[ -z $end || -z $ca_end ]]; then
        s_fail "certificates: cannot read $crt or $ca"
    elif ! openssl x509 -noout -checkend 0 -in "$crt" >/dev/null; then
        s_fail "certificates: this server's expired on $end (yubikey-turnkey --renew-certs, then setup.sh on each server)"
    elif ! openssl x509 -noout -checkend $((60 * 86400)) -in "$crt" >/dev/null; then
        s_warn "certificates: this server's expires on $end (yubikey-turnkey --renew-certs, then setup.sh on each server)"
    elif ! openssl x509 -noout -checkend $((60 * 86400)) -in "$ca" >/dev/null; then
        s_warn "certificates: the CA's expires on $ca_end"
    else
        s_ok "certificates: this server's until $end, the CA's until $ca_end"
    fi
}

status_system() {
    local avail
    avail=$(df -P -k /var/lib 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }')
    if [[ -z $avail ]]; then
        s_warn "disk: cannot tell how much of /var/lib is free"
    elif ((avail < 1)); then
        s_fail "disk: less than 1 GiB free in /var/lib"
    elif ((avail < 10)); then
        s_warn "disk: $avail GiB free in /var/lib (PostgreSQL keeps up to 8 GB of WAL for a standby that is down)"
    else
        s_ok "disk: $avail GiB free in /var/lib"
    fi
    case $(timedatectl show -p NTPSynchronized --value 2>/dev/null) in
        yes) s_ok "clock synchronized" ;;
        no)  s_warn "the clock isn't synchronized (NTP)" ;;
        *)   s_warn "cannot tell whether the clock is synchronized (timedatectl)" ;;
    esac
}

# Whether setup.sh finished, with this folder and this version.
status_setup() {
    local have
    have=$(pkg_version radiator-yubikey)
    if ! done_ setup; then
        s_warn "setup.sh hasn't finished on this server: run it"
    elif [[ $have != "$VERSION" ]]; then
        s_warn "setup.sh: the folder is for radiator-yubikey $VERSION, but ${have:-none} is installed: run setup.sh"
    elif [[ $ENV_DIR == "$HERE" && $(folder_sum) != "$(cat "$STATE/folder" 2>/dev/null)" ]]; then
        s_warn "setup.sh: $HERE has changed since setup.sh last finished: run it"
    else
        s_ok "setup.sh: finished $(cat "$STATE/setup"), radiator-yubikey $VERSION"
    fi
}

status() {
    local rc=0 summary=OK
    status_services
    status_etcd
    status_patroni
    status_radiator
    status_anycast
    status_partition
    status_bgp
    status_backup
    status_firewall
    status_certs
    status_system
    status_setup
    if [[ ${#S_FAIL[@]} -gt 0 ]]; then
        rc=2 summary=CRITICAL
    elif [[ ${#S_WARN[@]} -gt 0 ]]; then
        rc=1 summary=WARNING
    fi
    if [[ $rc != 0 ]]; then
        summary+=" - $(printf '%s; ' "${S_FAIL[@]}" "${S_WARN[@]}" | sed 's/; $//')"
    fi
    printf '%s: %s\n\n' "$NAME" "$summary"
    printf '%s\n' "${S_LINES[@]}"
    exit "$rc"
}

reset() {
    [[ $(id -u) == 0 ]] || die "run it as root (sudo ./$PROG)"
    [[ $RESET == "$NAME" && $(hostname -s) == "$NAME" ]] \
        || die "--reset needs this server's host name, $NAME, and this server's folder"
    step "reset $NAME"
    local u
    for u in yubikey-backup.timer yubikey-anycast yubikey-partition radiator "$PATRONI_UNIT" etcd; do
        systemctl disable --now "$u" 2>/dev/null
    done
    rm -rf /var/lib/etcd/default /var/lib/yubikey-anycast /var/lib/yubikey-partition "$STATE"
    if grep -q '^18 main ' <<<"$(pg_lsclusters -h 2>/dev/null)"; then pg_dropcluster --stop 18 main; fi
    rm -rf /var/lib/postgresql/18/main /etc/postgresql/18/main
    rm -f "$CONF_D"/yubikey.conf "$CONF_D"/yubikey-cluster.conf "$CONF_D"/yubikey-partition.conf
    ip addr del "$ANYCAST4/32" dev lo 2>/dev/null
    ip -6 addr del "$ANYCAST6/128" dev lo 2>/dev/null
    ok "stopped etcd, Patroni, Radiator, the checks and the backups; removed their data (the backups in /var/backups stay). Run $PROG: on this server alone, while the other two run, it joins them again; after --reset on all three, on all three."
}

# alone: when the other two servers are lost for good, this server the
# cluster alone: its etcd a cluster of one, with its data (Patroni's), and
# its PostgreSQL the primary. Then setup.sh on the other two, set up again,
# adds their etcd members (as learners first) and copies the database.
alone() {
    [[ $(id -u) == 0 ]] || die "run it as root (sudo ./$PROG)"
    done_ setup || die "--alone: setup.sh hasn't finished on this server: it isn't one of the cluster's"
    step "alone: $NAME"
    local ip port answers='' answer out
    for ip in $IPV4S; do
        [[ $ip == "$IPV4" ]] && continue
        for port in 2379 2380 5432 8008; do
            if timeout 3 bash -c "</dev/tcp/$ip/$port" 2>/dev/null; then answers+=" $ip:$port"; fi
        done
    done
    [[ -z $answers ]] || die "--alone: the others answer (TCP$answers): it is only for when both are lost for good"
    ok "the other two answer on none of etcd's, PostgreSQL's and Patroni's ports"
    if [[ $YES == 0 ]]; then
        printf '%s\n' "This makes $NAME the cluster alone: its etcd forgets the other two servers, and its" \
            "PostgreSQL becomes the primary. Only when both are lost for good: if they still run, cut off" \
            "from here, they go on as a cluster of their own, and there are two primaries."
        [[ -t 0 ]] || die "--alone: answer on a terminal, or add --yes"
        read -r -p "Make $NAME the cluster alone? Type yes: " answer
        [[ $answer == yes ]] || die "--alone: nothing changed"
    fi
    # etcd: once with --force-new-cluster, which keeps the data and makes
    # this server its only member; then as before.
    if ! etcd_one; then
        printf 'ETCD_FORCE_NEW_CLUSTER=true\n' >>/etc/default/etcd
        systemctl restart etcd || die "etcd didn't start as a cluster of one (journalctl -u etcd)"
        install_files etcd >/dev/null
        systemctl restart etcd || die "etcd didn't start (journalctl -u etcd)"
        wait_for "etcd, a cluster of one" 60 etcd_one || exit 1
    fi
    ok "etcd: a cluster of one, $NAME"
    # Patroni, in quorum mode, doesn't promote this server by itself: without
    # the other standby, it can't tell that this one has every transaction.
    # Once the lost primary's leader key has expired (in up to 30 s): a
    # failover to this server.
    if ! leading; then
        wait_for "the lost primary's leader key to expire" 120 no_leader || exit 1
        out=$(patronictl -c $PATRONI failover --candidate "$NAME" --force 2>&1) \
            || die "Patroni: cannot fail over to $NAME: $out"
        wait_for "this server's PostgreSQL to become the primary" 120 leading || exit 1
    fi
    ok "Patroni: $NAME's PostgreSQL is the primary"
    if [[ $PARTITION == 1 ]]; then
        info "partition mode stays on until one of the other two answers again; then the counters of the logins in between go into the database"
    fi
    ok "$NAME is the cluster alone. Now set up the other two again: new servers with the same names and addresses, their folders, and setup.sh on both (see \"Two servers lost\" in the guide)."
}

# etcd_one: this server's etcd, healthy, its only member.
etcd_one() {
    [[ $(etcdctl_ member list 2>/dev/null | wc -l) == 1 ]] && etcdctl_ endpoint health >/dev/null 2>&1
}

# no_leader: no member of Patroni's cluster leads, or this server.
no_leader() {
    local lead
    lead=$(leader)
    [[ -z $lead || $lead == "$NAME" ]]
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--check)    CHECK=1; shift ;;
            --no-firewall) NO_FIREWALL=1; shift ;;
            --reset)       RESET=${2:?--reset needs this server\'s host name}; shift 2 ;;
            --status)      STATUS=1; shift ;;
            --alone)       ALONE=1; shift ;;
            --yes)         YES=1; shift ;;
            -h|--help)     usage; exit 0 ;;
            *) printf '%s: unknown option %s (see --help)\n' "$PROG" "$1" >&2; exit 2 ;;
        esac
    done
    if [[ $YES == 1 && $ALONE == 0 ]]; then
        printf '%s: --yes goes with --alone (see --help)\n' "$PROG" >&2
        exit 2
    fi
    if [[ $ALONE == 1 && ( $CHECK == 1 || $NO_FIREWALL == 1 || -n $RESET || $STATUS == 1 ) ]]; then
        printf '%s: --alone goes alone, or with --yes (see --help)\n' "$PROG" >&2
        exit 2
    fi
    if [[ $STATUS == 1 ]]; then
        if [[ $CHECK == 1 || $NO_FIREWALL == 1 || -n $RESET ]]; then
            printf '%s: --status goes alone (see --help)\n' "$PROG" >&2
            exit 2
        fi
        [[ $(id -u) == 0 ]] || die "run it as root (sudo $0 --status)"
        # The folder's server.env, or the copy that setup.sh keeps.
        [[ -f $HERE/server.env ]] || ENV_DIR=$KEEP
        [[ -f $ENV_DIR/server.env ]] || die "no server.env next to $0 or in $KEEP: setup.sh hasn't run on this server"
        read_env "$ENV_DIR/server.env"
        [[ -n $NAME && -n $VERSION ]] || die "$ENV_DIR/server.env is incomplete"
        status
    fi
    read_env "$HERE/server.env"
    read_env "$HERE/secrets.env"
    [[ -n $NAME && -n $VERSION ]] || die "$HERE/server.env is incomplete"
    if [[ -n $RESET ]]; then reset; exit 0; fi
    if [[ $ALONE == 1 ]]; then alone; exit 0; fi
    if [[ $CHECK == 0 ]]; then
        [[ $(id -u) == 0 ]] || die "run it as root (sudo ./$PROG)"
        mkdir -p "$STATE"
        exec > >(tee -a "$LOG") 2>&1
        printf '\n%s: %s, radiator-yubikey %s, %s on %s\n' "$(date -u '+%F %T UTC')" "$PROG" "$VERSION" "$NAME" "$SITE_NAME"
    fi
    preflight
    if [[ $CHECK == 1 ]]; then
        if [[ $PROBLEMS == 0 ]]; then printf '\nNothing to fix.\n'; exit 0; fi
        printf '\n%d thing(s) to fix.\n' "$PROBLEMS"
        exit 1
    fi
    [[ $PROBLEMS == 0 ]] || die "fix what the preflight reports first ($PROG --check)"
    packages
    system_step
    etcd_step
    patroni_step
    database_step
    radiator_step
    partition_step
    anycast_step
    backup_step
    firewall_step
    # Every step is done, with this folder (for --status).
    mark setup
    folder_sum >"$STATE/folder"
    report
    if [[ $PROBLEMS == 0 ]]; then
        printf '\n%s is set up.\n' "$NAME"
        exit 0
    fi
    printf '\n%s: set up, with %d problem(s) above.\n' "$NAME" "$PROBLEMS"
    exit 1
}

main "$@"
