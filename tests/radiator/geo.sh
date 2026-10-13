#!/usr/bin/env bash
#
# geo.sh - Test Radiator with PostgreSQL on three sites under Patroni, and one
# anycast address for all three, through reboots, power losses and network
# partitions, in Docker containers.
#
# Usage: tests/radiator/geo.sh IMAGE
#   IMAGE is the test image that tests/radiator/run.sh builds, for example
#   yk-radiator-test:4.30-1. run.sh runs this script after ha.sh.
#
# One container per site, on the Docker network yk-geo (172.31.97.0/24), each
# running systemd with etcd, PostgreSQL 18 under Patroni (patroni@18-main)
# and Radiator, as the guide's "Three sites" section sets them up:
#   yk-geo-east1  172.31.97.11  east1.yk.test: the usual primary
#   yk-geo-east2  172.31.97.12  east2.yk.test
#   yk-geo-west   172.31.97.13  west.yk.test: primary only as a
#                               last resort (failover_priority 1, not 2)
# Traffic control in each container adds the WAN: 55 ms round trip between
# West and East, 4 ms between the East sites. Patroni keeps one standby
# synchronous ("ANY 1 (east2,west)"), so every committed login is on two
# sites. Every Radiator server lists PGHOST=east1,east2,west and uses
# whichever is the primary.
#
# Anycast, as the guide's "Anycast" section sets it up: each site's FRR
# advertises 192.0.2.153 and 2001:db8:153::153 with BGP, with BFD, while
# yubikey-anycast.sh keeps them on lo (while its logins work). One more
# container stands in for West's router (yk-geo-rtr, FRR; 172.31.97.2 and
# fd53:97::2 on yk-geo, 172.31.98.2 and fd53:98::2 on yk-geo-nas): it
# prefers West, then East1, then East2. Behind it, a RADIUS client
# (yk-geo-nas, 172.31.98.10 and fd53:98::10) logs in at the anycast
# addresses. The sites run yubikey-anycast.sh and yubikey-partition.sh from
# the radiator-yubikey package, with its systemd units. The steps in the
# containers are in geo-node.sh.
#
# The containers get CAP_SYS_ADMIN (systemd mounts its cgroups) and
# CAP_NET_ADMIN (traffic control in their own network), not --privileged:
# they see no host devices and cannot change host kernel settings.
#
# Checks: the cluster forms with a synchronous standby; logins work at every
# site, and how long they take; Patroni's REST API tells the primary from the
# standbys; a reboot of each server, one at a time, loses no OTP, and East2,
# not West, takes over from the primary; so it does when the primary loses
# power; a Patroni crash on the primary changes nothing; West cut off from
# both East sites rejects logins (it has no primary), doesn't promote itself,
# and catches up after; the primary's site cut off steps down and is rewound
# when it rejoins; with the link between the East sites broken, East1 stays
# the primary through West; a standby can be copied again; with two servers
# down, the last one stops being the primary. Planned switchovers bring the
# primary back to East1 after each failover.
# Partition mode, as the guide's "Partition mode" section sets it up, last:
# a server that no other site answers logs users in from its own copy of the
# keys, and copies the counters back to the primary when the network is back
# (West cut off, the primary cut off, two servers down); one that still
# reaches another site doesn't.
# Anycast checks: all three sites advertise, and West answers the client,
# from the anycast address, over IPv4 and IPv6; the check's user is
# rejected from the client; West withdraws when its Radiator stops and when
# its check is stopped, and advertises again after; the router drops West
# within a second or two when it loses power (BFD); a site that can't reach
# the primary withdraws, and so does every site while there is none.
# Set KEEP=1 to leave the containers running afterwards.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$(dirname -- "$here")")
image=${1:?usage: tests/radiator/geo.sh IMAGE}
pass=0 fail=0
SITES=(east1 east2 west)

remove_lab() {
    docker rm -f yk-geo-east1 yk-geo-east2 yk-geo-west yk-geo-rtr yk-geo-nas >/dev/null 2>&1
    docker network rm yk-geo yk-geo-nas >/dev/null 2>&1
    docker volume rm yk-geo-lab >/dev/null 2>&1
}
remove_lab
if [[ ${KEEP-} == 1 ]]; then
    trap 'echo "KEEP=1: the containers are still running"' EXIT
else
    trap remove_lab EXIT
fi

docker network create --ipv6 --subnet 172.31.97.0/24 --subnet fd53:97::/64 yk-geo >/dev/null || exit 1
docker network create --ipv6 --subnet 172.31.98.0/24 --subnet fd53:98::/64 yk-geo-nas >/dev/null || exit 1
docker volume create yk-geo-lab >/dev/null || exit 1
# The radiator-yubikey package, in the shared volume, for the sites to install.
docker run --rm -v "$root:/repo:ro" -v yk-geo-lab:/lab "$image" /repo/packaging/build-deb.sh /lab/deb >/dev/null || exit 1

declare -A IP=([east1]=172.31.97.11 [east2]=172.31.97.12 [west]=172.31.97.13 [rtr]=172.31.97.2)
declare -A IP6=([east1]=fd53:97::11 [east2]=fd53:97::12 [west]=fd53:97::13 [rtr]=fd53:97::2)
# SIGRTMIN+3 makes systemd shut down cleanly, so 'docker stop' and 'docker
# restart' are a clean shutdown and reboot; 'docker kill' is a power loss.
# The sites may bind to addresses they don't have (the anycast addresses
# while they are off lo); the router forwards. The host names are short:
# Docker maps a container's host name to its IPv6 address too, and the
# servers reach each other over IPv4 only (as their /etc/hosts lines say).
for n in "${SITES[@]}" rtr; do
    if [[ $n == rtr ]]; then
        sysctls=(--sysctl net.ipv4.ip_forward=1 --sysctl net.ipv6.conf.all.forwarding=1)
    else
        sysctls=(--sysctl net.ipv4.ip_nonlocal_bind=1 --sysctl net.ipv6.ip_nonlocal_bind=1)
    fi
    docker run -d --name "yk-geo-$n" --hostname "$n" --network yk-geo --ip "${IP[$n]}" \
        --ip6 "${IP6[$n]}" "${sysctls[@]}" \
        --add-host east1.yk.test:172.31.97.11 --add-host east2.yk.test:172.31.97.12 \
        --add-host west.yk.test:172.31.97.13 \
        --cap-add SYS_ADMIN --cap-add NET_ADMIN --security-opt apparmor=unconfined --cgroupns private \
        --tmpfs /run --tmpfs /run/lock --stop-signal SIGRTMIN+3 \
        -v "$root:/repo:ro" -v yk-geo-lab:/lab "$image" \
        sh -c 'mount -o remount,rw /sys/fs/cgroup && exec /lib/systemd/systemd' >/dev/null || exit 1
done
docker network connect --ip 172.31.98.2 --ip6 fd53:98::2 yk-geo-nas yk-geo-rtr || exit 1
docker run -d --name yk-geo-nas --hostname nas --network yk-geo-nas --ip 172.31.98.10 \
    --ip6 fd53:98::10 --cap-add NET_ADMIN -v "$root:/repo:ro" "$image" sleep infinity >/dev/null || exit 1

# node NAME COMMAND [ARGS]: one geo-node.sh step on a site's server.
node() {
    local n=$1; shift
    docker exec "yk-geo-$n" bash /repo/tests/radiator/geo-node.sh "$@"
}

# booted NAME: wait for systemd on NAME to finish starting its services.
booted() {
    local s
    for _ in $(seq 120); do
        s=$(docker exec "yk-geo-$1" systemctl is-system-running 2>/dev/null)
        [[ $s == running || $s == degraded ]] && return 0
        sleep 0.5
    done
    echo "$1 did not finish booting ($s)"
    return 1
}

# check LABEL EXPECTED ACTUAL: count and print one result.
check() {
    if [[ $3 == "$2" ]]; then
        pass=$((pass + 1)); printf 'PASS  %s: %s\n' "$1" "$3"
    else
        fail=$((fail + 1)); printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

# between LABEL LOW HIGH VALUE: check that VALUE is a number from LOW to HIGH.
between() {
    if [[ $4 =~ ^[0-9]+$ ]] && (($4 >= $2 && $4 <= $3)); then
        pass=$((pass + 1)); printf 'PASS  %s: %s (%s to %s)\n' "$1" "$4" "$2" "$3"
    else
        fail=$((fail + 1)); printf 'FAIL  %s: expected %s to %s, got %s\n' "$1" "$2" "$3" "$4"
    fi
}

# OTPs are alice's, session 0; C is the counter of the last one sent.
C=0

# login LABEL EXPECTED SITE [COUNTER [TIMEOUT]]: alice logs in at SITE with
# the OTP for COUNTER, by default a new one, waiting up to TIMEOUT seconds
# (default 15) for an answer. Sets MS to the time Radiator took to answer.
MS=0
login() {
    local out counter=${4:-$((C + 1))}
    ((counter > C)) && C=$counter
    out=$(node "$3" login alice s3cr3t "$counter" 0 "${5:-15}")
    MS=$(tail -1 <<<"$out")
    check "$1 [$3, OTP $counter, $MS ms]" "$2" "$(head -1 <<<"$out")"
}

# logins LABEL SITE: five new OTPs at SITE, all to be accepted. Sets MS to
# the median time Radiator took to answer.
logins() {
    local i out answers=() times=()
    for i in 1 2 3 4 5; do
        C=$((C + 1))
        out=$(node "$2" login alice s3cr3t "$C" 0)
        answers+=("$(head -1 <<<"$out")")
        times+=("$(tail -1 <<<"$out")")
    done
    MS=$(printf '%s\n' "${times[@]}" | sort -n | sed -n 3p)
    check "$1 [$2, OTPs $((C - 4)) to $C, median $MS ms]" "ACCEPT ACCEPT ACCEPT ACCEPT ACCEPT" "${answers[*]}"
}

# login_settled LABEL EXPECTED SITE COUNTER: alice logs in at SITE with
# COUNTER's OTP, once a second while there is no answer or Radiator can't
# reach its database (for up to 20 s, as when it restarts); then checks the
# answer. A replayed OTP stays rejected, however often it is sent.
login_settled() {
    local out answer start=$SECONDS
    while :; do
        out=$(node "$3" login alice s3cr3t "$4" 0 5)
        answer=$(head -1 <<<"$out")
        [[ $answer == "NO REPLY" || $answer == "REJECT: Yubikey secret not found in database" ]] || break
        ((SECONDS - start < 20)) || break
        sleep 1
    done
    MS=$(tail -1 <<<"$out")
    check "$1 [$3, OTP $4, $MS ms]" "$2" "$(head -1 <<<"$out")"
}

# login_until LABEL SITE [LIMIT]: a new OTP at SITE once a second until one
# is accepted, for up to LIMIT seconds (default 60). Reports the seconds
# since T0, which the caller sets when the failure starts.
T0=0
login_until() {
    local out start=$SECONDS
    while ((SECONDS - start < ${3:-60})); do
        C=$((C + 1))
        out=$(node "$2" login alice s3cr3t "$C" 0 5 | head -1)
        [[ $out == ACCEPT ]] && break
        sleep 1
    done
    check "$1 [$2, OTP $C, after $((SECONDS - T0)) s]" ACCEPT "$out"
}

# median_login SITE: 20 logins at SITE. Sets LAT[SITE] to the median of the
# last 15, in milliseconds. Each of Radiator's four processes opens its own
# connection to PostgreSQL the first time it handles a login, which takes
# several round trips; at most four logins pay for that, so the median is
# the time of a login on an open connection.
declare -A LAT
median_login() {
    local i out times=()
    for i in $(seq 20); do
        C=$((C + 1))
        out=$(node "$1" login alice s3cr3t "$C" 0)
        [[ $(head -1 <<<"$out") == ACCEPT ]] || { LAT[$1]="no: $(head -1 <<<"$out")"; return; }
        ((i > 5)) && times+=("$(tail -1 <<<"$out")")
    done
    LAT[$1]=$(printf '%s\n' "${times[@]}" | sort -n | sed -n 8p)
}

# cluster LABEL EXPECTED FROM [LIMIT]: poll the members' roles, as FROM sees
# them in etcd, for up to LIMIT seconds (default 60).
cluster() {
    local start=$SECONDS out
    while ((SECONDS - start < ${4:-60})); do
        out=$(node "$3" members 2>/dev/null)
        [[ $out == "$2" ]] && break
        sleep 1
    done
    check "$1 [after $((SECONDS - start)) s]" "$2" "$out"
}

# leader LABEL NAME FROM [LIMIT]: wait for NAME to be the running leader, as
# FROM sees it, for up to LIMIT seconds (default 60). A member that stopped
# stays in the list until its entry in etcd expires (ttl, 30 s).
leader() {
    local start=$SECONDS out
    while ((SECONDS - start < ${4:-60})); do
        out=$(node "$3" members 2>/dev/null)
        [[ " $out " == *" $2=leader "* ]] && break
        sleep 1
    done
    check "$1 [after $((SECONDS - T0)) s]" "$2=leader" "$(grep -o '[a-z0-9]*=leader' <<<"$out")"
}

# wait_for LABEL EXPECTED NODE SQL [LIMIT]: poll SQL on NODE for up to LIMIT
# seconds (default 10).
wait_for() {
    local start=$SECONDS out
    while ((SECONDS - start < ${5:-10})); do
        out=$(node "$3" sql yubikey "$4" 2>/dev/null)
        [[ $out == "$2" ]] && break
        sleep 0.2
    done
    check "$1 [after $((SECONDS - start)) s]" "$2" "$out"
}

# The sites whose Radiator has a session with PRIMARY's PostgreSQL.
uses() {
    local n out=()
    for n in "${SITES[@]}"; do
        [[ $(node "$1" sql yubikey "SELECT count(*) FROM pg_stat_activity
                WHERE usename = 'radiator' AND client_addr = '${IP[$n]}'") -gt 0 ]] && out+=("$n")
    done
    echo "${out[*]}"
}

# partition SITE: cut SITE off from the other two sites; heal SITE: undo it.
partition() {
    local n others=()
    for n in "${SITES[@]}"; do [[ $n != "$1" ]] && others+=("$n"); done
    node "$1" cut "${others[@]}"
    for n in "${others[@]}"; do node "$n" cut "$1"; done
}
heal() {
    local n others=()
    for n in "${SITES[@]}"; do [[ $n != "$1" ]] && others+=("$n"); done
    node "$1" heal "${others[@]}"
    for n in "${others[@]}"; do node "$n" heal "$1"; done
}

# rewinds NAME: how many times Patroni has run pg_rewind on NAME.
rewinds() {
    docker exec "yk-geo-$1" journalctl -u patroni@18-main | grep -c 'pg_rewind exit code=0'
}

# switchover TO SITE: a planned switchover from the current leader to TO;
# reports how long logins at SITE are rejected.
switchover() {
    T0=$SECONDS
    node "$1" ctl switchover --candidate "$1" --force >/dev/null
    login_until "OTP at $2 after a planned switchover to $1" "$2" 30
}

# one_leader LABEL: wait for all three to be up, streaming, with East1 or
# East2 as the leader, for up to 90 s.
one_leader() {
    local start=$SECONDS out
    while ((SECONDS - start < 90)); do
        out=$(node east1 members 2>/dev/null)
        [[ $out =~ ^east1=(leader|quorum)\ east2=(leader|quorum)\ west=quorum$ && $out == *leader* ]] && break
        sleep 1
    done
    check "$1 [after $((SECONDS - start)) s]" "one leader in the East, all streaming" \
        "$( [[ $out =~ ^east1=(leader|quorum)\ east2=(leader|quorum)\ west=quorum$ && $out == *leader* ]] \
            && echo "one leader in the East, all streaming" || echo "$out")"
}

# mode_until LABEL SITE MODE [LIMIT]: wait up to LIMIT seconds (default 60)
# for SITE's partition mode service to be in MODE (normal or partition).
mode_until() {
    local start=$SECONDS out
    while ((SECONDS - start < ${4:-60})); do
        out=$(node "$2" partition-mode 2>/dev/null)
        [[ $out == "$3" ]] && break
        sleep 0.5
    done
    check "$1 [after $((SECONDS - T0)) s]" "$3" "$out"
}

# routes_until LABEL EXPECTED [LIMIT]: wait up to LIMIT seconds (default 60)
# for the anycast routes on West's router to be EXPECTED, as geo-node.sh
# 'routes' prints them. Sets RT to the seconds since T0.
RT=0
routes_until() {
    local start=$SECONDS out
    while ((SECONDS - start < ${3:-60})); do
        out=$(node rtr routes 2>/dev/null)
        [[ $out == "$2" ]] && break
        sleep 0.5
    done
    RT=$((SECONDS - T0))
    check "$1 [after $RT s]" "$2" "$out"
}

# The number of logins from the NAS in each site's authentication log, "x"
# for a site that is down.
nas_logins() {
    local n out
    for n in "${SITES[@]}"; do
        out=$(docker exec "yk-geo-$n" grep -c "client='\(172.31.98.10\|fd53:98::10\)'" \
                  /var/log/radiator/authentication.log 2>/dev/null)
        echo "${out:-x}"
    done | paste -sd' '
}

# nas_login ADDRESS USER PASSWORD: one login from the NAS, behind West's
# router. Sets NAS to "ANSWER by SITE" (SITE from the authentication logs:
# "nobody" when none logged it) and MS to Radiator's time.
NAS=''
nas_login() {
    local before after out who=() i
    before=$(nas_logins)
    out=$(docker exec yk-geo-nas bash /repo/tests/radiator/geo-node.sh nas-login "$@")
    MS=$(tail -1 <<<"$out")
    for _ in 1 2 3 4 5; do
        after=$(nas_logins)
        [[ $after != "$before" ]] && break
        [[ $out == "NO REPLY"* ]] && break
        sleep 0.2
    done
    read -ra b <<<"$before"
    read -ra a <<<"$after"
    for i in 0 1 2; do [[ ${a[i]} != "${b[i]}" && ${a[i]} != x ]] && who+=("${SITES[i]}"); done
    NAS="$(head -1 <<<"$out") by ${who[*]:-nobody}"
}

# nas LABEL EXPECTED FAMILY: alice logs in from the NAS with a new OTP, at
# the IPv4 (FAMILY 4) or IPv6 (6) anycast address.
ANY4=192.0.2.153 ANY6=2001:db8:153::153
K1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
nas() {
    local addr=$ANY4
    [[ $3 == 6 ]] && addr=ipv6:$ANY6
    C=$((C + 1))
    nas_login "$addr" alice "s3cr3t:$(docker exec yk-geo-nas /repo/tests/make-otp.sh vvccccbbcdef 4a6f8e2d1c3b $K1 "$C" 0)"
    check "$1 [OTP $C, $MS ms]" "$2" "$NAS"
}

# transitions SITE SINCE: when SITE's check withdrew and advertised the
# anycast addresses after the Unix time SINCE, in seconds from then, from its
# log: "withdrawn 13 s, advertised 41 s".
transitions() {
    docker exec "yk-geo-$1" journalctl -u yubikey-anycast --since "@$2" -o short-unix 2>/dev/null \
        | awk -v t0="$2" '/: withdrawing / { printf "%swithdrawn %d s", sep, $1 - t0; sep = ", " }
                          /: advertising / { printf "%sadvertised %d s", sep, $1 - t0; sep = ", " }'
}

ALICE="SELECT counter FROM yubikeys WHERE username = 'alice'"
NORMAL="east1=leader east2=quorum west=quorum"
ALL3="west,east1,east2 west,east1,east2"
EAST="east1,east2 east1,east2"

echo "== Setup: etcd, Patroni and Radiator on three sites"
for n in "${SITES[@]}"; do booted "$n" || exit 1; done
node east1 pki
for n in "${SITES[@]}"; do
    node "$n" wan-install
    node "$n" etcd-setup
done
between "round trip West to East1 (ms)"  55 60 "$(node west rtt east1)"
between "round trip East1 to East2 (ms)" 4 8   "$(node east1 rtt east2)"
for n in "${SITES[@]}"; do node "$n" etcd-start & done
wait
check "etcd: three members, all healthy" 3 \
    "$(node west etcdctl endpoint health --cluster 2>&1 | grep -c 'is healthy')"
node east1 patroni-setup 2
node east2 patroni-setup 2
node west patroni-setup 1
node east1 patroni-start
cluster "Patroni bootstraps the database on east1" "east1=leader" east1
node east2 patroni-start
node west patroni-start
cluster "east2 and west are copied from east1 and confirm its commits" "$NORMAL" east1
check "east1 waits for one of the two standbys" "ANY 1 (east2,west)" \
    "$(node east1 sql postgres 'SHOW synchronous_standby_names')"
node east1 db-init
for n in "${SITES[@]}"; do node "$n" rad-setup || exit 1; done
check "DBSource from 'config'" \
    "dbi:Pg:dbname=yubikey;host=east1.yk.test,east2.yk.test,west.yk.test;port=5432;sslmode=verify-full;sslrootcert=/etc/radiator/pg-ca.crt;connect_timeout=2;target_session_attrs=read-write" \
    "$(docker exec yk-geo-west awk '/^ +DBSource/ {print $2}' /etc/radiator/conf.d/yubikey.conf)"
node west admin add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $K1 -w s3cr3t >/dev/null
check "the admin adds alice at West; she is on the primary" alice \
    "$(node east1 sql yubikey 'SELECT username FROM yubikeys')"
node nas nas-setup
node rtr router-setup
for n in "${SITES[@]}"; do node "$n" frr-setup; done
T0=$SECONDS
check "the anycast check's first login, at each site" "ACCEPT ACCEPT ACCEPT" \
    "$(for n in "${SITES[@]}"; do node "$n" anycast-setup | cut -d' ' -f1; done | paste -sd' ')"
routes_until "West's router has the anycast routes of all three sites, West's first" "$ALL3"
check "...a BGP session with BFD to each site, over IPv4 and over IPv6" "BGP 6, BFD 6" "$(node rtr sessions)"

echo
echo "== Normal operation"
login "OTP at East1"                            ACCEPT east1
login "the same OTP at West"                    "REJECT: Replay attack detected" west "$C"
login "OTP at West"                             ACCEPT west
login "OTP at East2"                            ACCEPT east2
check "every site's Radiator uses east1" "east1 east2 west" "$(uses east1)"
check "Patroni's REST API: /primary on east1, east2, west" "200 503 503" \
    "$(for n in "${SITES[@]}"; do node west api "$n" primary; done | paste -sd' ')"
check "Patroni's REST API: /replica on east1, east2, west" "503 200 200" \
    "$(for n in "${SITES[@]}"; do node west api "$n" replica; done | paste -sd' ')"
check "Patroni's REST API: /health on east1, east2, west" "200 200 200" \
    "$(for n in "${SITES[@]}"; do node west api "$n" health; done | paste -sd' ')"
wait_for "West's standby has alice's counter ($C)" "$C" west "$ALICE"
for n in "${SITES[@]}"; do median_login "$n"; done
# At the East sites, mostly the time to write the commit to disk on the
# primary and on East2; the lab's three servers share one disk.
between "login time at East1, median ms"                           1 100 "${LAT[east1]}"
between "login time at East2, median ms"                           1 100 "${LAT[east2]}"
between "login time at West, median ms (two round trips to East1)" 110 300 "${LAT[west]}"

echo
echo "== Anycast: one address for the three sites"
nas "OTP from the NAS behind West's router, IPv4" "ACCEPT from $ANY4 by west" 4
nas "OTP from the NAS, IPv6"                    "ACCEPT from $ANY6 by west" 6
read -r user password <<<"$(node west check-cred)"
nas_login "$ANY4" "$user" "$password"
check "the anycast check's user, from the NAS (an OTP ahead of the check's)" \
    "REJECT from $ANY4 by west" "$NAS"
check "...West's check is not disturbed" advertised "$(node west anycast-status | head -1 | cut -d' ' -f1)"
check "the check's logins are not in the authentication log" 0 \
    "$(docker exec yk-geo-west grep -c "user='anycast-west'.*result=OK" /var/log/radiator/authentication.log)"

echo
echo "== Anycast: Radiator stops at West"
T0=$SECONDS
docker exec yk-geo-west systemctl stop radiator
routes_until "West withdraws after 3 failed checks" "$EAST" 40
between "...seconds after Radiator stopped" 10 17 "$RT"
withdraw_s=$RT
nas "OTP from the NAS, IPv4: East1 answers" "ACCEPT from $ANY4 by east1" 4
nas "OTP from the NAS, IPv6"                "ACCEPT from $ANY6 by east1" 6
T0=$SECONDS
docker exec yk-geo-west systemctl start radiator
routes_until "West advertises again after 2 good checks" "$ALL3" 40
advertise_s=$RT
# Radiator started while the addresses were off lo: it listens on them
# because the server may bind to addresses it doesn't have.
nas "OTP from the NAS, IPv4: West again" "ACCEPT from $ANY4 by west" 4
nas "OTP from the NAS, IPv6"             "ACCEPT from $ANY6 by west" 6

echo
echo "== Anycast: stop West's check (maintenance)"
T0=$SECONDS
docker exec yk-geo-west systemctl stop yubikey-anycast
routes_until "stopping the check withdraws West at once" "$EAST" 10
check "...the addresses are off lo" "not running, on lo: none" \
    "$(node west anycast-status | head -2 | paste -sd',' | sed 's/,/, /')"
nas "OTP from the NAS: East1 answers" "ACCEPT from $ANY4 by east1" 4
T0=$SECONDS
docker exec yk-geo-west systemctl start yubikey-anycast
routes_until "West advertises again when its check starts" "$ALL3" 30

echo
echo "== Reboot West (a standby)"
docker stop -t 60 yk-geo-west >/dev/null
check "West's anycast routes are gone" "$EAST" "$(node rtr routes)"
nas "OTP from the NAS while West is down: East1 answers" "ACCEPT from $ANY4 by east1" 4
logins "5 OTPs at East1, West down" east1
between "...no slower than usual (median ms)" 1 100 "$MS"
docker start yk-geo-west >/dev/null
booted west
cluster "West is back and confirms commits again" "$NORMAL" east1
login "OTP at West after its reboot"            ACCEPT west
T0=$SECONDS
routes_until "West advertises again" "$ALL3" 30
nas "OTP from the NAS: West answers" "ACCEPT from $ANY4 by west" 4

echo
echo "== West loses power"
T0=$SECONDS
docker kill yk-geo-west >/dev/null
routes_until "BFD: the router drops West's anycast routes" "$EAST" 10
bfd_s=$RT
between "...within 2 s" 0 2 "$RT"
nas "OTP from the NAS: East1 answers" "ACCEPT from $ANY4 by east1" 4
docker start yk-geo-west >/dev/null
booted west
cluster "West is back" "$NORMAL" east1
T0=$SECONDS
routes_until "West advertises again" "$ALL3" 60

echo
echo "== Reboot East2 (the standby that usually confirms first)"
docker stop -t 60 yk-geo-east2 >/dev/null
logins "5 OTPs at East1, East2 down" east1
between "...each commit now waits for West (median ms)" 55 300 "$MS"
docker start yk-geo-east2 >/dev/null
booted east2
cluster "East2 is back" "$NORMAL" east1
login "OTP at East2 after its reboot"           ACCEPT east2

echo
echo "== Reboot East1 (the primary)"
login "OTP at West, just before"                ACCEPT west
last=$C
T0=$SECONDS
docker stop -t 60 yk-geo-east1 >/dev/null
login_until "OTP at West while East1 shuts down" west 30
leader "East2 took over, not West" east2 east2
login "OTP $last again (from before the reboot)" "REJECT: Replay attack detected" east2 "$last"
docker start yk-geo-east1 >/dev/null
booted east1
cluster "East1 rejoins as a standby" "east1=quorum east2=leader west=quorum" east2
switchover east1 east2
cluster "back to normal, East1 the primary" "$NORMAL" east1
login "OTP at West"                             ACCEPT west

echo
echo "== The primary (East1) loses power"
login "OTP at East2, just before"               ACCEPT east2
last=$C
T0=$SECONDS
since=$(date +%s)
docker kill yk-geo-east1 >/dev/null
login "OTP at East2, no primary yet"            "REJECT: Yubikey secret not found in database" east2
login_until "OTP at East2 once Patroni promotes a standby" east2 60
leader "East2 took over, not West" east2 east2 10
# No site can log in until East2 is the primary, longer than three checks:
# West and East2 withdraw too, and the NAS gets no answer until they
# advertise again.
routes_until "West and East2 advertise again" "west,east2 west,east2" 60
nas "OTP from the NAS: West answers" "ACCEPT from $ANY4 by west" 4
for n in west east2; do
    tr=$(transitions "$n" "$since")
    check "$n withdrew while there was no primary, then advertised again [$tr]" yes \
        "$([[ $tr =~ ^withdrawn\ [0-9]+\ s,\ advertised\ [0-9]+\ s$ ]] && echo yes || echo "${tr:-no change}")"
    [[ $n == west ]] && { failover_s=${tr##*advertised }; failover_s=${failover_s% s}; }
done
login "OTP $last again (from before the power loss)" "REJECT: Replay attack detected" west "$last"
login "OTP at West"                             ACCEPT west
docker start yk-geo-east1 >/dev/null
booted east1
cluster "East1 rejoins as a standby" "east1=quorum east2=leader west=quorum" east2
T0=$SECONDS
routes_until "East1 advertises again" "$ALL3" 30
switchover east1 east1
cluster "back to normal, East1 the primary" "$NORMAL" east1

echo
echo "== Patroni on the primary (East1) crashes"
login "OTP at East1, just before"               ACCEPT east1
docker exec yk-geo-east1 systemctl kill --kill-whom=main -s KILL patroni@18-main
sleep 3
check "systemd started Patroni again" active "$(docker exec yk-geo-east1 systemctl is-active patroni@18-main)"
login "OTP at East1"                            ACCEPT east1
login "OTP at West"                             ACCEPT west
check "East1 kept the lease: no failover" "$NORMAL" "$(node east2 members)"

echo
echo "== West is cut off from both East sites"
login "OTP at West, just before"               ACCEPT west
partition west
T0=$SECONDS
logins "5 OTPs at East1, West cut off" east1
between "...no slower than usual (median ms)" 1 100 "$MS"
login "OTP at West: no primary within reach"    "REJECT: Yubikey secret not found in database" west
between "...answered within 7 s (ms)" 1 7000 "$MS"
routes_until "West withdraws: its check can't log in" "$EAST" 40
nas "OTP from the NAS: East1 answers (the router still reaches it)" "ACCEPT from $ANY4 by east1" 4
login "OTP at East2"                            ACCEPT east2
during=$C
cluster "the East sites drop West from the cluster" "east1=leader east2=quorum" east1 45
check "West's PostgreSQL stays a standby" standby "$(node west role)"
login "OTP at West, still cut off"              "REJECT: Yubikey secret not found in database" west
T0=$SECONDS
heal west
cluster "West follows East1 again" "$NORMAL" east1
# Its old replication connection may wait for TCP to retry, or for
# wal_receiver_timeout (60 s) to replace it.
wait_for "West's standby has alice's counter ($during)" "$during" west "$ALICE" 90
login_settled "OTP $during again at West (used at East2 during the cut)" "REJECT: Replay attack detected" west "$during"
login_until "OTP at West" west 30
T0=$SECONDS
routes_until "West advertises again" "$ALL3" 30

echo
echo "== East1 (the primary's site) is cut off from the others"
T0=$SECONDS
partition east1
login "OTP at East1: its commit waits for a standby it cannot reach" "NO REPLY" east1 "" 6
login_until "OTP at East2 once Patroni promotes it" east2 60
# Patroni stops East1's PostgreSQL as soon as it cannot reach etcd; the stop
# waits for the connections to the standbys to time out (wal_sender_timeout,
# 60 s), then it starts again as a standby.
check "East1's PostgreSQL is no longer a primary" "stopping or standby" \
    "$(r=$(node east1 role 2>/dev/null); [[ $r == primary ]] && echo primary || echo "stopping or standby")"
login "OTP at East1, still cut off"             "REJECT: Yubikey secret not found in database" east1
login "OTP at West"                             ACCEPT west
routes_until "West and East2 advertise; East1, cut off, does not" "west,east2 west,east2" 30
T0=$SECONDS
before=$(rewinds east1)
heal east1
cluster "East1 rejoins as a standby" "east1=quorum east2=leader west=quorum" east2
check "...after pg_rewind removed its unconfirmed commit" 1 "$(($(rewinds east1) - before))"
wait_for "East1 has East2's data (alice's counter)" "$C" east1 "$ALICE"
T0=$SECONDS
routes_until "East1 advertises again" "$ALL3" 30
switchover east1 east1
cluster "back to normal, East1 the primary" "$NORMAL" east1

echo
echo "== The link between East1 and East2 fails; both still reach West"
T0=$SECONDS
node east1 cut east2
node east2 cut east1
logins "5 OTPs at East1" east1
between "...now confirmed by West (median ms)" 55 300 "$MS"
login "OTP at West"                             ACCEPT west
login "OTP at East2: East1 out of reach, the others are standbys" \
    "REJECT: Yubikey secret not found in database" east2
routes_until "East2 withdraws" "west,east1 west,east1" 40
sleep 35    # longer than the lease
T0=$SECONDS
leader "East1 keeps the lease, through West's etcd" east1 west 5
login "OTP at East1"                            ACCEPT east1
node east1 heal east2
node east2 heal east1
cluster "East2 follows East1 again" "$NORMAL" east1
login_until "OTP at East2" east2 30
T0=$SECONDS
routes_until "East2 advertises again" "$ALL3" 30

echo
echo "== Copy a standby again from the primary (patronictl reinit)"
started=$(node west sql postgres "SELECT pg_postmaster_start_time()")
node east1 ctl reinit 18-main west --force --wait >/dev/null
check "West's PostgreSQL was replaced" yes \
    "$([[ $(node west sql postgres "SELECT pg_postmaster_start_time()") != "$started" ]] && echo yes || echo no)"
cluster "West streams again" "$NORMAL" east1
login "OTP at West"                             ACCEPT west
wait_for "West's copy has alice's counter ($C)" "$C" west "$ALICE"

echo
echo "== East2 and West down at the same time"
docker stop -t 60 yk-geo-east2 >/dev/null &
docker stop -t 60 yk-geo-west >/dev/null &
wait
T0=$SECONDS
for _ in $(seq 60); do [[ $(node east1 role 2>/dev/null) == primary ]] || break; sleep 1; done
check "East1 is no longer a primary: etcd has no majority [after $((SECONDS - T0)) s]" "stopping or standby" \
    "$(r=$(node east1 role 2>/dev/null); [[ $r == primary ]] && echo primary || echo "stopping or standby")"
login "OTP at East1, alone"                     "REJECT: Yubikey secret not found in database" east1
routes_until "East1 withdraws too: no site advertises" "- -" 40
nas "OTP from the NAS: no answer" "NO REPLY by nobody" 4
docker start yk-geo-east2 yk-geo-west >/dev/null
booted east2
booted west
one_leader "East2 and West back: a new leader"
[[ $(node east1 members) == "$NORMAL" ]] || switchover east1 east1
cluster "back to normal, East1 the primary" "$NORMAL" east1
login_until "OTP at West" west 30
T0=$SECONDS
routes_until "all three sites advertise again" "$ALL3" 30
nas "OTP from the NAS: West answers" "ACCEPT from $ANY4 by west" 4

echo
echo "== Partition mode: set up on the three servers"
check "setup, at West" "moved yubikey.conf to yubikey-cluster.conf (in /etc/radiator/conf.d)|the copy: /var/lib/yubikey-partition/keys.db, 4 YubiKeys|Radiator's clause: yubikey.conf -> yubikey-cluster.conf; in partition mode -> yubikey-partition.conf" \
    "$(node west partition-setup | paste -sd'|')"
for n in east1 east2; do node "$n" partition-setup >/dev/null; done
# (The service updates the copy as it starts: wait for its lock.)
check "each server has a copy of the 4 YubiKeys (alice's, and the anycast checks')" "4 4 4" \
    "$(for n in "${SITES[@]}"; do docker exec "yk-geo-$n" sqlite3 -cmd '.timeout 10000' \
         /var/lib/yubikey-partition/keys.db 'SELECT count(*) FROM yubikeys'; done | paste -sd' ')"
check "normal mode: Radiator uses the cluster" "normal normal normal" \
    "$(for n in "${SITES[@]}"; do node "$n" partition-mode; done | paste -sd' ')"
login "OTP at West"                             ACCEPT west

echo
echo "== Partition mode: West is cut off from both East sites"
login "OTP at East2, just before the cut"       ACCEPT east2
before_cut=$C
T0=$SECONDS
partition west
login "OTP at West, at once: no primary within reach" "REJECT: Yubikey secret not found in database" west
mode_until "West enters partition mode: no other site answers" west partition 40
part_s=$((SECONDS - T0))
# The copy is updated every 5 minutes, and again when partition mode begins.
login_settled "OTP $before_cut (used at East2 just before the cut) at West: in West's copy, a replay" \
    "REJECT: Replay attack detected" west "$before_cut"
login_until "OTP at West, from West's copy of the keys" west 30
west_otp=$C
login "OTP at East1"                            ACCEPT east1
login "OTP $C (just used at East1) again at West: accepted, the risk of partition mode" ACCEPT west "$C"
login "OTP $west_otp (used at West) again at West" "REJECT: Replay attack detected" west "$west_otp"
node east1 admin disable alice >/dev/null
login "OTP at West while alice is disabled at East1: accepted (West can't know)" ACCEPT west
node east1 admin enable alice >/dev/null
last_west=$C
routes_until "West advertises again, logging in from its copy" "$ALL3" 40
nas "OTP from the NAS: West answers, from its copy" "ACCEPT from $ANY4 by west" 4
last_west=$C
T0=$SECONDS
heal west
mode_until "West leaves partition mode once East answers and the primary is reachable" west normal 60
wait_for "the primary has alice's counter from West's copy ($last_west)" "$last_west" east1 "$ALICE" 10
login "OTP $last_west (used at West while cut off) at East2: a replay" "REJECT: Replay attack detected" east2 "$last_west"
login_until "OTP at West, through the primary again" west 30

echo
echo "== Partition mode: East1 (the primary's site) is cut off from the others"
T0=$SECONDS
partition east1
mode_until "East1 enters partition mode" east1 partition 60
login_until "OTP at East1, from its copy" east1 60
east1_otp=$C
login_until "OTP at East2 once Patroni promotes it" east2 60
login "OTP at West"                             ACCEPT west
check "West and East2 stayed in normal mode: they answer each other" "normal normal" \
    "$(node west partition-mode) $(node east2 partition-mode)"
T0=$SECONDS
heal east1
mode_until "East1 leaves partition mode" east1 normal 90
cluster "East1 rejoins as a standby" "east1=quorum east2=leader west=quorum" east2 90
login "OTP $east1_otp (used at East1 while cut off) at West: a replay" "REJECT: Replay attack detected" west "$east1_otp"
switchover east1 east1
cluster "back to normal, East1 the primary" "$NORMAL" east1

echo
echo "== Partition mode: East2 and West down at the same time"
docker stop -t 60 yk-geo-east2 >/dev/null &
docker stop -t 60 yk-geo-west >/dev/null &
wait
T0=$SECONDS
mode_until "East1, alone, enters partition mode" east1 partition 60
login_until "OTP at East1, from its copy" east1 60
alone_otp=$C
docker start yk-geo-east2 yk-geo-west >/dev/null
booted east2
booted west
T0=$SECONDS
mode_until "East1 leaves partition mode once there is a primary again" east1 normal 120
one_leader "a leader in the East, all streaming"
[[ $(node east1 members) == "$NORMAL" ]] || switchover east1 east1
cluster "back to normal, East1 the primary" "$NORMAL" east1
login "OTP $alone_otp (used at East1 alone) at West: a replay" "REJECT: Replay attack detected" west "$alone_otp"
login_until "OTP at West" west 30

echo
echo "== Partition mode: the link between East1 and East2 fails"
T0=$SECONDS
node east1 cut east2
node east2 cut east1
login "OTP at East2: East1 out of reach" "REJECT: Yubikey secret not found in database" east2
sleep 20    # longer than three checks
check "East2 stays in normal mode: West still answers" normal "$(node east2 partition-mode)"
node east1 heal east2
node east2 heal east1
cluster "East2 follows East1 again" "$NORMAL" east1
login_until "OTP at East2" east2 30
T0=$SECONDS
routes_until "all three sites advertise" "$ALL3" 30

echo
echo "Login times (median, warm connections): East1 ${LAT[east1]} ms, East2 ${LAT[east2]} ms, West ${LAT[west]} ms"
echo "Anycast: West withdrawn ${withdraw_s} s after its Radiator stopped, back ${advertise_s} s after it started;" \
     "dropped in under $((bfd_s + 1)) s after a power loss (BFD); back ${failover_s} s after the primary lost power"
echo "Partition mode: West, cut off, used its copy ${part_s} s after the cut"
printf 'Three sites: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
