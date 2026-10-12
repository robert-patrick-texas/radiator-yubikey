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
#
# The pg_* scenarios also need psql and a PostgreSQL 18 (or later) server that
# this user can reach with the default libpq settings, as a role with CREATEDB
# and CREATEROLE, for example:
#     sudo -u postgres createuser --createdb --createrole "$USER"
# pg_radiator also logs in over TCP to 127.0.0.1 with a password, which
# Ubuntu's default pg_hba.conf allows. The scenarios create databases and roles
# named yk_test_<pid>_*, and drop them afterwards. They are skipped when no
# server is reachable.

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname -- "$TESTS_DIR")
SCRIPT=${YUBIKEY_DB_SH:-$ROOT/yubikey-db.sh}   # override to test another copy
EXPECTED=$TESTS_DIR/expected
UPDATE=0
TMPROOT=       # per-run temp directory, removed on exit
WORK=          # scenario scratch directory under TMPROOT, emptied per scenario
PGT=yk_test_$$ # prefix for throwaway PostgreSQL databases and roles
PGDB=${PGT}_db
PG_OK=0        # 1 when a PostgreSQL 18+ server is reachable
PG_SKIP_REASON="no PostgreSQL server reachable"

cleanup() {
    if [[ $PG_OK == 1 ]]; then pg_cleanup; fi
    if [[ -n $TMPROOT ]]; then rm -rf -- "$TMPROOT"; fi
}
trap cleanup EXIT

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
    local db=$1 user=$2 pw=$3
    verify_crypt "$user" "$pw" "$(sqlite3 -batch "$db" "SELECT password FROM yubikeys WHERE username = '$user';")"
}

check_crypt_pg() {
    local user=$1 pw=$2
    verify_crypt "$user" "$pw" "$(pgq "$PGDB" "SELECT password FROM yubikeys WHERE username = '$user';")"
}

verify_crypt() {
    local user=$1 pw=$2 stored=$3
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

# Run one SQL command as this user, unaligned and without headers: pgq DB SQL
pgq() {
    psql -X -q -v ON_ERROR_STOP=1 --no-align --tuples-only -d "$1" -c "$2"
}

# Print a query result with headers, columns separated by ' | ': pgtable SQL
pgtable() {
    psql -X -q -v ON_ERROR_STOP=1 --no-align --field-separator ' | ' \
        --pset footer=off -d "$PGDB" -c "$1"
}

dump_pg() {
    printf '# yubikeys table in %s\n' "$PGDB"
    pgtable "SELECT username, password, active, pg_typeof(active) AS active_type,
                    to_char(created AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS created,
                    accessed, tokenId, userId, secret, counter, low, high
               FROM yubikeys ORDER BY userId;"
    echo
}

# Table definition, ownership and privileges, from catalog queries. NOT NULL
# constraints are left out of the constraint list; the column list shows them.
schema_pg() {
    printf '# columns\n'
    pgtable "SELECT column_name, data_type, character_maximum_length AS max_length,
                    is_nullable, column_default
               FROM information_schema.columns
              WHERE table_name = 'yubikeys' ORDER BY ordinal_position;"
    printf '# constraints (NOT NULL is shown in the columns above)\n'
    pgtable "SELECT conname, pg_get_constraintdef(oid) AS definition FROM pg_constraint
              WHERE conrelid = 'yubikeys'::regclass AND contype <> 'n' ORDER BY conname;"
    printf '# indexes\n'
    pgtable "SELECT indexname FROM pg_indexes WHERE tablename = 'yubikeys' ORDER BY indexname;"
    printf '# owners\n'
    pgtable "SELECT (SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()) AS database_owner,
                    (SELECT tableowner FROM pg_tables WHERE tablename = 'yubikeys') AS table_owner;"
    printf '# privileges for roles other than the owner\n'
    pgtable "SELECT grantee, privilege_type, string_agg(column_name, ', ' ORDER BY column_name) AS columns
               FROM information_schema.column_privileges
              WHERE table_name = 'yubikeys' AND grantee LIKE '${PGT}%' AND grantee <> '${PGT}_admin'
              GROUP BY grantee, privilege_type ORDER BY grantee, privilege_type;"
    pgtable "SELECT grantee, privilege_type AS table_level_privilege
               FROM information_schema.table_privileges
              WHERE table_name = 'yubikeys' AND grantee <> '${PGT}_admin' ORDER BY 1, 2;"
    pgtable "SELECT datacl AS database_acl FROM pg_database WHERE datname = current_database();"
    printf '# members of the admin role (test roles only)\n'
    pgtable "SELECT r.rolname AS member FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member
              WHERE m.roleid = '${PGT}_admin'::regrole AND r.rolname LIKE '${PGT}%' ORDER BY 1;"
    echo
}

# Run SQL as the Radiator role over TCP, the way Radiator connects from
# another host, and record the output: as_radiator SQL
as_radiator() {
    local out rc=0
    out=$(PGPASSWORD=test-only psql -X -q --no-align --field-separator ' | ' --pset footer=off \
            -v VERBOSITY=terse -h 127.0.0.1 -U "${PGT}_radiator" -d "$PGDB" -c "$1" 2>&1) || rc=$?
    printf '$ radiator> %s\n%s%s[exit %d]\n\n' "$1" "$out" "${out:+$'\n'}" "$rc"
}

pg_cleanup() {
    psql -X -q -d postgres >/dev/null 2>&1 <<EOF
DROP DATABASE IF EXISTS ${PGT}_db WITH (FORCE);
DROP DATABASE IF EXISTS ${PGT}_empty WITH (FORCE);
DROP ROLE IF EXISTS ${PGT}_op, ${PGT}_radiator, ${PGT}_admin;
EOF
}

# Replace values that differ between runs with fixed placeholders.
# shellcheck disable=SC2016  # the $ signs in the sed patterns are literal
normalize() {
    sed -E \
        -e "s|$WORK|<WORK>|g" \
        -e "s|$ROOT|<ROOT>|g" \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/<TIMESTAMP>/g' \
        -e 's/\{crypt\}\$6\$[^ |]*/{crypt}$6$<HASH>/g' \
        -e 's/(if Radiator does not run as) [^ ]+$/\1 <USER>/' \
        -e "s/$PGT/<T>/g" \
        -e 's/connection to server .* failed:/connection to server <SERVER> failed:/' \
        -e "s/\(is $(id -un) a member of/(is <USER> a member of/"
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

# PostgreSQL behavior that needs no server.
scenario_pg_offline() {
    local env
    local -a assignments
    run -b mysql list
    run init-pg
    run_env PSQL=/nonexistent/psql -- -b pg list
    run_env PG_ADMIN_ROLE=Bad-Name -- -b pg list
    # PostgreSQL older than 18 is refused (a stand-in psql reports 16.4).
    printf '#!/bin/sh\ncat >/dev/null\necho "160004|16.4"\n' >"$WORK/psql16"
    chmod +x "$WORK/psql16"
    run_env PSQL="$WORK/psql16" -- -b pg -d yubikey init-pg
    run_env PSQL="$WORK/psql16" -- -b pg -d yubikey init
    run -b pg config
    for env in DB_BACKEND=pg PGHOST=db.example.com PGHOST=/var/run/postgresql \
               'PGHOST=db.example.com PGPORT=6432 PGSSLMODE=require' PGSERVICE=yubikey \
               'PGSERVICE=yubikey PGDATABASE=radius' PG_RADIATOR_ROLE=radiusd; do
        read -ra assignments <<<"$env"
        printf '$ %s yubikey-db.sh -b pg config | grep DB\n' "$env"
        env "${assignments[@]}" "$SCRIPT" -b pg config | grep -E '^ +DB(Source|Username)'
        echo
    done
    printf '$ yubikey-db.sh -b pg -d radius config | grep DB\n'
    "$SCRIPT" -b pg -d radius config | grep -E '^ +DB(Source|Username)'
    echo
}

scenario_pg_init() {
    run -b pg -d "$PGDB" list
    run -b pg -d "$PGDB" init-pg --admin "${PGT}_op"
    schema_pg
    run -b pg -d "$PGDB" init-pg
    run -b pg -d "$PGDB" init
    run -b pg -d "$PGDB" list
    run -b pg -d "$PGDB" init --bogus
    run -b pg -d "$PGDB" init-pg --bogus
    run -b pg -d "$PGDB" init-pg --admin Bad-Login
    run -b pg -d bad-name init-pg
    run -b pg -d "$PGDB" init-pg --set-password
    pgq postgres "CREATE DATABASE ${PGT}_empty;"
    run -b pg -d "${PGT}_empty" list
}

scenario_pg_import() {
    run -b pg -d "$PGDB" init-pg >/dev/null
    csv example.csv <"$ROOT/users.example.csv"
    run -b pg -d "$PGDB" import --dry-run example.csv
    run -b pg -d "$PGDB" import example.csv
    dump_pg
    check_crypt_pg test.user abc123
    run -b pg -d "$PGDB" list
    run -b pg -d "$PGDB" list test.user2
    run -b pg -d "$PGDB" list nobody

    # Importing the same rows again fails and is rolled back.
    run -b pg -d "$PGDB" import example.csv
    run -b pg -d "$PGDB" list
    # With --replace the rows are overwritten, and their counters reset.
    pgq "$PGDB" "UPDATE yubikeys SET counter = 9;"
    run -b pg -d "$PGDB" import --replace example.csv
    run -b pg -d "$PGDB" list
}

scenario_pg_add() {
    run -b pg -d "$PGDB" init-pg >/dev/null
    run -b pg -d "$PGDB" add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d -w 's3cr3t'
    check_crypt_pg alice 's3cr3t'
    run -b pg -d "$PGDB" add -u bob -P vvccccbbcdeg -p cccccccccccb -k 0f1e2d3c4b5a69788796a5b4c3d2e1f0 --no-password --inactive
    dump_pg

    # Duplicate public ID, then the same with --replace (counters reset).
    pgq "$PGDB" "UPDATE yubikeys SET counter = 7, low = 3, accessed = now() WHERE username = 'alice';"
    run -b pg -d "$PGDB" add -u alice -P vvccccbbcdef -p 111111111111 -k 00000000000000000000000000000000 --no-password
    run -b pg -d "$PGDB" add --replace -u alice -P vvccccbbcdef -p 111111111111 -k 00000000000000000000000000000000 --no-password
    dump_pg

    # --replace when the new row clashes with two existing rows (one by
    # public ID, one by private ID): both are replaced by the single new row.
    run -b pg -d "$PGDB" add --replace -u carol -P vvccccbbcdeg -p 111111111111 -k ffffffffffffffffffffffffffffffff --no-password
    dump_pg
}

scenario_pg_encodings() {
    run -b pg -d "$PGDB" init-pg >/dev/null
    run -b pg -d "$PGDB" -e hex -H clear add -u hexuser -P vvccccbbcdef -p 4a6f8e2d1c3b -k 6B1F0A9D2C7E4F3A8B5D0C1E9F2A7B6D -w 'plain pw'
    run -b pg -d "$PGDB" -H clear add -u braceuser -P vvccccbbcdeg -p 4a6f8e2d1c3c -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d -w '{SHA}not-really'
    # Quotes, backslashes and dollar signs must be stored exactly as given.
    run -b pg -d "$PGDB" -H clear add -u quoteuser -P vvccccbbcdeh -p 4a6f8e2d1c3d -k 00112233445566778899aabbccddeeff -w "it's \\ \$\$ :x"
    dump_pg
}

scenario_pg_modify() {
    run -b pg -d "$PGDB" init-pg >/dev/null
    csv users.csv <<'EOF'
alice,vvccccbbcdef,4a6f8e2d1c3b,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
alice,vvccccbbcdeg,4a6f8e2d1c3c,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
bob,vvccccbbcdeh,4a6f8e2d1c3d,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
carol,vvccccbbcdei,4a6f8e2d1c3e,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
EOF
    run -b pg -d "$PGDB" import "$WORK/users.csv"
    run -b pg -d "$PGDB" disable alice
    run -b pg -d "$PGDB" enable alice VVCCCCBBCDEG
    run -b pg -d "$PGDB" disable bob
    dump_pg
    run -b pg -d "$PGDB" delete alice vvccccbbcdef
    run -b pg -d "$PGDB" delete bob
    run -b pg -d "$PGDB" delete bob
    # Quotes in arguments must not change the SQL: these match no rows,
    # and carol must still be active afterwards.
    run -b pg -d "$PGDB" enable "o'brien"
    run -b pg -d "$PGDB" disable "x' OR '1'='1"
    run -b pg -d "$PGDB" disable carol "x' OR '1'='1"
    dump_pg
}

# What Radiator's login role can and cannot do, using the queries from
# 'config' with Radiator's %-substitutions filled in.
scenario_pg_radiator() {
    run -b pg -d "$PGDB" init-pg >/dev/null
    csv example.csv <"$ROOT/users.example.csv"
    run -b pg -d "$PGDB" import example.csv >/dev/null
    pgq postgres "ALTER ROLE ${PGT}_radiator PASSWORD 'test-only';"

    as_radiator "select secret, active, userId, counter, low, high, password from yubikeys where username='test.user2' and tokenId='cbdefghijklr'"
    as_radiator "update yubikeys set accessed=to_timestamp(1791314814), counter=5, low=2, high=0 where username='test.user2' and tokenId='cbdefghijklr'"
    run -b pg -d "$PGDB" list test.user2

    as_radiator "update yubikeys set active=1 where username='test.user2'"
    as_radiator "insert into yubikeys (username, tokenId, userId, secret) values ('x', 'x', 'x', 'x')"
    as_radiator "delete from yubikeys"
    as_radiator "select * from yubikeys"

    # The management script refuses to run as Radiator's role.
    run_env PGHOST=127.0.0.1 PGUSER="${PGT}_radiator" PGPASSWORD=test-only -- -b pg -d "$PGDB" list
    run_env PGHOST=127.0.0.1 PGUSER="${PGT}_radiator" PGPASSWORD=test-only -- -b pg -d "$PGDB" disable test.user
}

# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------

ALL=(help init import import_formats import_errors add encodings modify permissions tools config
     pg_offline pg_init pg_import pg_add pg_encodings pg_modify pg_radiator)

# Scenarios that need a PostgreSQL server.
needs_pg() { [[ $1 == pg_* && $1 != pg_offline ]]; }

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
pass=0 fail=0 skip=0

# Scenarios pick their own databases, so ignore any set in the environment.
unset PGDATABASE PGSERVICE
if command -v psql >/dev/null; then
    pg_version=$(psql -X -d postgres -tAc 'SHOW server_version_num' 2>/dev/null)
    if [[ $pg_version =~ ^[0-9]+$ ]]; then
        if (( pg_version >= 180000 )); then PG_OK=1; else PG_SKIP_REASON="needs PostgreSQL 18 or later"; fi
    fi
fi

for name in "${SELECTED[@]}"; do
    declare -F "scenario_$name" >/dev/null || { echo "unknown scenario: $name" >&2; exit 2; }
    if needs_pg "$name" && [[ $PG_OK == 0 ]]; then
        echo "SKIP     $name ($PG_SKIP_REASON)"; skip=$((skip + 1)); continue
    fi
    rm -rf -- "$WORK" && mkdir -p "$WORK"
    DB=$WORK/yubicred.db
    actual=$TMPROOT/$name.out
    if needs_pg "$name"; then pg_cleanup; fi
    (
        cd "$WORK" || exit
        if needs_pg "$name"; then
            export PG_ADMIN_ROLE=${PGT}_admin PG_RADIATOR_ROLE=${PGT}_radiator
        fi
        "scenario_$name"
    ) 2>&1 | normalize >"$actual"
    if needs_pg "$name"; then pg_cleanup; fi

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
    echo "$pass passed, $fail failed, $skip skipped"
    [[ $fail -eq 0 ]]
fi
