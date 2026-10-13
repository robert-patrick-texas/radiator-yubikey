#!/usr/bin/env bash
#
# yubikey-db-migrate.sh - Copy the YubiKey users from the SQLite database that
#                         yubikey-db.sh manages into its PostgreSQL database.
#
# VERSION
#   1.3.0
#
# HOW IT WORKS
#   1. Takes a consistent snapshot of the SQLite file (sqlite3 .backup) into a
#      private temporary directory, so Radiator can keep using SQLite.
#   2. Streams the snapshot into PostgreSQL (COPY) inside one transaction and
#      normalizes rows made by older tools: active 'true' becomes 1 and
#      'false' becomes 0 (reported, since Radiator treated it as active), AES keys
#      are re-encoded (base64 by default), modhex private IDs become hex,
#      invalid timestamps are replaced. Counters are always copied: resetting
#      them would let previously used OTPs be replayed.
#   3. Checks every migrated row against an independent SHA-256 fingerprint of
#      the snapshot (computed in Perl from a separate read), and commits only
#      if all of them match. Otherwise nothing is changed.
#   AES keys and private IDs never appear in output or on a command line; the
#   snapshot is deleted (shred) when the script exits.
#
# MODES
#   new   (default) First migration. The PostgreSQL table must be empty.
#   sync  Brings PostgreSQL up to date after a 'new' migration: inserts keys
#         that are missing and moves counters forward where SQLite is ahead.
#         It never moves a counter backward, never deletes, and leaves rows
#         that differ in username, password, active or key unchanged (they are
#         listed). Run it right after Radiator switches to PostgreSQL.
#
# CUTOVER
#   1. sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin "$USER"
#   2. ./yubikey-db-migrate.sh --dry-run /etc/radiator/db/yubicred.db
#   3. ./yubikey-db-migrate.sh /etc/radiator/db/yubicred.db
#   4. Point Radiator at PostgreSQL (./yubikey-db.sh -b pg config), restart it
#   5. ./yubikey-db-migrate.sh --mode sync /etc/radiator/db/yubicred.db
#   Keep the SQLite file unchanged afterwards, for rollback.
#
# PREREQUISITES
#   Ubuntu 26.04 LTS, bash 4+, sqlite3, psql, perl (JSON::PP, Digest::SHA,
#   MIME::Base64), PostgreSQL 18 or later set up with 'yubikey-db.sh -b pg
#   init-pg'. Run as a member of the admin role (yubikey_admin).
#
# ENVIRONMENT
#   PGDATABASE       PostgreSQL database name (default yubikey; -d overrides)
#   PGHOST, PGPORT, PGUSER, PGSSLMODE, PGSERVICE, PGTARGETSESSIONATTRS
#                    Standard PostgreSQL connection settings, used by psql.
#                    With two servers (PGHOST=db1,db2),
#                    PGTARGETSESSIONATTRS defaults to read-write.
#   PG_ADMIN_ROLE    Admin role named in error hints (default yubikey_admin)
#   SQLITE3, PSQL    sqlite3 and psql binaries (default: found on PATH)

set -euo pipefail
umask 077   # the snapshot holds AES keys

PROG=${0##*/}
VERSION=1.3.0
SQLITE3=${SQLITE3:-sqlite3}
PSQL=${PSQL:-psql}
MODE=new
SECRET_ENCODING=base64
DRY_RUN=0
SKIP_INVALID=0
DB_OPT=
SRC=
WORKDIR=      # private temp directory holding the snapshot; removed on exit

cleanup() {
    if [[ -n $WORKDIR ]]; then
        if [[ -f $WORKDIR/snapshot.db ]]; then
            shred -u -- "$WORKDIR/snapshot.db" 2>/dev/null || rm -f -- "$WORKDIR/snapshot.db"
        fi
        rm -rf -- "$WORKDIR"
    fi
}
trap cleanup EXIT

die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
    cat <<EOF
Usage: $PROG [options] SQLITE_FILE

Copy the users and YubiKeys from a yubikey-db.sh SQLite database into its
PostgreSQL database, in one transaction, verified row by row.

Options:
  -d, --db NAME                 PostgreSQL database (default: yubikey)
  -m, --mode MODE               new (default): the PostgreSQL table must be empty
                                sync: add missing keys and move counters forward
  -e, --secret-encoding ENC     How AES keys are stored in PostgreSQL:
                                base64 (default) | hex (match yubikey-db.sh -e)
  -n, --dry-run                 Do everything, then roll back: nothing changes
      --skip-invalid            Migrate the valid rows even if some are invalid
  -h, --help                    Show this help
  -V, --version                 Show the version

PostgreSQL connections use the standard PGHOST, PGPORT, PGUSER, PGSSLMODE and
PGSERVICE settings. Keep passwords in ~/.pgpass. With a primary and a standby,
list both (PGHOST=db1,db2): the copy goes to the one that accepts writes.
EOF
}

# Run psql on SQL read from stdin, stopping at the first error. Terse errors
# leave out PostgreSQL's DETAIL line, which can show key values. The exit
# status is psql's own, even when psql stops reading early on purpose.
pg_psql() {
    "$PSQL" -X -q -v ON_ERROR_STOP=1 "$@" < <(
        cat <<'EOF'
\set VERBOSITY terse
SET client_min_messages = warning;
SET standard_conforming_strings = on;
SET lock_timeout = '5s';
EOF
        cat
    )
}

# Columns read from SQLite. rowid identifies a row in messages and links the
# two reads of the snapshot.
SRC_COLUMNS="rowid, username, password, active, created, accessed, tokenId, userId, secret, counter, low, high"

# Read the snapshot as JSON (a separate read from the CSV that is loaded) and
# print "rowid,sha256" per row. The fingerprint covers username, password,
# active, public ID, private ID and AES key, normalized by the same rules as
# the SQL below but implemented independently, so a mistake in either shows
# up as a mismatch.
source_fingerprints() {
    "$SQLITE3" -batch -readonly -json "$WORKDIR/snapshot.db" \
        "SELECT rowid AS n, username, password, active, tokenId AS tokenid, userId AS userid, secret FROM yubikeys ORDER BY rowid;" \
    | perl -MJSON::PP -MDigest::SHA=sha256_hex -MMIME::Base64 -MEncode=encode_utf8 -e '
        local $/;
        my $json = <STDIN>;
        exit 0 unless defined $json && $json =~ /\S/;
        sub trim { my $v = shift; return undef unless defined $v; $v =~ s/^ +| +$//g; $v }
        for my $r (@{ decode_json($json) }) {
            my $active = $r->{active};
            if (!defined $active) {
                $active = 1;
            } else {
                my $a = lc trim("$active");
                $active = $a =~ /^(?:1|true|t|yes|y|on)$/ ? 1 : $a =~ /^(?:0|false|f|no|n|off|)$/ ? 0 : "?";
            }
            my $token = lc(trim($r->{tokenid}) // "");
            my $user  = lc(trim($r->{userid}) // "");
            $user =~ tr/cbdefghijklnrtuv/0123456789abcdef/
                if $user !~ /^[0-9a-f]{12}$/ && $user =~ /^[cbdefghijklnrtuv]{12}$/;
            my $s = trim($r->{secret}) // "";
            my $key = $s =~ /^[0-9A-Fa-f]{32}$/ ? lc $s
                    : $s =~ m{^[A-Za-z0-9+/]{22}==$} ? unpack("H*", decode_base64($s)) : "";
            my $line = join "\x1f", $r->{username} // "", $r->{password} // "", $active, $token, $user, $key;
            print "$r->{n},", sha256_hex(encode_utf8($line)), "\n";
        }'
}

# The migration, after the snapshot and fingerprints are loaded into the temp
# tables yk_src and yk_digest. psql variables: mode, enc, dry_run, skip_invalid.
# Lines starting with @@ are read by this script, not shown.
migration_sql() {
    cat <<'EOF'
SELECT :'mode' = 'new' AS is_new, :'mode' = 'sync' AS is_sync \gset

-- Normalize every source row. NULL means the value could not be used.
CREATE TEMP TABLE yk_norm ON COMMIT DROP AS
SELECT n, username,
       coalesce(password, '') AS password,
       active AS active_raw,
       CASE WHEN active IS NULL THEN 1   -- Radiator treats a missing value as active
            WHEN lower(btrim(active)) IN ('1', 'true', 't', 'yes', 'y', 'on') THEN 1
            WHEN lower(btrim(active)) IN ('0', 'false', 'f', 'no', 'n', 'off', '') THEN 0
       END AS active,
       tokenid AS tokenid_raw,
       lower(btrim(tokenid)) AS tokenid,
       (lower(btrim(userid)) !~ '^[0-9a-f]{12}$' AND lower(btrim(userid)) ~ '^[cbdefghijklnrtuv]{12}$') AS userid_was_modhex,
       CASE WHEN lower(btrim(userid)) ~ '^[0-9a-f]{12}$' THEN lower(btrim(userid))
            WHEN lower(btrim(userid)) ~ '^[cbdefghijklnrtuv]{12}$'
                THEN translate(lower(btrim(userid)), 'cbdefghijklnrtuv', '0123456789abcdef')
       END AS userid,
       CASE WHEN btrim(secret) ~ '^[0-9A-Fa-f]{32}$' THEN 'hex'
            WHEN btrim(secret) ~ '^[A-Za-z0-9+/]{22}==$' THEN 'base64'
       END AS secret_format,
       CASE WHEN btrim(secret) ~ '^[0-9A-Fa-f]{32}$' THEN lower(btrim(secret))
            WHEN btrim(secret) ~ '^[A-Za-z0-9+/]{22}==$' THEN encode(decode(btrim(secret), 'base64'), 'hex')
       END AS key_hex,
       CASE WHEN coalesce(counter, '') = '' THEN 0 WHEN counter ~ '^[0-9]{1,9}$' THEN counter::integer END AS counter,
       CASE WHEN coalesce(low, '') = '' THEN 0 WHEN low ~ '^[0-9]{1,9}$' THEN low::integer END AS low,
       CASE WHEN coalesce(high, '') = '' THEN 0 WHEN high ~ '^[0-9]{1,9}$' THEN high::integer END AS high,
       -- SQLite stores times as UTC text
       CASE WHEN created ~ '^\d{4}-\d{2}-\d{2}' AND pg_input_is_valid(created, 'timestamp')
            THEN created::timestamp AT TIME ZONE 'UTC' END AS created,
       CASE WHEN accessed ~ '^\d{4}-\d{2}-\d{2}' AND pg_input_is_valid(accessed, 'timestamp')
            THEN accessed::timestamp AT TIME ZONE 'UTC' END AS accessed,
       coalesce(accessed, '') <> '' AS had_accessed,
       NULL::text AS problem
  FROM yk_src;

UPDATE yk_norm SET problem = CASE
    WHEN coalesce(username, '') = '' THEN 'username is empty'
    WHEN length(username) > 255 THEN 'username is longer than 255 characters'
    WHEN username ~ '[[:cntrl:]]' THEN 'username contains control characters'
    WHEN tokenid IS NULL OR tokenid !~ '^([cbdefghijklnrtuv]{2}){1,16}$'
        THEN 'public ID is not modhex (2-32 characters from cbdefghijklnrtuv)'
    WHEN userid IS NULL THEN 'private ID is not 12 hex or 12 modhex characters'
    WHEN key_hex IS NULL THEN 'AES key is not 32 hex or 24 base64 characters'
    WHEN active IS NULL THEN 'active value ' || quote_literal(active_raw) || ' is not 1/0, true/false, yes/no or empty'
    WHEN counter IS NULL OR low IS NULL OR high IS NULL THEN 'counter, low or high is not a whole number'
END;

-- After normalization, two rows can name the same key (for example, a private
-- ID stored once in hex and once in modhex). Neither is migrated.
UPDATE yk_norm v SET problem = 'public ID is used by more than one source row (rows ' || d.rows || ')'
  FROM (SELECT tokenid, string_agg(n::text, ', ' ORDER BY n) AS rows FROM yk_norm
         WHERE problem IS NULL GROUP BY tokenid HAVING count(*) > 1) d
 WHERE v.problem IS NULL AND v.tokenid = d.tokenid;
UPDATE yk_norm v SET problem = 'private ID is used by more than one source row (rows ' || d.rows || ')'
  FROM (SELECT userid, string_agg(n::text, ', ' ORDER BY n) AS rows FROM yk_norm
         WHERE problem IS NULL GROUP BY userid HAVING count(*) > 1) d
 WHERE v.problem IS NULL AND v.userid = d.userid;

\if :is_sync
UPDATE yk_norm v SET problem = 'public ID belongs to a different key in PostgreSQL'
 WHERE v.problem IS NULL
   AND EXISTS (SELECT FROM yubikeys y WHERE y.tokenid = v.tokenid AND y.userid <> v.userid);
\endif

SELECT 'invalid: source row ' || n || ' (user ' || coalesce(regexp_replace(username, '[[:cntrl:]]', '?', 'g'), '?')
       || ', public ID ' || coalesce(regexp_replace(tokenid_raw, '[[:cntrl:]]', '?', 'g'), '?') || '): ' || problem
  FROM yk_norm WHERE problem IS NOT NULL ORDER BY n;

SELECT count(*) AS n_rows,
       count(*) FILTER (WHERE problem IS NULL) AS n_valid,
       count(*) FILTER (WHERE problem IS NOT NULL) AS n_invalid
  FROM yk_norm \gset
\echo 'Read' :n_rows 'row(s) from the snapshot:' :n_valid 'valid,' :n_invalid 'invalid'
SELECT (:n_invalid > 0 AND NOT :skip_invalid) AS stop_invalid, (:n_valid = 0) AS no_valid \gset
\if :stop_invalid
    ROLLBACK;
    \echo 'Nothing migrated: fix the rows above in SQLite, or re-run with --skip-invalid.'
    \echo '@@result invalid'
    \quit
\endif
\if :no_valid
    ROLLBACK;
    \echo 'Nothing migrated: there are no valid rows.'
    \echo '@@result empty'
    \quit
\endif

-- Insert keys that PostgreSQL does not have yet (all of them in mode new),
-- with their counters.
CREATE TEMP TABLE yk_inserted (userid text PRIMARY KEY) ON COMMIT DROP;
WITH ins AS (
    INSERT INTO yubikeys (username, password, active, created, accessed, tokenId, userId, secret, counter, low, high)
    SELECT username, password, active, coalesce(created, now()), accessed, tokenid, userid,
           CASE WHEN :'enc' = 'hex' THEN key_hex ELSE encode(decode(key_hex, 'hex'), 'base64') END,
           counter, low, high
      FROM yk_norm v
     WHERE problem IS NULL
       AND NOT EXISTS (SELECT FROM yubikeys y WHERE y.userid = v.userid)
     ORDER BY n
    RETURNING userid)
INSERT INTO yk_inserted SELECT userid FROM ins;
SELECT count(*) AS n_inserted FROM yk_inserted \gset
\echo 'Inserted' :n_inserted 'row(s), with their counters'

-- What normalization changed, among the rows inserted
SELECT count(*) FILTER (WHERE lower(btrim(active_raw)) IN ('true', 't', 'yes', 'y', 'on')) AS n_active_text,
       count(*) FILTER (WHERE lower(btrim(active_raw)) IN ('false', 'f', 'no', 'n', 'off')) AS n_active_off_text,
       count(*) FILTER (WHERE active_raw IS NULL) AS n_active_null,
       count(*) FILTER (WHERE secret_format <> :'enc') AS n_reencoded,
       count(*) FILTER (WHERE userid_was_modhex) AS n_modhex,
       count(*) FILTER (WHERE created IS NULL) AS n_created_fixed,
       count(*) FILTER (WHERE had_accessed AND accessed IS NULL) AS n_accessed_dropped
  FROM yk_norm v WHERE EXISTS (SELECT FROM yk_inserted i WHERE i.userid = v.userid) \gset
SELECT 'changed: ' || :n_active_text || ' active value(s) like ''true'' set to 1 (Radiator already treated them as active)'
 WHERE :n_active_text > 0;
SELECT 'changed: ' || :n_active_off_text || ' active value(s) like ''false'' set to 0: Radiator treated these as active, so these keys could log in before and now cannot'
 WHERE :n_active_off_text > 0;
SELECT 'changed: ' || :n_active_null || ' empty (NULL) active value(s) set to 1 (Radiator already treated them as active)'
 WHERE :n_active_null > 0;
SELECT 'changed: ' || :n_reencoded || ' AES key(s) re-encoded as ' || :'enc' WHERE :n_reencoded > 0;
SELECT 'changed: ' || :n_modhex || ' private ID(s) converted from modhex to hex' WHERE :n_modhex > 0;
SELECT 'changed: ' || :n_created_fixed || ' invalid created time(s) replaced with the current time'
 WHERE :n_created_fixed > 0;
SELECT 'changed: ' || :n_accessed_dropped || ' invalid accessed time(s) cleared' WHERE :n_accessed_dropped > 0;

-- Sync: move counters forward where SQLite is ahead. The condition is checked
-- again on the current row if Radiator updates it meanwhile, so a counter
-- never moves backward.
\if :is_sync
WITH upd AS (
    UPDATE yubikeys y
       SET counter = v.counter, low = v.low, high = v.high,
           accessed = GREATEST(y.accessed, v.accessed)
      FROM yk_norm v
     WHERE v.problem IS NULL AND y.userid = v.userid AND y.tokenid = v.tokenid
       AND NOT EXISTS (SELECT FROM yk_inserted i WHERE i.userid = v.userid)
       AND (v.counter, v.low) > (y.counter, y.low)
    RETURNING 1)
SELECT count(*) AS n_advanced FROM upd \gset
\echo 'Counters moved forward on' :n_advanced 'row(s)'
\endif

-- Verify: compare each migrated row in PostgreSQL with the fingerprint of the
-- snapshot, and its counters with the source.
CREATE TEMP TABLE yk_check ON COMMIT DROP AS
SELECT v.n, v.username, v.tokenid, v.counter, v.low,
       i.userid IS NOT NULL AS inserted,
       y.userid IS NOT NULL AS present,
       y.counter AS t_counter, y.low AS t_low,
       d.digest AS source_digest,
       encode(sha256(convert_to(concat_ws(E'\x1f', y.username, y.password, y.active::text, y.tokenid, y.userid,
           CASE WHEN y.secret ~ '^[0-9A-Fa-f]{32}$' THEN lower(y.secret)
                WHEN y.secret ~ '^[A-Za-z0-9+/]{22}==$' THEN encode(decode(y.secret, 'base64'), 'hex')
                ELSE '' END), 'UTF8')), 'hex') AS target_digest
  FROM yk_norm v
  LEFT JOIN yk_digest d USING (n)
  LEFT JOIN yubikeys y ON y.userid = v.userid
  LEFT JOIN yk_inserted i ON i.userid = v.userid
 WHERE v.problem IS NULL;

SELECT 'differs: user ' || username || ' (public ID ' || tokenid || ') has a different username, password,'
       || ' active, public ID or AES key in PostgreSQL; left unchanged'
  FROM yk_check WHERE present AND NOT inserted AND target_digest IS DISTINCT FROM source_digest ORDER BY n;
SELECT count(*) AS n_differs FROM yk_check
 WHERE present AND NOT inserted AND target_digest IS DISTINCT FROM source_digest \gset
\if :is_sync
SELECT count(*) AS n_target_only FROM yubikeys y
 WHERE NOT EXISTS (SELECT FROM yk_norm v WHERE v.problem IS NULL AND v.userid = y.userid) \gset
SELECT 'Rows that differ and were left unchanged: ' || :n_differs WHERE :n_differs > 0;
\echo 'Rows only in PostgreSQL, left unchanged:' :n_target_only
\endif

SELECT 'MISMATCH: source row ' || n || ' (user ' || username || ', public ID ' || tokenid || '): '
       || CASE WHEN NOT present THEN 'missing from PostgreSQL after the copy'
               WHEN inserted AND target_digest IS DISTINCT FROM source_digest THEN 'stored values differ from the source'
               WHEN inserted THEN 'counters differ from the source'
               ELSE 'counters are behind the source' END
  FROM yk_check
 WHERE NOT present
    OR (inserted AND (target_digest IS DISTINCT FROM source_digest OR (t_counter, t_low) <> (counter, low)))
    OR (NOT inserted AND target_digest = source_digest AND (t_counter, t_low) < (counter, low))
 ORDER BY n;
SELECT count(*) AS n_failed FROM yk_check
 WHERE NOT present
    OR (inserted AND (target_digest IS DISTINCT FROM source_digest OR (t_counter, t_low) <> (counter, low)))
    OR (NOT inserted AND target_digest = source_digest AND (t_counter, t_low) < (counter, low)) \gset

SELECT (:n_failed = 0) AS verified, (:n_failed = 0 AND NOT :dry_run) AS do_commit \gset
\if :verified
\echo 'Verified:' :n_valid 'row(s) checked against an independent SHA-256 fingerprint of the snapshot'
\endif
\if :do_commit
    COMMIT;
    \echo '@@result committed'
\elif :verified
    ROLLBACK;
    \echo '@@result dry-run'
\else
    ROLLBACK;
    \echo '@@result mismatch'
\endif
EOF
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--db)              DB_OPT=${2:?--db needs a database name}; shift 2 ;;
        -m|--mode)            MODE=${2:?--mode needs new or sync}; shift 2 ;;
        -e|--secret-encoding) SECRET_ENCODING=${2:?--secret-encoding needs base64 or hex}; shift 2 ;;
        -n|--dry-run)         DRY_RUN=1; shift ;;
        --skip-invalid)       SKIP_INVALID=1; shift ;;
        -h|--help)            usage; exit 0 ;;
        -V|--version)         printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
        -*)                   die "unknown option '$1' (see '$PROG --help')" ;;
        *)                    [[ -z $SRC ]] || die "only one SQLite file allowed"; SRC=$1; shift ;;
    esac
done
[[ -n $SRC ]] || { usage >&2; exit 1; }
[[ $MODE == new || $MODE == sync ]] || die "--mode must be new or sync"
[[ $SECRET_ENCODING == base64 || $SECRET_ENCODING == hex ]] || die "--secret-encoding must be base64 or hex"

for tool in "$SQLITE3" "$PSQL" perl; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
perl -MJSON::PP -MDigest::SHA -MMIME::Base64 -MEncode -e 1 2>/dev/null \
    || die "perl modules JSON::PP, Digest::SHA, MIME::Base64 and Encode are required"

[[ -f $SRC && -r $SRC ]] || die "cannot read $SRC"

if [[ -n $DB_OPT ]]; then
    export PGDATABASE=$DB_OPT
elif [[ -z ${PGDATABASE-} && -z ${PGSERVICE-} ]]; then
    export PGDATABASE=yubikey
fi
# With a primary and a standby (PGHOST=db1,db2), write to the primary.
if [[ ${PGHOST-} == *,* && -z ${PGTARGETSESSIONATTRS-} ]]; then
    export PGTARGETSESSIONATTRS=read-write
fi
DB_DESC="PostgreSQL database ${PGDATABASE:-from service $PGSERVICE}"

# Check the target before touching the source.
state=$(pg_psql --no-align --tuples-only 2>&1 <<'EOF'
SELECT CASE
    WHEN current_setting('server_version_num')::int < 180000 THEN 'version ' || current_setting('server_version')
    WHEN to_regclass('yubikeys') IS NULL THEN 'missing'
    WHEN NOT (has_table_privilege('yubikeys', 'SELECT') AND has_table_privilege('yubikeys', 'INSERT')
              AND has_table_privilege('yubikeys', 'UPDATE')) THEN 'denied'
    WHEN NOT has_database_privilege(current_database(), 'TEMPORARY') THEN 'no-temp'
    ELSE 'ok' END;
EOF
) || die "cannot use $DB_DESC: ${state#psql: error: }"
case $state in
    ok)        ;;
    version*)  die "PostgreSQL 18 or later is required (this server runs ${state#version })" ;;
    missing)   die "$DB_DESC has no yubikeys table; run 'yubikey-db.sh -b pg init-pg' first" ;;
    *)         die "${PGUSER:-$(id -un)} cannot write to the yubikeys table in $DB_DESC or create temporary tables (is it a member of ${PG_ADMIN_ROLE:-yubikey_admin}?)" ;;
esac

# Snapshot the source.
WORKDIR=$(mktemp -d)
"$SQLITE3" -batch -readonly "$SRC" ".backup '$WORKDIR/snapshot.db'" 2>/dev/null \
    || die "$SRC is not a readable SQLite database"
snapshot_time=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
check=$("$SQLITE3" -batch -readonly "$WORKDIR/snapshot.db" "PRAGMA quick_check;" 2>&1) || true
if [[ $check != ok ]]; then
    die "the snapshot of $SRC failed SQLite's integrity check: $check"
fi
"$SQLITE3" -batch -readonly "$WORKDIR/snapshot.db" "SELECT $SRC_COLUMNS FROM yubikeys LIMIT 0;" >/dev/null 2>&1 \
    || die "$SRC has no yubikeys table with the columns yubikey-db.sh uses"

info "Source: $SRC (snapshot taken $snapshot_time)"
info "Target: $DB_DESC, mode $MODE, AES keys stored as $SECRET_ENCODING"
if [[ $DRY_RUN == 1 ]]; then info "Dry run: all changes will be rolled back"; fi

bool() { if [[ $1 == 1 ]]; then echo true; else echo false; fi; }

# The whole psql session: the snapshot and its fingerprints are streamed in
# with COPY, between the SQL, so secrets never touch disk again.
session() {
    echo 'BEGIN;'
    if [[ $MODE == new ]]; then
        # The table must be empty, and no other session may add rows meanwhile.
        cat <<'EOF'
LOCK TABLE yubikeys IN SHARE ROW EXCLUSIVE MODE;
SELECT count(*) AS n_target, count(*) > 0 AS target_used FROM yubikeys \gset
\if :target_used
    ROLLBACK;
    \echo 'Nothing migrated: the yubikeys table in PostgreSQL already has' :n_target 'row(s); use --mode sync'
    \echo '@@result not-empty'
    \quit
\endif
EOF
    fi
    cat <<'EOF'
CREATE TEMP TABLE yk_src (n bigint, username text, password text, active text, created text,
    accessed text, tokenid text, userid text, secret text, counter text, low text, high text) ON COMMIT DROP;
COPY yk_src FROM STDIN (FORMAT csv);
EOF
    "$SQLITE3" -batch -readonly -csv "$WORKDIR/snapshot.db" "SELECT $SRC_COLUMNS FROM yubikeys ORDER BY rowid;"
    echo '\.'
    echo 'CREATE TEMP TABLE yk_digest (n bigint PRIMARY KEY, digest text NOT NULL) ON COMMIT DROP;'
    echo 'COPY yk_digest FROM STDIN (FORMAT csv);'
    source_fingerprints
    echo '\.'
    migration_sql
}

if ! out=$(pg_psql --no-align --tuples-only -v mode="$MODE" -v enc="$SECRET_ENCODING" \
            -v dry_run="$(bool "$DRY_RUN")" -v skip_invalid="$(bool "$SKIP_INVALID")" < <(session)); then
    die "migration failed and was rolled back; $DB_DESC was not changed"
fi

result=
while IFS= read -r line; do
    case $line in
        '@@result '*) result=${line#@@result } ;;
        *)            info "$line" ;;
    esac
done <<<"$out"

case $result in
    committed)
        info "Committed."
        if [[ $MODE == new ]]; then
            info "If Radiator still uses SQLite, switch it to PostgreSQL now, then run: $PROG --mode sync $SRC"
        fi ;;
    dry-run)
        info "Dry run complete: everything checked out, and the changes were rolled back." ;;
    mismatch)
        die "verification failed; the changes were rolled back and $DB_DESC was not changed" ;;
    *)
        exit 1 ;;
esac
