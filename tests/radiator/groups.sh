#!/bin/bash
#
# groups.sh - Runs inside the container that tests/radiator/run.sh builds, with
# the repository at /repo (read-only). Runs Radiator with
# radiator-groups.example.conf and the clauses from 'yubikey-db.sh config',
# and logs in over TACACS+ (with tacacs.pl) and RADIUS (with radpwtst), by
# YubiKey and by service account, from devices in different device groups:
# the login, the privilege level, the command rules and the RADIUS reply must
# be the ones the groups in the database give. With SQLite, then PostgreSQL.
#
# The devices are addresses in 127.0.0.0/8, which the loopback interface
# already has: core switches (127.0.0.11 and .12), an access subnet
# (127.0.0.20/30) and anything else (the catch-all <Client DEFAULT>).

set -uo pipefail

Y=/repo/yubikey-db.sh
RAD=/opt/radiator/radiator
LOG=/var/log/radiator/radiator.log
CONF=/etc/radiator/conf.d/yubikey.conf
K1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
B=()          # backend options for yubikey-db.sh
pass=0 fail=0

check() {
    if [[ $3 == "$2" ]]; then
        pass=$((pass + 1)); printf 'PASS  %s: %s\n' "$1" "$3"
    else
        fail=$((fail + 1)); printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

# The OTPs of each user's YubiKey. One counter for all, in a file, since
# OTPs are made in $(...) subshells.
echo 0 >/tmp/counter
next() { local n; n=$(($(cat /tmp/counter) + 1)); echo "$n" >/tmp/counter; echo "$n"; }
alice() { /repo/tests/make-otp.sh vvccccbbcdef 4a6f8e2d1c3b $K1 "$(next)" 0; }
bob()   { /repo/tests/make-otp.sh vvccccbbcdeg 4a6f8e2d1c3c $K1 "$(next)" 0; }
carol() { /repo/tests/make-otp.sh vvccccbbcdeh 4a6f8e2d1c3d $K1 "$(next)" 0; }

# tac FROM KEY authen|author|acct USER ...: TACACS+ from the device at FROM.
tac() { local from=$1 key=$2; shift 2; perl /repo/tests/radiator/tacacs.pl 127.0.0.1 "$key" "$from" "$@" 2>&1; }
CORE=(127.0.0.11 core-key) CORE2=(127.0.0.12 core2-key) ACCESS=(127.0.0.21 access-key) OTHER=(127.0.0.99 other-key)

# rad FROM SECRET USER PASSWORD [SERVICE_TYPE]: RADIUS from the device at
# FROM: "ACCEPT" and the reply attributes, or "REJECT" (or "NO-ANSWER").
rad() {
    local out
    out=$(perl "$RAD/radpwtst" -s 127.0.0.1 -secret "$2" -bind_address "$1" -auth_port 1812 -noacct \
            -timeout 3 -trace 4 -user "$3" -password "$4" ${5:+-service_type "$5"} 2>&1)
    if grep -q '^OK' <<<"$out"; then
        printf 'ACCEPT'
        sed -n '/Access-Accept/,$s/^[[:space:]]*\([A-Za-z-]*\) = \(.*\)$/ \1=\2/p' <<<"$out" \
            | grep -v 'Message-Authenticator' | tr -d '\n'
    elif grep -q 'Rejected' <<<"$out"; then
        printf 'REJECT'
    else
        printf 'NO-ANSWER'
    fi
}

# burst FROM KEY USER PASSWORD: a TACACS+ login, then 8 exec authorizations
# at the same moment, each on its own connection, so that several of
# Radiator's farm processes answer, most of them without having seen the
# login. Prints the login's answer and how many authorizations got priv-lvl=15.
burst() {
    local i pids=()
    tac "$1" "$2" authen "$3" "$4" >/tmp/burst-login
    for i in $(seq 8); do tac "$1" "$2" author "$3" 'service=shell,cmd*' >"/tmp/burst$i" & pids+=($!); done
    wait "${pids[@]}"
    printf '%s %s' "$(cat /tmp/burst-login)" "$(cat /tmp/burst[1-8] | grep -c '^PASS_ADD priv-lvl=15$')"
}

changed() { sleep 2.1; }

start_radiator() {
    pkill -f radiusd 2>/dev/null
    while pgrep -f radiusd >/dev/null; do sleep 0.2; done
    rm -f "$LOG"
    su radiator -s /bin/sh -c "perl $RAD/radiusd -foreground -no_pid_file -config_file /etc/radiator/radiator.conf" \
        >/tmp/radiusd.out 2>&1 &
    for _ in $(seq 50); do
        grep -qs 'Server started' "$LOG" && return
        sleep 0.2
    done
    echo "radiusd did not start:"; tail -20 "$LOG" /tmp/radiusd.out; exit 1
}

# The configuration, as the guide installs it, with the test devices.
install -m 0644 /repo/dictionary.yubikey /etc/radiator/dictionary.yubikey
install -m 0640 -o root -g radiator /repo/radiator-groups.example.conf /etc/radiator/radiator.conf
mkdir -p /etc/radiator/clients.d /etc/radiator/conf.d /var/lib/radiator
chown radiator /var/lib/radiator
cat >/etc/radiator/clients.d/test.conf <<'EOF'
<Client 127.0.0.11>
    Identifier     core
    Secret         core-secret
    TACACSPLUSKey  core-key
</Client>
<Client 127.0.0.12>
    Identifier     core
    Secret         core2-secret
    TACACSPLUSKey  core2-key
</Client>
<Client 127.0.0.20/30>
    Identifier     access
    Secret         access-secret
    TACACSPLUSKey  access-key
</Client>
<Client DEFAULT>
    Identifier     unlisted
    Secret         other-secret
    TACACSPLUSKey  other-key
</Client>
EOF

# The users, service account and groups, in the database chosen by B.
#   netadmins (alice, carol): core at 15, every command but reload; access
#     at 15, every command; unlisted devices at 1.
#   helpdesk (bob, carol): access at 1, only show.
#   backup (svc.backup): core at 15, only show running-config and copy.
setup_db() {
    "$Y" "${B[@]}" add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $K1 -w s3cr3t >/dev/null
    "$Y" "${B[@]}" add -u bob   -P vvccccbbcdeg -p 4a6f8e2d1c3c -k $K1 -w s3cr3t >/dev/null
    "$Y" "${B[@]}" add -u carol -P vvccccbbcdeh -p 4a6f8e2d1c3d -k $K1 -w s3cr3t >/dev/null
    "$Y" "${B[@]}" add -u anycast-test -P vvccccbbcdei -p 4a6f8e2d1c3e -k $K1 -w s3cr3t >/dev/null
    printf 'backup-password-1\n' | "$Y" "${B[@]}" service add svc.backup >/dev/null
    "$Y" "${B[@]}" group add netadmins >/dev/null
    "$Y" "${B[@]}" group add helpdesk >/dev/null
    "$Y" "${B[@]}" group add backup >/dev/null
    "$Y" "${B[@]}" member add netadmins alice carol >/dev/null
    "$Y" "${B[@]}" member add helpdesk bob carol >/dev/null
    "$Y" "${B[@]}" member add backup svc.backup >/dev/null
    "$Y" "${B[@]}" access set netadmins core 15 -r 'cisco-avpair="shell:priv-lvl=15"' >/dev/null
    "$Y" "${B[@]}" rule add netadmins core 'deny service=shell cmd=reload' >/dev/null
    "$Y" "${B[@]}" rule add netadmins core 'permit service=shell' >/dev/null
    "$Y" "${B[@]}" access set netadmins access 15 >/dev/null
    "$Y" "${B[@]}" access set netadmins unlisted 1 >/dev/null
    "$Y" "${B[@]}" access set helpdesk access 1 -r 'cisco-avpair="shell:priv-lvl=1"' >/dev/null
    "$Y" "${B[@]}" rule add helpdesk access 'permit service=shell cmd=show' >/dev/null
    "$Y" "${B[@]}" rule add helpdesk access 'deny .*' >/dev/null
    "$Y" "${B[@]}" access set backup core 15 >/dev/null
    "$Y" "${B[@]}" rule add backup core 'permit service=shell cmd=show cmd-arg=running-config' >/dev/null
    "$Y" "${B[@]}" rule add backup core 'permit service=shell cmd=copy' >/dev/null
    "$Y" "${B[@]}" rule add backup core 'deny .*' >/dev/null
}

# Every check, against the database Radiator is using now.
logins() {
    local o r
    echo "-- TACACS+: login, then authorizations answered by any farm process"
    check "alice on a core switch, then 8 exec authorizations at once" "PASS 8" \
        "$(burst "${CORE[@]}" alice "s3cr3t:$(alice)")"
    check "an authorization with no login before it (Authorize-Only)" "PASS_ADD priv-lvl=15" \
        "$(tac "${CORE[@]}" author alice 'service=shell,cmd*')"
    check "the same, with an empty cmd= (exec on some devices)" "PASS_ADD priv-lvl=15" \
        "$(tac "${CORE[@]}" author alice 'service=shell,cmd=')"

    "$Y" "${B[@]}" access set netadmins localhost 1 >/dev/null
    r=$(perl /opt/radiator/radiator/goodies/tacacsplustest -s 127.0.0.1 -key local-test-key \
            -user alice -password "s3cr3t:$(alice)" -noacct -notrace; echo "exit $?")
    check "the guide's test with Radiator's tacacsplustest" "OK OK exit 0" "$(paste -sd ' ' <<<"$r")"
    "$Y" "${B[@]}" access delete netadmins localhost >/dev/null

    echo "-- TACACS+: commands"
    check "alice: show on core" PASS_ADD "$(tac "${CORE[@]}" author alice 'service=shell,cmd=show,cmd-arg=version,cmd-arg=<cr>')"
    check "alice: reload on core (denied by rule)" FAIL "$(tac "${CORE[@]}" author alice 'service=shell,cmd=reload,cmd-arg=<cr>')"
    check "alice: reload on access (no rules: every command)" PASS_ADD \
        "$(tac "${ACCESS[@]}" author alice 'service=shell,cmd=reload,cmd-arg=<cr>')"
    check "alice: a service other than shell" FAIL "$(tac "${CORE[@]}" author alice 'service=ppp,protocol=ip')"

    echo "-- TACACS+: device groups"
    check "bob on core: refused" FAIL "$(tac "${CORE[@]}" authen bob "s3cr3t:$(bob)")"
    check "bob on access" PASS "$(tac "${ACCESS[@]}" authen bob "s3cr3t:$(bob)")"
    check "bob: exec on access" "PASS_ADD priv-lvl=1" "$(tac "${ACCESS[@]}" author bob 'service=shell,cmd*')"
    check "bob: show on access" PASS_ADD "$(tac "${ACCESS[@]}" author bob 'service=shell,cmd=show,cmd-arg=interfaces,cmd-arg=<cr>')"
    check "bob: configure on access (denied)" FAIL \
        "$(tac "${ACCESS[@]}" author bob 'service=shell,cmd=configure,cmd-arg=terminal,cmd-arg=<cr>')"
    check "bob: exec on core, no login (a proper FAIL)" FAIL "$(tac "${CORE[@]}" author bob 'service=shell,cmd*')"
    check "bob: a command on core, no login" FAIL "$(tac "${CORE[@]}" author bob 'service=shell,cmd=show,cmd-arg=version,cmd-arg=<cr>')"
    check "an unknown user: exec" FAIL "$(tac "${CORE[@]}" author nobody 'service=shell,cmd*')"
    check "carol (helpdesk and netadmins) on access: the more privileged group" "PASS_ADD priv-lvl=15" \
        "$(tac "${ACCESS[@]}" author carol 'service=shell,cmd*')"
    check "alice on the second core switch, with its own key" PASS "$(tac "${CORE2[@]}" authen alice "s3cr3t:$(alice)")"
    check "the second core switch with the first one's key: no answer" ERROR \
        "$(tac 127.0.0.12 core-key authen alice "s3cr3t:$(alice)")"
    check "alice from an unlisted device (catch-all)" PASS "$(tac "${OTHER[@]}" authen alice "s3cr3t:$(alice)")"
    check "alice: exec there" "PASS_ADD priv-lvl=1" "$(tac "${OTHER[@]}" author alice 'service=shell,cmd*')"
    check "bob from an unlisted device: refused" FAIL "$(tac "${OTHER[@]}" authen bob "s3cr3t:$(bob)")"

    echo "-- TACACS+: service account"
    check "svc.backup on core" PASS "$(tac "${CORE[@]}" authen svc.backup backup-password-1)"
    check "svc.backup, wrong password" FAIL "$(tac "${CORE[@]}" authen svc.backup backup-password-2)"
    check "svc.backup: copy" PASS_ADD "$(tac "${CORE[@]}" author svc.backup 'service=shell,cmd=copy,cmd-arg=running-config,cmd-arg=tftp:')"
    check "svc.backup: show running-config" PASS_ADD \
        "$(tac "${CORE[@]}" author svc.backup 'service=shell,cmd=show,cmd-arg=running-config,cmd-arg=<cr>')"
    check "svc.backup: show version (denied)" FAIL \
        "$(tac "${CORE[@]}" author svc.backup 'service=shell,cmd=show,cmd-arg=version,cmd-arg=<cr>')"
    check "svc.backup on access: refused" FAIL "$(tac "${ACCESS[@]}" authen svc.backup backup-password-1)"
    "$Y" "${B[@]}" service disable svc.backup >/dev/null
    check "svc.backup, disabled" FAIL "$(tac "${CORE[@]}" authen svc.backup backup-password-1)"
    "$Y" "${B[@]}" service enable svc.backup >/dev/null

    echo "-- TACACS+: enable, accounting"
    o=$(alice)
    check "alice: enable with a new OTP" PASS "$(tac "${CORE[@]}" authen alice "s3cr3t:$o" enable)"
    check "alice: enable with the same OTP again" FAIL "$(tac "${CORE[@]}" authen alice "s3cr3t:$o" enable)"
    check "accounting start" SUCCESS "$(tac "${CORE[@]}" acct alice start)"
    check "accounting stop" SUCCESS "$(tac "${CORE[@]}" acct alice stop)"
    sleep 0.3
    check "both written to tacacs-accounting.log" 2 \
        "$(grep -c 'User-Name = "alice"' /var/log/radiator/tacacs-accounting.log 2>/dev/null)"
    rm -f /var/log/radiator/tacacs-accounting.log

    echo "-- RADIUS"
    check "alice on core: the group's reply attributes" 'ACCEPT cisco-avpair="shell:priv-lvl=15"' \
        "$(rad 127.0.0.11 core-secret alice "s3cr3t:$(alice)")"
    check "bob on core: refused" REJECT "$(rad 127.0.0.11 core-secret bob "s3cr3t:$(bob)")"
    check "bob on access" 'ACCEPT cisco-avpair="shell:priv-lvl=1"' "$(rad 127.0.0.21 access-secret bob "s3cr3t:$(bob)")"
    check "alice on access (no reply attributes)" ACCEPT "$(rad 127.0.0.21 access-secret alice "s3cr3t:$(alice)")"
    check "alice from an unlisted device" ACCEPT "$(rad 127.0.0.99 other-secret alice "s3cr3t:$(alice)")"
    check "svc.backup on core" ACCEPT "$(rad 127.0.0.11 core-secret svc.backup backup-password-1)"
    check "Authorize-Only from a RADIUS client: refused" REJECT \
        "$(rad 127.0.0.11 core-secret alice whatever Authorize-Only)"
    check "the anycast check's user, from this server: no group needed" ACCEPT \
        "$(rad 127.0.0.1 local-test-secret anycast-test "s3cr3t:$(/repo/tests/make-otp.sh vvccccbbcdei 4a6f8e2d1c3e $K1 "$(next)" 0)")"
    check "the anycast check's user, from a device: refused" REJECT \
        "$(rad 127.0.0.11 core-secret anycast-test "s3cr3t:$(/repo/tests/make-otp.sh vvccccbbcdei 4a6f8e2d1c3e $K1 "$(next)" 0)")"

    echo "-- Changes in the database apply within 2 s, to sessions already open"
    # Radiator keeps the answer to a login or an authorization until its
    # next whole second (AuthorizationTimeout 0); changed() waits that out.
    "$Y" "${B[@]}" access set helpdesk core 5 >/dev/null
    check "bob on core, after 'access set helpdesk core 5'" PASS "$(tac "${CORE[@]}" authen bob "s3cr3t:$(bob)")"
    check "bob: exec there" "PASS_ADD priv-lvl=5" "$(tac "${CORE[@]}" author bob 'service=shell,cmd*')"
    "$Y" "${B[@]}" access delete helpdesk core >/dev/null
    changed
    check "bob: exec there, after 'access delete'" FAIL "$(tac "${CORE[@]}" author bob 'service=shell,cmd*')"
    "$Y" "${B[@]}" member delete netadmins carol >/dev/null
    changed
    check "carol on access, after leaving netadmins: helpdesk's level" "PASS_ADD priv-lvl=1" \
        "$(tac "${ACCESS[@]}" author carol 'service=shell,cmd*')"
    "$Y" "${B[@]}" member add netadmins carol >/dev/null
    check "alice logs in on core" PASS "$(tac "${CORE[@]}" authen alice "s3cr3t:$(alice)")"
    "$Y" "${B[@]}" disable alice >/dev/null
    changed
    check "alice: a command, after 'disable alice'" FAIL "$(tac "${CORE[@]}" author alice 'service=shell,cmd=show,cmd-arg=version,cmd-arg=<cr>')"
    "$Y" "${B[@]}" enable alice >/dev/null
    changed
    check "alice: a command, after 'enable alice'" PASS_ADD "$(tac "${CORE[@]}" author alice 'service=shell,cmd=show,cmd-arg=version,cmd-arg=<cr>')"
    r=$(grep -E 'ERR|Bad attribute' "$LOG" | grep -v 'Bad Key?')
    check "no errors in Radiator's log (but the wrong key's)" "" "$r"
}

check "radiusd -c accepts radiator-groups.example.conf" ok \
    "$("$Y" config >"$CONF" 2>/dev/null && su radiator -s /bin/sh -c \
        "perl $RAD/radiusd -c -foreground -no_pid_file -config_file /etc/radiator/radiator.conf" >/dev/null 2>&1 && echo ok)"

echo "== SQLite"
"$Y" init --owner radiator:radiator >/dev/null 2>&1
setup_db
"$Y" config >"$CONF"
start_radiator
logins

echo
echo "== PostgreSQL (local socket)"
pg_ctlcluster 18 main start
su postgres -c "$Y -b pg init-pg --admin root" >/dev/null
B=(-b pg)
setup_db
"$Y" "${B[@]}" config >"$CONF"
start_radiator
logins

echo "-- PostgreSQL stopped"
# Each of Radiator's processes refuses the first request it gets whose query
# the stop cuts off (Radiator counts it as no such user), and keeps that
# answer until its next whole second; after that, with no database server
# answering, it gives no answer (a TACACS+ error), so the device may try
# another server. Which process gets which request varies, so a refusal
# may come after errors. Nothing is allowed. With 4 processes, each
# refusing for at most a second, and about 4 requests a second, at most 16
# of 20 requests are refused.
pg_ctlcluster 18 main stop -m fast
changed
for i in $(seq 20); do tac "${CORE[@]}" author alice 'service=shell,cmd*' | cut -d' ' -f1; sleep 0.25; done >/tmp/down
check "20 TACACS+ authorizations over 5 s: none allowed" 0 "$(grep -c PASS /tmp/down)"
check "...each refused or an error" 20 "$(grep -c -E '^(FAIL|ERROR)$' /tmp/down)"
r=$(paste -sd ' ' /tmp/down)
if [[ $(grep -c '^ERROR$' /tmp/down) -ge 4 ]]; then r=yes; fi
check "...at least 4 errors" yes "$r"
# RADIUS logins stop at the YubiKey check, as without groups: held, then
# rejected (see the guide's Troubleshooting).
for i in $(seq 4); do rad 127.0.0.11 core-secret alice "s3cr3t:$(alice)"; echo; done >/tmp/down
check "4 RADIUS logins: none accepted" 0 "$(grep -c ACCEPT /tmp/down)"
pg_ctlcluster 18 main start

echo
printf 'Radiator %s: %d passed, %d failed\n' \
    "$(dpkg-query -W -f '${Version}' radiator)" "$pass" "$fail"
[[ $fail -eq 0 ]]
