#!/usr/bin/env bash
#
# run.sh - Test yubikey-db.sh against a real Radiator, in a Docker container.
#
# Usage: tests/radiator/run.sh DIR [LAB...]
#   LAB: e2e, groups, ha, geo, package, turnkey or upgrade (all seven by
#   default, in that order).
#   DIR holds the Radiator packages from Radiator Software, which are not part
#   of this repository: radiator_<version>_all.deb and
#   radiator-radius-utilxs_<version>_amd64.deb.
#
# Builds an Ubuntu 26.04 image with Radiator, SQLite, PostgreSQL 18, Patroni,
# etcd and FRR, tagged yk-radiator-test:<Radiator version>, then runs the labs,
# or only those named:
#   e2e  e2e.sh in a throwaway container with this repository mounted
#        read-only: SQLite, PostgreSQL on the same host, cutover (about 1 min)
#   ha   ha.sh: two PostgreSQL servers (primary and standby) and two Radiator
#        servers in separate containers, through failures (about 2 min)
#   geo  geo.sh: three sites, each with etcd, PostgreSQL under Patroni,
#        Radiator and FRR, with one anycast address and then partition mode,
#        through reboots, power losses and network partitions (about 15 min)
#   package  package.sh: the radiator-yubikey package and install.sh, on fresh
#        Ubuntu 26.04 containers without Radiator, with Radiator Software's
#        packages, and with Radiator's source; the services under systemd
#        (about 4 min; apt-get in the containers needs network access)
#   turnkey  turnkey.sh: yubikey-turnkey's setup.sh on three fresh Ubuntu
#        26.04 servers at once, with two routers and a device: logins at the
#        anycast addresses over RADIUS and TACACS+, the firewall, a second
#        run, a reboot, a new device, backups, servers rebuilt and replaced,
#        new passwords (about 30 min; apt-get needs network access)
#   upgrade  upgrade.sh: the same lab, set up with radiator-yubikey 1.12.0
#        (from its git tag), then upgraded to this version, to a newer
#        Radiator, and Ubuntu's updates one server at a time (about 10 min)
# Each lab stops after about twice its usual time (LIMIT below), so one that
# hangs fails and the others still run; it removes its containers as it
# stops. Needs Docker, usable without sudo (membership of the docker group).
# Exits 0 when every check passes.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$(dirname -- "$here")")
die() { printf 'run.sh: error: %s\n' "$*" >&2; exit 1; }

LABS=(e2e groups ha geo package turnkey upgrade)
# Minutes.
declare -A LIMIT=([e2e]=5 [groups]=5 [ha]=5 [geo]=30 [package]=10 [turnkey]=60 [upgrade]=20)

dir=${1:-}
[[ -n $dir && -d $dir ]] || die "usage: tests/radiator/run.sh DIR [LAB...] (DIR: the directory with the Radiator .deb packages; LAB: e2e, groups, ha, geo, package, turnkey or upgrade)"
shift
which=("$@")
if [[ ${#which[@]} -eq 0 || ${which[*]} == all ]]; then which=("${LABS[@]}"); fi
for lab in "${which[@]}"; do
    [[ -n ${LIMIT[$lab]-} ]] || die "unknown lab '$lab' (e2e, groups, ha, geo, package, turnkey or upgrade)"
done
shopt -s nullglob
rad=("$dir"/radiator_*_all.deb)
utilxs=("$dir"/radiator-radius-utilxs_*.deb)
[[ ${#rad[@]} -eq 1 && ${#utilxs[@]} -eq 1 ]] \
    || die "$dir must hold exactly one radiator_*_all.deb and one radiator-radius-utilxs_*.deb"
command -v docker >/dev/null || die "docker not found"

version=$(dpkg-deb -f "${rad[0]}" Version)
image=yk-radiator-test:$version
ctx=$(mktemp -d)
trap 'rm -rf -- "$ctx"' EXIT
cp -- "${rad[0]}" "${utilxs[0]}" "$here/Dockerfile" "$ctx/"

echo "Building $image (Radiator $version) ..."
docker build -q -t "$image" "$ctx" >/dev/null
status=0 n=0
for lab in "${which[@]}"; do
    ((n++ == 0)) || echo
    case $lab in
        # --init: the lab stops when its time is up (bash as PID 1 would not).
        e2e|groups) cmd=(docker run --rm --init -v "$root:/repo:ro" "$image" bash "/repo/tests/radiator/$lab.sh") ;;
        ha|geo)     cmd=("$here/$lab.sh" "$image") ;;
        *)          cmd=("$here/$lab.sh" "$image" "$dir") ;;
    esac
    # --foreground: Ctrl-C still reaches the lab.
    rc=0
    timeout --foreground -k 1m "${LIMIT[$lab]}m" "${cmd[@]}" || rc=$?
    if [[ $rc == 124 || $rc == 137 ]]; then
        printf 'run.sh: %s stopped after %s min, about twice its usual time\n' "$lab" "${LIMIT[$lab]}" >&2
    fi
    [[ $rc == 0 ]] || status=1
done
exit $status
