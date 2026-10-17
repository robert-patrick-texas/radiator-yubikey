#!/usr/bin/env bash
#
# build-deb.sh - Build the radiator-yubikey .deb package, which installs the
#                scripts and their examples in /opt/radiator-yubikey.
#
# Usage: packaging/build-deb.sh [OUTDIR]
#   Writes radiator-yubikey_VERSION_all.deb to OUTDIR (default: dist/ in the
#   repository), and install.sh, to go next to it in a release. VERSION is
#   the one in the file VERSION, and the package's date is the date of that
#   version's section in CHANGELOG.md, so the same files always make the
#   same package.
#
# The package is built from a copy of the files that
# packaging/debian/radiator-yubikey.install names, with the rest of
# packaging/debian as its debian/ directory, and a debian/changelog made here.
# In the copy, each script has the version written into its VERSION= line,
# so that it needs no VERSION file next to it; so does the install.sh
# written to OUTDIR.
#
# Needs dpkg-dev and debhelper (sudo apt install dpkg-dev debhelper).

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
die() { printf 'build-deb.sh: error: %s\n' "$*" >&2; exit 1; }

out=${1:-$root/dist}
if ! command -v dpkg-buildpackage >/dev/null || ! command -v dh >/dev/null; then
    die "needs dpkg-dev and debhelper (sudo apt install dpkg-dev debhelper)"
fi

version=$(cat -- "$root/VERSION")
[[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "VERSION holds no version: $version"

# The date of the version's changelog section, or today for a version that
# has none yet.
day=$(sed -n "s/^## ${version//./\\.} - \([0-9-]\{10\}\)\$/\1/p" "$root/CHANGELOG.md")
if [[ -z $day ]]; then
    day=$(date -u +%F)
    printf 'build-deb.sh: warning: CHANGELOG.md has no "## %s - DATE" section; using %s\n' "$version" "$day" >&2
fi

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
src=$tmp/radiator-yubikey-$version
mkdir -p "$src"
cp -r -- "$here/debian" "$src/debian"
while read -r file _; do
    [[ -n $file ]] || continue
    mkdir -p "$src/$(dirname -- "$file")"
    cp -p -- "$root/$file" "$src/$file"
done <"$here/debian/radiator-yubikey.install"
for s in yubikey-db.sh yubikey-db-migrate.sh yubikey-partition.sh yubikey-anycast.sh yubikey-backup.sh install.sh; do
    [[ $(grep -c '^VERSION=' "$src/$s") == 1 ]] || die "$s has no single VERSION= line"
    sed -i "s/^VERSION=.*/VERSION=$version/" "$src/$s"
done

maintainer=$(sed -n 's/^Maintainer: //p' "$here/debian/control")
cat >"$src/debian/changelog" <<EOF
radiator-yubikey ($version) unstable; urgency=medium

  * Version $version: see /opt/radiator-yubikey/CHANGELOG.md.

 -- $maintainer  $(date -u -R -d "$day")
EOF

# -d: no check of the build dependencies, which always include
# build-essential (a C compiler, which this package doesn't need); debhelper
# is checked above.
(cd "$src" && dpkg-buildpackage -A -us -uc -d) >"$tmp/build.log" 2>&1 \
    || { cat "$tmp/build.log" >&2; die "dpkg-buildpackage failed"; }
deb=radiator-yubikey_${version}_all.deb
mkdir -p "$out"
mv -- "$tmp/$deb" "$out/$deb"
cp -p -- "$src/install.sh" "$out/install.sh"
printf '%s\n' "$out/$deb"
