#!/usr/bin/env bash
#
# upgrade.sh - Test the upgrades of a turn-key setup, as the guide's
# "Upgrade a turn-key setup" says to do them, with a TACACS+ login at the
# anycast address every second all along: three servers set up with
# radiator-yubikey 1.12.1 (its yubikey-turnkey and package, from the git tag
# v1.12.1), then upgraded to this version (yubikey-turnkey again with the
# new package, setup.sh on the primary first, then on the other two; built
# from the working tree, as 1.12.1.1 while VERSION is still 1.12.1); then
# a newer Radiator (4.30-1 again as 4.30-1+lab1, with a changed sample
# radiator.conf: this server's stays); then Ubuntu's updates one server at
# a time, with needrestart as Ubuntu Server has it (a new PostgreSQL, which
# needrestart restarts Patroni for: the standbys, a switchover, the old
# primary), and the same update on the primary without the switchover, as
# the automatic updates do it: a failover.
#
# Usage: tests/radiator/upgrade.sh IMAGE DIR
#   IMAGE  the test image that run.sh builds
#   DIR    the Radiator packages, as for run.sh
#
# The lab is turnkey.sh's (turnkey-lib.sh). Needs Docker, usable without
# sudo, and network access (apt-get on the servers). KEEP=1 leaves the
# containers running. Exits 0 when every check passes.

# shellcheck disable=SC2016  # the containers' shells expand the commands given to "on"

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$(dirname -- "$here")")
[[ $# -eq 2 && -d $2 ]] || { echo "usage: tests/radiator/upgrade.sh IMAGE DIR" >&2; exit 2; }
image=$1
# shellcheck disable=SC2034  # for turnkey-lib.sh
rads=$(cd -- "$2" && pwd)
# shellcheck source=tests/radiator/turnkey-lib.sh disable=SC1091
. "$here/turnkey-lib.sh"
OLD=1.12.1
git -C "$root" rev-parse -q --verify "v$OLD^{tag}" >/dev/null || { echo "upgrade.sh: no git tag v$OLD" >&2; exit 2; }
lab_start
lab_prepare
work=$(mktemp -d)
# This version, from the working tree, and its package; while its VERSION
# is still the old one's (before a release), as the next one's, OLD.1.
NEW=$(cat "$root/VERSION")
[[ $NEW == "$OLD" ]] && NEW=$OLD.1
tar -C "$root" --exclude=./.git --exclude=./dist -c . \
    | docker run --rm -i -v yk-tk-lab:/lab "$image" bash -c "mkdir -p /lab/new && tar -x -C /lab/new && echo $NEW >/lab/new/VERSION" \
    || exit 1
lab 'mkdir -p /lab/pkgs-up && /lab/new/packaging/build-deb.sh /lab/pkgs-up >/dev/null && cp /radiator/*.deb /lab/pkgs-up/' || exit 1
gen_new() { lab "cd /lab && python3 /lab/new/yubikey-turnkey $1 2>&1"; }

echo "== radiator-yubikey $OLD on three fresh servers"
# Its tree, from the tag, its package, and its folders, from turnkey.sh's
# site.toml.
git -C "$root" archive "v$OLD" | docker run --rm -i -v yk-tk-lab:/lab "$image" bash -c 'mkdir -p /lab/old && tar -x -C /lab/old' \
    || exit 1
lab 'mkdir -p /lab/pkgs-old && /lab/old/packaging/build-deb.sh /lab/pkgs-old >/dev/null && cp /radiator/*.deb /lab/pkgs-old/' || exit 1
site_toml '' | docker run --rm -i -v yk-tk-lab:/lab "$image" bash -c 'cat >/lab/site.toml' || exit 1
out=$(lab 'cd /lab && python3 /lab/old/yubikey-turnkey -p /lab/pkgs-old site.toml 2>&1'); rc=$?
check "yubikey-turnkey $OLD makes the folders" 0 "$rc"
[[ $rc == 0 ]] || { printf '%s\n' "$out"; exit 1; }
CORE_SECRET=$(secret "device|$NAS4|secret") CORE_KEY=$(secret "device|$NAS4|tacacs_key")
lab_machines
for n in "${SITES[@]}"; do on "$n" "cp -a /lab/out/$n /root/turnkey && chmod 700 /root/turnkey" || exit 1; done
for n in "${SITES[@]}"; do
    on "$n" '/root/turnkey/setup.sh' >"$work/$n.log" 2>&1 &
    echo $! >"$work/$n.pid"
done
for n in "${SITES[@]}"; do
    wait "$(cat "$work/$n.pid")"; rc=$?
    check "$n: setup.sh $OLD" "0 $n is set up." "$rc $(tail -1 "$work/$n.log")"
    [[ $rc == 0 ]] || cat "$work/$n.log"
done
check "radiator-yubikey $OLD on the three" "$OLD $OLD $OLD" \
    "$(for n in "${SITES[@]}"; do on "$n" "dpkg-query -W -f '\${Version}' radiator-yubikey"; echo; done | paste -sd' ')"
check "Patroni: East1 the primary" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 60 "east1=leader east2=quorum west=quorum" members west)"
# The admin's YubiKey user and service account, as in turnkey.sh.
on nas 'cp /lab/out/admin/ca.crt /root/.yubikey-ca.crt && install -m 0600 /lab/out/admin/pgpass /root/.pgpass' || exit 1
admin "import - <<'EOF'
alice,vvccccbbcdef,4a6f8e2d1c3b,$K1,s3cr3t,1
EOF
" >/dev/null 2>&1 || exit 1
printf '%s\n' 'backup-password-1234' | admin 'service add svc.backup' >/dev/null 2>&1
for a in 'member add netadmins alice' 'group add backup' 'member add backup svc.backup' 'access set backup core 15'; do
    admin "$a" >/dev/null 2>&1 </dev/null
done
ALICE=(vvccccbbcdef 4a6f8e2d1c3b)
otp "${ALICE[@]}"
check "alice logs in" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
check "svc.backup logs in over TACACS+" PASS "$(tac "$ANY4" "$CORE_KEY" "$NAS4" authen svc.backup backup-password-1234)"
check "rtr1: all three advertise" "west,east1,east2 west,east1,east2" \
    "$(until_eq 60 "west,east1,east2 west,east1,east2" routes rtr1)"

echo
echo "== Upgraded to $NEW: the primary first, then the other two"
probe_start
out=$(gen_new '-p /lab/pkgs-up site.toml'); rc=$?
check "yubikey-turnkey $NEW: the folders again" 0 "$rc"
# Nothing new from 1.12.1. (A release that makes new secrets shows them
# here, and in the guide's sample.)
check "it keeps every secret, and makes none" "" "$(grep '^secrets\.toml' <<<"$out")"
for n in east1 east2 west; do
    on "$n" "cp -a /lab/out/$n/. /root/turnkey/" || exit 1
    out=$(on "$n" '/root/turnkey/setup.sh'); rc=$?
    check "$n: setup.sh $NEW" "0 $n is set up." "$rc $(tail -1 <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
    check_match "$n: radiator-yubikey $NEW, with its install.sh" \
        "  \.\.    installing radiator-yubikey ${NEW//./\\.} with its install\.sh" "$out"
    if [[ $n == east1 ]]; then
        check "east1, the primary: no role's password changed" 0 "$(grep -c "new password" <<<"$out")"
    fi
done
check "radiator-yubikey $NEW on the three" "$NEW $NEW $NEW" \
    "$(for n in "${SITES[@]}"; do on "$n" "dpkg-query -W -f '\${Version}' radiator-yubikey"; echo; done | paste -sd' ')"
check "opsadmin's password: as set before, still noted" t \
    "$(on east1 "runuser -u postgres -- psql -X -At -c \"SELECT shobj_description(oid, 'pg_authid') LIKE 'yubikey-turnkey: password %' FROM pg_roles WHERE rolname = 'opsadmin'\"")"
check "the admin logs in as before" 1 "$(admin 'list alice' 2>/dev/null </dev/null | grep -c vvccccbbcdef)"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done
otp "${ALICE[@]}"
check "alice logs in" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
probe_stop "logins all along" 15

echo
echo "== A newer Radiator, one server at a time"
# Radiator 4.30-1 again, as 4.30-1+lab1, with a line more in its sample
# radiator.conf (a conffile, which this server's replaced).
lab 'set -e; cd /lab; mkdir -p pkgs-new rad; dpkg-deb -R pkgs-up/radiator_4.30-1_all.deb rad
     sed -i "s/^Version: .*/Version: 4.30-1+lab1/" rad/DEBIAN/control
     echo "# 4.30-1+lab1" >>rad/etc/radiator/radiator.conf
     (cd rad && find . -type f ! -path "./DEBIAN/*" -printf "%P\0" | xargs -0 md5sum >DEBIAN/md5sums)
     dpkg-deb -b --root-owner-group rad pkgs-new/radiator_4.30-1+lab1_all.deb >/dev/null
     cp pkgs-up/radiator-radius-utilxs_*.deb pkgs-up/radiator-yubikey_*_all.deb pkgs-up/install.sh pkgs-new/' || exit 1
probe_start
out=$(gen_new '-p /lab/pkgs-new site.toml'); rc=$?
check "yubikey-turnkey: the folders with the new Radiator" 0 "$rc"
for n in east1 east2 west; do
    before=$(since "$n" radiator)
    on "$n" "cp -a /lab/out/$n/. /root/turnkey/" || exit 1
    out=$(on "$n" '/root/turnkey/setup.sh'); rc=$?
    check "$n: setup.sh" "0 $n is set up." "$rc $(tail -1 <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
    check_match "$n: the folder's Radiator replaces the old one" "  \.\.    radiator 4\.30-1: replaced by the folder's 4\.30-1\+lab1" "$out"
    check "$n: Radiator 4.30-1+lab1, restarted" "4.30-1+lab1 restarted" \
        "$(on "$n" "dpkg-query -W -f '\${Version}' radiator") $( (($(since "$n" radiator) > before)) && echo restarted)"
    check "$n: its radiator.conf stays; the package's new one beside it" "same 1" \
        "$(on "$n" 'cmp -s /root/turnkey/files/etc/radiator/radiator.conf /etc/radiator/radiator.conf && echo same; grep -c "4.30-1+lab1" /etc/radiator/radiator.conf.dpkg-dist' | paste -sd' ')"
done
out=$(on west '/root/turnkey/setup.sh'); rc=$?
check "west: setup.sh again: Radiator left as it is" "0 west is set up. 0" "$rc $(tail -1 <<<"$out") $(grep -c 'radiator 4' <<<"$out")"
probe_stop "logins all along" 15

echo
echo "== Ubuntu's updates, one server at a time"
# needrestart, as Ubuntu Server has it. A new PostgreSQL (the same one
# again, which replaces its files as an update would) makes it restart
# Patroni, which restarts PostgreSQL.
for n in "${SITES[@]}"; do
    on "$n" 'DEBIAN_FRONTEND=noninteractive apt-get -q -y install needrestart >/dev/null 2>&1' || exit 1
done
update() { on "$1" "DEBIAN_FRONTEND=noninteractive ${2-} apt-get -q -y install --reinstall postgresql-18 >/dev/null 2>&1"; }
patroni_unit=patroni@18-main
before=$(since west $patroni_unit)
update west NEEDRESTART_MODE=l
check "west: with NEEDRESTART_MODE=l, as setup.sh runs apt-get: Patroni not restarted" same \
    "$( (($(since west $patroni_unit) == before)) && echo same)"
probe_start
for n in west east2; do
    before=$(since "$n" $patroni_unit)
    update "$n"
    check "$n, a standby: needrestart restarts Patroni" restarted "$( (($(since "$n" $patroni_unit) > before)) && echo restarted)"
    check "Patroni: $n streams again" "east1=leader east2=quorum west=quorum" \
        "$(until_eq 90 "east1=leader east2=quorum west=quorum" members west)"
done
switchover east2
check "the primary moved to East2, updated" "east1=quorum east2=leader west=quorum" \
    "$(until_eq 90 "east1=quorum east2=leader west=quorum" members west)"
before=$(since east1 $patroni_unit)
update east1
check "east1, now a standby: needrestart restarts Patroni" restarted "$( (($(since east1 $patroni_unit) > before)) && echo restarted)"
check "Patroni: east1 streams again" "east1=quorum east2=leader west=quorum" \
    "$(until_eq 90 "east1=quorum east2=leader west=quorum" members west)"
switchover east1
check "the primary back on East1" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 90 "east1=leader east2=quorum west=quorum" members west)"
probe_stop "logins all along" 15
# The same update on the primary, without the switchover (as Ubuntu's
# automatic updates do it): needrestart restarts Patroni there, which stops
# PostgreSQL, and another server takes over.
probe_start
update east1
check_match "east1, the primary: needrestart restarts Patroni, and the other two fail over" '^(east2|west)$' \
    "$(until_match 90 '^(east2|west)$' leader_now)"
m=$(until_match 90 '^east1=quorum east2=(leader|quorum) west=(leader|quorum)$' members west)
check_match "Patroni: east1 a standby, streaming" '^east1=quorum east2=(leader|quorum) west=(leader|quorum)$' "$m"
probe_stop "logins: an unplanned failover" 30
switchover east1
check "the primary back on East1" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 90 "east1=leader east2=quorum west=quorum" members west)"
otp "${ALICE[@]}"
check "alice logs in" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done

rm -rf -- "$work"
echo
echo "Upgrade: $pass passed, $fail failed"
[[ $fail == 0 ]]
