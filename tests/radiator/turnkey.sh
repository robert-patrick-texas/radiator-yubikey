#!/usr/bin/env bash
#
# turnkey.sh - Test yubikey-turnkey the way its runbook says to use it: make
# the folders from a site.toml, copy each to a fresh Ubuntu 26.04 server
# (systemd, and nothing else installed), run setup.sh on the three at the
# same time, and check what they set up, from a device and from the
# routers.
#
# Usage: tests/radiator/turnkey.sh IMAGE DIR
#   IMAGE  the test image that run.sh builds: it runs the generator (as the
#          admins' machine), the routers (FRR) and the device
#   DIR    the Radiator packages, as for run.sh
#
# The lab, on the Docker network yk-tk (172.31.99.0/24, fd53:99::/64):
#   yk-tk-east1  .11  the usual primary         router: rtr1
#   yk-tk-east2  .12                            router: rtr1
#   yk-tk-west   .13  the last resort           routers: rtr1 and rtr2
#   yk-tk-rtr1   .2   FRR, preferring West, then East1, then East2; also on
#                     yk-tk-nas (172.31.100.0/24, fd53:100::/64) as .2
#   yk-tk-rtr2   .3   FRR, West's second router
#   yk-tk-nas    172.31.100.10 on yk-tk-nas: a device in device group core,
#                     and the admins' machine (the admin subnet)
# The servers start from the image yk-turnkey-base:26.04 (ubuntu:26.04 with
# systemd and iproute2), so setup.sh installs everything with apt-get (this
# needs network access); the packages come from yubikey-turnkey --packages.
#
# Checks: the generator's output and --check; setup.sh --check; setup.sh on
# the three at once; the cluster, the anycast check and the BGP sessions;
# logins at the anycast addresses over RADIUS and TACACS+, IPv4 and IPv6,
# as a YubiKey user and a service account, refused for a group without
# access to the device's group and from an unknown device (the catch-all);
# West withdrawn from both of its routers when only its TACACS+ login
# fails, and when its check stops; setup.sh --status, when all is well and
# when etcd, a router, the primary, the anycast check or the folder isn't;
# the backups (setup.sh's first, the daily ones on a standby, how many it
# keeps, --status when one is old or the timer is off, a check on the
# admin's machine, a restore on the primary: what it undoes, the counters
# and the anycast checks' keys it keeps, and a refusal on a standby); the
# firewall; setup.sh run again (nothing changes or restarts); a reboot; a
# new device from site.toml; new certificates; servers rebuilt with the
# same names and addresses, while the other two run (West, whose check
# renewed its key, and East1, the first server, lost while the primary,
# on new servers; East2 in place, after --reset on it alone), setup.sh
# stopping when two servers' etcd is down, and waiting when all three's
# is, to join once the others start; two servers lost (East1 and East2:
# West in partition mode, then setup.sh --alone on it, refused while they
# answer, without a terminal and when not answered yes, and again with
# --yes; the two set up again at once, the
# counters of West's logins in between kept, the primary moved back);
# --reset on all three, then the last backup restored into the new
# cluster; then servers replaced (West moved to new addresses, after
# --reset on it; East1, lost while the primary, replaced by east1b, a new
# name and addresses): site.toml, the routers, setup.sh on the two that
# stay (etcd with quorum only, the anycast checks swapped by the primary),
# then on the new one (the old etcd member removed), the primary moved to
# the new first server; and new passwords and keys (yubikey-turnkey
# --rotate: a standby run first waits for the primary, logins every second
# all along, replication with the new password, a switchover, the admin's
# old and new passwords and their own kept, a device's new key). The lab
# itself is in turnkey-lib.sh, with upgrade.sh's.
#
# Needs Docker, usable without sudo. KEEP=1 leaves the containers running.
# Exits 0 when every check passes.

# shellcheck disable=SC2016  # the containers' shells expand the commands given to "on"

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$(dirname -- "$here")")
[[ $# -eq 2 && -d $2 ]] || { echo "usage: tests/radiator/turnkey.sh IMAGE DIR" >&2; exit 2; }
image=$1
# shellcheck disable=SC2034  # for turnkey-lib.sh
rads=$(cd -- "$2" && pwd)
# shellcheck source=tests/radiator/turnkey-lib.sh disable=SC1091
. "$here/turnkey-lib.sh"
lab_start

# east1_primary: after Patroni lost its DCS (and demoted East1, perhaps),
# wait for a primary and two standbys, and move the primary back to East1
# if East2 has it.
east1_primary() {
    local m
    m=$(until_match 90 '^east1=(leader|quorum) east2=(leader|quorum) west=quorum$' members)
    check_match "Patroni: a primary and two standbys again" '^east1=(leader|quorum) east2=(leader|quorum) west=quorum$' "$m"
    if [[ $m == *east2=leader* ]]; then
        on east1 'patronictl -c /etc/patroni/18-main.yml switchover --candidate east1 --force >/dev/null 2>&1'
    fi
    check "East1 the primary" "east1=leader east2=quorum west=quorum" \
        "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
}

lab_prepare
site_toml '' | docker run --rm -i -v yk-tk-lab:/lab "$image" bash -c 'cat >/lab/site.toml' || exit 1

echo "== The generator"
out=$(gen '-p /lab/pkgs site.toml'); rc=$?
check "yubikey-turnkey makes the folders" 0 "$rc"
[[ $rc == 0 ]] || { printf '%s\n' "$out"; exit 1; }
check "secrets.toml is the admin's only" 600 "$(lab 'stat -c %a /lab/secrets.toml')"
check "out/ is the admin's only" 700 "$(lab 'stat -c %a /lab/out')"
check "a server's folder has setup.sh and the packages" \
    "install.sh radiator radiator-radius-utilxs radiator-yubikey setup.sh" \
    "$(lab 'cd /lab/out/west && ls *.deb install.sh setup.sh | sed "s/_.*//" | sort -u | paste -sd" "')"
check "--check: up to date" "0 up to date" \
    "$(lab 'cd /lab && python3 /repo/yubikey-turnkey --check -p /lab/pkgs site.toml >/tmp/o; echo $? $(sed "s/.*: //" /tmp/o)')"
check "the same input gives the same output" "out: up to date" "$(gen '-p /lab/pkgs site.toml')"

CORE_SECRET=$(secret "device|$NAS4|secret") CORE_KEY=$(secret "device|$NAS4|tacacs_key")
CORE6_SECRET=$(secret "device|$NAS6|secret") CORE6_KEY=$(secret "device|$NAS6|tacacs_key")
CATCH_KEY=$(secret 'catch_all|tacacs_key')

lab_machines

echo "== setup.sh"
for n in "${SITES[@]}"; do on "$n" "cp -a /lab/out/$n /root/turnkey && chmod 700 /root/turnkey" || exit 1; done
for n in "${SITES[@]}"; do
    out=$(on "$n" '/root/turnkey/setup.sh --check'); rc=$?
    check "$n: setup.sh --check on a fresh server" "0 Nothing to fix." "$rc $(tail -1 <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
done
work=$(mktemp -d)
start=$SECONDS
for n in "${SITES[@]}"; do
    on "$n" '/root/turnkey/setup.sh' >"$work/$n.log" 2>&1 &
    echo $! >"$work/$n.pid"
done
for n in "${SITES[@]}"; do
    wait "$(cat "$work/$n.pid")"; rc=$?
    check "$n: setup.sh" "0 $n is set up." "$rc $(tail -1 "$work/$n.log")"
    if [[ $rc != 0 ]]; then echo "--- $n's setup.sh:"; cat "$work/$n.log"; fi
done
echo "(the three setup.sh took $((SECONDS - start)) s)"
for n in "${SITES[@]}"; do sed -n '/== report/,$p' "$work/$n.log" | sed "s/^/$n: /"; done

check "west: /etc/hosts has the three servers, IPv4 only" \
    "${IP[east1]} east1.$DOMAIN east1|${IP[east2]} east2.$DOMAIN east2|${IP[west]} west.$DOMAIN west" \
    "$(on west 'sed -n "/^# BEGIN yubikey-turnkey/,/^# END/{/^#/d;p}" /etc/hosts' | tr '\t' ' ' | paste -sd'|')"
check "and the host name no other address" "" "$(on west 'grep -v "^#" /etc/hosts | grep -wn west | grep -v "${IP[west]}"')"

echo
echo "== The cluster and the anycast check"
check "Patroni: East1 leads, the others confirm its commits" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 30 "east1=leader east2=quorum west=quorum" members)"
for n in "${SITES[@]}"; do
    check "$n: the anycast check advertises" advertised \
        "$(until_eq 30 advertised on "$n" '/opt/radiator-yubikey/yubikey-anycast.sh status | head -1 | cut -d" " -f1')"
    check_match "$n: its last check logged in over RADIUS and TACACS+" '^ACCEPT in [0-9]+ ms; TACACS\+ PASS in [0-9]+ ms' \
        "$(on "$n" '/opt/radiator-yubikey/yubikey-anycast.sh status | sed -n "s/^last check: //p"')"
    check "$n: partition mode, normal" "normal" \
        "$(on "$n" '/opt/radiator-yubikey/yubikey-partition.sh status | head -1 | cut -d" " -f1')"
done
check "rtr1: the routes of all three, West first" "west,east1,east2 west,east1,east2" \
    "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
check "rtr2 (West's second router): West's routes" "west west" "$(until_eq 30 "west west" routes rtr2)"
check "rtr1: BGP and BFD with the three servers, IPv4 and IPv6" "BGP 6, BFD 6" "$(until_eq 30 "BGP 6, BFD 6" sessions rtr1)"
check "west: BGP sessions with both routers" "BGP 4, BFD 4" "$(until_eq 30 "BGP 4, BFD 4" sessions west)"

echo
echo "== setup.sh --status"
for n in "${SITES[@]}"; do check_status "$n: --status: all is well" "$n" "^0 $n: OK\$"; done
on east1 'cat /tmp/status.out' | sed 's/^/east1: /'
echo "(east1's --status took $(on east1 's=$(date +%s%N); /root/turnkey/setup.sh --status >/dev/null; echo $((($(date +%s%N) - s) / 1000000))') ms)"
check "every line ok" 0 "$(on east1 'tail -n +3 /tmp/status.out | grep -cv "^  ok    "')"
check "west: the package's copy, without the folder" "0 west: OK" \
    "$(on west 'mv /root/turnkey /root/turnkey.away
                /opt/radiator-yubikey/yubikey-turnkey-setup.sh --status >/tmp/status.out 2>&1; echo "$? $(head -1 /tmp/status.out)"
                mv /root/turnkey.away /root/turnkey')"
check "not as root: UNKNOWN" "3 UNKNOWN - run it as root (sudo /opt/radiator-yubikey/yubikey-turnkey-setup.sh --status)" \
    "$(on west 'out=$(runuser -u nobody -- /opt/radiator-yubikey/yubikey-turnkey-setup.sh --status); echo "$? $out"')"

echo
echo "== Logins at the anycast addresses"
# The admin, from the device's machine (in the admin subnet), with the files
# from out/admin.
on nas 'cp /lab/out/admin/ca.crt /root/.yubikey-ca.crt && install -m 0600 /lab/out/admin/pgpass /root/.pgpass' || exit 1
out=$(admin "import - <<'EOF'
alice,vvccccbbcdef,4a6f8e2d1c3b,$K1,s3cr3t,1
bob,vvccccbbcdeg,4a6f8e2d1c3c,$K1,s3cr3t,1
EOF
") || printf '%s\n' "$out"
check "the admin loads YubiKeys over TLS, from the admin subnet" "Imported 2 row(s)" "$(grep -o 'Imported 2 row(s)' <<<"$out")"
printf '%s\n' 'backup-password-1234' | admin 'service add svc.backup' >/dev/null 2>&1
for a in 'member add netadmins alice' 'member add helpdesk bob' 'group add backup' 'member add backup svc.backup' \
         'access set backup core 15'; do
    admin "$a" >/dev/null 2>&1 </dev/null
done
ALICE=(vvccccbbcdef 4a6f8e2d1c3b) BOB=(vvccccbbcdeg 4a6f8e2d1c3c)
otp "${ALICE[@]}"
check "RADIUS over IPv4: alice (netadmins) on a core device" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
otp "${ALICE[@]}"
check "RADIUS over IPv6" "ACCEPT from $ANY6" "$(radius "$ANY6" "$CORE6_SECRET" alice "s3cr3t:$OTP")"
otp "${ALICE[@]}"
check "TACACS+ over IPv4: alice" PASS "$(tac "$ANY4" "$CORE_KEY" "$NAS4" authen alice "s3cr3t:$OTP")"
otp "${ALICE[@]}"
check "TACACS+ over IPv6" PASS "$(tac "$ANY6" "$CORE6_KEY" "$NAS6" authen alice "s3cr3t:$OTP")"
check "TACACS+ authorization: netadmins' level 15" "PASS_ADD priv-lvl=15" \
    "$(tac "$ANY4" "$CORE_KEY" "$NAS4" author alice service=shell,cmd*)"
otp "${BOB[@]}"
check "bob (helpdesk, access devices only) on a core device: RADIUS" "REJECT from $ANY4" \
    "$(radius "$ANY4" "$CORE_SECRET" bob "s3cr3t:$OTP")"
otp "${BOB[@]}"
check "and TACACS+" FAIL "$(tac "$ANY4" "$CORE_KEY" "$NAS4" authen bob "s3cr3t:$OTP")"
check "the service account svc.backup over TACACS+" PASS "$(tac "$ANY4" "$CORE_KEY" "$NAS4" authen svc.backup backup-password-1234)"
check "and over RADIUS" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" svc.backup backup-password-1234)"
on nas 'ip addr add 172.31.100.20/24 dev eth0' || exit 1
check "an unknown device (the catch-all, device group unlisted): no access" FAIL \
    "$(tac "$ANY4" "$CATCH_KEY" 172.31.100.20 authen svc.backup backup-password-1234)"
admin 'access set backup unlisted 1' >/dev/null 2>&1 </dev/null
check "with access to unlisted" PASS "$(tac "$ANY4" "$CATCH_KEY" 172.31.100.20 authen svc.backup backup-password-1234)"
check "the check's user is refused from a device" "REJECT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" anycast-west x:y)"

echo
echo "== Backups"
for n in "${SITES[@]}"; do
    check "$n: setup.sh made the first backup, for the group adm" "640 root:adm" \
        "$(on "$n" 'stat -c "%a %U:%G" /var/backups/yubikey-db.cms.0')"
    check_match "$n: the daily timer, next at about 03:00" '^active .* 03:[0-3][0-9]:[0-9]{2} ' \
        "$(on "$n" 'echo "$(systemctl is-active yubikey-backup.timer) $(systemctl show -P NextElapseUSecRealtime yubikey-backup.timer)"')"
done
check "west: secrets.toml, encrypted, from the folder" same \
    "$(on west 'cmp -s /var/backups/yubikey-turnkey-secrets.toml.cms /lab/out/secrets.toml.cms && echo same')"
for _ in 1 2 3; do on west 'systemctl start yubikey-backup.service'; done
check "west: three more, as the timer makes them: it keeps 3" "yubikey-db.cms.0 yubikey-db.cms.1 yubikey-db.cms.2" \
    "$(on west 'cd /var/backups && ls yubikey-db.cms.* | paste -sd" "')"
check_match "west: from its own PostgreSQL, a standby" '^made /var/backups/yubikey-db\.cms\.0 \([0-9]+ KB, of database yubikey on a standby\); keeping 3$' \
    "$(on west 'journalctl -u yubikey-backup -o cat | grep "^made" | tail -1')"
check_status "west: --status OK" west '^0 west: OK$'
check_match "with its line" '^  ok    backups: the newest backup is 0 min old, 3 of 3 kept$' "$(on west 'grep "backups:" /tmp/status.out')"
on east2 'touch -d "-30 hours" /var/backups/yubikey-db.cms.0'
check_status "east2: the newest 30 hours old: WARNING" east2 \
    '^1 east2: WARNING - backups: the newest backup is 30 h old: none was made in the last 26 hours'
on east2 'systemctl start yubikey-backup.service'
check_status "a new one: OK" east2 '^0 east2: OK$'
on east2 'systemctl stop yubikey-backup.timer'
check_status "the timer stopped: WARNING" east2 '^1 east2: WARNING - backups: the daily timer is off'
on east2 'systemctl start yubikey-backup.timer'
check_status "started: OK" east2 '^0 east2: OK$'

# The admin fetches east1's newest, checks it, and decrypts it on their
# machine, with the key (in /lab); the dump goes to the primary.
on east1 'systemctl start yubikey-backup.service'
fetch() { on "$1" "cat $2" | docker exec -i yk-tk-nas bash -c "cat >$3"; }
put() { on nas "cat $1" | docker exec -i "yk-tk-$2" bash -c "umask 077 && cat >$3"; }
fetch east1 /var/backups/yubikey-db.cms.0 /root/east1.cms
out=$(on nas 'bash /repo/yubikey-backup.sh check --key /lab/backup.key --passin pass:lab-only /root/east1.cms')
check_match "the admin's machine: it decrypts and reads back whole" \
    '^/root/east1\.cms: a whole backup of the YubiKey database, made [0-9-]+ [0-9:]+ UTC \(PostgreSQL 18' "$(head -1 <<<"$out")"
check "with the YubiKeys, the service accounts and the groups" \
    "  it holds 5 YubiKeys (of 5 users), 4 service accounts, 4 groups" "$(tail -1 <<<"$out")"
on nas 'bash /repo/yubikey-backup.sh decrypt --key /lab/backup.key --passin pass:lab-only /root/east1.cms /root/east1.dump >/dev/null' \
    || exit 1
put /root/east1.dump east1 /root/east1.dump
put /root/east1.dump east2 /root/east1.dump
# Since that backup: alice logs in (her counters move ahead), bob's YubiKey
# is deleted, svc.backup leaves the group backup, and West's check renews
# its key.
otp "${ALICE[@]}"
USED=$OTP
check "alice logs in after the backup" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$USED")"
admin 'delete bob vvccccbbcdeg' >/dev/null 2>&1 </dev/null
admin 'member delete backup svc.backup' >/dev/null 2>&1 </dev/null
check_match "west's check renews its key" '^renewed the key of anycast-west' \
    "$(on west 'systemctl stop yubikey-anycast && /opt/radiator-yubikey/yubikey-anycast.sh renew; systemctl start yubikey-anycast')"
check "east2, a standby: no restore there" \
    "3 yubikey-backup.sh: error: this server's PostgreSQL is a standby: restore on the primary" \
    "$(on east2 'out=$(/opt/radiator-yubikey/yubikey-backup.sh restore --yes /root/east1.dump 2>&1); echo "$? $out"')"
out=$(on east1 '/opt/radiator-yubikey/yubikey-backup.sh restore --yes /root/east1.dump 2>&1'); rc=$?
check "east1, the primary: the restore" 0 "$rc"
[[ $rc == 0 ]] || printf '%s\n' "$out"
check "it says that bob's YubiKey comes back" "  YubiKeys deleted since the backup, which come back: bob vvccccbbcdeg" \
    "$(grep '^  YubiKeys' <<<"$out")"
check "and the group's member" "  Groups changed since the backup, which are put back as they were: backup (members)" \
    "$(grep '^  Groups' <<<"$out")"
check "it keeps alice's counters, and the three checks' keys" \
    "Kept the counters of 1 YubiKey(s) that were ahead, and the keys of 3 anycast check(s)." "$(tail -1 <<<"$out")"
check "alice's OTP from after the backup: still refused" "REJECT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$USED")"
otp "${ALICE[@]}"
check "her next one: accepted" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
check "bob's YubiKey is back" 1 "$(admin 'list bob' 2>/dev/null </dev/null | grep -c vvccccbbcdeg)"
check "svc.backup is in the group backup again" PASS "$(tac "$ANY4" "$CORE_KEY" "$NAS4" authen svc.backup backup-password-1234)"
sleep 10
check "west's renewed key stays: all three still advertise" "west,east1,east2 west,east1,east2" \
    "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
check_match "west's check logs in" '^ACCEPT in [0-9]+ ms; TACACS\+ PASS' \
    "$(on west '/opt/radiator-yubikey/yubikey-anycast.sh status | sed -n "s/^last check: //p"')"
check_status "east1: --status OK" east1 '^0 east1: OK$'

echo
echo "== West withdraws when only its TACACS+ login fails, from both routers"
admin 'service disable svc.anycast-west' >/dev/null 2>&1 </dev/null
check "rtr1: West gone" "east1,east2 east1,east2" "$(until_eq 40 "east1,east2 east1,east2" routes rtr1)"
check "rtr2: West gone" "- -" "$(until_eq 10 "- -" routes rtr2)"
check_match "west's check: RADIUS works, TACACS+ refused" '^ACCEPT in [0-9]+ ms; TACACS\+ FAIL in [0-9]+ ms: No such user' \
    "$(on west '/opt/radiator-yubikey/yubikey-anycast.sh status | sed -n "s/^last check: //p"')"
check_status "west: --status: CRITICAL, withdrawn" west '^2 west: CRITICAL - anycast: withdrawn since .*TACACS\+ FAIL'
otp "${ALICE[@]}"
check "RADIUS at the anycast address: East1 answers" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
admin 'service enable svc.anycast-west' >/dev/null 2>&1 </dev/null
check "West back on rtr1" "west,east1,east2 west,east1,east2" "$(until_eq 40 "west,east1,east2 west,east1,east2" routes rtr1)"
check "and on rtr2" "west west" "$(until_eq 10 "west west" routes rtr2)"
on west 'systemctl stop yubikey-anycast'
check "West's check stopped: gone from rtr2 at once" "- -" "$(until_eq 10 "- -" routes rtr2)"
on west 'systemctl start yubikey-anycast'
check "and back" "west west" "$(until_eq 30 "west west" routes rtr2)"

echo
echo "== What --status sees"
on east2 'systemctl stop etcd'
check_status "etcd stopped on east2: east1 warns" east1 '^1 east1: WARNING - etcd: 2 of 3 members healthy \(not east2\)$'
check_status "east2: CRITICAL" east2 '^2 east2: CRITICAL - not running: etcd .*etcd: 2 of 3 members healthy \(not east2\)'
on east2 'systemctl start etcd'
check_status "etcd started: east2 OK" east2 '^0 east2: OK$'
on rtr2 'systemctl stop frr'
check_status "rtr2 stopped: west warns" west '^1 west: WARNING - BGP: .*Established.*(Active|Connect|Idle)'
on rtr2 'systemctl start frr'
check_status "rtr2 back: west OK" west '^0 west: OK$'
on east1 'patronictl -c /etc/patroni/18-main.yml switchover --candidate east2 --force >/dev/null 2>&1'
check "the primary moved to east2" "east1=quorum east2=leader west=quorum" \
    "$(until_eq 60 "east1=quorum east2=leader west=quorum" members)"
check_status "east1 warns: the primary isn't east1" east1 \
    '^1 east1: WARNING - Patroni: the primary is east2, not east1 \(patronictl switchover --candidate east1\)'
on east1 'patronictl -c /etc/patroni/18-main.yml switchover --candidate east1 --force >/dev/null 2>&1'
check "and back to east1" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
check_status "east1: OK" east1 '^0 east1: OK$'

echo
echo "== The firewall"
check "east1: INPUT drops what isn't allowed" "-P INPUT DROP" "$(on east1 'iptables -S INPUT | head -1')"
check "and IPv6" "-P INPUT DROP" "$(on east1 'ip6tables -S INPUT | head -1')"
check "ufw isn't running" "inactive" "$(on east1 'systemctl is-active ufw')"
check "PostgreSQL from outside the admin subnet (rtr2): no answer" "timeout" \
    "$(on rtr2 "timeout 3 bash -c 'exec 3<>/dev/tcp/${IP[east1]}/5432' 2>/dev/null && echo open || { [[ \$? == 124 ]] && echo timeout || echo refused; }")"
check "Patroni's API from the admin subnet" 200 \
    "$(on nas "curl -s -o /dev/null -w '%{http_code}' --cacert /lab/out/admin/ca.crt https://east1.$DOMAIN:8008/primary")"

echo
echo "== setup.sh again"
pid=$(on west 'systemctl show -p MainPID --value radiator')
out=$(on west '/root/turnkey/setup.sh'); rc=$?
check "west: setup.sh again" "0 west is set up." "$rc $(tail -1 <<<"$out")"
check "it changes nothing" "" "$(grep -E '^  \.\.    (installed|updated|removed)' <<<"$out")"
check "and restarts nothing (Radiator's PID)" "$pid" "$(on west 'systemctl show -p MainPID --value radiator')"
out=$(on west '/root/turnkey/setup.sh --check'); rc=$?
check "setup.sh --check on a server it set up" "0 Nothing to fix." "$rc $(tail -1 <<<"$out")"
[[ $rc == 0 ]] || printf '%s\n' "$out"

echo
echo "== A reboot"
docker restart yk-tk-west >/dev/null && booted west
check "west: the firewall is back" "-P INPUT DROP" "$(on west 'iptables -S INPUT | head -1')"
check "Patroni: west streams again" "west=quorum" \
    "$(until_eq 60 west=quorum bash -c "docker exec yk-tk-west patronictl -c /etc/patroni/18-main.yml list -f json | python3 -c '
import json, sys
print(\" \".join(\"%s=%s\" % (m[\"Member\"], \"quorum\" if m[\"Role\"] == \"Quorum Standby\" and m[\"State\"] == \"streaming\" else m[\"Role\"]) for m in json.load(sys.stdin) if m[\"Member\"] == \"west\"))'")"
check "rtr2: West advertises again" "west west" "$(until_eq 60 "west west" routes rtr2)"

echo
echo "== A new device, from site.toml"
site_toml '[[device]]
address = "172.31.100.20"
group = "lab2"' | docker run --rm -i -v yk-tk-lab:/lab "$image" bash -c 'cat >/lab/site.toml' || exit 1
out=$(gen '-p /lab/pkgs site.toml')
check_match "the generator writes the folders again" 'out/east1/: [0-9]+ written' "$out"
check "with the new device's file in each" 3 "$(lab 'ls /lab/out/*/files/etc/radiator/clients.d/lab2.conf | wc -l')"
LAB2_KEY=$(secret 'device|172.31.100.20|tacacs_key')
for n in "${SITES[@]}"; do
    on "$n" "cp -a /lab/out/$n/. /root/turnkey/" || exit 1
    if [[ $n == west ]]; then
        check "west: --status: the folder isn't set up yet" \
            "1 west: WARNING - setup.sh: /root/turnkey has changed since setup.sh last finished: run it" "$(status west)"
    fi
    out=$(on "$n" '/root/turnkey/setup.sh'); rc=$?
    check "$n: setup.sh with the new device" "0 $n is set up." "$rc $(tail -1 <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
done
check_status "west: --status: OK again" west '^0 west: OK$'
check "the new device, in device group lab2: no access yet" FAIL \
    "$(tac "$ANY4" "$LAB2_KEY" 172.31.100.20 authen svc.backup backup-password-1234)"
admin 'access set backup lab2 1' >/dev/null 2>&1 </dev/null
check "with access to lab2" PASS "$(tac "$ANY4" "$LAB2_KEY" 172.31.100.20 authen svc.backup backup-password-1234)"

echo
echo "== New certificates, one server at a time"
# served HOST PORT [starttls]: the serial of the certificate a server presents.
served() {
    on nas "openssl s_client -connect $1:$2 ${3:+-starttls $3} -CAfile /lab/out/admin/ca.crt </dev/null 2>/dev/null \
            | openssl x509 -noout -serial"
}
old=$(served "east1.$DOMAIN" 8008)
out=$(gen '--renew-certs -p /lab/pkgs site.toml')
# (In each folder the certificate and key, for etcd and for Patroni, and the
# copy of secrets.toml.)
check_match "the generator makes new ones" "out/east1/: 5 written" "$out"
for n in east2 west east1; do
    on "$n" "cp -a /lab/out/$n/. /root/turnkey/" || exit 1
    out=$(on "$n" '/root/turnkey/setup.sh'); rc=$?
    check "$n: setup.sh with the new certificate" "0 $n is set up." "$rc $(tail -1 <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
    new=$(on "$n" 'openssl x509 -noout -serial -in /etc/patroni/tls/server.crt')
    # Patroni takes up a reload in its own loop, within 10 s.
    check "$n: Patroni's REST API presents it" "$new" "$(until_eq 30 "$new" served "$n.$DOMAIN" 8008)"
    check "$n: PostgreSQL presents it" "$new" "$(served "$n.$DOMAIN" 5432 postgres)"
    check "$n: etcd presents it" "$new" \
        "$(on "$n" "openssl s_client -connect ${IP[$n]}:2379 -cert /etc/etcd/tls/server.crt -key /etc/etcd/tls/server.key \
                    -CAfile /etc/etcd/tls/ca.crt </dev/null 2>/dev/null | openssl x509 -noout -serial")"
done
check "east1's is a new one" new "$(if [[ $old != "$new" ]]; then echo new; else echo old; fi)"
check "etcd: 3 members healthy" 3 \
    "$(on east1 'etcdctl --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt --key /etc/etcd/tls/server.key \
                 --endpoints https://'"${IP[east1]}"':2379 endpoint health --cluster 2>&1 | grep -c "is healthy"')"
check "Patroni: as before" "east1=leader east2=quorum west=quorum" "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
check "rtr1: all three advertise" "west,east1,east2 west,east1,east2" "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
otp "${ALICE[@]}"
check "and log users in" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"

echo
echo "== West rebuilt: a new server with the same name and addresses"
# West's disk is lost. Its check renewed its key (in the backups' part), so
# the key in its folder is no longer the one the database has.
renewed=$(on west 'sed -n "s/^private_id=//p" /var/lib/yubikey-anycast/key')
check "west's check has a renewed key, not its folder's" renewed \
    "$([[ $renewed != "$(on east1 'sed -n "s/^private_id=//p" /lab/out/west/files/var/lib/yubikey-anycast/key')" ]] && echo renewed)"
docker rm -f yk-tk-west >/dev/null
check "rtr1: West gone" "east1,east2 east1,east2" "$(until_eq 30 "east1,east2 east1,east2" routes rtr1)"
otp "${ALICE[@]}"
check "logins go on" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
check_status "east1: --status without West" east1 \
    '^1 east1: WARNING - etcd: 2 of 3 members healthy \(not west\); Patroni: west is missing'
server west && booted west && lab_route west || exit 1
on west "cp -a /lab/out/west /root/turnkey && chmod 700 /root/turnkey" || exit 1
t=$SECONDS
out=$(on west '/root/turnkey/setup.sh'); rc=$?
check "west: setup.sh on the new server, the other two running" "0 west is set up." "$rc $(tail -1 <<<"$out")"
[[ $rc == 0 ]] || printf '%s\n' "$out"
echo "(it took $((SECONDS - t)) s)"
check_match "etcd: West's member from before removed, added again as a learner, promoted, and joined" \
    $'== etcd\n.*  \\.\\.    etcd: removed this server\'s member from before \\([0-9a-f]+\\), to add it again\n  \\.\\.    etcd: added this server\'s member \\([0-9a-f]+\\), as a learner until it has caught up\n.*  \\.\\.    etcd: promoted this server\'s member, which has caught up\n(  \\.\\.    [^\n]*\n)*  ok    etcd: joined the cluster; 3 members healthy' "$out"
check "/etc/default/etcd: the folder's again" "" \
    "$(on west 'cmp /root/turnkey/files/etc/default/etcd /etc/default/etcd')"
check "Patroni: West copied the database" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
check_match "the check's key, from the database" \
    $'== anycast\n.*  \\.\\.    the anycast check\'s key from the database: renewed on [0-9-]{10}\n[^=]*  ok    the anycast check: [^\n]*' "$out"
check "the renewed one" "$renewed" "$(on west 'sed -n "s/^private_id=//p" /var/lib/yubikey-anycast/key')"
check "rtr1: West advertises again, first" "west,east1,east2 west,east1,east2" \
    "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
check "rtr2 too" "west west" "$(until_eq 30 "west west" routes rtr2)"
check "west: BGP and BFD with both routers" "BGP 4, BFD 4" "$(until_eq 30 "BGP 4, BFD 4" sessions west)"
check_match "west's check logs in over RADIUS and TACACS+" '^ACCEPT in [0-9]+ ms; TACACS\+ PASS' \
    "$(on west '/opt/radiator-yubikey/yubikey-anycast.sh status | sed -n "s/^last check: //p"')"
check "with the database's counter: none of its OTPs refused as used" 0 \
    "$(on west 'journalctl -u yubikey-anycast -o cat | grep -c "moved ahead"')"
otp "${ALICE[@]}"
check "alice logs in, through West" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
check "west: a backup, made by setup.sh" "yubikey-db.cms.0" "$(on west 'ls /var/backups | grep -m1 yubikey-db')"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done
out=$(on west '/root/turnkey/setup.sh'); rc=$?
check "west: setup.sh again: nothing changes" "0 west is set up.|" \
    "$rc $(tail -1 <<<"$out")|$(grep -E '^  \.\.    (installed|updated|removed|etcd)' <<<"$out")"

echo
echo "== East1 rebuilt: the first server, lost while the primary"
docker rm -f yk-tk-east1 >/dev/null
check "Patroni: East2 takes over" "east2=leader west=quorum" \
    "$(until_eq 90 "east2=leader west=quorum" members east2)"
check "rtr1: West and East2 advertise" "west,east2 west,east2" "$(until_eq 60 "west,east2 west,east2" routes rtr1)"
otp "${ALICE[@]}"
check "logins go on" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
server east1 && booted east1 && lab_route east1 || exit 1
on east1 "cp -a /lab/out/east1 /root/turnkey && chmod 700 /root/turnkey" || exit 1
out=$(on east1 '/root/turnkey/setup.sh'); rc=$?
check "east1: setup.sh on the new server" "0 east1 is set up." "$rc $(tail -1 <<<"$out")"
[[ $rc == 0 ]] || printf '%s\n' "$out"
check_match "etcd: joined again" "  ok    etcd: joined the cluster; 3 members healthy" "$out"
check_match "Patroni: it copies the cluster that runs" \
    "  \.\.    the cluster exists, with east2 as its primary: this server copies it, as a standby" "$out"
check_match "the database: left as it is" \
    "  \.\.    this server's PostgreSQL isn't the primary now: the database was made before; left as it is" "$out"
check "Patroni: East1 a standby" "east1=quorum east2=leader west=quorum" \
    "$(until_eq 60 "east1=quorum east2=leader west=quorum" members east2)"
check "its check's key: the folder's, never renewed" \
    "$(on east1 'sed -n "s/^private_id=//p" /root/turnkey/files/var/lib/yubikey-anycast/key')" \
    "$(on east1 'sed -n "s/^private_id=//p" /var/lib/yubikey-anycast/key')"
check "rtr1: all three advertise" "west,east1,east2 west,east1,east2" \
    "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
check "its counter: the database's" \
    "$(on east1 "runuser -u postgres -- psql -X -At -d yubikey -c \"SELECT counter FROM yubikeys WHERE username = 'anycast-east1'\"")" \
    "$(on east1 'cat /var/lib/yubikey-anycast/counter')"
check "east1's check: none of its OTPs refused as used" 0 \
    "$(on east1 'journalctl -u yubikey-anycast -o cat | grep -c "moved ahead"')"
check_status "east1: --status: the primary isn't east1" east1 \
    '^1 east1: WARNING - Patroni: the primary is east2, not east1 \(patronictl switchover --candidate east1\) \(east1 Quorum Standby, lag [0-9]+ MB; east2 Leader; west Quorum Standby, lag [0-9]+ MB\)$'
on east1 'patronictl -c /etc/patroni/18-main.yml switchover --candidate east1 --force >/dev/null 2>&1'
check "moved back, as the guide says" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
otp "${ALICE[@]}"
check "alice logs in" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done

echo
echo "== East2 started over in place: --reset on it alone, then setup.sh"
out=$(on east2 '/root/turnkey/setup.sh --reset east2'); rc=$?
check "east2: setup.sh --reset" "0 gone" "$rc $(on east2 '[[ -e /var/lib/etcd/default || -e /var/lib/postgresql/18/main ]] && echo there || echo gone')"
[[ $rc == 0 ]] || printf '%s\n' "$out"
since=$(on east2 'date +%s')
out=$(on east2 '/root/turnkey/setup.sh'); rc=$?
check "east2: setup.sh" "0 east2 is set up." "$rc $(tail -1 <<<"$out")"
[[ $rc == 0 ]] || printf '%s\n' "$out"
check_match "etcd: joined again" "  ok    etcd: joined the cluster; 3 members healthy" "$out"
check "Patroni: East2 copied the database" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
check "rtr1: all three advertise" "west,east1,east2 west,east1,east2" \
    "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
check "east2's check: none of its OTPs refused as used" 0 \
    "$(on east2 "journalctl -u yubikey-anycast --since @$since -o cat | grep -c 'moved ahead'")"
check "its backups stay" "yubikey-db.cms.0" "$(on east2 'ls /var/backups | grep -m1 yubikey-db')"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done

echo
echo "== Two servers down: setup.sh can't add one back"
# East2's etcd stopped, and West started over: East1's etcd alone has no
# quorum, so West's member can't be removed and added again. (East1's peer
# port, which needs none, says the cluster has it from before.)
on east2 'systemctl stop etcd'
on west '/root/turnkey/setup.sh --reset west >/dev/null'
out=$(on west 'TURNKEY_WAIT=120 /root/turnkey/setup.sh 2>&1'); rc=$?
check "west: setup.sh stops" 1 "$rc"
check "at etcd, saying why" \
    'setup.sh: error: etcd: the cluster has this server'"'"'s member from before, and fewer than two servers run etcd, which adding it again needs. Start etcd on the other two (see "Rebuild a turn-key server" in the guide)' \
    "$(tail -1 <<<"$out")"
check "before West's etcd starts" gone "$(on west '[[ -e /var/lib/etcd/default ]] && echo there || echo gone')"
on east2 'systemctl start etcd'
out=$(on west '/root/turnkey/setup.sh'); rc=$?
check "with etcd on east2 again, west joins" "0 west is set up." "$rc $(tail -1 <<<"$out")"
[[ $rc == 0 ]] || printf '%s\n' "$out"
check_match "etcd: West's member removed, added again, and joined" \
    "  \.\.    etcd: removed this server's member from before .*  ok    etcd: joined the cluster; 3 members healthy" "$out"
# (Without quorum, Patroni demoted East1: either East may lead now.)
east1_primary
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done

echo
echo "== All three servers' etcd down: West, started over, joins when the others start"
# With no etcd answering, West's starts as in a new cluster, as the member
# it was at first, which the cluster removed when it added West's again
# (above): once East1 and East2 run, they refuse it, and setup.sh adds
# West's member again.
on west '/root/turnkey/setup.sh --reset west >/dev/null'
on east1 'systemctl stop etcd'
on east2 'systemctl stop etcd'
docker exec -d yk-tk-west bash -c 'rm -f /root/setup.rc; /root/turnkey/setup.sh >/root/setup.out 2>&1; echo $? >/root/setup.rc'
check "west: its etcd waits, as in a new cluster" yes \
    "$(until_eq 180 yes on west '[[ -d /var/lib/etcd/default/member/wal ]] && echo yes')"
on east1 'systemctl start --no-block etcd'
on east2 'systemctl start --no-block etcd'
rc=$(until_match 900 '^[0-9]+$' on west 'cat /root/setup.rc')
out=$(on west 'cat /root/setup.out')
check "west: setup.sh, once East1 and East2 run etcd" "0 west is set up." "$rc $(tail -1 <<<"$out")"
[[ $rc == 0 ]] || printf '%s\n' "$out"
check_match "etcd: refused, as the member it was at first" \
    "  \.\.    etcd: the others refused this server's etcd, started as in a new cluster: they have its member under another ID" "$out"
check_match "removed, added again, and joined" \
    "  \.\.    etcd: removed this server's member from before .*  ok    etcd: joined the cluster; 3 members healthy" "$out"
check "/etc/default/etcd: the folder's again" "" \
    "$(on west 'cmp /root/turnkey/files/etc/default/etcd /etc/default/etcd')"
east1_primary
check "rtr1: all three advertise" "west,east1,east2 west,east1,east2" \
    "$(until_eq 90 "west,east1,east2 west,east1,east2" routes rtr1)"
otp "${ALICE[@]}"
check "alice logs in" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done

echo
echo "== Two servers lost: East1 and East2; West alone, then the two set up again"
out=$(on west '/root/turnkey/setup.sh --alone --yes 2>&1'); rc=$?
check_match "west: --alone while the others run: refused" \
    '^1 setup\.sh: error: --alone: the others answer \(TCP( 172\.31\.99\.1[12]:[0-9]+)+\): it is only for when both are lost for good$' \
    "$rc $(tail -1 <<<"$out")"
docker rm -f yk-tk-east1 yk-tk-east2 >/dev/null
check "west: partition mode, by itself" "partition mode" \
    "$(until_eq 90 "partition mode" on west '/opt/radiator-yubikey/yubikey-partition.sh status | head -1 | cut -d" " -f1,2')"
# (Partition mode restarted Radiator, with the copy. Checks begun before
# failed, and may have withdrawn West: one that passed since, advertised.)
check "west: its check passes, with the copy" up "$(until_eq 90 up on west 's=/run/yubikey-anycast/status
    r=$(systemctl show -P ActiveEnterTimestamp --timestamp=unix radiator); r=${r#@}
    /opt/radiator-yubikey/yubikey-partition.sh status | grep -q "^Radiator uses: yubikey-partition.conf" \
        && [[ $(sed -n "s/^state=//p" $s) == advertised && $(sed -n "s/^last=//p" $s) == ACCEPT* ]] \
        && (( $(sed -n "s/^last_at=//p" $s) > r + 1 )) && echo up')"
check "rtr1: West alone" "west west" "$(until_eq 90 "west west" routes rtr1)"
otp "${ALICE[@]}"
USED=$OTP
check "alice logs in, through West, from its copy" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$USED")"
out=$(on west '/root/turnkey/setup.sh --alone </dev/null 2>&1'); rc=$?
check "west: --alone asks, on a terminal" "1 setup.sh: error: --alone: answer on a terminal, or add --yes" "$rc $(tail -1 <<<"$out")"
# On a terminal (script's): "no", then "yes".
alone() { docker exec -i yk-tk-west script -qec '/root/turnkey/setup.sh --alone' /dev/null <<<"$1" | tr -d '\r'; }
out=$(alone no); rc=$?
check "west: answered no: nothing changed" "1 Make west the cluster alone? Type yes: setup.sh: error: --alone: nothing changed" \
    "$rc $(tail -1 <<<"$out")"
alone_done="  ok    west is the cluster alone. Now set up the other two again: new servers with the same names and addresses, their folders, and setup.sh on both (see \"Two servers lost\" in the guide)."
t=$SECONDS
out=$(alone yes); rc=$?
check "west: answered yes" "0 $alone_done" "$rc $(tail -1 <<<"$out")"
[[ $rc == 0 ]] || printf '%s\n' "$out"
echo "(it took $((SECONDS - t)) s)"
# (On the terminal, the answer shows before the question, and the next
# line after it.)
check_match "its steps" $'== alone: west\n  ok    the other two answer on none of etcd\'s, PostgreSQL\'s and Patroni\'s ports\n.*Make west the cluster alone\\? Type yes: (  \\.\\.    [^\n]*\n)*  ok    etcd: a cluster of one, west\n(  \\.\\.    [^\n]*\n)*  ok    Patroni: west\'s PostgreSQL is the primary\n  \\.\\.    partition mode stays on until one of the other two answers again; [^\n]*' "$out"
check "etcd: West its only member" "west" \
    "$(on west 'etcdctl --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt --key /etc/etcd/tls/server.key \
                --endpoints https://172.31.99.13:2379 member list' | awk -F', ' '{print $3}' | paste -sd' ')"
check "/etc/default/etcd: the folder's" "" "$(on west 'cmp /root/turnkey/files/etc/default/etcd /etc/default/etcd')"
check "Patroni: West the primary" "west=leader" "$(until_eq 30 "west=leader" members west)"
out=$(on west '/root/turnkey/setup.sh --alone --yes 2>&1'); rc=$?
check "west: --alone --yes again: nothing to do" "0 $alone_done" "$rc $(tail -1 <<<"$out")"
check_status "west: --status, alone" west '^[12] west: (WARNING|CRITICAL) - '
otp "${ALICE[@]}"
check "alice logs in, through West" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
for n in east1 east2; do
    server "$n" && booted "$n" && lab_route "$n" || exit 1
    on "$n" "cp -a /lab/out/$n /root/turnkey && chmod 700 /root/turnkey" || exit 1
done
t=$SECONDS
for n in east1 east2; do
    on "$n" '/root/turnkey/setup.sh' >"$work/$n.log" 2>&1 &
    echo $! >"$work/$n.pid"
done
for n in east1 east2; do
    wait "$(cat "$work/$n.pid")"; rc=$?
    check "$n: setup.sh on the new server, with West alone" "0 $n is set up." "$rc $(tail -1 "$work/$n.log")"
    if [[ $rc != 0 ]]; then
        echo "--- $n's setup.sh:"; cat "$work/$n.log"
        for s in west east1 east2; do
            echo "--- $s's etcd: its warnings"
            on "$s" "journalctl -u etcd --since '-40 min' -o cat | grep -E '\"level\":\"(warn|error)\"' | tail -30 | cut -c1-300"
        done
    fi
    check_match "$n: etcd: added as a learner, promoted, and joined" \
        $'  \\.\\.    etcd: added this server\'s member \\([0-9a-f]+\\), as a learner until it has caught up\n.*  \\.\\.    etcd: promoted this server\'s member, which has caught up\n(  \\.\\.    [^\n]*\n)*  ok    etcd: joined the cluster; 3 members healthy' \
        "$(cat "$work/$n.log")"
done
echo "(the two setup.sh took $((SECONDS - t)) s)"
check_match "east1: it copies West's cluster" \
    "  \.\.    the cluster exists, with west as its primary: this server copies it, as a standby" "$(cat "$work/east1.log")"
check "Patroni: West the primary, the Easts its standbys" "east1=quorum east2=quorum west=leader" \
    "$(until_eq 60 "east1=quorum east2=quorum west=leader" members west)"
check "west: partition mode left" "normal mode" \
    "$(until_eq 60 "normal mode" on west '/opt/radiator-yubikey/yubikey-partition.sh status | head -1 | cut -d" " -f1,2')"
check "alice's OTP used on West alone, again: refused" "REJECT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$USED")"
check "rtr1: all three advertise" "west,east1,east2 west,east1,east2" \
    "$(until_eq 60 "west,east1,east2 west,east1,east2" routes rtr1)"
on east1 'patronictl -c /etc/patroni/18-main.yml switchover --candidate east1 --force >/dev/null 2>&1'
check "the primary moved back to East1" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
otp "${ALICE[@]}"
check "alice logs in" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done

echo
echo "== Start over: --reset on all three, then setup.sh again"
# (East1's backups now: the one its setup.sh made when it was rebuilt, and
# perhaps one from the daily timer, at about 03:00.)
backups=$(on east1 'cd /var/backups && ls yubikey-db.cms.* | paste -sd" "')
for n in "${SITES[@]}"; do
    out=$(on "$n" "/root/turnkey/setup.sh --reset $n"); rc=$?
    check "$n: setup.sh --reset" "0 gone" "$rc $(on "$n" '[[ -e /var/lib/etcd/default || -e /var/lib/postgresql/18/main ]] && echo there || echo gone')"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
done
check "--reset needs the server's name" 1 "$(on west '/root/turnkey/setup.sh --reset east1 >/dev/null 2>&1; echo $?')"
check "rtr1: none advertises" "- -" "$(until_eq 10 "- -" routes rtr1)"
for n in "${SITES[@]}"; do
    on "$n" '/root/turnkey/setup.sh' >"$work/$n.log" 2>&1 &
    echo $! >"$work/$n.pid"
done
for n in "${SITES[@]}"; do
    wait "$(cat "$work/$n.pid")"; rc=$?
    check "$n: setup.sh after --reset" "0 $n is set up." "$rc $(tail -1 "$work/$n.log")"
    if [[ $rc != 0 ]]; then echo "--- $n's setup.sh:"; cat "$work/$n.log"; fi
done
check "Patroni: a new cluster" "east1=leader east2=quorum west=quorum" "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
check "rtr1: all three advertise" "west,east1,east2 west,east1,east2" "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
otp "${ALICE[@]}"
check "the database is new: alice's YubiKey isn't in it" "REJECT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"

# As after losing the whole cluster: the last backup, restored into the new
# one. (The backups stayed; setup.sh made no new one, as one was there.)
check "east1: the backups stay after --reset" "$backups" \
    "$(on east1 'cd /var/backups && ls yubikey-db.cms.* | paste -sd" "')"
fetch east1 /var/backups/yubikey-db.cms.0 /root/last.cms
on nas 'bash /repo/yubikey-backup.sh decrypt --key /lab/backup.key --passin pass:lab-only /root/last.cms /root/last.dump >/dev/null' \
    || exit 1
put /root/last.dump east1 /root/last.dump
out=$(on east1 '/opt/radiator-yubikey/yubikey-backup.sh restore --yes /root/last.dump 2>&1'); rc=$?
check "east1: the last backup, restored into the new cluster" 0 "$rc"
[[ $rc == 0 ]] || printf '%s\n' "$out"
check_match "the new cluster's anycast keys stay" 'and the keys of 3 anycast check\(s\)\.$' "$(tail -1 <<<"$out")"
otp "${ALICE[@]}"
check "alice logs in again" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
check "the groups are back: svc.backup over TACACS+" PASS "$(tac "$ANY4" "$CORE_KEY" "$NAS4" authen svc.backup backup-password-1234)"
sleep 10
check "rtr1: all three still advertise" "west,east1,east2 west,east1,east2" \
    "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done

echo
echo "== West moves: new addresses, the same name"
# Planned: West, a standby, started over and gone; then site.toml, the
# routers, the two that stay, and West at its new addresses.
on west '/root/turnkey/setup.sh --reset west >/dev/null' || exit 1
docker rm -f yk-tk-west >/dev/null
check "rtr1: West gone" "east1,east2 east1,east2" "$(until_eq 60 "east1,east2 east1,east2" routes rtr1)"
old4=${IP[west]} old6=${IP6[west]}
IP[west]=172.31.99.14 IP6[west]=fd53:99::14
lab "sed -i 's/^ipv4 = \"$old4\"\$/ipv4 = \"${IP[west]}\"/; s/^ipv6 = \"$old6\"\$/ipv6 = \"${IP6[west]}\"/' /lab/site.toml" || exit 1
out=$(gen '-p /lab/pkgs site.toml')
check_match "the generator: West's new certificate" \
    'west has new addresses, and so a new certificate \(a server replaced: see the guide.s "Replace a turn-key server"\)' "$out"
# The routers' admin, from routers.md.
router_conf rtr1 east1 east2 west | docker exec -i yk-tk-rtr1 bash -c 'cat >/etc/frr/frr.conf && systemctl restart frr' || exit 1
router_conf rtr2 west | docker exec -i yk-tk-rtr2 bash -c 'cat >/etc/frr/frr.conf && systemctl restart frr' || exit 1
check "rtr1: East1 and East2 again" "east1,east2 east1,east2" "$(until_eq 60 "east1,east2 east1,east2" routes rtr1)"
# The new server, before the two that stay know it: their firewall drops
# its connections.
names=(--add-host "east1.$DOMAIN:${IP[east1]}" --add-host "east2.$DOMAIN:${IP[east2]}" --add-host "west.$DOMAIN:${IP[west]}")
server west && booted west && lab_route west || exit 1
on west "cp -a /lab/out/west /root/turnkey && chmod 700 /root/turnkey" || exit 1
check "west: --check, before the two that stay have run setup.sh: no answer from them" \
    "  WARN  no answer from ${IP[east1]} on TCP 2380 within 3 s: the servers must reach each other on TCP 2379, 2380, 5432 and 8008|  WARN  no answer from ${IP[east2]} on TCP 2380 within 3 s: the servers must reach each other on TCP 2379, 2380, 5432 and 8008" \
    "$(on west '/root/turnkey/setup.sh --check' | grep 'no answer from' | paste -sd'|')"
since=$(on east1 'systemctl show -P ActiveEnterTimestamp --timestamp=unix etcd')
for n in east1 east2; do
    on "$n" "cp -a /lab/out/$n/. /root/turnkey/" || exit 1
    out=$(on "$n" '/root/turnkey/setup.sh'); rc=$?
    check "$n: setup.sh with West's new addresses" "0 $n is set up." "$rc $(tail -1 <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
    check_match "$n: etcd, without West" '  ok    etcd: 2 of 3 members healthy \(not west\), with quorum' "$out"
done
check "east1: etcd not restarted (only ETCD_INITIAL_CLUSTER changed)" "$since" \
    "$(on east1 'systemctl show -P ActiveEnterTimestamp --timestamp=unix etcd')"
check "east1: /etc/hosts has West's new address" "${IP[west]} west.$DOMAIN west" "$(on east1 "getent hosts west.$DOMAIN" | tr -s ' ')"
check "east1: PostgreSQL lets it replicate" 1 \
    "$(on east1 "runuser -u postgres -- psql -X -At -c \"SELECT count(*) FROM pg_hba_file_rules WHERE 'replication' = ANY(database) AND address = '${IP[west]}'\"")"
out=$(on west '/root/turnkey/setup.sh'); rc=$?
check "west: setup.sh at its new addresses" "0 west is set up." "$rc $(tail -1 <<<"$out")"
[[ $rc == 0 ]] || printf '%s\n' "$out"
check_match "etcd: its member at the old address removed, the new one added" \
    $'== etcd\n.*  \\.\\.    etcd: removed the member of west \\(https://172\\.31\\.99\\.13:2380\\), which isn\'t one of the three servers now\n  \\.\\.    etcd: added this server\'s member \\([0-9a-f]+\\), as a learner until it has caught up\n.*  ok    etcd: joined the cluster; 3 members healthy' "$out"
check "etcd: West's member, at its new address" "https://${IP[west]}:2380" \
    "$(on east1 'etcdctl --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt --key /etc/etcd/tls/server.key \
                --endpoints https://172.31.99.11:2379 member list' | awk -F', ' '$3 == "west" {print $4}')"
check "Patroni: West copied the database" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
check "rtr1: West advertises again, first" "west,east1,east2 west,east1,east2" \
    "$(until_eq 60 "west,east1,east2 west,east1,east2" routes rtr1)"
check "rtr2 too" "west west" "$(until_eq 60 "west west" routes rtr2)"
check "west: BGP and BFD with both routers" "BGP 4, BFD 4" "$(until_eq 30 "BGP 4, BFD 4" sessions west)"
otp "${ALICE[@]}"
check "alice logs in, through West" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done

echo
echo "== East1 replaced: a new name and addresses, after it was lost"
docker rm -f yk-tk-east1 >/dev/null
check "Patroni: East2 takes over" "east2=leader west=quorum" "$(until_eq 90 "east2=leader west=quorum" members east2)"
check "rtr1: West and East2 advertise" "west,east2 west,east2" "$(until_eq 60 "west,east2 west,east2" routes rtr1)"
otp "${ALICE[@]}"
check "logins go on" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
lab "sed -i 's/^name = \"east1\"\$/name = \"east1b\"/; s/^fqdn = \"east1\.$DOMAIN\"\$/fqdn = \"east1b.$DOMAIN\"/;
            s/^ipv4 = \"${IP[east1]}\"\$/ipv4 = \"${IP[east1b]}\"/; s/^ipv6 = \"${IP6[east1]}\"\$/ipv6 = \"${IP6[east1b]}\"/' /lab/site.toml" \
    || exit 1
out=$(gen '-p /lab/pkgs site.toml')
check_match "the generator: East1's keys and certificate gone" \
    'the anycast keys and certificates of servers no longer in site\.toml are gone: east1 \(a server replaced' "$out"
SITES=(east1b east2 west)
router_conf rtr1 east1b east2 west | docker exec -i yk-tk-rtr1 bash -c 'cat >/etc/frr/frr.conf && systemctl restart frr' || exit 1
check "rtr1: West and East2 again" "west,east2 west,east2" "$(until_eq 60 "west,east2 west,east2" routes rtr1)"
for n in east2 west; do
    on "$n" "cp -a /lab/out/$n/. /root/turnkey/" || exit 1
    out=$(on "$n" '/root/turnkey/setup.sh'); rc=$?
    check "$n: setup.sh with east1b instead of East1" "0 $n is set up." "$rc $(tail -1 <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
    if [[ $n == east2 ]]; then
        check_match "east2, the primary: East1's anycast check out of the database, east1b's in" \
            $'  \\.\\.    removed the anycast check of east1, which isn\'t one of the servers now\n  \\.\\.    removed the service account svc\\.anycast-east1\n  ok    the anycast checks of east1b east2 west: keys, service accounts, group anycast-check' "$out"
    fi
done
names=(--add-host "east1b.$DOMAIN:${IP[east1b]}" --add-host "east2.$DOMAIN:${IP[east2]}" --add-host "west.$DOMAIN:${IP[west]}")
server east1b && booted east1b && lab_route east1b || exit 1
on east1b "cp -a /lab/out/east1b /root/turnkey && chmod 700 /root/turnkey" || exit 1
out=$(on east1b '/root/turnkey/setup.sh'); rc=$?
check "east1b: setup.sh, the new first server" "0 east1b is set up." "$rc $(tail -1 <<<"$out")"
[[ $rc == 0 ]] || printf '%s\n' "$out"
check_match "etcd: East1's member removed, east1b's added" \
    $'  \\.\\.    etcd: removed the member of east1 \\(https://172\\.31\\.99\\.11:2380\\), which isn\'t one of the three servers now\n  \\.\\.    etcd: added this server\'s member \\([0-9a-f]+\\), as a learner until it has caught up\n.*  ok    etcd: joined the cluster; 3 members healthy' "$out"
check_match "Patroni: it copies East2's cluster" \
    "  \.\.    the cluster exists, with east2 as its primary: this server copies it, as a standby" "$out"
check_match "the database: its anycast check, from East2" "  ok    the database has this server's anycast check" "$out"
check "the database: the anycast checks of the three" "anycast-east1b anycast-east2 anycast-west|svc.anycast-east1b svc.anycast-east2 svc.anycast-west" \
    "$(on east2 "runuser -u postgres -- psql -X -At -d yubikey -c \"SELECT (SELECT string_agg(DISTINCT username, ' ') FROM yubikeys WHERE username LIKE 'anycast-%')
                 || '|' || (SELECT string_agg(username, ' ' ORDER BY username) FROM service_accounts WHERE username LIKE 'svc.anycast-%')\"")"
check "Patroni: east1b a standby" "east1b=quorum east2=leader west=quorum" \
    "$(until_eq 60 "east1b=quorum east2=leader west=quorum" members east2)"
check_status "east1b: --status: the primary isn't east1b" east1b '^1 east1b: WARNING - Patroni: the primary is east2, not east1b '
on east1b 'patronictl -c /etc/patroni/18-main.yml switchover --candidate east1b --force >/dev/null 2>&1'
check "the primary moved to east1b" "east1b=leader east2=quorum west=quorum" \
    "$(until_eq 60 "east1b=leader east2=quorum west=quorum" members east1b)"
check "rtr1: all three advertise" "west,east1b,east2 west,east1b,east2" \
    "$(until_eq 60 "west,east1b,east2 west,east1b,east2" routes rtr1)"
check_match "east1b's check logs in over RADIUS and TACACS+" '^ACCEPT in [0-9]+ ms; TACACS\+ PASS' \
    "$(on east1b '/opt/radiator-yubikey/yubikey-anycast.sh status | sed -n "s/^last check: //p"')"
otp "${ALICE[@]}"
check "alice logs in" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done

echo
echo "== New passwords and keys: --rotate"
prim=$(leader_now)
others=()
for n in "${SITES[@]}"; do
    [[ $n == "$prim" ]] || others+=("$n")
    # (The admin's machine, by the servers' names, as DNS would.)
    on nas "grep -q ' $n\.$DOMAIN\$' /etc/hosts || echo '${IP[$n]} $n.$DOMAIN' >>/etc/hosts" || exit 1
done
# A TACACS+ login through the anycast address every second, from now on.
probe_start
out=$(gen '--rotate radiator,patroni,admins,localhost -p /lab/pkgs site.toml')
check_match "the generator: new passwords, and the order to run setup.sh in" \
    'new database passwords \(radiator, replicator, rewinder and opsadmin\): copy the folders, and run setup\.sh on the primary first' "$out"
for n in "${SITES[@]}"; do on "$n" "cp -a /lab/out/$n/. /root/turnkey/" || exit 1; done
# West, a standby, first: it waits until the primary has the new passwords.
on west '/root/turnkey/setup.sh' >"$work/west.log" 2>&1 &
west_pid=$!
check "west, a standby, first: it waits for the primary" 1 \
    "$(until_eq 120 1 grep -c "waiting for the primary, $prim, to have the new passwords of replicator and rewinder (run setup.sh there first)" "$work/west.log")"
check "Patroni: West streams all along" "quorum" \
    "$(members west | tr ' ' '\n' | sed -n 's/^west=//p')"
out=$(on "$prim" '/root/turnkey/setup.sh'); rc=$?
check "$prim, the primary: setup.sh" "0 $prim is set up." "$rc $(tail -1 <<<"$out")"
[[ $rc == 0 ]] || printf '%s\n' "$out"
check_match "$prim: it gives the roles their new passwords" \
    $'  \\.\\.    set radiator\'s new password\n  \\.\\.    set replicator\'s new password\n  \\.\\.    set rewinder\'s new password\n  \\.\\.    set opsadmin\'s new password\n' "$out"
wait "$west_pid"; rc=$?
check "west: then it goes on" "0 west is set up." "$rc $(tail -1 "$work/west.log")"
[[ $rc == 0 ]] || cat "$work/west.log"
for n in "${others[@]}"; do
    [[ $n == west ]] && continue
    out=$(on "$n" '/root/turnkey/setup.sh'); rc=$?
    check "$n: setup.sh, after the primary: no wait" "0 $n is set up. 0" \
        "$rc $(tail -1 <<<"$out") $(grep -c 'waiting for the primary' <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
done
want="$prim=leader"
for n in "${others[@]}"; do want+=" $n=quorum"; done
want=$(tr ' ' '\n' <<<"$want" | sort | paste -sd' ')
check "Patroni: the two stream" "$want" "$(until_eq 60 "$want" members west)"
check "replicator has its new SCRAM verifier" "$(secret 'cluster|replication_scram' | tr -d '\n' | md5sum | cut -d' ' -f1)" \
    "$(on "$prim" "runuser -u postgres -- psql -X -At -c \"SELECT md5(rolpassword) FROM pg_authid WHERE rolname = 'replicator'\"")"
# The standbys' replication connections cut on the primary: they connect
# again, with the new password.
check "the primary's WAL senders stopped" "t t" \
    "$(on "$prim" "runuser -u postgres -- psql -X -At -c 'SELECT pg_terminate_backend(pid) FROM pg_stat_replication'" | paste -sd' ')"
sleep 2
check "the standbys stream again, with the new replication password" 2 \
    "$(until_eq 60 2 on "$prim" "runuser -u postgres -- psql -X -At -c \"SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'\"")"
check "Patroni: both standbys again" "$want" "$(until_eq 60 "$want" members west)"
# Patroni's REST API: a switchover, asked on a standby, and back.
on west "patronictl -c /etc/patroni/18-main.yml switchover --candidate ${others[0]} --force >/dev/null 2>&1"
check "a switchover asked on West, with the new REST API password" "${others[0]}" "$(until_eq 60 "${others[0]}" leader_now)"
want2="${others[0]}=leader"
for n in "$prim" "${others[@]:1}"; do want2+=" $n=quorum"; done
want2=$(tr ' ' '\n' <<<"$want2" | sort | paste -sd' ')
check "Patroni: $prim a standby" "$want2" "$(until_eq 90 "$want2" members west)"
on "$prim" "patronictl -c /etc/patroni/18-main.yml switchover --candidate $prim --force >/dev/null 2>&1"
check "and back" "$want" "$(until_eq 90 "$want" members west)"
# The admin: the old ~/.pgpass is refused, the new one works.
admin_login() { if admin 'list' >/dev/null 2>&1 </dev/null; then echo works; else echo refused; fi; }
check "the admin's old password: refused" refused "$(admin_login)"
on nas 'install -m 0600 /lab/out/admin/pgpass /root/.pgpass' || exit 1
check "the new one, from admin/pgpass" works "$(admin_login)"
# localhost's new secret and key: each check logs in, all three advertise.
for n in "${SITES[@]}"; do
    check_match "$n's check logs in, with localhost's new secret and key" '^ACCEPT in [0-9]+ ms; TACACS\+ PASS' \
        "$(until_match 60 '^ACCEPT in [0-9]+ ms; TACACS\+ PASS' on "$n" '/opt/radiator-yubikey/yubikey-anycast.sh status | sed -n "s/^last check: //p"')"
done
check_match "rtr1: all three advertise" '^([a-z0-9]+,){2}[a-z0-9]+ ([a-z0-9]+,){2}[a-z0-9]+$' \
    "$(until_match 60 '^([a-z0-9]+,){2}[a-z0-9]+ ([a-z0-9]+,){2}[a-z0-9]+$' routes rtr1)"
probe_stop "logins all along" 15

# An admin's own new password stays, until secrets.toml has a new one.
on nas ". /lab/out/admin/pg.env && psql -X -q 'dbname=yubikey target_session_attrs=read-write' \
             -c \"ALTER ROLE opsadmin PASSWORD 'MyOwnPassword-2026'\" && sed -i 's/:opsadmin:.*/:opsadmin:MyOwnPassword-2026/' /root/.pgpass" \
    || exit 1
out=$(on "$prim" '/root/turnkey/setup.sh'); rc=$?
check "$prim: setup.sh again" "0 $prim is set up." "$rc $(tail -1 <<<"$out")"
check "the admin's own password stays" works "$(admin_login)"
# A device's new secret and key, and the admin's: the old key is refused
# once setup.sh has run on the three; the new one works.
out=$(gen '--rotate device:172.31.100.20,admin:opsadmin -p /lab/pkgs site.toml')
check_match "the generator: new secrets for the device" \
    'new RADIUS secrets and TACACS\+ keys for 172\.31\.100\.20: once setup\.sh has run on the three servers, put them on the devices' "$out"
for n in "$prim" "${others[@]}"; do
    on "$n" "cp -a /lab/out/$n/. /root/turnkey/" || exit 1
    out=$(on "$n" '/root/turnkey/setup.sh'); rc=$?
    check "$n: setup.sh with the device's new secrets" "0 $n is set up." "$rc $(tail -1 <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
done
check_match "the device's old key: refused" '^(FAIL|ERROR)' "$(tac "$ANY4" "$LAB2_KEY" 172.31.100.20 authen svc.backup backup-password-1234)"
LAB2_KEY=$(secret 'device|172.31.100.20|tacacs_key')
check "the new one" PASS "$(tac "$ANY4" "$LAB2_KEY" 172.31.100.20 authen svc.backup backup-password-1234)"
check "the admin's own password: replaced" refused "$(admin_login)"
on nas 'install -m 0600 /lab/out/admin/pgpass /root/.pgpass' || exit 1
check "the new one from admin/pgpass" works "$(admin_login)"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done

rm -rf -- "$work"
echo
echo "Turnkey: $pass passed, $fail failed"
[[ $fail == 0 ]]
