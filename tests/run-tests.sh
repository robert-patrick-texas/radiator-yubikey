#!/usr/bin/env bash
#
# run-tests.sh - Regression tests for yubikey-db.sh.
#
# Runs yubikey-db.sh through a fixed set of scenarios against throwaway
# databases and compares the combined transcript (commands, output, exit
# codes, and final table contents) with tests/expected/<scenario>.out.
# Values that change on every run (timestamps, temp paths, password salts)
# are replaced with placeholders before comparing.
#
# Usage:
#   tests/run-tests.sh            run every scenario and report pass/fail
#   tests/run-tests.sh --update   rewrite the expected files from this run
#   tests/run-tests.sh NAME...    run only the named scenarios
#
#   YUBIKEY_DB_SH=/path/to/yubikey-db.sh tests/run-tests.sh
#                                 test another copy of the script (it must be
#                                 named yubikey-db.sh, which appears in messages)
#
# Needs: bash 4+, sqlite3, perl. Run as a normal user, not root (one scenario
# checks permission errors, which root bypasses).

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname -- "$TESTS_DIR")
SCRIPT=${YUBIKEY_DB_SH:-$ROOT/yubikey-db.sh}   # override to test another copy
EXPECTED=$TESTS_DIR/expected
UPDATE=0
TMPROOT=       # per-run temp directory, removed on exit
WORK=          # scenario scratch directory under TMPROOT, emptied per scenario

trap 'if [[ -n $TMPROOT ]]; then rm -rf -- "$TMPROOT"; fi' EXIT

# --------------------------------------------------------------------------
# Helpers used by the scenarios. Each writes to stdout, which is captured as
# the scenario's transcript.
# --------------------------------------------------------------------------

# Run yubikey-db.sh with stdin from /dev/null (so it never prompts) and record
# the command, its merged stdout/stderr, and its exit code.
run() {
    local out rc=0
    out=$("$SCRIPT" "$@" </dev/null 2>&1) || rc=$?
    printf '$ yubikey-db.sh %s\n%s%s[exit %d]\n\n' "$*" "$out" "${out:+$'\n'}" "$rc"
}

# Same as run, with environment assignments in front: run_env VAR=x -- ARGS...
run_env() {
    local -a envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    local out rc=0
    out=$(env "${envs[@]}" "$SCRIPT" "$@" </dev/null 2>&1) || rc=$?
    printf '$ %s yubikey-db.sh %s\n%s%s[exit %d]\n\n' "${envs[*]}" "$*" "$out" "${out:+$'\n'}" "$rc"
}

# Print every row and column of the yubikeys table, so the test sees exactly
# what was stored (including secrets, which these test values are).
dump() {
    printf '# yubikeys table in %s\n' "${1##*/}"
    sqlite3 -batch -header -separator ' | ' "$1" \
        'SELECT username, password, active, typeof(active) AS active_type, created,
                accessed, tokenId, userId, secret, counter, low, high
           FROM yubikeys ORDER BY userId;'
    echo
}

schema() {
    printf '# schema of %s\n' "${1##*/}"
    sqlite3 -batch "$1" .schema
    echo
}

# Check that a stored {crypt} hash matches a password, without printing the hash.
check_crypt() {
    local db=$1 user=$2 pw=$3 stored
    stored=$(sqlite3 -batch "$db" "SELECT password FROM yubikeys WHERE username = '$user';")
    printf '# crypt check for %s: ' "$user"
    PW=$pw STORED=$stored perl -e '
        my $h = $ENV{STORED};
        $h =~ s/^\{crypt\}// or do { print "not a {crypt} value\n"; exit };
        print crypt($ENV{PW}, $h) eq $h ? "match\n" : "MISMATCH\n";'
    echo
}

# Write a CSV file into the scratch directory: csv NAME <<EOF ... EOF
csv() {
    cat >"$WORK/$1"
    chmod 600 "$WORK/$1"
}

# Replace values that differ between runs with fixed placeholders.
# shellcheck disable=SC2016  # the $ signs in the sed patterns are literal
normalize() {
    sed -E \
        -e "s|$WORK|<WORK>|g" \
        -e "s|$ROOT|<ROOT>|g" \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/<TIMESTAMP>/g' \
        -e 's/\{crypt\}\$6\$[^ |]*/{crypt}$6$<HASH>/g' \
        -e 's/(if Radiator does not run as) [^ ]+$/\1 <USER>/'
}

# --------------------------------------------------------------------------
# Scenarios. Each function runs in the scratch directory with DB set to a
# fresh database path that does not exist yet.
# --------------------------------------------------------------------------

scenario_help() {
    run --help
    run --version
    run
    run bogus
    run --bogus-option list
    run -e rot13 list
    run -H md5 list
}

scenario_init() {
    run -d "$DB" list
    run -d "$DB" init
    schema "$DB"
    run -d "$DB" init
    stat -c '# db mode %a' "$DB"
    run -d "$WORK/sub/dir/yk.db" init
    stat -c '# new directory mode %a' "$WORK/sub/dir"
    run -d "$DB" list
    run -d "$DB" init --bogus
}

scenario_import() {
    run -d "$DB" init >/dev/null
    csv example.csv <"$ROOT/users.example.csv"
    run -d "$DB" import --dry-run example.csv
    run -d "$DB" import example.csv
    dump "$DB"
    check_crypt "$DB" test.user abc123
    run -d "$DB" list
    run -d "$DB" list test.user2
    run -d "$DB" list nobody
    run -d "$DB" list a b

    # Importing the same rows again fails and is rolled back.
    run -d "$DB" import example.csv
    run -d "$DB" list
}

scenario_import_formats() {
    run -d "$DB" init >/dev/null
    csv formats.csv <<'EOF'
# comment line, then a blank line

  alice , VVCCCCBBCDEF , 4A:6F:8E:2D:1C:3B , "6b1f 0a9d 2c7e 4f3a 8b5d 0c1e 9f2a 7b6d" , , YES
"bob",vvccccbbcdeg,ttttttttttttt,0f1e2d3c4b5a69788796a5b4c3d2e1f0
bob,vvccccbbcdeh,vvvvvvvvvvvv,0f1e2d3c4b5a69788796a5b4c3d2e1f0,,off
carol@example.com,vvccccbbcdei,0a1b2c3d4e5f,00112233445566778899aabbccddeeff,{weird}pw,n
EOF
    # Windows line endings on one more row
    printf 'dave,vvccccbbcdej,0a1b2c3d4e60,00112233445566778899aabbccddeef0,,1\r\n' >>"$WORK/formats.csv"

    # bob's first row has a 13-character private ID, so the import is refused...
    run -d "$DB" import "$WORK/formats.csv"
    # ...unless invalid rows are skipped.
    run -d "$DB" import --skip-invalid "$WORK/formats.csv"
    dump "$DB"
}

scenario_import_errors() {
    run -d "$DB" init >/dev/null
    csv bad.csv <<'EOF'
username,public_id,private_id,aes_key,password,active
bad user,vvccccbbcdef,4a6f8e2d1c3b,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
ok1,abc,4a6f8e2d1c3b,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
ok2,vvccccbbcdef,4a6f8e2d1c3,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
ok3,vvccccbbcdeg,4a6f8e2d1c3c,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6
ok4,vvccccbbcdeh,4a6f8e2d1c3d,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,,maybe
ok5,vvccccbbcdei
ok6,vvccccbbcdei,4a6f8e2d1c3e,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,pw,1,extra
dup1,vvccccbbcdej,4a6f8e2d1c3f,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
dup2,vvccccbbcdej,4a6f8e2d1c40,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
dup3,vvccccbbcdek,4a6f8e2d1c3f,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
EOF
    run -d "$DB" import --dry-run "$WORK/bad.csv"
    run -d "$DB" import --skip-invalid --dry-run "$WORK/bad.csv"
    run -d "$DB" import --skip-invalid "$WORK/bad.csv"
    dump "$DB"

    csv empty.csv <<'EOF'
# nothing but a comment
EOF
    run -d "$DB" import "$WORK/empty.csv"
    run -d "$DB" import
    run -d "$DB" import "$WORK/missing.csv"
    run -d "$DB" import "$WORK/bad.csv" "$WORK/empty.csv"
    run -d "$DB" import --bogus "$WORK/bad.csv"

    # A world-readable CSV produces a warning.
    chmod 644 "$WORK/empty.csv"
    run -d "$DB" import --dry-run "$WORK/empty.csv"

    # Importing into a database that does not exist yet.
    run -d "$WORK/none.db" import bad.csv
}

scenario_add() {
    run -d "$DB" init >/dev/null
    run -d "$DB" add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d -w 's3cr3t'
    check_crypt "$DB" alice 's3cr3t'
    run -d "$DB" add -u bob -P vvccccbbcdeg -p cccccccccccb -k 0f1e2d3c4b5a69788796a5b4c3d2e1f0 --no-password --inactive
    dump "$DB"

    # Duplicate public ID, then the same with --replace (counters reset).
    sqlite3 "$DB" "UPDATE yubikeys SET counter = 7, low = 3, accessed = '2026-01-01 00:00:00' WHERE username = 'alice';"
    run -d "$DB" add -u alice -P vvccccbbcdef -p 111111111111 -k 00000000000000000000000000000000 --no-password
    run -d "$DB" add --replace -u alice -P vvccccbbcdef -p 111111111111 -k 00000000000000000000000000000000 --no-password
    dump "$DB"

    # --replace when the new row clashes with two existing rows (one by
    # public ID, one by private ID): both are replaced by the single new row.
    run -d "$DB" add --replace -u carol -P vvccccbbcdeg -p 111111111111 -k ffffffffffffffffffffffffffffffff --no-password
    dump "$DB"

    # Missing values with no terminal to prompt on.
    run -d "$DB" add -u dave -P vvccccbbcdeh
    run -d "$DB" add -u dave -P vvccccbbcdeh -p 4a6f8e2d1c3b -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
    run -d "$DB" add -u 'bad name' -P vvccccbbcdeh -p 4a6f8e2d1c3b -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d --no-password
    run -d "$DB" add --bogus
    run -d "$WORK/none.db" add -u x -P vvccccbbcdeh -p 4a6f8e2d1c3b -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d --no-password
}

scenario_encodings() {
    run -d "$DB" -e hex -H clear init >/dev/null
    run -d "$DB" -e hex -H clear add -u hexuser -P vvccccbbcdef -p 4a6f8e2d1c3b -k 6B1F0A9D2C7E4F3A8B5D0C1E9F2A7B6D -w 'plain pw'
    run -d "$DB" -H clear add -u braceuser -P vvccccbbcdeg -p 4a6f8e2d1c3c -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d -w '{SHA}not-really'
    run_env SECRET_ENCODING=hex PASSWORD_HASH=clear -- -d "$DB" add -u envuser -P vvccccbbcdeh -p 4a6f8e2d1c3d -k 00112233445566778899aabbccddeeff -w "it's"
    dump "$DB"
}

scenario_modify() {
    run -d "$DB" init >/dev/null
    csv users.csv <<'EOF'
alice,vvccccbbcdef,4a6f8e2d1c3b,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
alice,vvccccbbcdeg,4a6f8e2d1c3c,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
bob,vvccccbbcdeh,4a6f8e2d1c3d,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
carol,vvccccbbcdei,4a6f8e2d1c3e,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
EOF
    run -d "$DB" import "$WORK/users.csv"
    run -d "$DB" disable alice
    run -d "$DB" enable alice VVCCCCBBCDEG
    run -d "$DB" disable bob
    dump "$DB"
    run -d "$DB" delete alice vvccccbbcdef
    run -d "$DB" delete bob
    run -d "$DB" delete bob
    # Quotes in arguments must not change the SQL: these match no rows,
    # and carol must still be active afterwards.
    run -d "$DB" enable "o'brien"
    run -d "$DB" disable "x' OR '1'='1"
    run -d "$DB" disable carol "x' OR '1'='1"
    run -d "$DB" enable
    run -d "$DB" disable a b c
    dump "$DB"
}

scenario_permissions() {
    run -d "$DB" init >/dev/null
    csv example.csv <"$ROOT/users.example.csv"
    run -d "$DB" import example.csv >/dev/null
    chmod 444 "$DB"
    run -d "$DB" disable test.user
    run -d "$DB" list test.user
    chmod 000 "$DB"
    run -d "$DB" list
    chmod 640 "$DB"
    mkdir "$WORK/ro" && chmod 555 "$WORK/ro"
    run -d "$WORK/ro/yk.db" init
    chmod 755 "$WORK/ro"
}

scenario_tools() {
    run_env SQLITE3=/nonexistent/sqlite3 -- -d "$DB" init
    run_env SQLITE3=/nonexistent/sqlite3 -- -d "$DB" config
}

scenario_config() {
    run config
    run -d /srv/radius/yubi.db -e hex config
    run_env DB_FILE=/opt/yk.db -- config
}

# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------

ALL=(help init import import_formats import_errors add encodings modify permissions tools config)

if [[ ${1-} == --update ]]; then UPDATE=1; shift; fi
if [[ $# -gt 0 ]]; then SELECTED=("$@"); else SELECTED=("${ALL[@]}"); fi

if [[ $EUID -eq 0 ]]; then
    echo "run-tests.sh: run as a normal user, not root" >&2
    exit 2
fi
for tool in sqlite3 perl; do
    command -v "$tool" >/dev/null || { echo "run-tests.sh: $tool is required" >&2; exit 2; }
done

TMPROOT=$(mktemp -d)
WORK=$TMPROOT/work
mkdir -p "$EXPECTED"
pass=0 fail=0

for name in "${SELECTED[@]}"; do
    declare -F "scenario_$name" >/dev/null || { echo "unknown scenario: $name" >&2; exit 2; }
    rm -rf -- "$WORK" && mkdir -p "$WORK"
    DB=$WORK/yubicred.db
    actual=$TMPROOT/$name.out
    ( cd "$WORK" && "scenario_$name" ) 2>&1 | normalize >"$actual"

    if [[ $UPDATE == 1 ]]; then
        mv -- "$actual" "$EXPECTED/$name.out"
        echo "updated  $name"
    elif diff -u --label "expected/$name.out" --label "actual/$name.out" \
            "$EXPECTED/$name.out" "$actual"; then
        echo "PASS     $name"; pass=$((pass + 1)); rm -f -- "$actual"
    else
        echo "FAIL     $name"; fail=$((fail + 1)); rm -f -- "$actual"
    fi
done

if [[ $UPDATE == 0 ]]; then
    echo "$pass passed, $fail failed"
    [[ $fail -eq 0 ]]
fi
