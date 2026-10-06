#!/usr/bin/env bash
#
# yubikey-db.sh - Manage the local SQLite YubiKey database used by Radiator
#                 RADIUS (<AuthBy SQLYUBIKEY>) for offline YubiKey OTP
#                 authentication with no YubiCloud dependency.
#
# VERSION
#   1.0.1
#
# HOW IT WORKS
#   Radiator's <AuthBy SQLYUBIKEY> decrypts each YubiKey OTP locally using the
#   AES key stored in this database, so no Yubico validation servers are
#   contacted. Every YubiKey must therefore be reprogrammed with an AES key you
#   control (the factory key in slot 1 is known only to Yubico), and that same
#   key must be loaded here.
#
#   Program a key (slot 2 shown; do NOT pass --upload, which sends it to Yubico):
#       ykman otp yubico 2 --serial-public-id --generate-private-id --generate-key
#   ykman prints the public ID (modhex), private ID (hex), and AES key (hex).
#   Record them, then load them with the 'add' or 'import' commands below.
#
# PREREQUISITES
#   On the host that runs this script : bash 4+, sqlite3, perl
#   On the Radiator host              : Perl modules DBD::SQLite,
#                                       Auth::Yubikey_Decrypter, Crypt::Rijndael
#
# COMMANDS
#   init      Create the database file and the yubikeys table (safe to re-run)
#   add       Add one user/YubiKey (values from options, or prompted)
#   import    Bulk-load users/YubiKeys from a CSV file in a single transaction
#   list      Show users and keys (never shows AES keys or passwords)
#   enable    Set active=1 for a user (optionally only one of their keys)
#   disable   Set active=0 for a user (optionally only one of their keys)
#   delete    Remove a user (optionally only one of their keys)
#   config    Print a sample Radiator <AuthBy SQLYUBIKEY> clause for this database
#   Run "yubikey-db.sh help" for every option.
#
# CSV FORMAT (for 'import')
#   username,public_id,private_id,aes_key,password,active
#   test.user,cbdefghijkln,456789abcdef,0123456789abcdef0123456789abcdef,abc123,1
#
#   - The header row is optional. Blank lines and lines starting with '#' are skipped.
#   - public_id : YubiKey public ID in modhex (usually 12 characters)
#   - private_id: 12 hex characters (12 modhex characters are also accepted)
#   - aes_key   : 32 hex characters (spaces and colons are removed)
#   - password  : optional static password/PIN, used with Require2Factor
#   - active    : optional; 1/0, true/false, yes/no (default 1)
#   - Fields cannot contain commas. Surrounding double quotes are removed.
#   - The CSV contains secret keys. Restrict its permissions, and delete it
#     securely (e.g. with 'shred -u') after importing.
#
# EXAMPLES
#   sudo ./yubikey-db.sh init --owner radiator:radiator
#   sudo ./yubikey-db.sh add -u test.user -P cbdefghijkln     # prompts for the rest
#   sudo ./yubikey-db.sh import --dry-run users.csv           # validate only
#   sudo ./yubikey-db.sh import users.csv
#   sudo ./yubikey-db.sh -d /srv/radius/yubi.db list
#   sudo ./yubikey-db.sh disable test.user
#
# DIFFERENCES FROM THE ORIGINAL EXAMPLE STATEMENTS
#   - created is set with an unquoted CURRENT_TIMESTAMP. In SQLite,
#     "current_timestamp" in double quotes stores the literal text.
#   - active is stored as 1/0. Radiator rejects the token unless active
#     equals 1, and the text 'true' does not.
#   - The secret is stored base64-encoded, as the Radiator AuthSelect
#     documentation specifies for result field 0 (use --secret-encoding hex
#     to change this).
#   - The private ID (userId column) is stored in hex, which is how the decrypted
#     OTP reports it. This matters if you enable CheckSecretId.
#   - Static passwords are stored as {crypt} SHA-512 hashes by default, not
#     plaintext (use --password-hash clear to store plaintext).
#   - SQL is passed to sqlite3 on stdin, not on the command line, so AES keys
#     are not visible in 'ps' output. All values are validated and quoted.
#
# ENVIRONMENT
#   DB_FILE          Database path (default /etc/radiator/db/yubicred.db)
#   SQLITE3          sqlite3 binary to use (default: sqlite3 on PATH)
#   SECRET_ENCODING  base64 (default) or hex
#   PASSWORD_HASH    crypt (default) or clear
#
# REFERENCE
#   https://files.radiatorsoftware.com/radiator/ref/AuthBySQLYUBIKEY.html
#   https://files.radiatorsoftware.com/radiator/ref/AuthSelect_AuthBySQLYUBIKEY.html
#   Radiator distribution: goodies/yubikey.cfg and goodies/yubikey.txt

set -euo pipefail
umask 027   # new files/directories are not world-readable

PROG=${0##*/}
VERSION=1.0.1
DB_FILE=${DB_FILE:-/etc/radiator/db/yubicred.db}
SQLITE3=${SQLITE3:-sqlite3}
SECRET_ENCODING=${SECRET_ENCODING:-base64}
PASSWORD_HASH=${PASSWORD_HASH:-crypt}
DB_BACKEND=sqlite   # every database operation goes through the db_* functions

# YubiKey "modhex" alphabet and the hex digits it maps to, position by position.
MODHEX=cbdefghijklnrtuv
HEXDIGITS=0123456789abcdef

REPLACE=0     # 1 = INSERT OR REPLACE (overwrite an existing YubiKey entry)
TMPFILE=      # temp SQL file used by 'import'; removed on exit
trap 'if [[ -n $TMPFILE ]]; then rm -f -- "$TMPFILE"; fi' EXIT

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
info() { printf '%s\n' "$*"; }

usage() {
    cat <<EOF
Usage: $PROG [global options] <command> [command options]

Global options:
  -d, --db FILE                 SQLite database (default: $DB_FILE)
  -e, --secret-encoding ENC     How the AES key is stored: base64 (default) | hex
  -H, --password-hash MODE      How static passwords are stored: crypt (default) | clear
  -h, --help                    Show this help
  -V, --version                 Show the version

Commands:
  init [-o|--owner USER[:GROUP]]
        Create the database directory, file, and yubikeys table. --owner chowns
        the directory and file so Radiator can update counters (it needs write
        access to the directory too, for SQLite's journal file).

  add [-u USER] [-P PUBLIC_ID] [-p PRIVATE_ID] [-k AES_KEY] [-w PASSWORD]
      [--no-password] [--inactive] [--replace]
        Add one user. Missing values are prompted for (the key and password
        are not echoed). Options -k and -w are visible to other users in
        'ps' and shell history, so prefer the prompts or 'import'.

  import [--dry-run] [--skip-invalid] [--replace] CSV_FILE
        Bulk-load from CSV (format: username,public_id,private_id,aes_key[,password[,active]]).
        Every row is validated first. If any row is invalid, nothing is
        imported unless you pass --skip-invalid. Valid rows are loaded in one
        transaction, so either all of them are loaded or none are.

  list [USER]                   List users/keys (no secrets shown)
  enable  USER [PUBLIC_ID]      Set active=1
  disable USER [PUBLIC_ID]      Set active=0
  delete  USER [PUBLIC_ID]      Delete the user's key(s)
  config                        Print a sample Radiator AuthBy clause

--replace overwrites any existing row with the same public ID or private ID,
and resets its counters. Use it after reprogramming a YubiKey.
EOF
}

require_tools() {
    db_require_tools
    command -v perl >/dev/null 2>&1 \
        || die "perl not found (needed for key encoding and password hashing)"
}

# Quote a value as an SQL string literal ('' escapes an embedded quote).
sql_quote() {
    local s=${1//\'/\'\'}
    printf "'%s'" "$s"
}

# Convert a 32-hex-character AES key into the stored format.
encode_secret() {
    case $SECRET_ENCODING in
        hex)    printf '%s' "$1" ;;
        base64) printf '%s' "$1" \
                    | perl -MMIME::Base64 -e 'local $/; print encode_base64(pack("H*", <STDIN>), "")' ;;
    esac
}

# Convert a static password into the stored format. With "crypt", Radiator
# verifies it with {crypt} (SHA-512 via the system crypt(3)). An empty
# password is stored as an empty string.
hash_password() {
    local pw=$1
    if [[ -z $pw ]]; then
        printf ''
    elif [[ $PASSWORD_HASH == clear ]]; then
        # A plaintext password that starts with "{" would be read as a hash
        # type, so Radiator's {clear} prefix is added to mark it as plaintext.
        if [[ $pw == \{* ]]; then printf '{clear}%s' "$pw"; else printf '%s' "$pw"; fi
    else
        printf '%s' "$pw" | perl -e '
            local $/; my $pw = <STDIN>;
            open(my $r, "<", "/dev/urandom") or die "cannot read /dev/urandom: $!\n";
            read($r, my $bytes, 16) == 16 or die "short read from /dev/urandom\n";
            my @c = ("a".."z", "A".."Z", 0..9, ".", "/");
            my $salt = join "", map { $c[ord($_) % 64] } split //, $bytes;
            my $h = crypt($pw, "\$6\$$salt\$");
            die "crypt() on this system does not support SHA-512 (\$6\$); use --password-hash clear\n"
                unless defined $h && $h =~ /^\$6\$/;
            print "{crypt}$h";'
    fi
}

# Validate and normalize one user record. On success, sets the R_* globals.
# On failure, sets ERR and returns 1. Error messages never include the AES
# key or private ID.
#   $1 username  $2 public_id  $3 private_id  $4 aes_key  $5 password  $6 active
validate_record() {
    local user=$1 pub=${2,,} priv=${3,,} key=${4,,} pw=${5-} active=${6-}
    active=${active,,}
    ERR=

    [[ $user =~ ^[A-Za-z0-9._@+-]{1,255}$ ]] \
        || { ERR="invalid username '$user' (allowed: letters, digits and . _ @ + -)"; return 1; }

    [[ $pub =~ ^([cbdefghijklnrtuv]{2}){1,16}$ ]] \
        || { ERR="invalid public ID '$2' for $user (expected modhex, normally 12 characters from '$MODHEX')"; return 1; }

    priv=${priv//[[:space:]:]/}
    if [[ $priv =~ ^[0-9a-f]{12}$ ]]; then
        :                                             # already hex
    elif [[ $priv =~ ^[cbdefghijklnrtuv]{12}$ ]]; then
        priv=$(tr "$MODHEX" "$HEXDIGITS" <<<"$priv")  # modhex -> hex
    else
        ERR="invalid private ID for $user (expected 12 hex or 12 modhex characters)"; return 1
    fi

    key=${key//[[:space:]:]/}
    [[ $key =~ ^[0-9a-f]{32}$ ]] \
        || { ERR="invalid AES key for $user (expected 32 hex characters)"; return 1; }

    case $active in
        ''|1|true|yes|y|on)  active=1 ;;
        0|false|no|n|off)    active=0 ;;
        *) ERR="invalid active value '$6' for $user (use 1/0, true/false, yes/no)"; return 1 ;;
    esac

    R_USER=$user
    R_PUB=$pub
    R_PRIV=$priv
    R_ACTIVE=$active
    # Explicit error checks: 'set -e' does not apply inside 'if validate_record'.
    R_SECRET=$(encode_secret "$key") || { ERR="could not encode the AES key for $user"; return 1; }
    R_PASSWORD=$(hash_password "$pw") || { ERR="could not hash the password for $user"; return 1; }
}

# Read a value from the terminal. $1 = variable name, $2 = prompt, $3 = "secret"
# to turn off echo.
prompt_value() {
    local __var=$1 __prompt=$2 __val
    [[ -t 0 ]] || die "missing value for: $__prompt (no terminal to prompt on; pass it as an option)"
    if [[ ${3-} == secret ]]; then
        read -rsp "$__prompt: " __val; echo >&2
    else
        read -rp "$__prompt: " __val
    fi
    printf -v "$__var" '%s' "$__val"
}

# --------------------------------------------------------------------------
# Database backend interface
#
# Commands reach the database only through these db_* functions. Each one
# calls the function with the same name for $DB_BACKEND (db_run calls
# sqlite_run, and so on), so a new backend is one more set of <backend>_*
# functions:
#
#   db_require_tools     exit unless the backend's client program is installed
#   db_run               run SQL read from stdin, stopping at the first error
#   db_ensure_readable   exit unless the database exists and can be read
#   db_ensure_writable   exit unless the database exists and can be changed
#   db_init [OPTIONS]    create the database and yubikeys table (safe to re-run)
#   db_insert_sql        print SQL that inserts the record in the R_* globals,
#                        replacing clashing rows when REPLACE=1
#   db_list [WHERE]      print users and keys, optionally filtered by WHERE
#   db_change SQL        run one UPDATE or DELETE and print how many rows it
#                        changed
#   db_config            print a sample Radiator <AuthBy SQLYUBIKEY> clause
# --------------------------------------------------------------------------

db_require_tools()   { "${DB_BACKEND}_require_tools"; }
db_run()             { "${DB_BACKEND}_run"; }
db_ensure_readable() { "${DB_BACKEND}_ensure_readable"; }
db_ensure_writable() { "${DB_BACKEND}_ensure_writable"; }
db_init()            { "${DB_BACKEND}_init" "$@"; }
db_insert_sql()      { "${DB_BACKEND}_insert_sql"; }
db_list()            { "${DB_BACKEND}_list" "$@"; }
db_change()          { "${DB_BACKEND}_change" "$@"; }
db_config()          { "${DB_BACKEND}_config" "$@"; }

# The query behind 'list', shared by every backend. It never selects the AES
# key or password. $1 = optional WHERE clause.
list_sql() {
    printf 'SELECT username, tokenId AS public_id, active, created, accessed, counter\n'
    printf '  FROM yubikeys %s ORDER BY username, tokenId;\n' "${1-}"
}

# --------------------------------------------------------------------------
# SQLite backend
# --------------------------------------------------------------------------

sqlite_require_tools() {
    command -v "$SQLITE3" >/dev/null 2>&1 \
        || die "sqlite3 not found (install the sqlite3 package or set SQLITE3=/path/to/sqlite3)"
}

# Run SQL read from stdin against the database. SQL is fed on stdin, never on
# the command line, so AES keys and passwords do not appear in 'ps'. .bail
# stops at the first error, so a failed import leaves its transaction
# uncommitted and SQLite rolls it back.
sqlite_run() {
    { printf '.bail on\n.timeout 5000\n'; cat; } | "$SQLITE3" -batch "$DB_FILE"
}

# Exit unless the database exists and this user can write to it and its
# directory (SQLite creates journal files next to the database).
sqlite_ensure_writable() {
    [[ -f $DB_FILE ]] || die "database $DB_FILE does not exist; run '$PROG init' first"
    [[ -w $DB_FILE && -w $(dirname -- "$DB_FILE") ]] \
        || die "no write access to $DB_FILE or its directory (run with sudo?)"
}

sqlite_ensure_readable() {
    [[ -f $DB_FILE ]] || die "database $DB_FILE does not exist; run '$PROG init' first"
    [[ -r $DB_FILE ]] || die "no read access to $DB_FILE (run with sudo?)"
}

# Table definition from the original example. The username index speeds up
# Radiator's lookups by user.
sqlite_schema() {
    cat <<'EOF'
CREATE TABLE IF NOT EXISTS yubikeys (
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
CREATE INDEX IF NOT EXISTS yubikeys_username ON yubikeys (username);
EOF
}

# Create the database directory and file, then the table. Options: --owner.
sqlite_init() {
    local owner=
    while [[ $# -gt 0 ]]; do
        case $1 in
            -o|--owner) owner=${2:?--owner needs USER[:GROUP]}; shift 2 ;;
            *) die "init: unknown option '$1'" ;;
        esac
    done

    local dir created_file=0
    dir=$(dirname -- "$DB_FILE")
    if [[ ! -d $dir ]]; then
        { mkdir -p -- "$dir" && chmod 0750 -- "$dir"; } || die "cannot create $dir (run with sudo?)"
        info "Created directory $dir"
    fi
    [[ -w $dir ]] || die "no write access to $dir (run with sudo?)"
    [[ -e $DB_FILE ]] || created_file=1

    sqlite_schema | sqlite_run
    if [[ $created_file == 1 ]]; then
        chmod 0640 -- "$DB_FILE"
    fi

    if [[ -n $owner ]]; then
        chown -- "$owner" "$dir" "$DB_FILE"
        info "Set owner of $dir and $DB_FILE to $owner"
    else
        warn "Radiator needs write access to $DB_FILE and its directory to update OTP counters;" \
             "re-run with --owner <radiator-user>[:group] if Radiator does not run as $(id -un)"
    fi
    info "Database ready: $DB_FILE"
}

# Print the INSERT statement for the record held in the R_* globals.
# tokenId = public ID (modhex), userId = private ID (hex). The accessed column
# starts empty and is filled in by Radiator's UpdateQuery.
sqlite_insert_sql() {
    local verb=INSERT
    [[ $REPLACE == 1 ]] && verb="INSERT OR REPLACE"
    printf "%s INTO yubikeys (username, password, active, created, accessed, tokenId, userId, secret, counter, low, high) VALUES (%s, %s, %s, CURRENT_TIMESTAMP, '', %s, %s, %s, 0, 0, 0);\n" \
        "$verb" \
        "$(sql_quote "$R_USER")" "$(sql_quote "$R_PASSWORD")" "$R_ACTIVE" \
        "$(sql_quote "$R_PUB")" "$(sql_quote "$R_PRIV")" "$(sql_quote "$R_SECRET")"
}

sqlite_list() {
    { printf '.headers on\n.mode column\n'; list_sql "${1-}"; } | sqlite_run
}

sqlite_change() {
    printf '%s\nSELECT changes();\n' "$1" | sqlite_run
}

sqlite_config() {
    cat <<EOF
# Sample Radiator <AuthBy SQLYUBIKEY> clause for $DB_FILE
# (secret stored as $SECRET_ENCODING; see the comments below)
<AuthBy SQLYUBIKEY>
    Identifier   YubiKeyLocal
    DBSource     dbi:SQLite:dbname=$DB_FILE
    DBUsername
    DBAuth

    # Columns must come back in this order: secret, active, userId,
    # counter, session_use (low), ignored (high), static_password.
    # %0 = quoted username, %3 = token (public) ID in modhex.
    AuthSelect   select secret, active, userId, counter, low, high, password from yubikeys where username=%0 and tokenId=%3

    # %0 = counter, %1 = session use, %2 = 0, %3 = quoted username,
    # %5 = Unix time, %7 = token ID in modhex. SQLite does not support
    # current_timestamp(), so %5 is used for the access time.
    UpdateQuery  update yubikeys set accessed=datetime(%5,'unixepoch'), counter=%0, low=%1, high=%2 where username=%3 and tokenId=%7

    # Require "password:OTP" (static password/PIN + YubiKey OTP).
    # Remove this if users authenticate with the OTP alone.
    Require2Factor

    # Also check that the private ID in the OTP matches userId.
    CheckSecretId
</AuthBy>
EOF
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

cmd_add() {
    local user='' pub='' priv='' key='' pw='' pw_set=0 active=1
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--user)        user=${2?}; shift 2 ;;
            -P|--public-id)   pub=${2?};  shift 2 ;;
            -p|--private-id)  priv=${2?}; shift 2 ;;
            -k|--key)         key=${2?};  shift 2 ;;
            -w|--password)    pw=${2?}; pw_set=1; shift 2 ;;
            --no-password)    pw=; pw_set=1; shift ;;
            --inactive)       active=0; shift ;;
            --replace)        REPLACE=1; shift ;;
            *) die "add: unknown option '$1'" ;;
        esac
    done
    db_ensure_writable

    [[ -n $user ]] || prompt_value user "Username"
    [[ -n $pub  ]] || prompt_value pub  "YubiKey public ID (modhex)"
    [[ -n $priv ]] || prompt_value priv "YubiKey private ID (12 hex)" secret
    [[ -n $key  ]] || prompt_value key  "YubiKey AES key (32 hex)" secret
    if [[ $pw_set == 0 ]]; then
        if [[ -t 0 ]]; then
            local pw2
            prompt_value pw  "Static password/PIN (Enter for none)" secret
            if [[ -n $pw ]]; then
                prompt_value pw2 "Repeat password/PIN" secret
                [[ $pw == "$pw2" ]] || die "passwords do not match"
            fi
        fi
    fi

    validate_record "$user" "$pub" "$priv" "$key" "$pw" "$active" || die "$ERR"
    if ! db_insert_sql | db_run; then
        die "could not add $R_USER (if this YubiKey is already in the database, use --replace)"
    fi
    info "Added $R_USER with YubiKey $R_PUB (active=$R_ACTIVE)"
}

cmd_import() {
    local file='' dry_run=0 skip_invalid=0
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)      dry_run=1; shift ;;
            --skip-invalid) skip_invalid=1; shift ;;
            --replace)      REPLACE=1; shift ;;
            -*)             die "import: unknown option '$1'" ;;
            *)              [[ -z $file ]] || die "import: only one CSV file allowed"; file=$1; shift ;;
        esac
    done
    [[ -n $file ]] || die "import: CSV file required"
    [[ -r $file ]] || die "cannot read $file"
    if [[ $dry_run == 0 ]]; then db_ensure_writable; fi

    # Warn if other users can read the CSV, since it contains AES keys.
    if [[ -n $(find "$file" -maxdepth 0 -perm /o=r 2>/dev/null) ]]; then
        warn "$file is world-readable and contains AES keys; consider: chmod 600 '$file'"
    fi

    TMPFILE=$(mktemp)          # created mode 0600
    echo 'BEGIN;' >"$TMPFILE"

    local line lineno=0 first_row=1 ok=0 bad=0 i
    local -a f
    local -A seen_pub=() seen_priv=()
    while IFS= read -r line || [[ -n $line ]]; do
        lineno=$((lineno + 1))
        line=${line%$'\r'}                              # tolerate Windows line endings
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue   # skip comments and blank lines

        IFS=, read -r -a f <<<"$line"
        for i in "${!f[@]}"; do                         # trim spaces and surrounding quotes
            f[i]=${f[i]#"${f[i]%%[![:space:]]*}"}
            f[i]=${f[i]%"${f[i]##*[![:space:]]}"}
            [[ ${f[i]} == \"*\" ]] && f[i]=${f[i]:1:-1}
        done

        if [[ $first_row == 1 ]]; then                  # optional header row
            first_row=0
            [[ ${f[0],,} == username ]] && continue
        fi

        if (( ${#f[@]} < 4 || ${#f[@]} > 6 )); then
            warn "line $lineno: expected 4-6 fields, found ${#f[@]}"; bad=$((bad + 1)); continue
        fi
        if ! validate_record "${f[0]}" "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]-}" "${f[5]-}"; then
            warn "line $lineno: $ERR"; bad=$((bad + 1)); continue
        fi
        if [[ -n ${seen_pub[$R_PUB]-} ]]; then
            warn "line $lineno: public ID $R_PUB is already used on line ${seen_pub[$R_PUB]}"; bad=$((bad + 1)); continue
        fi
        if [[ -n ${seen_priv[$R_PRIV]-} ]]; then
            warn "line $lineno: private ID for $R_USER is already used on line ${seen_priv[$R_PRIV]}"; bad=$((bad + 1)); continue
        fi
        seen_pub[$R_PUB]=$lineno
        seen_priv[$R_PRIV]=$lineno

        db_insert_sql >>"$TMPFILE"
        ok=$((ok + 1))
    done <"$file"
    echo 'COMMIT;' >>"$TMPFILE"

    info "Validated $file: $ok valid row(s), $bad invalid row(s)"
    if [[ $bad -gt 0 && $skip_invalid == 0 ]]; then
        die "nothing imported; fix the rows above or re-run with --skip-invalid"
    fi
    if [[ $ok == 0 ]]; then die "no valid rows to import"; fi
    if [[ $dry_run == 1 ]]; then info "Dry run: database not changed"; return; fi

    if ! db_run <"$TMPFILE"; then
        die "import failed and was rolled back; no rows imported (an existing YubiKey? use --replace)"
    fi
    info "Imported $ok row(s) into $DB_FILE"
}

cmd_list() {
    db_ensure_readable
    local where=''
    [[ $# -le 1 ]] || die "list: too many arguments"
    if [[ $# -eq 1 ]]; then where="WHERE username = $(sql_quote "$1")"; fi
    db_list "$where"
}

# enable / disable / delete share the same USER [PUBLIC_ID] targeting.
cmd_modify() {
    local action=$1; shift
    [[ $# -ge 1 && $# -le 2 ]] || die "$action: usage: $PROG $action USER [PUBLIC_ID]"
    db_ensure_writable

    local where
    where="username = $(sql_quote "$1")"
    if [[ $# -eq 2 ]]; then where+=" AND tokenId = $(sql_quote "${2,,}")"; fi

    local stmt
    case $action in
        enable)  stmt="UPDATE yubikeys SET active = 1 WHERE $where;" ;;
        disable) stmt="UPDATE yubikeys SET active = 0 WHERE $where;" ;;
        delete)  stmt="DELETE FROM yubikeys WHERE $where;" ;;
    esac

    local n
    n=$(db_change "$stmt")
    [[ $n -gt 0 ]] || die "$action: no matching entry for '$*'"
    info "$action: $n row(s) changed"
}

# --------------------------------------------------------------------------
# Main: global options, then dispatch the command
# --------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--db)              DB_FILE=${2:?--db needs a file}; shift 2 ;;
        -e|--secret-encoding) SECRET_ENCODING=${2:?}; shift 2 ;;
        -H|--password-hash)   PASSWORD_HASH=${2:?}; shift 2 ;;
        -h|--help|help)       usage; exit 0 ;;
        -V|--version|version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
        -*)                   die "unknown option '$1' (see '$PROG help')" ;;
        *)                    break ;;
    esac
done

[[ $SECRET_ENCODING == base64 || $SECRET_ENCODING == hex ]] \
    || die "--secret-encoding must be base64 or hex"
[[ $PASSWORD_HASH == crypt || $PASSWORD_HASH == clear ]] \
    || die "--password-hash must be crypt or clear"
[[ $# -gt 0 ]] || { usage >&2; exit 1; }

cmd=$1; shift
case $cmd in
    config) db_config "$@"; exit ;;    # needs no tools or database
esac
require_tools
case $cmd in
    init)                   db_init "$@" ;;
    add)                    cmd_add "$@" ;;
    import)                 cmd_import "$@" ;;
    list)                   cmd_list "$@" ;;
    enable|disable|delete)  cmd_modify "$cmd" "$@" ;;
    *)                      die "unknown command '$cmd' (see '$PROG help')" ;;
esac
