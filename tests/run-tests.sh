#!/usr/bin/env bash
#
# run-tests.sh - Regression tests for yubikey-db.sh (and yubikey-anycast.sh).
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
# checks permission errors, which root bypasses). The verify scenarios also
# need openssl (to make test OTPs) and the Perl module Crypt::Rijndael, and
# are skipped without them; so are the anycast scenarios, which need the
# Perl module. The install scenario needs dpkg-deb, and is skipped without it.
#
# The pg_* and migrate_* scenarios (except *_offline) also need psql and a
# PostgreSQL 18 (or later) server that
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
MIGRATE=$ROOT/yubikey-db-migrate.sh
ANYCAST=$ROOT/yubikey-anycast.sh
PARTITION=$ROOT/yubikey-partition.sh
VERSION=$(cat "$ROOT/VERSION")
HOST_S=$(hostname -s | tr '[:upper:]' '[:lower:]')   # the anycast check's user is anycast-HOST_S
EXPECTED=$TESTS_DIR/expected
UPDATE=0
TMPROOT=       # per-run temp directory, removed on exit
WORK=          # scenario scratch directory under TMPROOT, emptied per scenario
PGT=yk_test_$$ # prefix for throwaway PostgreSQL databases and roles
PGDB=${PGT}_db
PG_OK=0        # 1 when a PostgreSQL 18+ server is reachable
OTP_OK=0       # 1 when openssl and Crypt::Rijndael are available
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

# Run yubikey-db-migrate.sh the same way: run_migrate [VAR=x ...] -- ARGS...
# (the -- is needed only with environment assignments)
run_migrate() {
    local -a envs=()
    if [[ " $* " == *" -- "* ]]; then
        while [[ $1 != -- ]]; do envs+=("$1"); shift; done
        shift
    fi
    local out rc=0
    out=$(env "${envs[@]}" "$MIGRATE" "$@" </dev/null 2>&1) || rc=$?
    printf '$ %syubikey-db-migrate.sh %s\n%s%s[exit %d]\n\n' "${envs[*]:+${envs[*]} }" "$*" "$out" "${out:+$'\n'}" "$rc"
}

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

# Same as run, with LINEs (CSV rows, or values to answer prompts) as standard
# input: run_lines LINE... -- ARGS...
run_lines() {
    local -a lines=()
    while [[ $1 != -- ]]; do lines+=("$1"); shift; done
    shift
    local out rc=0
    out=$(printf '%s\n' "${lines[@]}" | "$SCRIPT" "$@" 2>&1) || rc=$?
    printf '$ printf %%s\\n %s | yubikey-db.sh %s\n%s%s[exit %d]\n\n' "${lines[*]@Q}" "$*" "$out" "${out:+$'\n'}" "$rc"
}

# Same as run, with standard input from a file: run_from FILE ARGS...
run_from() {
    local in=$1 out rc=0
    shift
    out=$("$SCRIPT" "$@" <"$in" 2>&1) || rc=$?
    printf '$ yubikey-db.sh %s < %s\n%s%s[exit %d]\n\n' "$*" "${in##*/}" "$out" "${out:+$'\n'}" "$rc"
}

# Print the OTP a YubiKey programmed with these values would type:
# otp PUBLIC_ID PRIVATE_ID AES_KEY COUNTER SESSION. make-otp.sh encrypts it
# with openssl, independently of the Perl code that 'verify' decrypts it with.
otp() {
    "$TESTS_DIR/make-otp.sh" "$@"
}

# Copy the example wrapper to $WORK/user.sh with the given settings, mode 0700:
# make_wrapper NAME=VALUE... (e.g. cred_username=alice)
make_wrapper() {
    local -a edits=(-e "s|^yubikey_db=''|yubikey_db='$SCRIPT'|")
    local kv
    for kv in "$@"; do edits+=(-e "s|^${kv%%=*}=[^ ]*|${kv%%=*}='${kv#*=}'|"); done
    sed "${edits[@]}" "$ROOT/yubikey-db-user.example.sh" >"$WORK/user.sh"
    chmod 700 "$WORK/user.sh"
}

# Run the wrapper made by make_wrapper, with no terminal, and record it.
run_wrapper() {
    local out rc=0
    out=$("$WORK/user.sh" </dev/null 2>&1) || rc=$?
    printf '$ user.sh\n%s%s[exit %d]\n\n' "$out" "${out:+$'\n'}" "$rc"
}

# Print every row and column of the yubikeys table, so the test sees exactly
# what was stored (including secrets, which these test values are).
dump() {
    printf '# yubikeys table in %s\n' "${1##*/}"
    sqlite3 -batch -header -separator ' | ' "$1" \
        'SELECT username, password, active, typeof(active) AS active_type, created,
                accessed, tokenId, userId, secret, counter, low, high, label
           FROM yubikeys ORDER BY userId;'
    echo
}

schema() {
    printf '# schema of %s\n' "${1##*/}"
    sqlite3 -batch "$1" .schema
    echo
}

# Make a SQLite database as yubikey-db.sh 1.7.0 made it (no label column),
# with one used key: old_sqlite_db FILE
old_sqlite_db() {
    sqlite3 -batch "$1" <<'EOF'
CREATE TABLE yubikeys (
    username varchar(255) not null,
    password varchar(64)  not null,
    active   boolean default false,
    created  datetime not null,
    accessed datetime not null,
    tokenId  varchar(60) unique not null,   -- YubiKey public ID (modhex)
    userId   varchar(60) unique not null,   -- YubiKey private ID (hex)
    secret   varchar(60) not null,          -- AES key (base64 or hex)
    counter  int default 0,
    low      int default 0,
    high     int default 0,
    primary key (userId)
);
CREATE INDEX yubikeys_username ON yubikeys (username);
CREATE TRIGGER yubikeys_counters_forward
BEFORE UPDATE OF counter, low ON yubikeys
FOR EACH ROW WHEN NEW.counter < OLD.counter OR (NEW.counter = OLD.counter AND NEW.low <= OLD.low)
BEGIN
    SELECT RAISE(ABORT, 'counter violation: this YubiKey already used this OTP or a later one');
END;
INSERT INTO yubikeys VALUES ('olduser', '', 1, '2026-07-01 08:00:00', '2026-10-01 12:00:00', 'vvccccbbcdef',
    '4a6f8e2d1c3b', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 4, 1, 0);
EOF
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
                    to_char(accessed AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS accessed,
                    tokenId, userId, secret, counter, low, high, label
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
    printf '# triggers\n'
    pgtable "SELECT tgname, pg_get_triggerdef(oid) AS definition FROM pg_trigger
              WHERE tgrelid = 'yubikeys'::regclass AND NOT tgisinternal ORDER BY tgname;"
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

# created and accessed in UTC, in a format the timestamp placeholder does not
# replace, so the values themselves are checked. A created time set during
# the run shows as "now".
times_pg() {
    printf '# times in %s (UTC)\n' "$PGDB"
    pgtable "SELECT username,
                    CASE WHEN created > now() - interval '1 hour' THEN 'now'
                         ELSE to_char(created AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS') END AS created,
                    to_char(accessed AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS') AS accessed
               FROM yubikeys ORDER BY username;"
    echo
}

# Build src.db in the scratch directory as an existing SQLite installation:
# rows added by yubikey-db.sh (one already used, with counters), plus rows in
# the format of the old example statements.
make_source() {
    "$SCRIPT" -d "$WORK/src.db" init >/dev/null 2>&1
    csv example.csv <"$ROOT/users.example.csv"
    "$SCRIPT" -d "$WORK/src.db" import example.csv >/dev/null
    sqlite3 "$WORK/src.db" <<'EOF'
UPDATE yubikeys SET created = '2026-07-01 08:00:00';
UPDATE yubikeys SET counter = 40, low = 7, accessed = '2026-10-01 12:00:00' WHERE username = 'test.user';
-- old example format: text active, literal created, hex key, modhex private ID, plaintext PIN
INSERT INTO yubikeys VALUES ('olduser', 'plainpin', 'true', 'current_timestamp', '2026-09-01 10:00:00',
    'vvccccbbcdef', 'tttttttttttt', '00112233445566778899AABBCCDDEEFF', 12, 3, 0, '');
-- NULL active and counters
INSERT INTO yubikeys VALUES ('nulluser', '', NULL, '2026-08-01 08:00:00', '',
    'vvccccbbcdeg', 'cccccccccccd', '0f1e2d3c4b5a69788796a5b4c3d2e1f0', NULL, NULL, NULL, 'nulls, from an old tool');
EOF
}

# Run SQL as the Radiator role over TCP, the way Radiator connects from
# another host, and record the output: as_radiator SQL
# Run one SQL statement on the SQLite database and print it, its output and
# its exit status: as_sqlite SQL
as_sqlite() {
    local out rc=0
    out=$(sqlite3 -batch "$DB" "$1" 2>&1) || rc=$?
    printf '$ sqlite> %s\n%s%s[exit %d]\n\n' "$1" "$out" "${out:+$'\n'}" "$rc"
}

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

# Replace values that differ between runs with fixed placeholders (and the
# version, so that a new one changes no transcript).
# shellcheck disable=SC2016  # the $ signs in the sed patterns are literal
normalize() {
    sed -E \
        -e "s/^([a-z-]+\.sh) ${VERSION//./\\.}\$/\1 <VERSION>/" \
        -e "s|$WORK|<WORK>|g" \
        -e "s|$ROOT|<ROOT>|g" \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/<TIMESTAMP>/g' \
        -e 's/\{crypt\}\$6\$[^ |,]*/{crypt}$6$<HASH>/g' \
        -e 's/(if Radiator does not run as) [^ ]+$/\1 <USER>/' \
        -e "s/$PGT/<T>/g" \
        -e 's/connection to server .* failed:/connection to server <SERVER> failed:/' \
        -e "s/\(is $(id -un) a member of/(is <USER> a member of/" \
        -e "s/anycast-$HOST_S\b/anycast-<HOST>/g" \
        -e 's/ in [0-9]+ ms/ in <N> ms/g' \
        -e 's/(does not listen on .*) port [0-9]+/\1 port <PORT>/'
}

# --------------------------------------------------------------------------
# Scenarios. Each function runs in the scratch directory with DB set to a
# fresh database path that does not exist yet.
# --------------------------------------------------------------------------

# add --update and import --update: a YubiKey already in the database keeps
# its times and counters when its private ID and AES key are unchanged, and
# is replaced (counters reset) when they changed. Also import from stdin.
scenario_update() {
    local k1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d k2=0f1e2d3c4b5a69788796a5b4c3d2e1f0
    local header=username,public_id,private_id,aes_key,password,active
    run -d "$DB" init >/dev/null

    # Not in the database yet: added.
    run -d "$DB" add --update -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 -w 's3cr3t'
    sqlite3 "$DB" "UPDATE yubikeys SET counter = 7, low = 3, high = 1, created = '2026-07-01 08:00:00', accessed = '2026-10-01 12:00:00';"

    # The same YubiKey with a new password and inactive: counters and times kept.
    run -d "$DB" add --update -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 -w 'n3w' --inactive
    check_crypt "$DB" alice 'n3w'
    times_sqlite "$DB"
    # Under another username, stored as hex this time: still the same YubiKey.
    run -d "$DB" -e hex add --update -u alice.b -P VVCCCCBBCDEF -p 4A6F8E2D1C3B -k ${k1^^} --no-password
    dump "$DB"
    # And back to base64: the hex key it finds is the same key.
    run -d "$DB" add --update -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 --no-password
    dump "$DB"
    # Reprogrammed with a new AES key: replaced, counters and times reset.
    run -d "$DB" add --update -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k2 --no-password
    dump "$DB"
    times_sqlite "$DB"

    # From standard input: a new key, an unchanged one (with counters), and
    # one reprogrammed with a new private ID. Only the changed rows report.
    "$SCRIPT" -d "$DB" add -u bob -P vvccccbbcdeg -p 4a6f8e2d1c3c -k $k1 --no-password >/dev/null
    "$SCRIPT" -d "$DB" add -u carol -P vvccccbbcdeh -p 4a6f8e2d1c3d -k $k1 --no-password >/dev/null
    sqlite3 "$DB" "UPDATE yubikeys SET counter = 5, low = 1 WHERE username IN ('bob', 'carol');"
    run_lines "$header" "bob,vvccccbbcdeg,4a6f8e2d1c3c,$k1,pw,1" "carol,vvccccbbcdeh,999999999999,$k1,,1" \
              "dave,vvccccbbcdei,4a6f8e2d1c3e,$k1,,1" -- -d "$DB" import --update -
    dump "$DB"
    # Without --update the same rows are refused, and nothing changes.
    run_lines "bob,vvccccbbcdeg,4a6f8e2d1c3c,$k1,other,0" "erin,vvccccbbcdej,4a6f8e2d1c3f,$k1" -- -d "$DB" import -
    run_lines "erin,vvccccbbcdej,4a6f8e2d1c3f,$k1" -- -d "$DB" import --dry-run -
    run -d "$DB" list

    # Onboarding takes only 12-character public IDs, which is all Radiator
    # reads from a login.
    run -d "$DB" add -u frank -P vvccccbbcdefgh -p 4a6f8e2d1c40 -k $k1 --no-password
    run_lines "frank,vvccccbbcd,4a6f8e2d1c40,$k1" -- -d "$DB" import --dry-run -

    run -d "$DB" add --update --replace -u x
    run -d "$DB" import --replace --update x.csv
    run -d "$DB" import --update --from-export x.csv
    run -d "$DB" import -x

    # An export restored from standard input.
    "$SCRIPT" -d "$DB" export all.csv >/dev/null 2>&1
    "$SCRIPT" -d "$WORK/restored.db" init >/dev/null 2>&1
    run_from all.csv -d "$WORK/restored.db" import --from-export -
    "$SCRIPT" -d "$WORK/restored.db" export restored.csv >/dev/null 2>&1
    compare_exports all.csv restored.csv
}

# Counters only move forward. Each statement is Radiator's UpdateQuery from
# 'config' with an OTP's counter and session counter filled in.
scenario_counters() {
    local q="update yubikeys set accessed=datetime(1791314814,'unixepoch'), high=0"
    local k="where username='alice' and tokenId='vvccccbbcdef'"
    run -d "$DB" init >/dev/null
    run -d "$DB" add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d -w s3cr3t >/dev/null
    as_sqlite "$q, counter=5, low=2 $k"     # saved
    as_sqlite "$q, counter=5, low=2 $k"     # the same OTP again: refused
    as_sqlite "$q, counter=5, low=1 $k"     # an older OTP: refused
    as_sqlite "$q, counter=4, low=9 $k"     # refused
    as_sqlite "$q, counter=5, low=3 $k"     # saved
    as_sqlite "update yubikeys set active=0 $k"   # other columns: not affected
    dump "$DB"
    # A database made before 1.2.1 has no trigger: init adds it.
    sqlite3 "$DB" "DROP TRIGGER yubikeys_counters_forward;"
    as_sqlite "$q, counter=5, low=3 $k"
    run -d "$DB" init
    as_sqlite "$q, counter=5, low=3 $k"
}

scenario_verify() {
    local k1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d k2=0f1e2d3c4b5a69788796a5b4c3d2e1f0 ssha
    run -d "$DB" init >/dev/null
    "$SCRIPT" -d "$DB" add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 -w 's3cr3t' >/dev/null
    "$SCRIPT" -d "$DB" add -u alice -P vvccccbbcdeg -p 4a6f8e2d1c3c -k $k2 -w 's3cr3t' -l 'spare, slot 2' >/dev/null
    "$SCRIPT" -d "$DB" -e hex add -u bob -P vvccccbbcdeh -p 4a6f8e2d1c3d -k $k2 --no-password >/dev/null
    "$SCRIPT" -d "$DB" add -u carol -P vvccccbbcdei -p 4a6f8e2d1c3e -k $k1 -w 's3cr3t' --inactive >/dev/null
    "$SCRIPT" -d "$DB" -H clear add -u dave -P vvccccbbcdej -p 4a6f8e2d1c3f -k $k1 -w '{weird}pw' >/dev/null
    "$SCRIPT" -d "$DB" -H clear add -u erin -P vvccccbbcdek -p 4a6f8e2d1c40 -k $k1 -w 'plain pw' >/dev/null
    # The sample OTP from Yubico's libyubikey README, which was not made by otp():
    # it decrypts to private ID 8792ebfe26cc, counter 19, session 17. Its public
    # ID has 8 characters, so it is still rejected, as Radiator rejects it. The
    # row is inserted directly, since 'add' takes only 12-character public IDs.
    sqlite3 "$DB" "INSERT INTO yubikeys VALUES ('yubico', '', 1, '2026-07-01 08:00:00', '', 'dteffuje',
        '8792ebfe26cc', 'ecde18dbe76fbd0c33330f1c354871db', 0, 0, 0, '');"
    run_lines '' dteffujehknhfjbrjnlnldnhcujvddbikngjrtgh -- -d "$DB" verify -u yubico --no-require2factor

    # Accepted; the counters are saved, so the same OTP is then a replay.
    run_lines 's3cr3t' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 3 1)" -- -d "$DB" verify -u alice
    run_lines 's3cr3t' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 3 1)" -- -d "$DB" verify -u alice
    run_lines 's3cr3t' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 2 9)" -- -d "$DB" verify -u alice
    # The next OTP in the same session, and the username read from stdin too.
    run_lines alice 's3cr3t' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 3 2)" -- -d "$DB" verify
    # Wrong password, or none: rejected, and the counters do not move.
    run_lines 'wrong' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 4 0)" -- -d "$DB" verify -u alice
    run_lines '' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 4 0)" -- -d "$DB" verify -u alice
    # Wrong AES key, wrong private ID, another of alice's keys.
    run_lines 's3cr3t' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k2 9 0)" -- -d "$DB" verify -u alice
    run_lines 's3cr3t' "$(otp vvccccbbcdef 111111111111 $k1 9 0)" -- -d "$DB" verify -u alice
    run_lines 's3cr3t' "$(otp vvccccbbcdeg 4a6f8e2d1c3c $k2 1 0)" -- -d "$DB" verify -u alice
    # The counter's top bit only says how the OTP was triggered: 0x8005 is 5.
    run_lines 's3cr3t' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 $((0x8005)) 0)" -- -d "$DB" verify -u alice
    dump "$DB"

    # No stored password (key stored as hex): rejected with Require2Factor.
    # Without it the OTP alone is enough, even for alice, who has a password,
    # but a password that is entered is still checked.
    run_lines '' "$(otp vvccccbbcdeh 4a6f8e2d1c3d $k2 1 0)" -- -d "$DB" verify -u bob
    run_lines '' "$(otp vvccccbbcdeh 4a6f8e2d1c3d $k2 1 0)" -- -d "$DB" verify -u bob --no-require2factor
    run_lines 'extra' "$(otp vvccccbbcdeh 4a6f8e2d1c3d $k2 2 0)" -- -d "$DB" verify -u bob --no-require2factor
    run_lines '' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 6 0)" -- -d "$DB" verify -u alice --no-require2factor
    # active=0 disables a key; the text 'false' does not.
    run_lines 's3cr3t' "$(otp vvccccbbcdei 4a6f8e2d1c3e $k1 1 0)" -- -d "$DB" verify -u carol
    sqlite3 "$DB" "UPDATE yubikeys SET active = 'false' WHERE username = 'carol';"
    run_lines 's3cr3t' "$(otp vvccccbbcdei 4a6f8e2d1c3e $k1 1 0)" -- -d "$DB" verify -u carol
    # A {clear} password; a plain-text password.
    run_lines '{weird}pw' "$(otp vvccccbbcdej 4a6f8e2d1c3f $k1 1 0)" -- -d "$DB" verify -u dave
    run_lines 'plain pw' "$(otp vvccccbbcdek 4a6f8e2d1c40 $k1 1 0)" -- -d "$DB" verify -u erin
    # An {SSHA} password and a NULL counter; a format the check cannot read; a
    # broken key.
    ssha=$(perl -MDigest::SHA=sha1 -MMIME::Base64 -e 'print "{SSHA}", encode_base64(sha1("anything" . "NaCl") . "NaCl", "")')
    sqlite3 "$DB" "UPDATE yubikeys SET password = '$ssha', counter = NULL WHERE username = 'dave';
                   UPDATE yubikeys SET secret = 'not-a-key' WHERE username = 'erin';"
    run_lines 'wrong' "$(otp vvccccbbcdej 4a6f8e2d1c3f $k1 1 0)" -- -d "$DB" verify -u dave
    run_lines 'anything' "$(otp vvccccbbcdej 4a6f8e2d1c3f $k1 1 0)" -- -d "$DB" verify -u dave
    sqlite3 "$DB" "UPDATE yubikeys SET password = '{nthash}0123456789abcdef0123456789abcdef' WHERE username = 'dave';"
    run_lines 'anything' "$(otp vvccccbbcdej 4a6f8e2d1c3f $k1 2 0)" -- -d "$DB" verify -u dave
    run_lines 'plain pw' "$(otp vvccccbbcdek 4a6f8e2d1c40 $k1 2 0)" -- -d "$DB" verify -u erin

    # Unknown user, a key that is not the user's, and a user without that key.
    run_lines '' "$(otp vvccccbbcdeh 4a6f8e2d1c3d $k2 5 0)" -- -d "$DB" verify -u nobody
    run_lines '' "$(otp vvccccbbcdeh 4a6f8e2d1c3d $k2 5 0)" -- -d "$DB" verify -u alice
    run_lines '' "$(otp vvccccbbcdel 4a6f8e2d1c41 $k2 5 0)" -- -d "$DB" verify -u alice
    # Not an OTP (not echoed back), no input, a bad option, no database.
    run_lines 's3cr3t' 's3cr3t' -- -d "$DB" verify -u alice
    run_lines 's3cr3t' "$(otp '' 4a6f8e2d1c3b $k1 5 0)" -- -d "$DB" verify -u alice
    run -d "$DB" verify -u alice
    run -d "$DB" verify --bogus
    run -d "$WORK/none.db" verify -u alice
    dump "$DB"
}

# The example wrapper: add, update (counters kept), reprogram (counters
# reset), and the values it refuses.
scenario_wrapper() {
    local k1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d k2=0f1e2d3c4b5a69788796a5b4c3d2e1f0
    local -a rec=(cred_username=test.user cred_publicid=vvccccbbcdef cred_privateid=4a6f8e2d1c3b db_name="$DB")
    run -d "$DB" init >/dev/null
    make_wrapper "${rec[@]}" cred_secret=$k1 cred_password=abc123
    run_wrapper
    check_crypt "$DB" test.user abc123
    sqlite3 "$DB" "UPDATE yubikeys SET counter = 7, low = 3, accessed = '2026-10-01 12:00:00';"
    make_wrapper "${rec[@]}" cred_secret=$k1 cred_password=n3w cred_active=0 'cred_label=spare slot 2'
    run_wrapper
    check_crypt "$DB" test.user n3w
    make_wrapper "${rec[@]}" cred_secret=$k2
    run_wrapper
    dump "$DB"

    make_wrapper "${rec[@]}"
    run_wrapper
    make_wrapper "${rec[@]}" cred_secret=$k1 cred_password=a,b
    run_wrapper
    make_wrapper "${rec[@]}" cred_secret=$k1 'cred_password="quoted"'
    run_wrapper
    make_wrapper "${rec[@]}" cred_secret=$k1 'cred_label=spare, slot 2'
    run_wrapper
    make_wrapper "${rec[@]}" cred_secret=$k1 require2factor=maybe
    run_wrapper
    make_wrapper "${rec[@]}" cred_secret=bad-key
    chmod 744 "$WORK/user.sh"
    run_wrapper
    make_wrapper "${rec[@]}" cred_secret=$k1 db_name="$WORK/none.db"
    run_wrapper
    dump "$DB"
}

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
ok6,vvccccbbcdei,4a6f8e2d1c3e,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,pw,1,label,extra
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

# Rows for the export scenarios: keys stored as base64 and as hex, a
# {crypt} password, a clear password with a comma and a quote, an inactive
# key, and a key that has been used (counters and accessed set).
export_rows() {
    local -a b=("$@")    # backend options, e.g. -b pg -d DB
    csv example.csv <"$ROOT/users.example.csv"
    "$SCRIPT" "${b[@]}" import example.csv >/dev/null
    "$SCRIPT" "${b[@]}" -e hex -H clear add -u comma.user -P vvccccbbcdef -p cccccccccccb \
        -k 00112233445566778899AABBCCDDEEFF -w 'a,b"c' --inactive </dev/null >/dev/null
}

scenario_export() {
    run -d "$DB" export out.csv
    run -d "$DB" init >/dev/null
    run -d "$DB" export empty.csv
    cat empty.csv; echo

    export_rows -d "$DB"
    sqlite3 "$DB" "UPDATE yubikeys SET counter = 40, low = 7, high = 1, accessed = '2026-10-01 12:00:00' WHERE username = 'test.user';"
    run -d "$DB" export out.csv
    stat -c '# out.csv mode %a' out.csv
    cat out.csv; echo
    check_crypt "$DB" test.user abc123

    run -d "$DB" export out.csv
    run -d "$DB" export --force out.csv
    run -d "$DB" export -
    run -d "$DB" export
    run -d "$DB" export a.csv b.csv
    run -d "$DB" export --bogus x.csv
    run -d "$DB" export "$WORK"
    run -d "$DB" export "$WORK/missing/x.csv"
    local -a leftovers=(.yubikey-export.*)
    [[ -e ${leftovers[0]} ]] || leftovers=()
    printf '# temporary files left: %d\n\n' "${#leftovers[@]}"

    # A stored key that is neither hex nor base64 is exported as it is.
    sqlite3 "$DB" "UPDATE yubikeys SET secret = 'not-a-key' WHERE username = 'test.user2';"
    run -d "$DB" export -
}

# A database to restore from: the export rows, a used key, a key in the old
# example format, and a username that onboarding import would not accept.
restore_source() {
    "$SCRIPT" -d "$WORK/src.db" init >/dev/null 2>&1
    export_rows -d "$WORK/src.db"
    sqlite3 "$WORK/src.db" "UPDATE yubikeys SET counter = 40, low = 7, high = 1, accessed = '2026-10-01 12:00:00', created = '2026-07-01 08:00:00' WHERE username = 'test.user';
        INSERT INTO yubikeys VALUES ('DOMAIN\\old user', 'plainpin', 'true', 'current_timestamp', '2026-09-01 10:00:00',
            'vvccccbbcdeg', 'tttttttttttt', '00112233445566778899AABBCCDDEEFF', 12, 3, 0, 'old, \"quoted\" key');"
    "$SCRIPT" -d "$WORK/src.db" export source.csv >/dev/null 2>&1
}

# Compare two export files, with times masked (a time set to "now" during the
# run can differ by a second); times_sqlite and times_pg check times exactly.
compare_exports() {
    printf '# %s vs %s (times masked): ' "$1" "$2"
    if cmp -s <(normalize <"$1") <(normalize <"$2"); then
        echo identical
    else
        echo differs:; diff <(normalize <"$1") <(normalize <"$2")
    fi
    echo
}

# SQLite counterpart of times_pg: created and accessed exactly, in a format the
# timestamp placeholder does not replace; a time set during the run is "now".
times_sqlite() {
    printf '# times in %s (UTC)\n' "${1##*/}"
    sqlite3 -batch -header -separator ' | ' "$1" \
        "SELECT username,
                CASE WHEN created >= datetime('now', '-1 hour') THEN 'now' ELSE replace(created, ' ', 'T') END AS created,
                replace(accessed, ' ', 'T') AS accessed
           FROM yubikeys ORDER BY username;"
    echo
}

scenario_restore() {
    restore_source
    cat source.csv; echo
    run -d "$DB" init >/dev/null

    # The default import is for onboarding and does not take an export.
    run -d "$DB" import source.csv

    run -d "$DB" import --from-export --dry-run source.csv
    run -d "$DB" import --from-export source.csv
    check_crypt "$DB" test.user abc123
    times_sqlite "$DB"
    "$SCRIPT" -d "$DB" export restored.csv >/dev/null 2>&1
    # Identical except the old-format row, which import normalizes.
    compare_exports source.csv restored.csv

    # Without --replace, existing keys make the whole restore fail.
    run -d "$DB" import --from-export source.csv

    # With --replace, the export's values come back, but counters never move
    # backward: test.user is ahead in the database (99/1) and keeps it;
    # the old-format key is behind (2/0) and gets the export's 12/3.
    # Moving a counter back needs the trigger out of the way (it exists to
    # refuse exactly that); init puts it back.
    sqlite3 "$DB" "DROP TRIGGER yubikeys_counters_forward;
        UPDATE yubikeys SET counter = 99, low = 1, accessed = '2026-10-12 11:00:00' WHERE username = 'test.user';
        UPDATE yubikeys SET counter = 2, low = 0 WHERE username = 'DOMAIN\\old user';
        UPDATE yubikeys SET password = 'changed', active = 0 WHERE username = 'test.user2';"
    "$SCRIPT" -d "$DB" init >/dev/null 2>&1
    run -d "$DB" import --from-export --replace source.csv
    dump "$DB"
    times_sqlite "$DB"
    "$SCRIPT" -d "$DB" export replaced.csv >/dev/null 2>&1
    compare_exports restored.csv replaced.csv
}

scenario_restore_errors() {
    run -d "$DB" init >/dev/null
    local header=username,public_id,private_id,aes_key,password,active,created,accessed,counter,low,high
    csv onboarding.csv <"$ROOT/users.example.csv"
    run -d "$DB" import --from-export onboarding.csv
    csv empty.csv </dev/null
    run -d "$DB" import --from-export empty.csv
    printf '%s\nalice,vvccccbbcdef,4a6f8e2d1c3b,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,"unterminated,1,,,0,0,0\n' "$header" >bad1.csv
    run -d "$DB" import --from-export bad1.csv
    printf '%s\nalice,vvccccbbcdef,4a6f8e2d1c3b,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,pass"word,1,,,0,0,0\n' "$header" >bad2.csv
    run -d "$DB" import --from-export bad2.csv

    {
        echo "$header"
        echo 'ok1,vvccccbbcdef,4a6f8e2d1c3b,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,,1,2026-07-01 08:00:00,,0,0,0'
        echo 'short,vvccccbbcdeg,4a6f8e2d1c3c'
        printf 'bell\a,vvccccbbcdeh,4a6f8e2d1c3d,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,,1,,,0,0,0\n'
        echo 'badkey,vvccccbbcdei,4a6f8e2d1c3e,ASNFZ4mrze8BI0VniavN7w==,,1,,,0,0,0'
        echo 'badcount,vvccccbbcdej,4a6f8e2d1c3f,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,,1,,,x,0,0'
        echo 'dup,vvccccbbcdef,4a6f8e2d1c40,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,,1,,,0,0,0'
        echo 'badtimes,vvccccbbcdek,4a6f8e2d1c41,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,,1,2026-13-01 00:00:00,yesterday,5,1,0'
        # quoted fields: a comma, a doubled quote and a line break; Windows line ending
        printf 'multi,vvccccbbcdel,4a6f8e2d1c42,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,"line1\nline2, ""q""",0,2026-07-01 08:00:00,2026-10-01 12:00:00,3,2,0\r\n'
    } >mixed.csv
    chmod 600 mixed.csv
    run -d "$DB" import --from-export mixed.csv
    run -d "$DB" import --from-export --skip-invalid mixed.csv
    dump "$DB"
}

scenario_pg_restore() {
    restore_source
    run -b pg -d "$PGDB" init-pg >/dev/null
    # A SQLite export restored into PostgreSQL, then exported again.
    run -b pg -d "$PGDB" import --from-export source.csv
    check_crypt_pg test.user abc123
    "$SCRIPT" -b pg -d "$PGDB" export restored.csv >/dev/null 2>&1
    compare_exports source.csv restored.csv
    times_pg

    pgq "$PGDB" "ALTER TABLE yubikeys DISABLE TRIGGER yubikeys_counters_forward;
        UPDATE yubikeys SET counter = 99, low = 1, accessed = '2026-10-12 11:00:00+00' WHERE username = 'test.user';
        UPDATE yubikeys SET counter = 2, low = 0 WHERE username = 'DOMAIN\\old user';
        UPDATE yubikeys SET password = 'changed', active = 0 WHERE username = 'test.user2';
        ALTER TABLE yubikeys ENABLE TRIGGER yubikeys_counters_forward;"
    run -b pg -d "$PGDB" import --from-export --replace source.csv
    dump_pg
    times_pg
}

scenario_pg_update() {
    local k1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d k2=0f1e2d3c4b5a69788796a5b4c3d2e1f0
    run -b pg -d "$PGDB" init-pg >/dev/null
    run -b pg -d "$PGDB" add --update -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 -w 's3cr3t'
    pgq "$PGDB" "UPDATE yubikeys SET counter = 7, low = 3, high = 1, created = '2026-07-01 08:00:00+00', accessed = '2026-10-01 12:00:00+00';"
    run -b pg -d "$PGDB" add --update -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 -w 'n3w' --inactive
    check_crypt_pg alice 'n3w'
    run -b pg -d "$PGDB" -e hex add --update -u alice.b -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 --no-password
    dump_pg
    times_pg
    run -b pg -d "$PGDB" add --update -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k2 --no-password
    dump_pg
    times_pg

    "$SCRIPT" -b pg -d "$PGDB" add -u bob -P vvccccbbcdeg -p 4a6f8e2d1c3c -k $k1 --no-password >/dev/null
    "$SCRIPT" -b pg -d "$PGDB" add -u carol -P vvccccbbcdeh -p 4a6f8e2d1c3d -k $k1 --no-password >/dev/null
    pgq "$PGDB" "UPDATE yubikeys SET counter = 5, low = 1 WHERE username IN ('bob', 'carol');"
    run_lines username,public_id,private_id,aes_key,password,active "bob,vvccccbbcdeg,4a6f8e2d1c3c,$k1,pw,1" \
              "carol,vvccccbbcdeh,999999999999,$k1,,1" "dave,vvccccbbcdei,4a6f8e2d1c3e,$k1,,1" \
              -- -b pg -d "$PGDB" import --update -
    dump_pg
    run_lines "bob,vvccccbbcdeg,4a6f8e2d1c3c,$k1,other,0" "erin,vvccccbbcdej,4a6f8e2d1c3f,$k1" -- -b pg -d "$PGDB" import -
    run -b pg -d "$PGDB" list

    # The example wrapper, against PostgreSQL.
    make_wrapper cred_username=bob cred_publicid=vvccccbbcdeg cred_privateid=4a6f8e2d1c3c cred_secret=$k1 \
                 cred_password=wrapped db_backend=pg db_name="$PGDB"
    run_wrapper
    check_crypt_pg bob wrapped
}

scenario_pg_verify() {
    local k1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
    run -b pg -d "$PGDB" init-pg >/dev/null
    "$SCRIPT" -b pg -d "$PGDB" add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 -w 's3cr3t' >/dev/null
    "$SCRIPT" -b pg -d "$PGDB" add -u carol -P vvccccbbcdei -p 4a6f8e2d1c3e -k $k1 --no-password --inactive >/dev/null
    run_lines 's3cr3t' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 3 1)" -- -b pg -d "$PGDB" verify -u alice
    run_lines 's3cr3t' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 3 1)" -- -b pg -d "$PGDB" verify -u alice
    run_lines 'wrong' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 4 0)" -- -b pg -d "$PGDB" verify -u alice
    run_lines '' "$(otp vvccccbbcdei 4a6f8e2d1c3e $k1 1 0)" -- -b pg -d "$PGDB" verify -u carol
    dump_pg
    # Radiator's login role cannot run it (it cannot read the table in full).
    pgq postgres "ALTER ROLE ${PGT}_radiator PASSWORD 'test-only';"
    local out rc=0
    out=$(printf '%s\n' 's3cr3t' "$(otp vvccccbbcdef 4a6f8e2d1c3b $k1 5 0)" \
            | PGHOST=127.0.0.1 PGUSER="${PGT}_radiator" PGPASSWORD=test-only "$SCRIPT" -b pg -d "$PGDB" verify -u alice 2>&1) || rc=$?
    printf '$ (as radiator) yubikey-db.sh -b pg -d <T>_db verify -u alice\n%s\n[exit %d]\n\n' "$out" "$rc"
}

scenario_pg_export() {
    run -b pg -d "$PGDB" init-pg >/dev/null
    export_rows -b pg -d "$PGDB"
    pgq "$PGDB" "UPDATE yubikeys SET counter = 40, low = 7, high = 1, accessed = '2026-10-01 12:00:00+00' WHERE username = 'test.user';"
    run -b pg -d "$PGDB" export out.csv
    stat -c '# out.csv mode %a' out.csv
    cat out.csv; echo
    run -b pg -d "$PGDB" export -
    # Radiator's login role cannot export.
    pgq postgres "ALTER ROLE ${PGT}_radiator PASSWORD 'test-only';"
    run_env PGHOST=127.0.0.1 PGUSER="${PGT}_radiator" PGPASSWORD=test-only -- -b pg -d "$PGDB" export radiator.csv
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
               'PGHOST=db.example.com PGPORT=6432 PGSSLMODE=require' \
               'PGHOST=db.example.com PGSSLROOTCERT=/etc/radiator/pg-ca.crt' PGSERVICE=yubikey \
               'PGSERVICE=yubikey PGDATABASE=radius' PG_RADIATOR_ROLE=radiusd \
               'PGHOST=db1.example.com,db2.example.com PGSSLROOTCERT=/etc/radiator/pg-ca.crt' \
               'PGHOST=db1,db2 PGCONNECT_TIMEOUT=3 PGTARGETSESSIONATTRS=primary' PGCONNECT_TIMEOUT=0; do
        read -ra assignments <<<"$env"
        printf '$ %s yubikey-db.sh -b pg config | grep -E "DB|ConnectTimeout"\n' "$env"
        env "${assignments[@]}" "$SCRIPT" -b pg config 2>&1 | grep -E '^ +(DB(Source|Username)|ConnectTimeout)|error'
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

    # Counters only move forward: the same OTP saved twice (two logins at
    # the same moment), or an older one, is refused.
    as_radiator "update yubikeys set accessed=to_timestamp(1791314815), counter=5, low=2, high=0 where username='test.user2' and tokenId='cbdefghijklr'"
    as_radiator "update yubikeys set accessed=to_timestamp(1791314815), counter=4, low=9, high=0 where username='test.user2' and tokenId='cbdefghijklr'"
    as_radiator "update yubikeys set accessed=to_timestamp(1791314815), counter=5, low=3, high=0 where username='test.user2' and tokenId='cbdefghijklr'"
    # A database made before 1.2.1 has no trigger: init adds it.
    pgq "$PGDB" "DROP TRIGGER yubikeys_counters_forward ON yubikeys;"
    as_radiator "update yubikeys set counter=5, low=3 where username='test.user2' and tokenId='cbdefghijklr'"
    run -b pg -d "$PGDB" init
    as_radiator "update yubikeys set counter=5, low=3 where username='test.user2' and tokenId='cbdefghijklr'"

    as_radiator "update yubikeys set active=1 where username='test.user2'"
    as_radiator "insert into yubikeys (username, tokenId, userId, secret) values ('x', 'x', 'x', 'x')"
    as_radiator "delete from yubikeys"
    as_radiator "select * from yubikeys"

    # The management script refuses to run as Radiator's role.
    run_env PGHOST=127.0.0.1 PGUSER="${PGT}_radiator" PGPASSWORD=test-only -- -b pg -d "$PGDB" list
    run_env PGHOST=127.0.0.1 PGUSER="${PGT}_radiator" PGPASSWORD=test-only -- -b pg -d "$PGDB" disable test.user
}

# Labels: set by add, import (the 7th field) and label; kept by --update and
# --replace when none is given; listed, exported and restored. A database made
# before 1.8.0 gets the label column from init.
scenario_labels() {
    local k1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d k2=0f1e2d3c4b5a69788796a5b4c3d2e1f0
    local old_header=username,public_id,private_id,aes_key,password,active,created,accessed,counter,low,high
    run -d "$DB" init >/dev/null
    run -d "$DB" add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 --no-password -l 'primary, slot 1'
    run -d "$DB" add -u alice -P vvccccbbcdeg -p 4a6f8e2d1c3c -k $k2 --no-password
    csv labels.csv <<'EOF'
username,public_id,private_id,aes_key,password,active,label
bob,vvccccbbcdeh,4a6f8e2d1c3d,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,,1,  "spare slot 2"
bob,vvccccbbcdei,4a6f8e2d1c3e,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,,,clé de secours
carol,vvccccbbcdej,4a6f8e2d1c3f,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
EOF
    run -d "$DB" import labels.csv
    run -d "$DB" list
    run -d "$DB" list bob

    # One YubiKey of one user at a time; '' removes the label.
    run -d "$DB" label alice VVCCCCBBCDEG "alice's backup, slot 2"
    run -d "$DB" label carol vvccccbbcdej 'loaner'
    run -d "$DB" label carol vvccccbbcdej ''
    run -d "$DB" label bob vvccccbbcdef 'not bob'"'"'s'
    run -d "$DB" label nobody vvccccbbcdef x
    run -d "$DB" label alice vvccccbbcdef "x' OR '1'='1"
    run -d "$DB" label alice vvccccbbcdef "$(printf '%0255d' 0)"
    run -d "$DB" label alice vvccccbbcdef "$(printf '%0256d' 0)"
    run -d "$DB" label alice vvccccbbcdef $'tab\there'
    run -d "$DB" label alice vvccccbbcdef
    run -d "$DB" label alice vvccccbbcdef a b
    run -d "$WORK/none.db" label alice vvccccbbcdef x
    run -d "$DB" label alice vvccccbbcdef 'primary, slot 1'
    dump "$DB"

    # Without a label, --update and --replace keep the YubiKey's label, also
    # when its keys changed; a label that is given replaces it.
    sqlite3 "$DB" "UPDATE yubikeys SET counter = 5, low = 1 WHERE username IN ('alice', 'bob');"
    run -d "$DB" add --update -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 -w 'n3w'
    run -d "$DB" add --replace -u alice -P vvccccbbcdeg -p 4a6f8e2d1c3c -k $k2 --no-password
    run_lines "bob,vvccccbbcdeh,999999999999,$k1,,0" "bob,vvccccbbcdei,4a6f8e2d1c3e,$k1,,1,new label" \
              -- -d "$DB" import --update -
    run -d "$DB" add --update -u carol -P vvccccbbcdej -p 4a6f8e2d1c3f -k $k1 --no-password -l 'loaner, returned'
    dump "$DB"

    # Invalid labels in a CSV file.
    {
        printf 'dave,vvccccbbcdek,4a6f8e2d1c40,%s,,1,bell\a\n' $k1
        printf 'erin,vvccccbbcdel,4a6f8e2d1c41,%s,,1,bad \xff byte\n' $k1
        printf 'frank,vvccccbbcdeu,4a6f8e2d1c42,%s,,1,%0256d\n' $k1 0
        printf 'gina,vvccccbbcden,4a6f8e2d1c43,%s,,1,a,b\n' $k1
    } >bad.csv
    chmod 600 bad.csv
    run -d "$DB" import --dry-run bad.csv

    # Export and restore keep the labels.
    run -d "$DB" export -
    "$SCRIPT" -d "$DB" export all.csv >/dev/null 2>&1
    "$SCRIPT" -d "$WORK/restored.db" init >/dev/null 2>&1
    run -d "$WORK/restored.db" import --from-export all.csv
    "$SCRIPT" -d "$WORK/restored.db" export restored.csv >/dev/null 2>&1
    compare_exports all.csv restored.csv

    # An export made before 1.8.0 (no label column) still restores; with
    # --replace, the YubiKeys keep their labels.
    printf '%s\n' "$old_header" "alice,vvccccbbcdef,4a6f8e2d1c3b,$k1,,1,2026-07-01 08:00:00,,9,0,0" \
        "henry,vvccccbbcder,4a6f8e2d1c44,$k1,,1,2026-07-01 08:00:00,,0,0,0" \
        "ivan,vvccccbbcdet,4a6f8e2d1c45,$k1,,1,2026-07-01 08:00:00,,0,0,0,a label" >old-export.csv
    chmod 600 old-export.csv
    run -d "$DB" import --from-export --replace old-export.csv
    run -d "$DB" import --from-export --replace --skip-invalid old-export.csv
    run -d "$DB" list

    # A database made before 1.8.0: the commands ask for init, which adds the
    # column at the end, as a new table has it.
    old_sqlite_db "$WORK/old.db"
    run -d "$WORK/old.db" list
    run -d "$WORK/old.db" label olduser vvccccbbcdef x
    run -d "$WORK/old.db" init
    schema "$WORK/old.db"
    run -d "$WORK/old.db" init
    run -d "$WORK/old.db" label olduser vvccccbbcdef 'after the upgrade'
    dump "$WORK/old.db"
    # A file with no yubikeys table.
    sqlite3 "$WORK/other.db" "CREATE TABLE users (name text);"
    run -d "$WORK/other.db" list
}

scenario_pg_labels() {
    local k1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d k2=0f1e2d3c4b5a69788796a5b4c3d2e1f0
    local old_header=username,public_id,private_id,aes_key,password,active,created,accessed,counter,low,high
    run -b pg -d "$PGDB" init-pg >/dev/null
    run -b pg -d "$PGDB" add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 --no-password -l 'primary, slot 1'
    run_lines username,public_id,private_id,aes_key,password,active,label \
              "alice,vvccccbbcdeg,4a6f8e2d1c3c,$k2,,1,clé de secours" "bob,vvccccbbcdeh,4a6f8e2d1c3d,$k1" \
              -- -b pg -d "$PGDB" import -
    run -b pg -d "$PGDB" label bob VVCCCCBBCDEH "bob's only key"
    run -b pg -d "$PGDB" label bob vvccccbbcdef x
    run -b pg -d "$PGDB" label alice vvccccbbcdef "$(printf '%0256d' 0)"
    run -b pg -d "$PGDB" label alice vvccccbbcdef "x' OR '1'='1 \\ \$\$"
    run -b pg -d "$PGDB" list

    # Without a label, --update and --replace keep the YubiKey's label.
    pgq "$PGDB" "UPDATE yubikeys SET counter = 5, low = 1 WHERE username = 'alice';"
    run -b pg -d "$PGDB" add --update -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $k1 -w 'n3w'
    run -b pg -d "$PGDB" add --replace -u alice -P vvccccbbcdeg -p 4a6f8e2d1c3c -k $k2 --no-password
    run_lines "bob,vvccccbbcdeh,999999999999,$k1,,1" -- -b pg -d "$PGDB" import --update -
    run -b pg -d "$PGDB" label alice vvccccbbcdef 'primary, slot 1'
    dump_pg

    # Export and restore keep the labels; an export made before 1.8.0 still
    # restores, and with --replace the YubiKeys keep their labels.
    run -b pg -d "$PGDB" export -
    printf '%s\n' "$old_header" "alice,vvccccbbcdef,4a6f8e2d1c3b,$k1,,1,2026-07-01 08:00:00,,9,0,0" \
        "henry,vvccccbbcder,4a6f8e2d1c44,$k1,,1,2026-07-01 08:00:00,,0,0,0" >old-export.csv
    chmod 600 old-export.csv
    run -b pg -d "$PGDB" import --from-export --replace old-export.csv
    run -b pg -d "$PGDB" list

    # Radiator's login role cannot read or change labels.
    pgq postgres "ALTER ROLE ${PGT}_radiator PASSWORD 'test-only';"
    as_radiator "select label from yubikeys"
    as_radiator "update yubikeys set label = 'x'"

    # A table made before 1.8.0: the commands ask for init, which adds the
    # column; Radiator's grants stay as they were.
    pgq "$PGDB" "ALTER TABLE yubikeys DROP COLUMN label;"
    run -b pg -d "$PGDB" list
    run -b pg -d "$PGDB" label alice vvccccbbcdef x
    run -b pg -d "$PGDB" init
    run -b pg -d "$PGDB" init
    schema_pg
    run -b pg -d "$PGDB" label alice vvccccbbcdef 'after the upgrade'
    run -b pg -d "$PGDB" list
}

# Migration checks that need no PostgreSQL server.
scenario_migrate_offline() {
    run_migrate --version
    run_migrate
    run_migrate --mode copy src.db
    run_migrate -e rot13 src.db
    run_migrate --bogus src.db
    run_migrate a.db b.db
    run_migrate "$WORK/missing.db"
}

scenario_migrate_new() {
    make_source
    run -b pg -d "$PGDB" init-pg >/dev/null
    sha256sum src.db >src.sum

    run_migrate -d "$PGDB" --dry-run src.db
    run -b pg -d "$PGDB" list
    run_migrate -d "$PGDB" src.db
    dump_pg
    times_pg
    check_crypt_pg test.user abc123
    printf '# SQLite source unchanged: %s\n\n' "$(sha256sum -c --quiet src.sum >/dev/null 2>&1 && echo yes || echo NO)"

    # A second first-time migration is refused.
    run_migrate -d "$PGDB" src.db

    # AES keys stored as hex instead.
    pgq "$PGDB" "DELETE FROM yubikeys;"
    run_migrate -d "$PGDB" -e hex src.db
    dump_pg

    # A SQLite database made before 1.8.0, with no label column.
    old_sqlite_db "$WORK/old.db"
    pgq "$PGDB" "DELETE FROM yubikeys;"
    run_migrate -d "$PGDB" old.db
    dump_pg
}

# Cutover: after the first copy, SQLite and PostgreSQL both change, then sync.
scenario_migrate_sync() {
    make_source
    run -b pg -d "$PGDB" init-pg >/dev/null
    run_migrate -d "$PGDB" src.db >/dev/null

    # SQLite: test.user logs in again (counter ahead), and a key is added.
    sqlite3 src.db "UPDATE yubikeys SET counter = 41, low = 2, accessed = '2026-10-12 09:00:00' WHERE username = 'test.user';
        INSERT INTO yubikeys VALUES ('newuser', '', 1, '2026-10-11 08:00:00', '', 'vvccccbbcdeh', 'cccccccccccf', '0f1e2d3c4b5a69788796a5b4c3d2e1f0', 0, 0, 0, 'added on SQLite');"
    # PostgreSQL: olduser logs in via Radiator (counter ahead of SQLite) and
    # gets a label, an admin changes test.user2's password, and a key exists
    # only here.
    pgq "$PGDB" "UPDATE yubikeys SET counter = 15, low = 1, accessed = '2026-10-12 10:00:00+00', label = 'labeled in PostgreSQL' WHERE username = 'olduser';
        UPDATE yubikeys SET password = 'changed-in-pg' WHERE username = 'test.user2';
        INSERT INTO yubikeys (username, tokenId, userId, secret) VALUES ('pgonly', 'vvccccbbcdei', '999999999999', 'ABEiM0RVZneImaq7zN3u/w==');"

    run_migrate -d "$PGDB" --mode sync --dry-run src.db
    run_migrate -d "$PGDB" --mode sync src.db
    dump_pg
    times_pg
    # Running it again changes nothing.
    run_migrate -d "$PGDB" --mode sync src.db

    # A SQLite key whose public ID belongs to a different key in PostgreSQL.
    sqlite3 src.db "INSERT INTO yubikeys VALUES ('clash', '', 1, '2026-08-01 08:00:00', '', 'vvccccbbcdei', '777777777777', '0f1e2d3c4b5a69788796a5b4c3d2e1f0', 0, 0, 0, '');"
    run_migrate -d "$PGDB" --mode sync src.db
    run_migrate -d "$PGDB" --mode sync --skip-invalid src.db
}

scenario_migrate_invalid() {
    "$SCRIPT" -d "$WORK/src.db" init >/dev/null 2>&1
    sqlite3 src.db <<'EOF'
INSERT INTO yubikeys VALUES ('good', '', 1, '2026-07-01 08:00:00', '', 'vvccccbbcdef', '4a6f8e2d1c3b', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, '');
INSERT INTO yubikeys VALUES ('', '', 1, '2026-07-01 08:00:00', '', 'vvccccbbcdeg', '4a6f8e2d1c3c', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, '');
INSERT INTO yubikeys VALUES ('bell' || char(7), '', 1, '2026-07-01 08:00:00', '', 'vvccccbbcdeh', '4a6f8e2d1c3d', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, '');
INSERT INTO yubikeys VALUES ('badpub', '', 1, '2026-07-01 08:00:00', '', 'abc', '4a6f8e2d1c3e', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, '');
INSERT INTO yubikeys VALUES ('badpriv', '', 1, '2026-07-01 08:00:00', '', 'vvccccbbcdei', 'xyz', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, '');
INSERT INTO yubikeys VALUES ('badkey', '', 1, '2026-07-01 08:00:00', '', 'vvccccbbcdej', '4a6f8e2d1c40', 'not-a-key', 0, 0, 0, '');
INSERT INTO yubikeys VALUES ('badactive', '', 'maybe', '2026-07-01 08:00:00', '', 'vvccccbbcdek', '4a6f8e2d1c41', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, '');
INSERT INTO yubikeys VALUES ('badcounter', '', 1, '2026-07-01 08:00:00', '', 'vvccccbbcdel', '4a6f8e2d1c42', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 'x', 0, 0, '');
-- the same private ID twice once lowercased
INSERT INTO yubikeys VALUES ('dup1', '', 1, '2026-07-01 08:00:00', '', 'vvccccbbcden', 'cccccccccccb', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, '');
INSERT INTO yubikeys VALUES ('dup2', '', 1, '2026-07-01 08:00:00', '', 'vvccccbbcder', 'CCCCCCCCCCCB', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, '');
-- the text 'false', which Radiator treats as active, becomes 0 (reported)
INSERT INTO yubikeys VALUES ('offuser', '', 'false', '2026-07-01 08:00:00', '', 'vvccccbbcdeu', '4a6f8e2d1c44', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, '');
-- a bad accessed time is cleared, not rejected
INSERT INTO yubikeys VALUES ('badtime', '', 1, '2026-07-01 08:00:00', 'yesterday', 'vvccccbbcdet', '4a6f8e2d1c43', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, '');
-- labels: too long, or with a control character
INSERT INTO yubikeys VALUES ('longlabel', '', 1, '2026-07-01 08:00:00', '', 'vvccccbbcdev', '4a6f8e2d1c45', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, hex(zeroblob(128)));
INSERT INTO yubikeys VALUES ('tablabel', '', 1, '2026-07-01 08:00:00', '', 'vvccccbbcdbc', '4a6f8e2d1c46', '6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d', 0, 0, 0, 'tab' || char(9) || 'label');
EOF
    run -b pg -d "$PGDB" init-pg >/dev/null
    run_migrate -d "$PGDB" src.db
    run -b pg -d "$PGDB" list
    run_migrate -d "$PGDB" --skip-invalid src.db
    dump_pg
}

scenario_migrate_errors() {
    make_source
    printf 'not a database\n' >text.db
    sqlite3 other.db "CREATE TABLE users (name text);"

    run_migrate -d "${PGT}_db" src.db
    run -b pg -d "$PGDB" init-pg >/dev/null
    pgq postgres "CREATE DATABASE ${PGT}_empty;"
    run_migrate -d "${PGT}_empty" src.db
    run_migrate -d "$PGDB" text.db
    run_migrate -d "$PGDB" other.db

    # Radiator's login role cannot migrate.
    pgq postgres "ALTER ROLE ${PGT}_radiator PASSWORD 'test-only';"
    run_migrate PGHOST=127.0.0.1 PGUSER="${PGT}_radiator" PGPASSWORD=test-only -- -d "$PGDB" src.db

    # If the fingerprint read disagrees with the copied data, nothing is
    # committed. A stand-in sqlite3 alters one password in the JSON read only.
    cat >sqlite3-tamper <<EOF
#!/bin/sh
case " \$* " in
    *" -json "*) $(command -v sqlite3) "\$@" | sed 's/"plainpin"/"tampered"/' ;;
    *)           exec $(command -v sqlite3) "\$@" ;;
esac
EOF
    chmod +x sqlite3-tamper
    run_migrate SQLITE3="$WORK/sqlite3-tamper" -- -d "$PGDB" src.db
    run -b pg -d "$PGDB" list

    # A PostgreSQL table made before 1.8.0 must be brought up to date first.
    pgq "$PGDB" "ALTER TABLE yubikeys DROP COLUMN label;"
    run_migrate -d "$PGDB" src.db
}

# --------------------------------------------------------------------------
# yubikey-anycast.sh, against stand-ins: a RADIUS server that checks each
# request the way Radiator 4.30's AuthBy SQLYUBIKEY checks a login (the
# Message-Authenticator, the user, PIN and public ID, the OTP and its
# counters), and ip and ss commands that keep lo's addresses and the
# listening sockets in files.
# --------------------------------------------------------------------------

# Start the stand-in RADIUS server, with the shared secret SECRET, for the
# check's key in $WORK/state/key. It reads what to do with each request from
# $WORK/radius/mode: accept (check it, as Radiator would), reject, silent (no
# answer), badsecret (sign the answer with another secret), or "ahead N" (the
# database's usage counter moves N past the last OTP accepted; then accept),
# and logs each OTP to $WORK/radius/log. Sets RADIUS_PID and PORT.
start_radius() {
    mkdir -p "$WORK/radius"
    echo accept >"$WORK/radius/mode"
    cat >"$WORK/radius/server.pl" <<'EOF'
use strict;
use warnings;
use Socket qw(PF_INET SOCK_DGRAM INADDR_LOOPBACK pack_sockaddr_in unpack_sockaddr_in);
use Digest::MD5 qw(md5);
use Crypt::Rijndael;

my ($dir, $keyfile, $secret) = @ARGV;
socket(my $s, PF_INET, SOCK_DGRAM, 0) or die "socket: $!";
bind($s, pack_sockaddr_in(0, INADDR_LOOPBACK)) or die "bind: $!";
my ($port) = unpack_sockaddr_in(getsockname($s));
open my $fh, ">", "$dir/port.tmp" or die;
print $fh "$port\n";
close $fh;
rename "$dir/port.tmp", "$dir/port" or die;

sub hmac_md5 {
    my ($k, $m) = @_;
    $k = md5($k) if length $k > 64;
    $k .= "\0" x (64 - length $k);
    md5(($k ^ ("\x5c" x 64)) . md5(($k ^ ("\x36" x 64)) . $m));
}
sub slurp { open my $f, "<", $_[0] or return ""; local $/; my $c = <$f> // ""; $c =~ s/\s+\z//; $c }
sub note { open my $f, ">>", "$dir/log" or die; print $f "$_[0]\n"; close $f }

my ($counter, $session) = (0, 0);   # a row just imported with --replace
while (1) {
    my $from = recv($s, my $req, 4096, 0);
    next unless defined $from && length $req >= 20;
    my $mode = slurp("$dir/mode");
    next if $mode eq "silent";
    my ($code, $id, $len) = unpack "C C n", $req;
    my $auth = substr($req, 4, 16);
    my (%attr, $ma_at);
    for (my $i = 20; $i + 2 <= $len; ) {
        my ($t, $l) = unpack "C C", substr($req, $i, 2);
        last if $l < 2;
        $attr{$t} = substr($req, $i + 2, $l - 2);
        $ma_at = $i + 2 if $t == 80;
        $i += $l;
    }
    # Radiator drops a request without a correct Message-Authenticator.
    my $zeroed = $req;
    substr($zeroed, $ma_at, 16) = "\0" x 16 if defined $ma_at;
    if (!defined $ma_at || hmac_md5($secret, $zeroed) ne $attr{80}) { note("wrong Message-Authenticator: dropped"); next }
    my ($pw, $prev, $hidden) = ("", $auth, $attr{2} // "");
    for (my $i = 0; $i < length $hidden; $i += 16) {
        my $c = substr($hidden, $i, 16);
        $pw .= $c ^ md5($secret . $prev);
        $prev = $c;
    }
    $pw =~ s/\0+\z//;
    my ($pin, $otp) = split /:/, $pw, 2;
    $otp //= "";
    my $user = $attr{1} // "";
    my %k = map { /^(\w+)=(.*)$/ ? ($1, $2) : () } split /\n/, slurp($keyfile);
    my ($result, $reason) = (2, "");
    if ($mode eq "reject") {
        ($result, $reason) = (3, "Yubikey secret not found in database");
        note("$user: rejected, as told");
    } elsif ($user ne ($k{user} // "") || $pin ne ($k{pin} // "") || substr($otp, 0, 12) ne ($k{public_id} // "")) {
        ($result, $reason) = (3, "Wrong user, PIN or public ID");
    } else {
        (my $hex = substr($otp, 12)) =~ tr/cbdefghijklnrtuv/0123456789abcdef/;
        my $token = Crypt::Rijndael->new(pack("H32", $k{aes_key}), Crypt::Rijndael::MODE_ECB())
                                   ->decrypt(pack("H32", $hex));
        my $crc = 0xffff;
        for my $b (unpack "C*", $token) {
            $crc ^= $b;
            for (1 .. 8) { my $lsb = $crc & 1; $crc >>= 1; $crc ^= 0x8408 if $lsb }
        }
        my ($priv, $c, $sess) = unpack "H12 v x3 C", $token;
        $c &= 0x7fff;
        if ($mode =~ /^ahead (\d+)$/) {
            ($counter, $session) = ($counter + $1, 0);
            open my $m, ">", "$dir/mode" or die;
            print $m "accept\n";
            close $m;
        }
        if ($crc != 0xf0b8 || $priv ne $k{private_id}) {
            ($result, $reason) = (3, "Wrong OTP");
        } elsif ($counter > $c || ($counter == $c && $session >= $sess)) {
            ($result, $reason) = (3, "Replay attack detected");
        } else {
            ($counter, $session) = ($c, $sess);
        }
        note("$user: OTP with usage counter $c, session $sess: " . ($result == 2 ? "accepted" : "rejected: $reason"));
    }
    my $attrs = $result == 3 ? pack("C C", 18, 2 + length $reason) . $reason : "";
    my $rep = pack("C C n", $result, $id, 20 + length $attrs) . $auth . $attrs;
    substr($rep, 4, 16) = md5($rep . ($mode eq "badsecret" ? "another secret" : $secret));
    send($s, $rep, 0, $from);
}
EOF
    perl "$WORK/radius/server.pl" "$WORK/radius" "$WORK/state/key" "$1" &
    RADIUS_PID=$!
    for _ in $(seq 50); do [[ -s $WORK/radius/port ]] && break; sleep 0.1; done
    PORT=$(<"$WORK/radius/port")
}

# Stand-ins for ip and ss: $WORK/lo has lo's addresses besides 127.0.0.1
# (ADDRESS/PREFIX lines), and ip logs each change to $WORK/ip.log;
# $WORK/listen has the UDP sockets ss lists (see listening). Also $WORK/proc,
# with net.ipv4.ip_nonlocal_bind and net.ipv6.ip_nonlocal_bind set to 1.
make_fakes() {
    : >"$WORK/lo"
    : >"$WORK/listen"
    cat >"$WORK/ip" <<'EOF'
#!/bin/bash
lo=$FAKE_DIR/lo
case "$*" in
    "-o addr show dev lo")
        echo '1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever'
        while read -r a; do
            if [[ $a == *:* ]]; then f=inet6; else f=inet; fi
            echo "1: lo    $f $a scope global lo\\       valid_lft forever preferred_lft forever"
        done <"$lo" ;;
    "-4 addr add "*" dev lo" | "-6 addr add "*" dev lo nodad")
        grep -qxF "$4" "$lo" && { echo "RTNETLINK answers: File exists" >&2; exit 2; }
        echo "$4" >>"$lo"
        echo "ip $*" >>"$FAKE_DIR/ip.log" ;;
    "-4 addr del "*" dev lo" | "-6 addr del "*" dev lo")
        grep -qxF "$4" "$lo" || { echo "RTNETLINK answers: Cannot assign requested address" >&2; exit 2; }
        grep -vxF "$4" "$lo" >"$lo.new"
        mv "$lo.new" "$lo"
        echo "ip $*" >>"$FAKE_DIR/ip.log" ;;
    *)  echo "ip stand-in: unexpected arguments: $*" >&2; exit 1 ;;
esac
EOF
    cat >"$WORK/ss" <<'EOF'
#!/bin/bash
[[ "$*" == -Hlun ]] || { echo "ss stand-in: unexpected arguments: $*" >&2; exit 1; }
cat "$FAKE_DIR/listen"
EOF
    chmod +x "$WORK/ip" "$WORK/ss"
    mkdir -p "$WORK/proc/net/ipv4" "$WORK/proc/net/ipv6"
    echo 1 >"$WORK/proc/net/ipv4/ip_nonlocal_bind"
    echo 1 >"$WORK/proc/net/ipv6/ip_nonlocal_bind"
}

# listening ADDRESS:PORT...: the UDP sockets the ss stand-in lists.
listening() {
    : >"$WORK/listen"
    local a
    for a in "$@"; do printf 'UNCONN 0      0      %s      0.0.0.0:*\n' "$a" >>"$WORK/listen"; done
}

# Run yubikey-anycast.sh with the test's directories and stand-ins.
anycast_env() {
    env TZ=UTC ANYCAST_STATE_DIR="$WORK/state" ANYCAST_RUN_DIR="$WORK/run" PROC_SYS="$WORK/proc" \
        IP="$WORK/ip" SS="$WORK/ss" FAKE_DIR="$WORK" "$ANYCAST" "$@"
}

# Start 'run' in the background, its output in $WORK/run.log. Sets RUN_PID
# (the script's own process, which env replaces itself with).
start_run() {
    env TZ=UTC ANYCAST_STATE_DIR="$WORK/state" ANYCAST_RUN_DIR="$WORK/run" PROC_SYS="$WORK/proc" \
        IP="$WORK/ip" SS="$WORK/ss" FAKE_DIR="$WORK" "$ANYCAST" -c anycast.conf run >"$WORK/run.log" 2>&1 &
    RUN_PID=$!
}

# Run it, with no standard input, and record it: any ARGS...
any() {
    local out rc=0
    out=$(anycast_env "$@" </dev/null 2>&1) || rc=$?
    printf '$ yubikey-anycast.sh %s\n%s%s[exit %d]\n\n' "$*" "$out" "${out:+$'\n'}" "$rc"
}

# enroll: 'enroll', recorded with the new key's random values masked (each
# masked only if it has the right form), then 'yubikey-db.sh import
# --replace -' with its output into $DB.
enroll() {
    local rc=0
    anycast_env enroll >"$WORK/enroll.csv" 2>"$WORK/enroll.err" || rc=$?
    printf '$ yubikey-anycast.sh enroll\n'
    sed -E 's/^(anycast-[a-z0-9-]+),vv[cbdefghijklnrtuv]{10},[0-9a-f]{12},[0-9a-f]{32},[A-Za-z0-9]{20},1$/\1,vv<PUBLIC ID>,<PRIVATE ID>,<AES KEY>,<PIN>,1/' \
        "$WORK/enroll.csv"
    cat "$WORK/enroll.err"
    printf '[exit %d]\n\n' "$rc"
    run_from "$WORK/enroll.csv" -d "$DB" import --replace -
}

# conf LINE...: write the settings file anycast.conf.
conf() { printf '%s\n' "$@" >"$WORK/anycast.conf"; }

# wait_status STATE: wait up to 10 s for the running check to be in STATE.
wait_status() {
    for _ in $(seq 100); do
        grep -qx "state=$1" "$WORK/run/status" 2>/dev/null && return
        sleep 0.1
    done
    echo "# timed out waiting for state=$1"
}

# The commands, the settings, the key, and one login at a time.
scenario_anycast() {
    make_fakes
    any
    any -V
    any bogus
    any -c missing.conf check
    conf 'ADDRESSES=192.0.2.153' 'SECRET=x' 'BOGUS=1'
    any -c anycast.conf check
    conf 'ADDRESSES="192.0.2.153 2001:db8::1 300.1.1.1"' 'SECRET=x'
    any -c anycast.conf withdraw
    conf 'ADDRESSES=192.0.2.153' 'SECRET=x' 'INTERVAL=0'
    any -c anycast.conf withdraw
    conf 'ADDRESSES=192.0.2.153' 'SECRET=x' 'TIMEOUT=6'
    any -c anycast.conf withdraw
    conf 'SECRET=x'
    any -c anycast.conf withdraw
    conf '# no secret' 'ADDRESSES = 192.0.2.153' 'SECRET'
    any -c anycast.conf withdraw

    # No key yet.
    conf 'ADDRESSES = "192.0.2.153  2001:DB8:153:0::153"' "SECRET='a secret with spaces'" 'TIMEOUT=1'
    any -c anycast.conf check

    # A key, in the database. A second one keeps the public ID, and
    # replaces the first in the database.
    run -d "$DB" init >/dev/null
    enroll
    stat -c '# %n mode %a' state state/key state/counter
    printf '# key file: %s\n' "$(cut -d= -f1 state/key | paste -sd' ')"
    first=$(grep public_id state/key)
    enroll
    printf '# same public ID: %s\n\n' "$([[ $(grep public_id state/key) == "$first" ]] && echo yes || echo no)"
    run -d "$DB" list | sed -E 's/vv[cbdefghijklnrtuv]{10}/vv<PUBLIC ID>/'

    # Logins. Radiator must also listen on both anycast addresses.
    start_radius 'a secret with spaces'
    conf 'ADDRESSES = "192.0.2.153  2001:DB8:153:0::153"' "SECRET='a secret with spaces'" 'TIMEOUT=1' "PORT=$PORT"
    any -c anycast.conf check
    listening "192.0.2.153:$PORT"
    any -c anycast.conf check
    listening "192.0.2.153:$PORT" "[2001:db8:153::153]:$PORT"
    any -c anycast.conf check
    any -c anycast.conf check
    echo reject >radius/mode
    any -c anycast.conf check
    echo silent >radius/mode
    any -c anycast.conf check
    # An answer signed with another secret is not Radiator's.
    echo badsecret >radius/mode
    any -c anycast.conf check
    echo accept >radius/mode
    conf 'ADDRESSES=192.0.2.153' 'SECRET=wrong' 'TIMEOUT=1' "PORT=$PORT"
    any -c anycast.conf check
    conf 'ADDRESSES = "192.0.2.153  2001:DB8:153:0::153"' "SECRET='a secret with spaces'" 'TIMEOUT=1' "PORT=$PORT"
    # The database is ahead of the counter file (restored from a backup).
    echo 'ahead 10' >radius/mode
    any -c anycast.conf check
    printf '# the server saw:\n'
    cat radius/log
    echo

    # Nothing listening on the port.
    kill "$RADIUS_PID"
    wait "$RADIUS_PID" 2>/dev/null
    any -c anycast.conf check

    # The counter file.
    echo 1000 >state/counter
    any -c anycast.conf status
    echo 32767 >state/counter
    any -c anycast.conf check
    echo junk >state/counter
    any -c anycast.conf check

    # withdraw, with the addresses on lo.
    printf '%s\n' 192.0.2.153/32 2001:db8:153::153/128 >lo
    any -c anycast.conf withdraw
    any -c anycast.conf withdraw
    printf '# ip calls:\n'
    cat ip.log
}

# The running check: the addresses go on lo after RISE good checks, off after
# FALL failed ones, back if removed, off when it stops; it skips ahead past
# OTPs the database has already seen.
scenario_anycast_run() {
    make_fakes
    run -d "$DB" init >/dev/null
    enroll >/dev/null
    start_radius s3cret
    conf 'ADDRESSES="192.0.2.153 2001:db8:153::153"' 'SECRET=s3cret' "PORT=$PORT" \
         'INTERVAL=1' 'TIMEOUT=1' 'FALL=3' 'RISE=2'
    listening "192.0.2.153:$PORT" "[2001:db8:153::153]:$PORT"
    echo 0 >proc/net/ipv6/ip_nonlocal_bind
    any -c anycast.conf run
    echo 1 >proc/net/ipv6/ip_nonlocal_bind

    start_run
    wait_status advertised
    printf '# on lo: %s\n\n' "$(paste -sd' ' lo)"
    any -c anycast.conf status | sed -E 's/[0-9]+ (s ago|days)/<N> \1/; s/OTPs left: [0-9]+/OTPs left: <N>/'
    any -c anycast.conf check
    any enroll

    echo reject >radius/mode
    wait_status withdrawn
    printf '# on lo: %s\n\n' "$(paste -sd' ' lo)"
    any -c anycast.conf status | sed -E 's/[0-9]+ (s ago|days)/<N> \1/; s/OTPs left: [0-9]+/OTPs left: <N>/'
    echo accept >radius/mode
    wait_status advertised

    # Two OTPs rejected as replays, then one accepted: still advertised.
    echo 'ahead 1' >radius/mode
    for _ in $(seq 100); do
        [[ $(grep -c 'check: ACCEPT' run.log) == 3 ]] && break
        sleep 0.1
    done
    printf '# %s\n' "$(grep state= run/status)"

    # An address removed by hand goes back on lo.
    grep -v : lo >lo.new; mv lo.new lo
    for _ in $(seq 30); do
        [[ $(wc -l <lo) == 2 ]] && break
        sleep 0.1
    done
    printf '# on lo: %s\n\n' "$(paste -sd' ' lo)"

    kill -TERM "$RUN_PID"
    wait "$RUN_PID"
    printf '# run exited with %d; its log:\n' "$?"
    cat run.log
    printf '\n# ip calls:\n'
    cat ip.log
    printf '# on lo: %s; status file: %s\n\n' "$(paste -sd' ' lo)" "$(ls run)"
    printf '# the server saw, from the first replay:\n'
    awk '/Replay/ { p = 1 } p { print } p && /accepted/ { exit }' radius/log \
        | sed -E 's/usage counter 1, session [0-9]+/usage counter 1, session <N>/'
    kill "$RADIUS_PID"
    wait "$RADIUS_PID" 2>/dev/null
}

# --------------------------------------------------------------------------
# yubikey-partition.sh, with the test's PostgreSQL as both this server's own
# database and the primary, a stand-in for systemctl, and a peer that is a
# port on this machine, listening or not.
# --------------------------------------------------------------------------

# Run yubikey-partition.sh with the test's directories and stand-ins.
partition_env() {
    env TZ=UTC PARTITION_STATE_DIR="$WORK/state" PARTITION_RUN_DIR="$WORK/run" PARTITION_CONF_D="$WORK/conf.d" \
        PARTITION_LOCAL_DB="$PGDB" PARTITION_OWNER='' SYSTEMCTL="$WORK/systemctl" YUBIKEY_DB_SH="$SCRIPT" \
        "$PARTITION" -c partition.conf "$@"
}

# Run it, with no standard input, and record it: part ARGS...
part() {
    local out rc=0
    out=$(partition_env "$@" </dev/null 2>&1) || rc=$?
    printf '$ yubikey-partition.sh %s\n%s%s[exit %d]\n\n' "$*" "$out" "${out:+$'\n'}" "$rc"
}

# The copy's rows, without the secrets.
copy_rows() {
    printf '# the copy:\n'
    sqlite3 -batch -header -separator ' | ' "$WORK/state/keys.db" \
        "SELECT username, tokenId, active, counter, low FROM yubikeys ORDER BY username, tokenId"
}

# The primary's counters.
primary_rows() {
    printf '# the primary:\n'
    pgq "$PGDB" "SELECT username || ' | ' || tokenId || ' | ' || coalesce(counter::text, '') || ' | ' || coalesce(low::text, '')
                 || ' | ' || CASE WHEN accessed IS NULL THEN '' ELSE 'accessed' END FROM yubikeys ORDER BY username, tokenId"
}

# peer_up / peer_down: the peer (a port on this machine) listens, or not.
PEER_PID=''
peer_up() {
    perl -MIO::Socket::INET -e '$s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $ARGV[0],
        Listen => 5, ReuseAddr => 1) or die; while (my $c = $s->accept) { close $c }' "$PEER_PORT" &
    PEER_PID=$!
    sleep 0.3
}
peer_down() {
    if [[ -n $PEER_PID ]]; then kill "$PEER_PID"; wait "$PEER_PID" 2>/dev/null; PEER_PID=''; fi
}

# wait_mode MODE: wait up to 15 s for the running service to be in MODE.
wait_mode() {
    for _ in $(seq 150); do
        [[ $(readlink "$WORK/conf.d/yubikey.conf") == "yubikey-$1.conf" ]] && return
        sleep 0.1
    done
    echo "# timed out waiting for $1 mode"
}

scenario_pg_partition() {
    run -b pg -d "$PGDB" init-pg >/dev/null
    csv example.csv <"$ROOT/users.example.csv"
    run -b pg -d "$PGDB" import example.csv >/dev/null
    pgq postgres "ALTER ROLE ${PGT}_radiator PASSWORD 'test-only';"
    printf '#!/bin/sh\necho "systemctl $*" >>"%s/systemctl.log"\n' "$WORK" >systemctl
    chmod +x systemctl
    PEER_PORT=$(perl -MIO::Socket::INET -e 'print IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1")->sockport')
    printf 'PEERS=127.0.0.1\nPORTS=%s\nINTERVAL=1\nENTER=2\nLEAVE=1\nSYNC=3600\n' "$PEER_PORT" >partition.conf
    # psql, except that this server's own PostgreSQL (no host=) doesn't
    # answer while local-down exists, as when Patroni stops it.
    cat >psql-local <<EOF
#!/bin/sh
if [ -e "$WORK/local-down" ]; then
    case "\$*" in *host=*) ;; *) echo "psql: error: FATAL:  the database system is shutting down" >&2; exit 2 ;; esac
fi
exec psql "\$@"
EOF
    chmod +x psql-local

    # Radiator's clause for the cluster, as 'config' writes it, with
    # Radiator's password.
    mkdir conf.d
    PGHOST=127.0.0.1 PGSSLMODE=disable PGCONNECT_TIMEOUT=2 "$SCRIPT" -b pg -d "$PGDB" config \
        | sed 's/^\( *\)DBAuth *$/\1DBAuth       test-only/' >conf.d/yubikey.conf
    part status
    part setup
    printf '# yubikey.conf -> %s\n' "$(readlink conf.d/yubikey.conf)"
    grep -E 'DBSource|Identifier' conf.d/yubikey-partition.conf | sed "s|$WORK|<WORK>|"
    copy_rows
    echo

    # Changes in the database reach the copy: a login elsewhere (counters
    # forward), a disabled user, new users, a deleted one, and a YubiKey
    # programmed with a new key (its counters start again).
    pgq "$PGDB" "UPDATE yubikeys SET counter = 9, low = 1 WHERE username = 'test.user'"
    run -b pg -d "$PGDB" disable test.user2 >/dev/null
    run_lines 'carol,vvccccdddddd,0a0b0c0d0e0f,00112233445566778899aabbccddeeff,pin1' \
              'dave,vvcccceeeeee,0a0b0c0d0e10,00112233445566778899aabbccddeef0,pin2' -- -b pg -d "$PGDB" import - >/dev/null
    pgq "$PGDB" "UPDATE yubikeys SET counter = 30, low = 0 WHERE username = 'carol'"
    part sync
    copy_rows
    run -b pg -d "$PGDB" delete dave >/dev/null
    run_lines 'carol,vvccccdddddd,aabbccddeeff,0f1e2d3c4b5a69788796a5b4c3d2e1f0,newpin' -- -b pg -d "$PGDB" import --replace - >/dev/null
    part sync
    copy_rows
    echo

    # The copy is ahead (logins here while cut off): its counters stay.
    sqlite3 -cmd '.timeout 10000' state/keys.db "UPDATE yubikeys SET counter = 12, low = 4, accessed = '2026-10-13 12:00:00' WHERE username = 'test.user'"
    part sync
    copy_rows
    echo
    part leave

    # The service: partition mode after 2 checks without the peer, back
    # after 1 check with the peer and the primary; the counters saved in the
    # copy go to the primary, only forward. The copy is updated when the
    # service starts and when partition mode begins (SYNC is an hour).
    peer_up
    env TZ=UTC PARTITION_STATE_DIR="$WORK/state" PARTITION_RUN_DIR="$WORK/run" PARTITION_CONF_D="$WORK/conf.d" \
        PARTITION_LOCAL_DB="$PGDB" SYSTEMCTL="$WORK/systemctl" PSQL="$WORK/psql-local" \
        "$PARTITION" -c partition.conf run >run.log 2>&1 &
    pid=$!
    sleep 2.5
    # A login at another site just before the cut.
    pgq "$PGDB" "UPDATE yubikeys SET counter = 4, low = 0 WHERE username = 'carol'"
    peer_down
    wait_mode partition
    part status | sed -E 's/since .* UTC/since <TIME>/; s/updated [0-9:]+/updated <TIME>/'
    copy_rows
    # Logins here (in the copy), and at another site (in the primary).
    sqlite3 -cmd '.timeout 10000' state/keys.db "UPDATE yubikeys SET counter = 13, low = 0, accessed = '2026-10-13 12:05:00' WHERE username = 'test.user'"
    sqlite3 -cmd '.timeout 10000' state/keys.db "UPDATE yubikeys SET counter = 6, low = 2, accessed = '2026-10-13 12:06:00' WHERE username = 'carol'"
    pgq "$PGDB" "UPDATE yubikeys SET counter = 5, low = 0 WHERE username = 'carol'"
    pgq "$PGDB" "UPDATE yubikeys SET counter = 14, low = 0 WHERE username = 'test.user'"
    sqlite3 -cmd '.timeout 10000' state/keys.db "UPDATE yubikeys SET counter = 7, low = 7, accessed = '2026-10-13 12:07:00' WHERE username = 'test.user2'"
    peer_up
    wait_mode cluster
    sleep 1.5
    primary_rows
    echo

    # Again, with this server's PostgreSQL not answering when partition mode
    # begins (a former primary, which Patroni is stopping): the copy is the
    # last one until PostgreSQL answers again.
    touch local-down
    pgq "$PGDB" "UPDATE yubikeys SET counter = 8, low = 0 WHERE username = 'test.user2'"
    peer_down
    wait_mode partition
    copy_rows
    rm local-down
    sleep 2.5
    copy_rows
    peer_up
    wait_mode cluster
    sleep 0.5
    peer_down
    kill "$pid"
    wait "$pid"
    printf '# the service exited with %d; its log:\n' "$?"
    sed -E 's/updated [0-9:]+/updated <TIME>/' run.log
    printf '# systemctl:\n'
    cat systemctl.log
    primary_rows
    printf '# merge-pending: %s\n\n' "$([[ -e state/merge-pending ]] && echo yes || echo no)"

    # leave, with the primary out of reach: nothing changes.
    sed -i 's/port=5432/port=1/' conf.d/yubikey-cluster.conf
    ln -sfn yubikey-partition.conf conf.d/yubikey.conf
    part leave | sed -E 's/(error: cannot copy the counters to the primary:).*/\1 <ERROR>/'
    printf '# yubikey.conf -> %s\n' "$(readlink conf.d/yubikey.conf)"

    # leave while a writer (Radiator saving a counter, or the sync) holds
    # the copy's lock, here for 1.5 s: the reads of the copy wait for it.
    sed -i 's/port=1/port=5432/' conf.d/yubikey-cluster.conf
    sqlite3 -cmd '.timeout 10000' state/keys.db "UPDATE yubikeys SET counter = 20, low = 0 WHERE username = 'test.user'"
    printf 'BEGIN EXCLUSIVE;\n.shell sleep 1.5\nCOMMIT;\n' | sqlite3 state/keys.db &
    lock=$!
    sleep 0.3
    part leave
    wait "$lock"
    printf '# yubikey.conf -> %s\n' "$(readlink conf.d/yubikey.conf)"
    primary_rows
}

# --------------------------------------------------------------------------
# install.sh, with stand-ins for apt-get, dpkg-query, getent and Perl, Radiator
# in $WORK/root, and small packages made with dpkg-deb.
# --------------------------------------------------------------------------

# The stand-ins, in $WORK/bin. $WORK/installed lists the installed packages
# ("NAME VERSION"), $WORK/modules the Perl modules that load, $WORK/inc the
# stand-in Perl's @INC, and $WORK/users the users. apt-get logs its arguments
# to $WORK/apt.log, and adds what it installs to $WORK/installed (and the
# Perl modules in it to $WORK/modules).
make_install_fakes() {
    mkdir -p "$WORK/bin" "$WORK/root"
    : >"$WORK/installed"; : >"$WORK/modules"; : >"$WORK/inc"; : >"$WORK/users"; : >"$WORK/apt.log"
    cat >"$WORK/bin/dpkg-query" <<'EOF'
#!/bin/bash
v=$(awk -v p="${!#}" '$1 == p {v = $2} END {print v}' "$FAKE_DIR/installed")
[[ -n $v ]] || { echo "dpkg-query: no packages found matching ${!#}" >&2; exit 1; }
echo "installed $v"
EOF
    cat >"$WORK/bin/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >>"$FAKE_DIR/apt.log"
[[ $1 == install ]] || exit 0
for a in "${@:2}"; do
    case $a in
        -*)    ;;
        *.deb) echo "$(dpkg-deb -f "$a" Package) $(dpkg-deb -f "$a" Version)" >>"$FAKE_DIR/installed" ;;
        *)     echo "$a 1.0" >>"$FAKE_DIR/installed"
               case $a in
                   libauth-yubikey-decrypter-perl) echo Auth::Yubikey_Decrypter ;;
                   libcrypt-rijndael-perl)         echo Crypt::Rijndael ;;
                   libcache-fastmmap-perl)         echo Cache::FastMmap ;;
                   libdbd-sqlite3-perl)            echo DBD::SQLite ;;
                   libdbd-pg-perl)                 echo DBD::Pg ;;
               esac >>"$FAKE_DIR/modules" ;;
    esac
done
EOF
    cat >"$WORK/bin/getent" <<'EOF'
#!/bin/bash
[[ $1 == passwd ]] && grep -qxF "$2" "$FAKE_DIR/users"
EOF
    # perl -IDIR -MMODULE -e 1: Radiator's Radius::AuthSQLYUBIKEY loads when
    # it is in DIR and Auth::Yubikey_Decrypter loads; other modules when they
    # are in $WORK/modules. perl -e CODE: the first directory of $WORK/inc
    # with Radius/Util.pm in it (what install.sh asks Perl for).
    cat >"$WORK/bin/perl" <<'EOF'
#!/bin/bash
inc='' module=''
for a in "$@"; do
    case $a in
        -I*) inc=${a#-I} ;;
        -M*) module=${a#-M} ;;
    esac
done
if [[ -z $module ]]; then
    while read -r d; do [[ -f $d/Radius/Util.pm ]] && { echo "$d"; exit 0; }; done <"$FAKE_DIR/inc"
    exit 0
fi
if [[ $module == Radius::* ]]; then
    [[ -f $inc/${module//:://}.pm ]] && grep -qxF Auth::Yubikey_Decrypter "$FAKE_DIR/modules"
else
    grep -qxF "$module" "$FAKE_DIR/modules"
fi
EOF
    chmod +x "$WORK/bin/"*
}

# fake_radiator DIR [#!LINE]: a stand-in radiusd in DIR (run by the stand-in
# Perl, or the given #! line), and Radiator 4.30's Perl modules in DIR, or
# in $WORK/root/usr/local/share/perl when DIR is $WORK/root/usr/local/bin.
fake_radiator() {
    local lib=$1
    if [[ $1 == "$WORK/root/usr/local/bin" ]]; then
        lib=$WORK/root/usr/local/share/perl
        echo "$lib" >>"$WORK/inc"
    fi
    mkdir -p "$1" "$lib/Radius"
    printf '%s\n# radiusd\n' "${2:-#!/usr/bin/env perl}" >"$1/radiusd"
    printf "package Radius::Util;\n\$main::VERSION = '4.30';\n" >"$lib/Radius/Util.pm"
    : >"$lib/Radius/AuthSQLYUBIKEY.pm"
}

# fake_deb NAME VERSION FILE: a package with nothing in it.
fake_deb() {
    rm -rf "$WORK/debroot"
    mkdir -p "$WORK/debroot/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: Test <test@example.com>\nDescription: test\n' \
        "$1" "$2" >"$WORK/debroot/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$WORK/debroot" "$3" >/dev/null
}

# Run install.sh (or $INSTALL) with the stand-ins and no standard input, and
# record it: inst ARGS...
inst() {
    local out rc=0
    out=$(env PATH="$WORK/bin:$PATH" FAKE_DIR="$WORK" APT_GET="$WORK/bin/apt-get" DPKG_QUERY="$WORK/bin/dpkg-query" \
              GETENT="$WORK/bin/getent" APT_PERL="$WORK/bin/perl" SYSROOT="$WORK/root" \
              RADIUSD_PATHS="$WORK/root/opt/radiator/radiator/radiusd $WORK/root/usr/local/bin/radiusd" \
              "${INSTALL:-$ROOT/install.sh}" "$@" </dev/null 2>&1) || rc=$?
    printf '$ install.sh %s\n%s%s[exit %d]\n\n' "$*" "$out" "${out:+$'\n'}" "$rc"
}

# What apt-get was asked to do since the last call, and forget it.
apt_log() {
    if [[ -s $WORK/apt.log ]]; then sed 's/^/# /' "$WORK/apt.log"; else echo "# apt-get: not run"; fi
    echo
    : >"$WORK/apt.log"
}

scenario_install() {
    make_install_fakes
    fake_deb radiator-yubikey 1.9.0 "$WORK/radiator-yubikey_1.9.0_all.deb"
    fake_deb something-else 1.0 "$WORK/other.deb"
    inst -V
    inst --help
    inst --bogus
    inst a.deb b.deb
    inst --radiusd
    inst missing.deb
    inst other.deb

    # No Radiator: a stop, without a terminal to ask on, and nothing installed;
    # then --check, and --yes.
    inst radiator-yubikey_1.9.0_all.deb
    apt_log
    inst --check
    inst --yes radiator-yubikey_1.9.0_all.deb
    apt_log

    # Radiator Software's packages, which put radiusd in /opt/radiator/radiator;
    # the Perl modules not installed yet.
    : >"$WORK/installed"; : >"$WORK/modules"
    printf 'radiator 4.30-1\nradiator-radius-utilxs 2.4-4\n' >>"$WORK/installed"
    fake_radiator "$WORK/root/opt/radiator/radiator"
    inst --check
    inst radiator-yubikey_1.9.0_all.deb
    apt_log
    inst --check
    # The same Radiator run by another Perl than the one apt-get installs
    # modules for: a note only while modules are missing.
    cp "$WORK/bin/perl" "$WORK/bin/other-perl"
    fake_radiator "$WORK/root/opt/radiator/radiator" "#!$WORK/bin/other-perl -w"
    inst --check
    sed -i '/^DBD::Pg$/d' "$WORK/modules"
    inst --check
    echo DBD::Pg >>"$WORK/modules"

    # A package of the same name that is not Radiator Software's, with no
    # radiusd.
    rm -rf "$WORK/root/opt/radiator"
    inst --check

    # Radiator's source in /opt/radiator/radiator: no user radiator and no
    # radiator.service at first.
    sed -i '/^radiator /d; /^radiator-radius-utilxs /d' "$WORK/installed"
    fake_radiator "$WORK/root/opt/radiator/radiator"
    inst --check
    echo radiator >"$WORK/users"
    mkdir -p "$WORK/root/etc/systemd/system"
    : >"$WORK/root/etc/systemd/system/radiator.service"
    inst --check
    rm -rf "$WORK/root/opt/radiator" "$WORK/root/etc"

    # After 'make install': radiusd in /usr/local/bin, the modules in Perl's @INC.
    mkdir -p "$WORK/root/usr/lib/systemd/system"
    : >"$WORK/root/usr/lib/systemd/system/radiator.service"
    fake_radiator "$WORK/root/usr/local/bin"
    inst --check
    rm -rf "$WORK/root/usr/local"

    # --radiusd: one that is not Radiator's, and one elsewhere.
    mkdir -p "$WORK/elsewhere"
    printf '#!/usr/bin/perl\n' >"$WORK/elsewhere/radiusd"
    inst --check --radiusd "$WORK/elsewhere/radiusd"
    fake_radiator "$WORK/elsewhere"
    inst --check --radiusd "$WORK/elsewhere/radiusd"

    # Units and scripts installed by hand, as the guide said before the
    # package: one enabled, one not, and a masked one, which is fine.
    mkdir -p "$WORK/root/etc/systemd/system/multi-user.target.wants" "$WORK/root/usr/local/sbin"
    : >"$WORK/root/etc/systemd/system/yubikey-anycast.service"
    ln -s ../yubikey-anycast.service "$WORK/root/etc/systemd/system/multi-user.target.wants/yubikey-anycast.service"
    : >"$WORK/root/etc/systemd/system/yubikey-partition.service"
    : >"$WORK/root/usr/local/sbin/yubikey-db.sh"
    : >"$WORK/root/usr/local/sbin/yubikey-partition.sh"
    inst --check --radiusd "$WORK/elsewhere/radiusd"
    rm "$WORK/root/etc/systemd/system/yubikey-partition.service"
    ln -s /dev/null "$WORK/root/etc/systemd/system/yubikey-partition.service"
    rm -r "$WORK/root/usr/local/sbin" "$WORK/root/etc/systemd/system/yubikey-anycast.service" \
        "$WORK/root/etc/systemd/system/multi-user.target.wants"
    inst --check --radiusd "$WORK/elsewhere/radiusd"

    # A git clone where the package would go.
    mkdir -p "$WORK/root/opt/radiator-yubikey/.git"
    inst --yes radiator-yubikey_1.9.0_all.deb
    apt_log
    rm -r "$WORK/root/opt/radiator-yubikey"

    # The newest package next to install.sh, by default. (This install.sh,
    # with no VERSION file next to it, doesn't know its version.)
    mkdir -p "$WORK/inst"
    cp "$ROOT/install.sh" "$WORK/inst/"
    fake_deb radiator-yubikey 1.9.0 "$WORK/inst/radiator-yubikey_1.9.0_all.deb"
    fake_deb radiator-yubikey 1.10.0 "$WORK/inst/radiator-yubikey_1.10.0_all.deb"
    INSTALL=$WORK/inst/install.sh inst --yes --radiusd "$WORK/elsewhere/radiusd"
    apt_log
}

# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------

ALL=(help init import import_formats import_errors add encodings modify permissions tools config
     export restore restore_errors update counters verify wrapper labels
     pg_offline pg_init pg_import pg_add pg_encodings pg_modify pg_radiator pg_export pg_restore
     pg_update pg_verify pg_labels
     migrate_offline migrate_new migrate_sync migrate_invalid migrate_errors
     anycast anycast_run pg_partition install)

# Scenarios that need a PostgreSQL server, or openssl and Crypt::Rijndael.
needs_pg() { [[ ($1 == pg_* || $1 == migrate_*) && $1 != *_offline ]]; }
needs_otp() { [[ $1 == verify || $1 == pg_verify || $1 == anycast* ]]; }
needs_dpkg() { [[ $1 == install ]]; }

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

if command -v openssl >/dev/null && perl -MCrypt::Rijndael -e 1 2>/dev/null; then OTP_OK=1; fi

for name in "${SELECTED[@]}"; do
    declare -F "scenario_$name" >/dev/null || { echo "unknown scenario: $name" >&2; exit 2; }
    if needs_otp "$name" && [[ $OTP_OK == 0 ]]; then
        echo "SKIP     $name (needs openssl and the Perl module Crypt::Rijndael)"; skip=$((skip + 1)); continue
    fi
    if needs_dpkg "$name" && ! command -v dpkg-deb >/dev/null; then
        echo "SKIP     $name (needs dpkg-deb)"; skip=$((skip + 1)); continue
    fi
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
