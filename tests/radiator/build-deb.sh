#!/usr/bin/env bash
#
# build-deb.sh - Build the radiator-yubikey package with packaging/build-deb.sh
# in the test image (which has debhelper), for the tests that install it.
#
# Usage: tests/radiator/build-deb.sh IMAGE OUTDIR
#   Prints the package's path: OUTDIR/radiator-yubikey_VERSION_all.deb.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$(dirname -- "$here")")
[[ $# -eq 2 ]] || { echo "usage: tests/radiator/build-deb.sh IMAGE OUTDIR" >&2; exit 2; }

mkdir -p "$2"
out=$(cd -- "$2" && pwd)
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$root:/repo:ro" -v "$out:/out" "$1" \
    /repo/packaging/build-deb.sh /out | sed "s|^/out/|$out/|"
