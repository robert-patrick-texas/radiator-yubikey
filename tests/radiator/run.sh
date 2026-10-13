#!/usr/bin/env bash
#
# run.sh - Test yubikey-db.sh against a real Radiator, in a Docker container.
#
# Usage: tests/radiator/run.sh DIR [e2e|ha|geo|package]
#   DIR holds the Radiator packages from Radiator Software, which are not part
#   of this repository: radiator_<version>_all.deb and
#   radiator-radius-utilxs_<version>_amd64.deb.
#
# Builds an Ubuntu 26.04 image with Radiator, SQLite, PostgreSQL 18, Patroni,
# etcd and FRR, tagged yk-radiator-test:<Radiator version>, then runs the four
# tests, or only the one named:
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
#        (about 5 min; apt-get in the containers needs network access)
# Needs Docker, usable without sudo (membership of the docker group). Exits 0
# when every check passes.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$(dirname -- "$here")")
die() { printf 'run.sh: error: %s\n' "$*" >&2; exit 1; }

dir=${1:-}
which=${2:-all}
[[ -n $dir && -d $dir ]] || die "usage: tests/radiator/run.sh DIR [e2e|ha|geo|package] (DIR: the directory with the Radiator .deb packages)"
[[ $which =~ ^(all|e2e|ha|geo|package)$ ]] || die "unknown test '$which' (e2e, ha, geo or package)"
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
status=0
if [[ $which == all || $which == e2e ]]; then
    docker run --rm -v "$root:/repo:ro" "$image" bash /repo/tests/radiator/e2e.sh || status=1
fi
if [[ $which == all || $which == ha ]]; then
    [[ $which == all ]] && echo
    "$here/ha.sh" "$image" || status=1
fi
if [[ $which == all || $which == geo ]]; then
    [[ $which == all ]] && echo
    "$here/geo.sh" "$image" || status=1
fi
if [[ $which == all || $which == package ]]; then
    [[ $which == all ]] && echo
    "$here/package.sh" "$image" "$dir" || status=1
fi
exit $status
