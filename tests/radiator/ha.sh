#!/usr/bin/env bash
#
# ha.sh - Test Radiator with two PostgreSQL servers, a primary and a
# streaming standby, through failures, in Docker containers.
#
# Usage: tests/radiator/ha.sh IMAGE
#   IMAGE is the test image that tests/radiator/run.sh builds, for example
#   yk-radiator-test:4.30-1. run.sh runs this script after e2e.sh.
#
# Containers, on the Docker network yk-ha (172.31.98.0/24):
#   yk-ha-db1   172.31.98.11  db1.yk.test, the first primary
#   yk-ha-db2   172.31.98.12  db2.yk.test, the first standby
#   yk-ha-rad1  172.31.98.21  Radiator, PGHOST=db1.yk.test,db2.yk.test
#   yk-ha-rad2  172.31.98.22  Radiator, PGHOST=db2.yk.test,db1.yk.test
# Replication is asynchronous, over TLS. Radiator's configuration comes from
# 'yubikey-db.sh config'. The steps in the containers are in ha-node.sh.
#
# Checks: both Radiator servers use the primary, whichever server they list
# first, and share its counters; the standby has the changes within seconds;
# after the primary dies and the standby is promoted, logins work again
# within FailureBackoffTime and OTPs used before the failure stay used; a
# server rebuilt as a standby is skipped; a hung primary costs a few seconds,
# not minutes; a planned switchover loses nothing; the same OTP sent to both
# Radiator servers at the same moment is accepted once. Two checks show the risks the guide warns about: an old
# primary started as it was accepts OTPs already used, and an OTP whose
# counter update had not reached the standby is accepted once more after a
# failover. Set KEEP=1 to leave the containers running afterwards.

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$(dirname -- "$here")")
image=${1:?usage: tests/radiator/ha.sh IMAGE}
pass=0 fail=0

remove_lab() {
    docker rm -f yk-ha-db1 yk-ha-db2 yk-ha-rad1 yk-ha-rad2 >/dev/null 2>&1
    docker network rm yk-ha >/dev/null 2>&1
    docker volume rm yk-ha-lab >/dev/null 2>&1
}
remove_lab
if [[ ${KEEP-} == 1 ]]; then
    trap 'echo "KEEP=1: the containers are still running"' EXIT
else
    trap remove_lab EXIT
fi

docker network create --subnet 172.31.98.0/24 yk-ha >/dev/null || exit 1
docker volume create yk-ha-lab >/dev/null || exit 1

declare -A IP=([db1]=172.31.98.11 [db2]=172.31.98.12 [rad1]=172.31.98.21 [rad2]=172.31.98.22)
# The names are in /etc/hosts, so they resolve even while a server is down,
# as with DNS on a real network.
for n in db1 db2 rad1 rad2; do
    docker run -d --init --name "yk-ha-$n" --hostname "$n.yk.test" --network yk-ha --ip "${IP[$n]}" \
        --add-host db1.yk.test:172.31.98.11 --add-host db2.yk.test:172.31.98.12 \
        -v "$root:/repo:ro" -v yk-ha-lab:/lab "$image" sleep infinity >/dev/null || exit 1
done

# node NAME COMMAND [ARGS]: one ha-node.sh step in a container.
node() {
    local n=$1; shift
    docker exec "yk-ha-$n" bash /repo/tests/radiator/ha-node.sh "$@"
}

# check LABEL EXPECTED ACTUAL: count and print one result.
check() {
    if [[ $3 == "$2" ]]; then
        pass=$((pass + 1)); printf 'PASS  %s: %s\n' "$1" "$3"
    else
        fail=$((fail + 1)); printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

# login LABEL EXPECTED RAD COUNTER: alice logs in on RAD with the OTP for
# COUNTER (session 0). Sets MS to the time Radiator took to answer.
MS=0
login() {
    local out
    out=$(node "$3" login alice s3cr3t "$4" 0)
    MS=$(tail -1 <<<"$out")
    check "$1 [$3, ${MS} ms]" "$2" "$(head -1 <<<"$out")"
}

# login_settled LABEL EXPECTED RAD COUNTER: login, for right after a
# failover. Each of Radiator's four processes reconnects on its own, so one
# that hasn't yet answers "Yubikey secret not found in database": retry once
# a second while that is the answer, for up to 20 s. (A replayed OTP stays
# rejected, however often it is sent.)
login_settled() {
    local start=$SECONDS out
    while :; do
        out=$(node "$3" login alice s3cr3t "$4" 0)
        [[ $(head -1 <<<"$out") == "REJECT: Yubikey secret not found in database" ]] || break
        ((SECONDS - start < 20)) || break
        sleep 1
    done
    MS=$(tail -1 <<<"$out")
    check "$1 [$3, ${MS} ms]" "$2" "$(head -1 <<<"$out")"
}

# login_until LABEL RAD COUNTER: retry the login once a second until it is
# accepted, for up to 20 s; reports how long that took.
login_until() {
    local start=$SECONDS out
    while ((SECONDS - start < 20)); do
        out=$(node "$2" login alice s3cr3t "$3" 0 | head -1)
        [[ $out == ACCEPT ]] && break
        sleep 1
    done
    check "$1 [$2, after $((SECONDS - start)) s]" ACCEPT "$out"
}

# wait_for LABEL EXPECTED NODE SQL: poll SQL on NODE for up to 10 s.
wait_for() {
    local start=$SECONDS out
    while ((SECONDS - start < 10)); do
        out=$(node "$3" sql yubikey "$4" 2>/dev/null)
        [[ $out == "$2" ]] && break
        sleep 0.2
    done
    check "$1" "$2" "$out"
}

# The database servers RAD has a session with: "db1", "db2" or "db1 db2".
uses() {
    local db out=()
    for db in db1 db2; do
        [[ $(docker inspect -f '{{.State.Running}} {{.State.Paused}}' "yk-ha-$db") == "true false" ]] || continue
        [[ $(node $db sql yubikey "SELECT count(*) FROM pg_stat_activity
                WHERE usename = 'radiator' AND client_addr = '${IP[$1]}'" 2>/dev/null) -gt 0 ]] && out+=("$db")
    done
    echo "${out[*]}"
}

# Who a server streams to: "NAME|state|sync_state" lines.
streams_to() {
    node "$1" sql postgres "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1"
}

ALICE="SELECT counter FROM yubikeys WHERE username = 'alice'"

# race COUNTER: alice's OTP for COUNTER on rad1 and rad2 at the same moment,
# while db1 (the primary) keeps her row locked for 1.8 s, so both servers
# read the counters before either saves them. Sets ANSWERS to both answers,
# sorted, and WAITING to the number of Radiator sessions waiting to save.
ANSWERS='' WAITING=''
race() {
    local lock a b out
    out=$(mktemp -d)
    node db1 hold-row 1.8 & lock=$!
    sleep 0.3
    node rad1 login alice s3cr3t "$1" 0 6 | head -1 >"$out/1" & a=$!
    node rad2 login alice s3cr3t "$1" 0 6 | head -1 >"$out/2" & b=$!
    sleep 0.8
    WAITING=$(node db1 sql yubikey "SELECT count(*) FROM pg_stat_activity
                                     WHERE usename = 'radiator' AND wait_event_type = 'Lock'")
    wait "$lock" "$a" "$b"
    ANSWERS=$(sort "$out/1" "$out/2" | paste -sd ' ')
    rm -rf -- "$out"
}

echo "== Setup: db1 primary, db2 streaming standby, two Radiator servers"
node db1 pki
node db1 db-setup db1
node db2 db-setup db2
node db1 primary-init
node db2 standby db2 db1
check "db1 streams to db2, asynchronously" "db2|streaming|async" "$(streams_to db1)"
check "db2 is a standby" standby "$(node db2 role)"
node rad1 rad-setup db1.yk.test,db2.yk.test
node rad2 rad-setup db2.yk.test,db1.yk.test
check "DBSource from 'config' (rad1)" \
    "dbi:Pg:dbname=yubikey;host=db1.yk.test,db2.yk.test;port=5432;sslmode=verify-full;sslrootcert=/etc/radiator/pg-ca.crt;connect_timeout=2;target_session_attrs=read-write" \
    "$(docker exec yk-ha-rad1 awk '/^ +DBSource/ {print $2}' /etc/radiator/conf.d/yubikey.conf)"
check "Timeouts from 'config'" "Timeout 2|ConnectTimeout 5|FailureBackoffTime 10" \
    "$(docker exec yk-ha-rad1 awk '/^ +(Timeout|ConnectTimeout|FailureBackoffTime) / {printf "%s%s %s", sep, $1, $2; sep="|"}' \
        /etc/radiator/conf.d/yubikey.conf)"
node rad1 admin add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d -w s3cr3t >/dev/null
check "the admin adds alice from rad1 (PGHOST=db1,db2)" "alice" "$(node db1 sql yubikey 'SELECT username FROM yubikeys')"
node rad1 rad-start
node rad2 rad-start

echo
echo "== Normal operation"
login "OTP 1"                                   ACCEPT rad1 1
login "OTP 1 on the other Radiator server"      "REJECT: Replay attack detected" rad2 1
login "OTP 2"                                   ACCEPT rad2 2
check "rad1 uses db1 (listed first)" db1 "$(uses rad1)"
check "rad2 uses db1, though it lists the standby first" db1 "$(uses rad2)"
wait_for "the standby has alice's counter (2)" 2 db2 "$ALICE"

echo
echo "== The primary (db1) dies"
docker kill yk-ha-db1 >/dev/null
login "OTP 3, no writable server"               "REJECT: Yubikey secret not found in database" rad1 3
node db2 promote
check "db2 promoted" primary "$(node db2 role)"
login_until "OTP 3, once FailureBackoffTime is over" rad1 3
login_settled "OTP 2 (used before the failure)" "REJECT: Replay attack detected" rad1 2
login "OTP 4, rad2's old session was to db1"    ACCEPT rad2 4
check "rad1 uses db2" db2 "$(uses rad1)"
check "rad2 uses db2" db2 "$(uses rad2)"
node rad1 admin add -u bob -P vvccccbbcdeg -p 4a6f8e2d1c3c -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d -w s3cr3t >/dev/null
check "the admin's change goes to db2" "bob" "$(node db2 sql yubikey "SELECT username FROM yubikeys WHERE username = 'bob'")"

echo
echo "== DANGER: the old primary is started as it was"
docker start yk-ha-db1 >/dev/null
node db1 start
check "db1 is a primary too" primary "$(node db1 role)"
check "db1 has alice's counter from before the failure" 2 "$(node db1 sql yubikey "$ALICE")"
node rad1 rad-start
login "OTP 4 again: accepted by the old primary" ACCEPT rad1 4
check "rad1 (restarted) uses db1, the first writable server it lists" db1 "$(uses rad1)"

echo
echo "== db1 rebuilt as a standby of db2"
node db1 standby db1 db2
check "db2 streams to db1" "db1|streaming|async" "$(streams_to db2)"
login "OTP 5, rad1's session to db1 was ended"  ACCEPT rad1 5
check "rad1 uses db2" db2 "$(uses rad1)"
node rad1 admin add -u carol -P vvccccbbcdeh -p 4a6f8e2d1c3d -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d -w s3cr3t >/dev/null
check "the admin's change goes to db2, though db1 is listed first" "carol" \
    "$(node db2 sql yubikey "SELECT username FROM yubikeys WHERE username = 'carol'")"
wait_for "db1 has alice's counter (5)" 5 db1 "$ALICE"

echo
echo "== A failover loses the newest counter update (asynchronous replication)"
node db1 stop-streaming
wait_for "db2 no longer streams to db1" "" db2 "SELECT application_name FROM pg_stat_replication"
login "OTP 6 on db2, not copied to db1"         ACCEPT rad2 6
docker kill yk-ha-db2 >/dev/null
node db1 promote
login_until "OTP 6 again: accepted by the promoted db1" rad2 6
login_settled "OTP 6 a third time"              "REJECT: Replay attack detected" rad2 6
login "OTP 7"                                   ACCEPT rad1 7
docker start yk-ha-db2 >/dev/null
node db2 standby db2 db1
check "db1 streams to db2" "db2|streaming|async" "$(streams_to db1)"

echo
echo "== The primary (db1) hangs: it accepts connections but never answers"
docker pause yk-ha-db1 >/dev/null
login "OTP 8, the primary hangs"                "REJECT: Yubikey secret not found in database" rad1 8
check "Radiator answered within 7 s (Timeout + connect_timeout)" yes "$([[ $MS -lt 7000 ]] && echo yes || echo "no, $MS ms")"
# Each of Radiator's farm processes has its own connection and its own
# FailureBackoffTime, so this one may try the servers itself.
login "OTP 8 again"                             "REJECT: Yubikey secret not found in database" rad1 8
check "Radiator answered within 7 s" yes "$([[ $MS -lt 7000 ]] && echo yes || echo "no, $MS ms")"
docker kill yk-ha-db1 >/dev/null    # fenced: powered off before the standby is promoted
node db2 promote
login_until "OTP 8 after db2 is promoted" rad1 8
login "OTP 9, rad2's old session was to db1"    ACCEPT rad2 9
docker start yk-ha-db1 >/dev/null
node db1 standby db1 db2
check "db2 streams to db1" "db1|streaming|async" "$(streams_to db2)"
login "OTP 10"                                  ACCEPT rad1 10
login_settled "OTP 10 on the other Radiator server" "REJECT: Replay attack detected" rad2 10
wait_for "db1 has alice's counter (10)" 10 db1 "$ALICE"

echo
echo "== Planned switchover: stop the primary (db2) cleanly, promote db1"
login "OTP 11, just before the switchover"      ACCEPT rad1 11
node db2 stop
node db1 promote
login_until "OTP 12 on db1" rad1 12
login_settled "OTP 11: the clean stop sent every change" "REJECT: Replay attack detected" rad2 11
node db2 standby db2 db1
check "db1 streams to db2" "db2|streaming|async" "$(streams_to db1)"
check "rad1 uses db1" db1 "$(uses rad1)"
check "rad2 uses db1" db1 "$(uses rad2)"

echo
echo "== The same OTP on both Radiator servers at the same moment"
node db1 sql yubikey "DROP TRIGGER yubikeys_counters_forward ON yubikeys" >/dev/null
race 20
check "without the trigger (before 1.2.1): both accepted" "ACCEPT ACCEPT" "$ANSWERS"
check "both servers waited to save" 2 "$WAITING"
node rad1 admin init >/dev/null
wait_for "the admin's init adds the trigger, and the standby has it" 1 db2 \
    "SELECT count(*) FROM pg_trigger WHERE tgname = 'yubikeys_counters_forward'"
race 21
check "with the trigger: one accepted, one not answered" "ACCEPT NO REPLY" "$ANSWERS"
check "both servers waited to save" 2 "$WAITING"
login "OTP 22"                                  ACCEPT rad2 22

echo
printf 'Two database servers: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
