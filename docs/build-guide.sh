#!/usr/bin/env bash
#
# build-guide.sh - Build yubikey-db-guide.html, the single-file HTML version
# of docs/guide.md, with pandoc and docs/guide-template.html.
#
# Usage: docs/build-guide.sh
#
# docs/guide.md is the source: edit it, then run this and commit both files.
# Needs pandoc 3 (Ubuntu: sudo apt install pandoc).

set -euo pipefail

docs=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$docs")
command -v pandoc >/dev/null || { echo "build-guide.sh: pandoc not found (sudo apt install pandoc)" >&2; exit 1; }

title=$(sed -n '1s/^# //p' "$docs/guide.md")
version=$(cat -- "$root/VERSION")
description="How to set up offline YubiKey OTP logins on Radiator RADIUS with SQLite or PostgreSQL on Linux, and add, verify and maintain accounts with yubikey-db.sh."

# Leave out the title line (the template shows it) and the Markdown contents
# list (the template has its own).
sed -e '1d' -e '/^<!-- toc -->$/,/^<!-- \/toc -->$/d' "$docs/guide.md" \
    | pandoc -f gfm -t html5 --standalone --template "$docs/guide-template.html" \
          --section-divs --no-highlight --toc --toc-depth=2 \
          --metadata title="$title" --metadata description="$description" --metadata version="$version" \
          -o "$root/yubikey-db-guide.html"
echo "Wrote $root/yubikey-db-guide.html"
