#!/usr/bin/env bash
#
# run.sh - Test yubikey-db.sh against a real Radiator, in a Docker container.
#
# Usage: tests/radiator/run.sh DIR
#   DIR holds the Radiator packages from Radiator Software, which are not part
#   of this repository: radiator_<version>_all.deb and
#   radiator-radius-utilxs_<version>_amd64.deb.
#
# Builds an Ubuntu 26.04 image with Radiator, SQLite and PostgreSQL 18, tagged
# yk-radiator-test:<Radiator version>, and runs e2e.sh in a throwaway container
# with this repository mounted read-only. Needs Docker, usable without sudo
# (membership of the docker group). Exits 0 when every check passes.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$(dirname -- "$here")")
die() { printf 'run.sh: error: %s\n' "$*" >&2; exit 1; }

dir=${1:-}
[[ -n $dir && -d $dir ]] || die "usage: tests/radiator/run.sh DIR (the directory with the Radiator .deb packages)"
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
docker run --rm -v "$root:/repo:ro" "$image" bash /repo/tests/radiator/e2e.sh
