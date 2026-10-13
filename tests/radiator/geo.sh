#!/usr/bin/env bash
#
# geo.sh - Test Radiator with PostgreSQL on three sites under Patroni, through
# reboots, a power loss and network partitions, in Docker containers.
#
# Usage: tests/radiator/geo.sh IMAGE
#   IMAGE is the test image that tests/radiator/run.sh builds, for example
#   yk-radiator-test:4.30-1. run.sh runs this script after ha.sh.
#
# One container per site, on the Docker network yk-geo (172.31.97.0/24), each
# running systemd with etcd, PostgreSQL 18 under Patroni (patroni@18-main)
# and Radiator, as the guide's "Three sites" section sets them up:
#   yk-geo-east1  172.31.97.11  east1.yk.test, Maryland: the usual primary
#   yk-geo-east2  172.31.97.12  east2.yk.test, Washington DC
#   yk-geo-west   172.31.97.13  west.yk.test, New Mexico: primary only as a
#                               last resort (failover_priority 1, not 2)
# Traffic control in each container adds the WAN: 55 ms round trip between
# West and East, 4 ms between the East sites. Patroni keeps one standby
# synchronous ("ANY 1 (east2,west)"), so every committed login is on two
# sites. Every Radiator server lists PGHOST=east1,east2,west and uses
# whichever is the primary. The steps in the containers are in geo-node.sh.
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
# Set KEEP=1 to leave the containers running afterwards.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$(dirname -- "$here")")
image=${1:?usage: tests/radiator/geo.sh IMAGE}
pass=0 fail=0
SITES=(east1 east2 west)

remove_lab() {
    docker rm -f yk-geo-east1 yk-geo-east2 yk-geo-west >/dev/null 2>&1
    docker network rm yk-geo >/dev/null 2>&1
    docker volume rm yk-geo-lab >/dev/null 2>&1
}
remove_lab
if [[ ${KEEP-} == 1 ]]; then
    trap 'echo "KEEP=1: the containers are still running"' EXIT
else
    trap remove_lab EXIT
fi

docker network create --subnet 172.31.97.0/24 yk-geo >/dev/null || exit 1
docker volume create yk-geo-lab >/dev/null || exit 1

declare -A IP=([east1]=172.31.97.11 [east2]=172.31.97.12 [west]=172.31.97.13)
# SIGRTMIN+3 makes systemd shut down cleanly, so 'docker stop' and 'docker
# restart' are a clean shutdown and reboot; 'docker kill' is a power loss.
for n in "${SITES[@]}"; do
    docker run -d --name "yk-geo-$n" --hostname "$n.yk.test" --network yk-geo --ip "${IP[$n]}" \
        --add-host east1.yk.test:172.31.97.11 --add-host east2.yk.test:172.31.97.12 \
        --add-host west.yk.test:172.31.97.13 \
        --cap-add SYS_ADMIN --cap-add NET_ADMIN --security-opt apparmor=unconfined --cgroupns private \
        --tmpfs /run --tmpfs /run/lock --stop-signal SIGRTMIN+3 \
        -v "$root:/repo:ro" -v yk-geo-lab:/lab "$image" \
        sh -c 'mount -o remount,rw /sys/fs/cgroup && exec /lib/systemd/systemd' >/dev/null || exit 1
done

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

ALICE="SELECT counter FROM yubikeys WHERE username = 'alice'"
NORMAL="east1=leader east2=quorum west=quorum"

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
node west admin add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d -w s3cr3t >/dev/null
check "the admin adds alice at West; she is on the primary" alice \
    "$(node east1 sql yubikey 'SELECT username FROM yubikeys')"

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
echo "== Reboot West (a standby)"
docker stop -t 60 yk-geo-west >/dev/null
logins "5 OTPs at East1, West down" east1
between "...no slower than usual (median ms)" 1 100 "$MS"
docker start yk-geo-west >/dev/null
booted west
cluster "West is back and confirms commits again" "$NORMAL" east1
login "OTP at West after its reboot"            ACCEPT west

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
docker kill yk-geo-east1 >/dev/null
login "OTP at East2, no primary yet"            "REJECT: Yubikey secret not found in database" east2
login_until "OTP at East2 once Patroni promotes a standby" east2 60
leader "East2 took over, not West" east2 east2 10
login "OTP $last again (from before the power loss)" "REJECT: Replay attack detected" west "$last"
login "OTP at West"                             ACCEPT west
docker start yk-geo-east1 >/dev/null
booted east1
cluster "East1 rejoins as a standby" "east1=quorum east2=leader west=quorum" east2
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
logins "5 OTPs at East1, West cut off" east1
between "...no slower than usual (median ms)" 1 100 "$MS"
login "OTP at West: no primary within reach"    "REJECT: Yubikey secret not found in database" west
between "...answered within 7 s (ms)" 1 7000 "$MS"
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
login "OTP $during again at West (used at East2 during the cut)" "REJECT: Replay attack detected" west "$during"
login_until "OTP at West" west 30

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
T0=$SECONDS
before=$(rewinds east1)
heal east1
cluster "East1 rejoins as a standby" "east1=quorum east2=leader west=quorum" east2
check "...after pg_rewind removed its unconfirmed commit" 1 "$(($(rewinds east1) - before))"
wait_for "East1 has East2's data (alice's counter)" "$C" east1 "$ALICE"
switchover east1 east1
cluster "back to normal, East1 the primary" "$NORMAL" east1

echo
echo "== The link between East1 and East2 fails; both still reach West"
node east1 cut east2
node east2 cut east1
logins "5 OTPs at East1" east1
between "...now confirmed by West (median ms)" 55 300 "$MS"
login "OTP at West"                             ACCEPT west
login "OTP at East2: East1 out of reach, the others are standbys" \
    "REJECT: Yubikey secret not found in database" east2
sleep 35    # longer than the lease
T0=$SECONDS
leader "East1 keeps the lease, through West's etcd" east1 west 5
login "OTP at East1"                            ACCEPT east1
node east1 heal east2
node east2 heal east1
cluster "East2 follows East1 again" "$NORMAL" east1
login_until "OTP at East2" east2 30

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
docker start yk-geo-east2 yk-geo-west >/dev/null
booted east2
booted west
one_leader "East2 and West back: a new leader"
[[ $(node east1 members) == "$NORMAL" ]] || switchover east1 east1
cluster "back to normal, East1 the primary" "$NORMAL" east1
login_until "OTP at West" west 30

echo
echo "Login times (median, warm connections): East1 ${LAT[east1]} ms, East2 ${LAT[east2]} ms, West ${LAT[west]} ms"
printf 'Three sites: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
