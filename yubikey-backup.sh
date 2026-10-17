#!/usr/bin/env bash
#
# yubikey-backup.sh - Encrypted backups of the YubiKey database in
#                     PostgreSQL: every day, each database server dumps its
#                     own copy of the database, encrypted to a certificate
#                     whose private key is kept elsewhere.
#
# VERSION
#   In the file VERSION, next to this script; -V shows it.
#
# HOW IT WORKS
#   'run' (yubikey-backup.service, which yubikey-backup.timer starts every
#   day) dumps the database from this server's own PostgreSQL (a standby or
#   the primary) with pg_dump, and encrypts the dump on the way with openssl
#   cms: AES-256-GCM, with a new key for each file, wrapped with RSA-OAEP
#   for the certificate CERT. The dump is never on disk in clear, and only
#   CERT's private key, kept off the servers, decrypts it. The newest backup
#   is DIR/yubikey-db.cms.0: each run moves the others up one (.0 to .1, .1
#   to .2, ...) and keeps KEEP of them, .0 to .KEEP-1.
#   'restore' puts a backup back, on the primary, in one transaction: each
#   table of the database is replaced with the backup's, except that a
#   counter that is ahead now stays (so an OTP used since the backup can't
#   be used again), and so do the keys of the anycast checks (anycast-*),
#   which renew themselves. It says first what the restore would undo, and
#   asks.
#
# COMMANDS
#   run       Make a backup now
#   status    Show the backups and the last run; exits 0 when the newest is
#             less than 26 hours old and the last run worked
#   decrypt --key KEY [--passin ARG] FILE OUT
#             Decrypt FILE (a backup, or another file encrypted to CERT) to
#             OUT, which is written only when FILE is whole and unchanged
#   check [--key KEY] [--passin ARG] FILE
#             Decrypt FILE and read the dump in it back whole, and show what
#             it holds. Changes nothing; needs only openssl and pg_restore,
#             so it works on an admin's machine too
#   restore [--key KEY] [--passin ARG] [--yes] FILE
#             Restore FILE, encrypted (with --key) or decrypted already,
#             into this server's PostgreSQL, which must be the primary
#
# OPTIONS
#   -c FILE        The settings (default /etc/radiator/backup.conf; restore
#                  works without them, with the default database)
#   --key KEY      CERT's private key (PEM), to decrypt with. openssl asks
#                  for its passphrase
#   --passin ARG   Where openssl takes the passphrase from instead, as its
#                  -passin: pass:TEXT, env:VAR, file:PATH or fd:N
#   --yes          restore: don't ask
#
# FILES
#   /etc/radiator/backup.conf     settings (see yubikey-backup.example.conf)
#   DIR/yubikey-db.cms.N          the backups, newest first (mode 0640,
#                                 group adm: encrypted, for the admins to
#                                 fetch)
#   /var/lib/yubikey-backup/last  the last run, for 'status'
#
# PREREQUISITES
#   PostgreSQL 18's client programs (pg_dump, pg_restore, psql) and openssl.
#   'run' and 'restore' as root on a database server (they use PostgreSQL
#   as postgres, through the local socket), or as a user who may dump or
#   restore the database (tests).
#
# EXIT STATUS
#   0 success (status: a backup of the last 26 hours, and the last run
#   worked); 1 a step failed (status: no recent backup, or the last run
#   failed); 3 a problem with the settings, the options or the system.
#
# ENVIRONMENT (for tests)
#   BACKUP_STATE_DIR   instead of /var/lib/yubikey-backup
#   BACKUP_GROUP       the backups' group (default adm; empty: unchanged)
#   PSQL, PG_DUMP, PG_RESTORE, OPENSSL
#                      the commands to use

set -uo pipefail
umask 077

PROG=${0##*/}
# The version is in the file VERSION, next to this script (the package has it
# written here instead).
VERSION=$(cat -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/VERSION" 2>/dev/null) || VERSION=unknown
DEFAULT_CONF=/etc/radiator/backup.conf
CONF=$DEFAULT_CONF
STATE_DIR=${BACKUP_STATE_DIR:-/var/lib/yubikey-backup}
GROUP=${BACKUP_GROUP-adm}
PSQL=${PSQL:-psql}
PG_DUMP=${PG_DUMP:-pg_dump}
PG_RESTORE=${PG_RESTORE:-pg_restore}
OPENSSL=${OPENSSL:-openssl}
BASE=yubikey-db.cms
MAX_AGE=$((26 * 3600))      # status: a newer backup than this is recent

# Settings, from the settings file
CERT=/etc/radiator/backup.crt KEEP=7 DIR=/var/backups DATABASE=yubikey

# Options
KEY='' PASSIN='' YES=0
TMP=''      # a private temporary directory, removed on exit

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 3; }
fail() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

cleanup() { if [[ -n $TMP ]]; then rm -rf -- "$TMP"; fi; }
trap cleanup EXIT

tmpdir() {
    [[ -n $TMP ]] || TMP=$(mktemp -d "${TMPDIR:-/tmp}/yubikey-backup.XXXXXX") || die "cannot make a temporary directory"
}

usage() {
    cat <<EOF
Usage: $PROG [-c FILE] COMMAND [OPTIONS]

Commands:
  run       Make a backup now (yubikey-backup.timer does it every day)
  status    Show the backups and the last run; exits 0 when the newest is
            less than 26 hours old and the last run worked
  decrypt --key KEY [--passin ARG] FILE OUT
            Decrypt FILE to OUT, only when FILE is whole and unchanged
  check [--key KEY] [--passin ARG] FILE
            Decrypt FILE, read the dump back whole and show what it holds;
            changes nothing
  restore [--key KEY] [--passin ARG] [--yes] FILE
            Restore FILE into this server's PostgreSQL (the primary). A
            counter that is ahead now stays, and so do the anycast checks'
            keys; it shows what it would undo, and asks

Options:
  -c FILE        The settings (default $DEFAULT_CONF)
  --key KEY      The private key of the backups' certificate (PEM)
  --passin ARG   Its passphrase, as openssl's -passin (pass:, env:, file:,
                 fd:); without it, openssl asks
  --yes          restore: don't ask
  -h             Show this help
  -V             Show the version
EOF
}

# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------

conf_pair() {
    case $1 in
        CERT|KEEP|DIR|DATABASE) printf -v "$1" '%s' "$2" ;;
        *) die "$CONF line $3: unknown setting '$1'" ;;
    esac
}

# NAME=value lines; blank lines and lines starting with # are skipped, and a
# value may be in quotes. The file is never run as shell code. With
# "optional", a missing file leaves the defaults.
load_conf() {
    local line n=0 name value
    if [[ ${1-} == optional && ! -e $CONF ]]; then return 0; fi
    [[ -f $CONF && -r $CONF ]] || die "cannot read $CONF"
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line =~ ^[[:space:]]*([A-Za-z_]+)[[:space:]]*=(.*)$ ]] || die "$CONF line $n: expected NAME=value"
        name=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        value=${value#"${value%%[![:space:]]*}"} value=${value%"${value##*[![:space:]]}"}
        if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
        conf_pair "$name" "$value" "$n"
    done <"$CONF"
    if ! [[ $KEEP =~ ^[0-9]{1,3}$ ]] || ((10#$KEEP < 1 || 10#$KEEP > 366)); then
        die "$CONF: KEEP must be a number from 1 to 366"
    fi
    KEEP=$((10#$KEEP))
    [[ $DIR == /* ]] || die "$CONF: DIR must be a full path"
    [[ $DATABASE =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || die "$CONF: DATABASE '$DATABASE' is not a database name"
}

# --------------------------------------------------------------------------
# PostgreSQL and openssl
# --------------------------------------------------------------------------

# as_postgres COMMAND...: run COMMAND as postgres, through the local socket
# (as the current user when not root).
as_postgres() {
    if [[ $EUID -eq 0 ]]; then
        # setpriv, not runuser: no PAM session.
        setpriv --reuid=postgres --regid=postgres --init-groups env -u PGHOST -u PGPORT -u PGUSER -u PGSERVICE \
            -u PGDATABASE HOME=/var/lib/postgresql "$@"
    else
        "$@"
    fi
}

local_psql() { as_postgres "$PSQL" -X -q -At -v ON_ERROR_STOP=1 -d "$DATABASE" "$@"; }

# encrypt OUT < DATA: encrypt standard input to CERT.
encrypt() {
    "$OPENSSL" cms -encrypt -binary -aes-256-gcm -recip "$CERT" -keyopt rsa_padding_mode:oaep \
        -keyopt rsa_oaep_md:sha256 -outform DER -out "$1"
}

# decrypt_to FILE OUT: decrypt FILE with KEY to OUT. On a file that isn't
# whole, or was changed, openssl fails but writes what it decrypted anyway:
# OUT is removed then.
decrypt_to() {
    local err rc=0
    [[ -n $KEY ]] || die "$1 is not a dump: to decrypt it (a backup), name the private key (--key KEY)"
    [[ -r $KEY ]] || die "cannot read the private key $KEY"
    err=$("$OPENSSL" cms -decrypt -binary -inform DER -in "$1" -inkey "$KEY" ${PASSIN:+-passin "$PASSIN"} \
              -out "$2" 2>&1) || rc=$?
    if [[ $rc != 0 ]]; then
        rm -f -- "$2"
        if grep -q 'maybe wrong password\|bad decrypt' <<<"$err"; then
            fail "cannot read the private key $KEY: a wrong passphrase"
        fi
        err=$(grep -v '^ *$' <<<"$err" | head -1)
        fail "$1 didn't decrypt: a wrong key, or the file isn't whole or was changed (openssl: ${err:-exit $rc})"
    fi
}

# open_dump FILE: the dump in FILE, in DUMP: FILE itself when it is a dump
# already (pg_dump's custom format), or FILE decrypted to a temporary file.
open_dump() {
    [[ -f $1 && -r $1 ]] || die "cannot read $1"
    if [[ $(head -c 5 -- "$1") == PGDMP ]]; then
        DUMP=$1
    else
        tmpdir
        DUMP=$TMP/dump
        decrypt_to "$1" "$DUMP"
    fi
}

# read_dump: check that DUMP is a whole dump of the YubiKey database, and
# read what it says about itself: MADE, FROM (PostgreSQL's version), SCHEMA.
read_dump() {
    local toc err
    # (The time the dump was made, which pg_dump wrote in UTC.)
    toc=$(TZ=UTC "$PG_RESTORE" -l -- "$DUMP" 2>&1) || fail "not a dump that pg_restore can read: ${toc%%$'\n'*}"
    [[ $toc =~ TABLE\ DATA\ ([a-z_][a-z0-9_]*)\ yubikeys\  ]] || fail "not a backup of the YubiKey database: it has no table yubikeys"
    SCHEMA=${BASH_REMATCH[1]}
    MADE=$(sed -n 's/^; *Archive created at //p' <<<"$toc")
    FROM=$(sed -n 's/^; *Dumped from database version: \([^ ]*\).*/\1/p' <<<"$toc")
    # Every part of it, decompressed (no database needed).
    err=$("$PG_RESTORE" -f /dev/null -- "$DUMP" 2>&1) || fail "the dump can't be read back whole: ${err%%$'\n'*}"
}

# dump_rows TABLE COLUMN...: the rows of TABLE in DUMP, those columns only,
# in COPY's text format (as COPY ... TO STDOUT writes them).
dump_rows() {
    local table=$1
    shift
    "$PG_RESTORE" -a -t "$table" -f - -- "$DUMP" 2>/dev/null | awk -v cols="$*" '
        BEGIN { n = split(cols, want, " ") }
        !copying && /^COPY / {
            s = $0; sub(/^COPY [^(]*\(/, "", s); sub(/\) FROM stdin;$/, "", s)
            m = split(s, have, ", "); delete at
            for (i = 1; i <= m; i++) { gsub(/"/, "", have[i]); at[have[i]] = i }
            copying = 1; next
        }
        copying && $0 == "\\." { copying = 0; next }
        copying {
            split($0, f, "\t"); line = ""
            for (i = 1; i <= n; i++) line = line (i > 1 ? "\t" : "") (want[i] in at ? f[at[want[i]]] : "")
            print line
        }'
}

# The columns that the preview of a restore compares, the key first.
YK_COLS="tokenid userid username secret password active label"
SA_COLS="username password active label"

# rows_of WHERE: the rows to compare, of the backup (dump) or the database
# (now), one file each in TMP. A table that isn't there has no rows.
rows_of() {
    local t c q
    if [[ $1 == dump ]]; then
        dump_rows yubikeys "$YK_COLS" >"$TMP/dump.yubikeys"
        dump_rows service_accounts "$SA_COLS" >"$TMP/dump.service_accounts"
        {
            dump_rows user_groups name label | sed 's/^/group\t/'
            dump_rows group_members user_group username | sed 's/^/member\t/'
            dump_rows group_access user_group device_group priv_lvl radius_reply | sed 's/^/access\t/'
            dump_rows group_rules user_group device_group seq rule | sed 's/^/rule\t/'
        } >"$TMP/dump.groups"
        return
    fi
    for t in yubikeys service_accounts; do
        c=$YK_COLS
        [[ $t == service_accounts ]] && c=$SA_COLS
        q="COPY (SELECT ${c// /, } FROM $SCHEMA.$t) TO STDOUT"
        if [[ $(local_psql -c "SELECT to_regclass('$SCHEMA.$t') IS NOT NULL") == t ]]; then
            local_psql -c "$q" >"$TMP/now.$t" || die "cannot read the table $t"
        else
            : >"$TMP/now.$t"
        fi
    done
    : >"$TMP/now.groups"
    if [[ $(local_psql -c "SELECT to_regclass('$SCHEMA.group_rules') IS NOT NULL") == t ]]; then
        local_psql >"$TMP/now.groups" <<EOF || die "cannot read the groups"
COPY (SELECT 'group', name, label FROM $SCHEMA.user_groups) TO STDOUT;
COPY (SELECT 'member', user_group, username FROM $SCHEMA.group_members) TO STDOUT;
COPY (SELECT 'access', user_group, device_group, priv_lvl, radius_reply FROM $SCHEMA.group_access) TO STDOUT;
COPY (SELECT 'rule', user_group, device_group, seq, rule FROM $SCHEMA.group_rules) TO STDOUT;
EOF
    fi
}

# counts PREFIX: "N YubiKeys (of M users), N service accounts, N groups".
counts() {
    python3 - "$TMP" "$1" <<'EOF'
import sys
d, p = sys.argv[1], sys.argv[2]
rows = lambda t: [l.split("\t") for l in open(f"{d}/{p}.{t}").read().split("\n") if l]
yk, sa, gr = rows("yubikeys"), rows("service_accounts"), rows("groups")
n = lambda k, one, many: f"{k} {one if k == 1 else many}"
users = len({r[2] for r in yk})
print(f"{n(len(yk), 'YubiKey', 'YubiKeys')} (of {n(users, 'user', 'users')}), "
      f"{n(len(sa), 'service account', 'service accounts')}, "
      f"{n(sum(r[0] == 'group' for r in gr), 'group', 'groups')}")
EOF
}

# preview: what a restore would undo: the YubiKeys, service accounts and
# groups added, deleted or changed since the backup (the anycast checks'
# keys stay, so they aren't listed). Prints nothing when nothing would.
preview() {
    python3 - "$TMP" <<'EOF'
import sys
d = sys.argv[1]
def rows(p, t):
    return [l.split("\t") for l in open(f"{d}/{p}.{t}").read().split("\n") if l]
def shown(items, most=10):
    s = ", ".join(items[:most])
    return s + (f", and {len(items) - most} more" if len(items) > most else "")
out = []
def section(what, b, n, change):
    gone = [k for k in n if k not in b]
    back = [k for k in b if k not in n]
    diff = []
    for k in b:
        if k in n and b[k] != n[k]:
            diff.append(f"{k} ({change(b[k], n[k])})")
    if gone:
        out.append(f"  {what} added since the backup, which go: {shown(sorted(gone))}")
    if back:
        out.append(f"  {what} deleted since the backup, which come back: {shown(sorted(back))}")
    if diff:
        out.append(f"  {what} changed since the backup, which are put back as they were: {shown(sorted(diff))}")

def active(b, n):
    if b != n:
        return ["enabled again" if b == "1" else "disabled again"]
    return []

# YubiKeys, by public ID: userid username secret password active label
def yk(p):
    return {f"{r[2]} {r[0]}": r[1:] for r in rows(p, "yubikeys") if not r[2].startswith("anycast-")}
def yk_change(b, n):
    c = []
    if b[0] != n[0] or b[2] != n[2]:
        c.append("its key")
    c += active(b[4], n[4])
    if b[3] != n[3]:
        c.append("its PIN")
    if b[5] != n[5]:
        c.append("its label")
    return ", ".join(c)
section("YubiKeys", yk("dump"), yk("now"), yk_change)

def sa(p):
    return {r[0]: r[1:] for r in rows(p, "service_accounts")}
def sa_change(b, n):
    c = []
    if b[0] != n[0]:
        c.append("its password")
    c += active(b[1], n[1])
    if b[2] != n[2]:
        c.append("its label")
    return ", ".join(c)
section("Service accounts", sa("dump"), sa("now"), sa_change)

def gr(p):
    g = {}
    for r in rows(p, "groups"):
        if r[0] == "group":
            g.setdefault(r[1], {})["label"] = r[2]
        else:
            g.setdefault(r[1], {}).setdefault(r[0], set()).add(tuple(r[2:]))
    return g
def gr_change(b, n):
    return ", ".join(w for k, w in (("label", "its label"), ("member", "members"), ("access", "access"),
                                    ("rule", "rules")) if b.get(k) != n.get(k))
section("Groups", gr("dump"), gr("now"), gr_change)
print("\n".join(out))
EOF
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

# record RESULT TEXT: the last run, for status.
record() {
    mkdir -p -- "$STATE_DIR" 2>/dev/null
    printf 'time=%s\nresult=%s\ntext=%s\n' "$(date +%s)" "$1" "${2//$'\n'/ }" >"$STATE_DIR/last.new" \
        && mv -f -- "$STATE_DIR/last.new" "$STATE_DIR/last"
}

# rotate: move the backups up one (.0 to .1, ...), keeping KEEP - 1 of them.
rotate() {
    local f i
    for f in "$DIR/$BASE".*; do
        i=${f##*.}
        if [[ $i =~ ^[0-9]+$ ]] && ((10#$i >= KEEP - 1)); then rm -f -- "$f"; fi
    done
    for ((i = KEEP - 2; i >= 0; i--)); do
        if [[ -e $DIR/$BASE.$i ]]; then mv -f -- "$DIR/$BASE.$i" "$DIR/$BASE.$((i + 1))"; fi
    done
}

cmd_run() {
    local new err rc role try size
    load_conf
    [[ -r $CERT ]] || die "cannot read the certificate $CERT"
    "$OPENSSL" x509 -noout -in "$CERT" 2>/dev/null || die "$CERT is not a certificate (PEM)"
    [[ -d $DIR && -w $DIR ]] || die "cannot write to $DIR"
    tmpdir
    new=$DIR/.$BASE.new
    for try in 1 2; do
        rc=0
        # pg_dump as postgres; the file is root's. (On a standby, a dump can
        # be cancelled by a conflict with recovery: once more, then.) The
        # dump holds the time it was made in pg_dump's time zone, without
        # the zone: UTC, as pg_restore reads it.
        TZ=UTC as_postgres "$PG_DUMP" -Fc --lock-wait-timeout=60000 -d "$DATABASE" 2>"$TMP/err" \
            | encrypt "$new" 2>>"$TMP/err" || rc=1
        [[ $rc == 0 ]] && break
        rm -f -- "$new"
        [[ $try == 1 ]] && sleep 10
    done
    if [[ $rc != 0 ]]; then
        err=$(grep -v '^ *$' "$TMP/err" | head -3 | paste -sd' ')
        record failed "${err:-pg_dump or openssl failed}"
        fail "no backup made: ${err:-pg_dump or openssl failed}"
    fi
    chmod 0640 -- "$new"
    if [[ -n $GROUP ]]; then chgrp -- "$GROUP" "$new" 2>/dev/null || chmod 0600 -- "$new"; fi
    rotate
    mv -f -- "$new" "$DIR/$BASE.0" || { record failed "cannot rename $new"; fail "cannot rename $new"; }
    role=$(local_psql -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'a standby' ELSE 'the primary' END" 2>/dev/null)
    size=$(( ($(stat -c %s -- "$DIR/$BASE.0") + 1023) / 1024 ))
    record ok "made $DIR/$BASE.0"
    log "made $DIR/$BASE.0 ($size KB, of database $DATABASE${role:+ on $role}); keeping $KEEP"
}

# ago SECONDS: "5 min", "3 h", "2 days".
ago() {
    if (($1 < 3600)); then echo "$(($1 / 60)) min"
    elif (($1 < 172800)); then echo "$(($1 / 3600)) h"
    else echo "$(($1 / 86400)) days"; fi
}

cmd_status() {
    local -A last=()
    local name value now f n=0 oldest='' newest age rc=0 subject end fp
    load_conf
    now=$(date +%s)
    for f in "$DIR/$BASE".*; do
        [[ ${f##*.} =~ ^[0-9]+$ && -f $f ]] || continue
        n=$((n + 1))
        if [[ -z $oldest || ${f##*.} -gt ${oldest##*.} ]]; then oldest=$f; fi
    done
    if [[ -f $STATE_DIR/last ]]; then
        while IFS='=' read -r name value; do last[$name]=$value; done <"$STATE_DIR/last"
    fi
    newest=$DIR/$BASE.0
    if [[ ${last[result]-} == failed ]]; then
        printf 'the last backup failed, %s ago: %s\n' "$(ago $((now - last[time])))" "${last[text]}"
        rc=1
    elif [[ ! -f $newest ]]; then
        printf 'no backup yet in %s\n' "$DIR"
        rc=1
    else
        age=$((now - $(stat -c %Y -- "$newest")))
        if ((age > MAX_AGE)); then
            printf 'the newest backup is %s old: none was made in the last 26 hours\n' "$(ago "$age")"
            rc=1
        else
            printf 'the newest backup is %s old\n' "$(ago "$age")"
        fi
    fi
    if [[ -f $newest ]]; then
        printf 'newest: %s, %s, %s KB\n' "$newest" "$(date -u -d "@$(stat -c %Y -- "$newest")" '+%F %T UTC')" \
            "$(( ($(stat -c %s -- "$newest") + 1023) / 1024 ))"
    fi
    if ((n > 0)); then
        printf 'kept: %d of %d, the oldest %s of %s\n' "$n" "$KEEP" "${oldest##*/}" \
            "$(date -u -d "@$(stat -c %Y -- "$oldest")" '+%F %T UTC')"
    fi
    if [[ -n ${last[time]-} ]]; then
        printf 'last run: %s, %s\n' "$(date -u -d "@${last[time]}" '+%F %T UTC')" "${last[result]}"
    fi
    if subject=$("$OPENSSL" x509 -noout -subject -nameopt oneline -in "$CERT" 2>/dev/null); then
        end=$("$OPENSSL" x509 -noout -enddate -dateopt iso_8601 -in "$CERT" 2>/dev/null | sed 's/^notAfter=//')
        fp=$("$OPENSSL" x509 -noout -fingerprint -sha256 -in "$CERT" 2>/dev/null | sed 's/^.*=//')
        printf 'encrypted to: %s (SHA-256 %s), until %s\n' "${subject#subject=}" "$fp" "${end%% *}"
    else
        printf 'encrypted to: cannot read %s\n' "$CERT"
        rc=1
    fi
    return $rc
}

# Options of decrypt, check and restore: --key, --passin, --yes; the rest
# in ARGS.
ARGS=()
key_options() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --key)    KEY=${2:?--key needs a file}; shift 2 ;;
            --passin) PASSIN=${2:?--passin needs an argument}; shift 2 ;;
            --yes)    YES=1; shift ;;
            --)       shift; ARGS+=("$@"); break ;;
            -?*)      die "unknown option '$1' (see '$PROG help')" ;;
            *)        ARGS+=("$1"); shift ;;
        esac
    done
}

cmd_decrypt() {
    local out dir
    key_options "$@"
    [[ $YES == 0 ]] || die "decrypt: --yes is for restore"
    [[ ${#ARGS[@]} == 2 ]] || die "decrypt: name the file and where to write it (decrypt --key KEY FILE OUT)"
    [[ -n $KEY ]] || die "decrypt: name the private key (--key KEY)"
    [[ -f ${ARGS[0]} && -r ${ARGS[0]} ]] || die "cannot read ${ARGS[0]}"
    out=${ARGS[1]}
    [[ ! -e $out ]] || die "$out exists: remove it first, or name another file"
    dir=$(dirname -- "$out")
    [[ -d $dir && -w $dir ]] || die "cannot write to the directory $dir"
    tmpdir
    decrypt_to "${ARGS[0]}" "$TMP/out"
    mv -- "$TMP/out" "$out" || die "cannot write $out"
    log "decrypted ${ARGS[0]} to $out ($(( ($(stat -c %s -- "$out") + 1023) / 1024 )) KB, mode 0600)"
}

cmd_check() {
    key_options "$@"
    [[ $YES == 0 ]] || die "check: --yes is for restore"
    [[ ${#ARGS[@]} == 1 ]] || die "check: name one file"
    open_dump "${ARGS[0]}"
    read_dump
    tmpdir
    rows_of dump
    log "${ARGS[0]}: a whole backup of the YubiKey database, made $MADE (PostgreSQL ${FROM:-?})"
    log "  it holds $(counts dump)"
}

cmd_restore() {
    local answer changes out ahead kept
    key_options "$@"
    [[ ${#ARGS[@]} == 1 ]] || die "restore: name one file"
    load_conf optional
    out=$(local_psql -c 'SELECT pg_is_in_recovery()' 2>&1) || die "cannot reach this server's PostgreSQL: ${out%%$'\n'*}"
    [[ $out == f ]] || die "this server's PostgreSQL is a standby: restore on the primary"
    open_dump "${ARGS[0]}"
    read_dump
    tmpdir
    rows_of dump
    rows_of now
    log "The backup, made $MADE: $(counts dump)."
    log "The database $DATABASE now: $(counts now)."
    changes=$(preview) || die "cannot compare the backup with the database"
    if [[ -n $changes ]]; then
        log "The restore puts the backup's tables back, and so undoes what changed since:"
        log "$changes"
    else
        log "The YubiKeys, service accounts and groups are as in the backup."
    fi
    log "Counters that are ahead now stay, and so do the anycast checks' keys."
    if [[ $YES == 0 ]]; then
        [[ -t 0 ]] || die "restore: answer on a terminal, or add --yes"
        read -r -p "Restore it into $DATABASE? Type yes: " answer
        [[ $answer == yes ]] || fail "nothing restored"
    fi

    # One transaction: the counters and the anycast checks' rows now, the
    # backup's tables (pg_restore --clean, written out whole first), and then
    # those counters and rows again. Logins wait for it; it waits at most
    # 10 s for a lock.
    out=$("$PG_RESTORE" --clean --if-exists -f "$TMP/restore.sql" -- "$DUMP" 2>&1) \
        || fail "nothing restored: ${out%%$'\n'*}"
    out=$( {
        cat <<EOF
\\o /dev/null
BEGIN;
SET lock_timeout = '10s';
SELECT to_regclass('$SCHEMA.yubikeys') IS NOT NULL AS had_yubikeys \\gset
\\if :had_yubikeys
CREATE TEMP TABLE keep_counters ON COMMIT DROP AS
    SELECT userid, counter, low, high, accessed FROM $SCHEMA.yubikeys;
CREATE TEMP TABLE keep_anycast ON COMMIT DROP AS
    SELECT username, password, active, created, accessed, tokenid, userid, secret, counter, low, high, label
      FROM $SCHEMA.yubikeys WHERE username LIKE 'anycast-%';
\\else
CREATE TEMP TABLE keep_counters (userid text, counter integer, low integer, high integer,
                                 accessed timestamptz) ON COMMIT DROP;
CREATE TEMP TABLE keep_anycast (username text, password text, active smallint, created timestamptz,
                                accessed timestamptz, tokenid text, userid text, secret text,
                                counter integer, low integer, high integer, label text) ON COMMIT DROP;
\\endif
EOF
        sed "s/^SET lock_timeout = 0;\$/SET lock_timeout = '10s';/" "$TMP/restore.sql"
        cat <<EOF
WITH gone AS (DELETE FROM $SCHEMA.yubikeys WHERE username IN (SELECT username FROM pg_temp.keep_anycast)
              RETURNING 1)
SELECT count(*) FROM gone \\gset
INSERT INTO $SCHEMA.yubikeys (username, password, active, created, accessed, tokenid, userid, secret,
                              counter, low, high, label)
    SELECT username, password, active, created, accessed, tokenid, userid, secret, counter, low, high, label
      FROM pg_temp.keep_anycast;
SELECT count(*) AS kept FROM pg_temp.keep_anycast \\gset
WITH ahead AS (
    UPDATE $SCHEMA.yubikeys y SET counter = k.counter, low = k.low, high = k.high, accessed = k.accessed
      FROM pg_temp.keep_counters k
     WHERE y.userid = k.userid AND (k.counter, k.low) > (y.counter, y.low)
       AND y.username NOT LIKE 'anycast-%'
    RETURNING 1)
SELECT count(*) AS ahead FROM ahead \\gset
COMMIT;
\\echo :ahead :kept
EOF
    } | local_psql 2>&1) || fail "nothing restored: ${out%%$'\n'*}"
    # (The last line, only after the COMMIT.)
    [[ ${out##*$'\n'} =~ ^([0-9]+)\ ([0-9]+)$ ]] || fail "the restore didn't finish: ${out%%$'\n'*}"
    ahead=${BASH_REMATCH[1]} kept=${BASH_REMATCH[2]}
    log "Restored the backup of $MADE into $DATABASE: $(counts dump | sed 's/ (of [^)]*)//')."
    log "Kept the counters of $ahead YubiKey(s) that were ahead, and the keys of $kept anycast check(s)."
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        -c)                   CONF=${2:?-c needs a file}; shift 2 ;;
        -h|--help|help)       usage; exit 0 ;;
        -V|--version|version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
        -*)                   die "unknown option '$1' (see '$PROG help')" ;;
        *)                    break ;;
    esac
done
[[ $# -ge 1 ]] || { usage >&2; exit 3; }

cmd=$1
shift
case $cmd in
    run)     [[ $# == 0 ]] || die "run takes no arguments"; cmd_run ;;
    status)  [[ $# == 0 ]] || die "status takes no arguments"; cmd_status ;;
    decrypt) cmd_decrypt "$@" ;;
    check)   cmd_check "$@" ;;
    restore) cmd_restore "$@" ;;
    *)       die "unknown command '$cmd' (see '$PROG help')" ;;
esac
