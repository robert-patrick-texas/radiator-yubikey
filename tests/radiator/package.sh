#!/usr/bin/env bash
#
# package.sh - Test the radiator-yubikey package and install.sh, in Docker,
# with Radiator installed in each of the ways that install.sh recognizes.
#
# Usage: tests/radiator/package.sh IMAGE DIR
#   IMAGE  the test image that run.sh builds: it builds the package, and runs
#          systemd for the services' test
#   DIR    the Radiator packages, as for run.sh
#
# Each of these starts from a fresh ubuntu:26.04 container, so install.sh
# installs everything with apt-get (this needs network access):
#   none     no Radiator: install.sh stops, or goes on with --yes, and the
#            scripts work without Radiator; a second run changes nothing
#   package  Radiator Software's packages
#   inplace  Radiator's source unpacked in /opt/radiator/radiator, where
#            Radiator's own radiator.service runs it
#   make     Radiator's source installed with 'perl Makefile.PL && make &&
#            make install' (radiusd in /usr/local/bin)
# The source comes from the radiator package, which holds Radiator's source
# distribution. Each case with Radiator ends with a login through it, and the
# same OTP again (rejected).
# Then, in IMAGE running systemd:
#   systemd  units installed by hand (as the guide did before the package),
#            and install.sh's commands to use the package's instead; the
#            package's units: not enabled or started by an install, restarted
#            by an upgrade only while they run, stopped by a removal, and
#            forgotten by a purge
#
# Needs Docker, usable without sudo. KEEP=1 leaves the containers running.
# Exits 0 when every check passes.

# shellcheck disable=SC2016  # the containers' shells expand the commands given to "on"

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$(dirname -- "$here")")
[[ $# -eq 2 && -d $2 ]] || { echo "usage: tests/radiator/package.sh IMAGE DIR" >&2; exit 2; }
image=$1
rads=$(cd -- "$2" && pwd)
pass=0 fail=0
CASES=(none package inplace make systemd)

work=$(mktemp -d)
remove_containers() {
    local c
    for c in "${CASES[@]}"; do docker rm -f "yk-pkg-$c" >/dev/null 2>&1; done
}
if [[ ${KEEP:-0} == 1 ]]; then
    trap 'rm -rf -- "$work"; echo "KEEP=1: the containers are still running"' EXIT
else
    trap 'remove_containers; rm -rf -- "$work"' EXIT
fi
remove_containers

# check LABEL EXPECTED ACTUAL: count and print one result.
check() {
    if [[ $3 == "$2" ]]; then
        pass=$((pass + 1)); printf 'PASS  %s: %s\n' "$1" "$3"
    else
        fail=$((fail + 1)); printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

# start CASE [systemd]: a container for CASE, from ubuntu:26.04, or from
# IMAGE running systemd.
start() {
    local -a mounts=(-v "$root:/repo:ro" -v "$rads:/radiator:ro" -v "$work/inst:/inst:ro")
    if [[ ${2-} == systemd ]]; then
        docker run -d --name "yk-pkg-$1" --hostname "$1" "${mounts[@]}" \
            --cap-add SYS_ADMIN --security-opt apparmor=unconfined --cgroupns private \
            --tmpfs /run --tmpfs /run/lock --stop-signal SIGRTMIN+3 "$image" \
            sh -c 'mount -o remount,rw /sys/fs/cgroup && exec /lib/systemd/systemd' >/dev/null || exit 1
        local s
        for _ in $(seq 120); do
            s=$(docker exec "yk-pkg-$1" systemctl is-system-running 2>/dev/null)
            [[ $s == running || $s == degraded ]] && return 0
            sleep 0.5
        done
        echo "systemd did not finish starting ($s)"; exit 1
    fi
    docker run -d --name "yk-pkg-$1" --hostname "$1" "${mounts[@]}" ubuntu:26.04 sleep infinity >/dev/null || exit 1
}

# on CASE COMMAND...: run a shell command in CASE's container.
on() {
    local c=$1; shift
    docker exec "yk-pkg-$c" bash -c "$*"
}

# step CASE COMMAND [ARGS]: one package-node.sh step in CASE's container.
step() {
    local c=$1; shift
    docker exec "yk-pkg-$c" bash /repo/tests/radiator/package-node.sh "$@"
}

# install CASE [ARGS]: run install.sh in CASE's container, with no terminal;
# its output in $work/CASE.out, and its exit status printed.
install() {
    local c=$1 rc=0; shift
    docker exec "yk-pkg-$c" bash /inst/install.sh "$@" </dev/null >"$work/$c.out" 2>&1 || rc=$?
    echo "$rc"
}

# said CASE PATTERN: "yes" when the last install.sh output of CASE has a line
# that matches the extended regular expression PATTERN.
said() {
    if grep -qE -- "$2" "$work/$1.out"; then echo yes; else echo no; fi
}

# version CASE PACKAGE: the version of PACKAGE installed in CASE's container
# ("none" when it is not installed).
version() {
    local v
    v=$(on "$1" "dpkg-query -W -f='\${db:Status-Status} \${Version}' $2 2>/dev/null")
    if [[ $v == installed\ * ]]; then echo "${v#installed }"; else echo none; fi
}

echo "== The package"
deb=$("$here/build-deb.sh" "$image" "$work/inst") || exit 1
cp -- "$root/install.sh" "$work/inst/"
pkg_version=$(dpkg-deb -f "$deb" Version)
check "the package's version is the scripts'" "$(sed -n 's/^VERSION=//p' "$root/yubikey-db.sh")" "$pkg_version"
check "lintian finds nothing" "" \
    "$(docker run --rm --user "$(id -u):$(id -g)" -v "$work/inst:/inst:ro" "$image" \
        lintian -I --pedantic "/inst/${deb##*/}" 2>&1)"
check "a second build is the same, byte for byte" "$(sha256sum <"$deb")" \
    "$("$here/build-deb.sh" "$image" "$work/again" >/dev/null && sha256sum <"$work/again/${deb##*/}")"
check "every file is in /opt/radiator-yubikey, a systemd unit, or the package's own" "" \
    "$(dpkg-deb -c "$deb" | awk '{print $6}' | grep -v '/$' \
        | grep -vE '^\./(opt/radiator-yubikey/|usr/lib/systemd/system/yubikey-(anycast|partition)\.service$|usr/share/(doc|lintian/overrides)/radiator-yubikey)')"
check "the units run the scripts in /opt/radiator-yubikey" \
    "/opt/radiator-yubikey/yubikey-anycast.sh run|/opt/radiator-yubikey/yubikey-partition.sh run" \
    "$(sed -n 's/^ExecStart=//p' "$root/yubikey-anycast.service" "$root/yubikey-partition.service" | paste -sd'|')"

echo
echo "== No Radiator"
start none
check "install.sh stops (exit 3)" 3 "$(install none)"
check "it says Radiator is not found" yes "$(said none '^Radiator: +not found')"
check "it says how to go on without it" yes "$(said none 'or run it with --yes')"
check "it installed nothing" "none none" "$(version none radiator-yubikey) $(version none sqlite3)"
check "with --yes, it installs (exit 0)" 0 "$(install none --yes)"
check "the package" "$pkg_version" "$(version none radiator-yubikey)"
check "and the packages it installs with apt-get" "" \
    "$(for p in libauth-yubikey-decrypter-perl libcrypt-rijndael-perl libcache-fastmmap-perl \
                libdbd-sqlite3-perl sqlite3 libdbd-pg-perl postgresql-client; do
           [[ $(version none $p) != none ]] || printf '%s ' "$p"; done)"
check "the scripts run from /opt/radiator-yubikey" \
    "yubikey-db.sh $pkg_version|yubikey-db-migrate.sh $pkg_version|yubikey-anycast.sh $pkg_version|yubikey-partition.sh $pkg_version|install.sh $pkg_version" \
    "$(on none 'for s in yubikey-db yubikey-db-migrate yubikey-anycast yubikey-partition install; do
                   /opt/radiator-yubikey/$s.sh -V; done' | paste -sd'|')"
check "they manage a database without Radiator" "2 users" \
    "$(on none 'cd /opt/radiator-yubikey && ./yubikey-db.sh -d /tmp/t.db init >/dev/null 2>&1 &&
                ./yubikey-db.sh -d /tmp/t.db import users.example.csv >/dev/null 2>&1 &&
                ./yubikey-db.sh -d /tmp/t.db list | grep -c "^test\.user"') users"
check "install.sh --check: something is missing (exit 1)" 1 "$(install none --check)"
check "only Radiator" "no" "$(said none '^  missing')"
ino=$(on none 'stat -c %i /opt/radiator-yubikey/yubikey-db.sh')
check "a second run (exit 0)" 0 "$(install none --yes)"
check "leaves the installed package as it is" "$ino" "$(on none 'stat -c %i /opt/radiator-yubikey/yubikey-db.sh')"
check "install.sh in /opt/radiator-yubikey, with no package next to it (exit 0)" 0 \
    "$(on none '/opt/radiator-yubikey/install.sh --yes </dev/null >/tmp/inst.out 2>&1'; echo $?)"
check "installs the other packages only" "yes no" \
    "$(on none 'grep -qx "Package:   radiator-yubikey [0-9.]*, installed" /tmp/inst.out && echo yes || echo no
                grep -q "radiator-yubikey_.*_all.deb" /tmp/inst.out && echo yes || echo no' | paste -sd' ')"

echo
echo "== Radiator Software's packages"
start package
step package radiator-package
check "install.sh (exit 0)" 0 "$(install package)"
check "it finds Radiator's packages" yes \
    "$(said package "^Radiator: +[0-9.-]+, Radiator Software's package radiator \(with radiator-radius-utilxs [0-9.a-z-]+\): /opt/radiator/radiator/radiusd$")"
check "Radiator's Perl loads every module" "6 0" \
    "$(grep -c '^  ok ' "$work/package.out") $(grep -c '^  missing ' "$work/package.out")"
check "nothing is left to do" no "$(said package '^To do:')"
check "a login, and the same OTP again" "ACCEPT REJECT" "$(step package login /opt/radiator/radiator/radiusd)"

echo
echo "== Radiator's source in /opt/radiator/radiator"
start inplace
step inplace radiator-inplace
check "install.sh (exit 0)" 0 "$(install inplace)"
check "it finds Radiator from source" yes "$(said inplace '^Radiator: +[0-9.]+, from source: /opt/radiator/radiator/radiusd$')"
check "Radiator's Perl loads every module" "6 0" \
    "$(grep -c '^  ok ' "$work/inplace.out") $(grep -c '^  missing ' "$work/inplace.out")"
check "it says there is no radiator user" yes "$(said inplace '^  - There is no user radiator')"
check "and no radiator.service" yes "$(said inplace '^  - There is no radiator.service')"
on inplace "$(step inplace todo-commands)"
step inplace radiator-dirs
step inplace radiator-unit
check "install.sh again (exit 0)" 0 "$(install inplace)"
check "after its commands, and the unit, nothing is left to do" no "$(said inplace '^To do:')"
check "a login, and the same OTP again" "ACCEPT REJECT" "$(step inplace login /opt/radiator/radiator/radiusd)"

echo
echo "== Radiator's source, installed with make install"
start make
step make radiator-make
check "install.sh (exit 0)" 0 "$(install make)"
check "it finds Radiator from source" yes "$(said make '^Radiator: +[0-9.]+, from source: /usr/local/bin/radiusd$')"
check "Radiator's Perl loads every module" "6 0" \
    "$(grep -c '^  ok ' "$work/make.out") $(grep -c '^  missing ' "$work/make.out")"
on make "$(step make todo-commands)"
step make radiator-dirs
check "install.sh again (exit 0)" 0 "$(install make)"
check "after its commands, only the unit is left to do" "no yes" \
    "$(said make '^  - There is no user radiator') $(said make '^  - There is no radiator.service')"
check "a login, and the same OTP again" "ACCEPT REJECT" "$(step make login /usr/local/bin/radiusd)"

echo
echo "== The services, under systemd"
start systemd systemd
# Ubuntu's container images have a policy-rc.d that stops package scripts
# from starting, stopping and restarting services; servers don't.
on systemd 'rm -f /usr/sbin/policy-rc.d'
# The anycast check installed and enabled by hand, as the guide said before
# the package, and partition mode's script.
on systemd "install -m 0755 /repo/yubikey-anycast.sh /repo/yubikey-partition.sh /usr/local/sbin/ &&
            sed 's|/opt/radiator-yubikey/|/usr/local/sbin/|' /repo/yubikey-anycast.service \
                >/etc/systemd/system/yubikey-anycast.service &&
            systemctl daemon-reload && systemctl enable yubikey-anycast 2>/dev/null"
on systemd "dpkg -i /inst/${deb##*/} >/dev/null"
check "the install enables and starts neither service" "disabled inactive inactive" \
    "$(on systemd 'systemctl is-enabled yubikey-partition; systemctl is-active yubikey-partition yubikey-anycast' | paste -sd' ')"
check "systemd finds nothing wrong with the units" "" \
    "$(on systemd 'systemd-analyze verify /usr/lib/systemd/system/yubikey-anycast.service /usr/lib/systemd/system/yubikey-partition.service 2>&1')"
install systemd --check >/dev/null
check "install.sh says the unit installed by hand hides the package's" yes \
    "$(said systemd '^  - /etc/systemd/system/yubikey-anycast.service, installed by hand, hides')"
check "and that the copies in /usr/local/sbin are not used" yes \
    "$(said systemd '^  - /usr/local/sbin/yubikey-anycast.sh')"
on systemd "$(step systemd todo-commands)" >/dev/null 2>&1
check "after its commands, the package's unit, enabled" "/usr/lib/systemd/system/yubikey-anycast.service enabled" \
    "$(on systemd 'systemctl show -P FragmentPath yubikey-anycast; systemctl is-enabled yubikey-anycast' | paste -sd' ')"
# From here, each service runs 'sleep' instead of its script, which would
# need the three sites.
on systemd 'for s in anycast partition; do
                mkdir -p /etc/systemd/system/yubikey-$s.service.d
                printf "[Service]\nExecStart=\nExecStart=/bin/sleep infinity\nExecStopPost=\n" \
                    >/etc/systemd/system/yubikey-$s.service.d/test.conf
            done
            systemctl daemon-reload && systemctl start yubikey-partition'
pid=$(on systemd 'systemctl show -P MainPID yubikey-partition')
on systemd "dpkg -i /inst/${deb##*/} >/dev/null"
check "an upgrade restarts a service that runs" "active yes" \
    "$(on systemd 'systemctl is-active yubikey-partition') $([[ $(on systemd 'systemctl show -P MainPID yubikey-partition') != "$pid" ]] && echo yes || echo no)"
check "and leaves a stopped one stopped, enabled or not" "inactive enabled" \
    "$(on systemd 'systemctl is-active yubikey-anycast; systemctl is-enabled yubikey-anycast' | paste -sd' ')"
on systemd 'dpkg -r radiator-yubikey >/dev/null'
check "a removal stops the services, and removes the scripts" "inactive gone" \
    "$(on systemd 'systemctl is-active yubikey-partition; [[ -e /opt/radiator-yubikey ]] && echo there || echo gone' | paste -sd' ')"
on systemd 'dpkg -P radiator-yubikey >/dev/null'
check "a purge removes the services' links" "" \
    "$(on systemd 'find /etc/systemd/system -name "yubikey-*.service" -type l')"

echo
echo "Package: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
