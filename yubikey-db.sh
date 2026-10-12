#!/usr/bin/env bash
#
# yubikey-db.sh - Manage the SQLite or PostgreSQL YubiKey database used by
#                 Radiator RADIUS (<AuthBy SQLYUBIKEY>) for offline YubiKey
#                 OTP authentication with no YubiCloud dependency.
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
#   Supported platform                : Ubuntu 26.04 LTS; PostgreSQL 18 or
#                                       later for the PostgreSQL backend
#   On the host that runs this script : bash 4+, perl, and sqlite3 (SQLite)
#                                       or psql (PostgreSQL: postgresql-client)
#   On the Radiator host              : Perl modules Auth::Yubikey_Decrypter,
#                                       Crypt::Rijndael, and DBD::SQLite or
#                                       DBD::Pg (libdbd-pg-perl)
#   For 'verify'                      : Crypt::Rijndael (libcrypt-rijndael-perl)
#
# DATABASES
#   SQLite (the default) keeps everything in one file on the Radiator host.
#   PostgreSQL (-b pg) can be shared by several Radiator servers, so the OTP
#   counters that block replayed OTPs are shared too. With PostgreSQL:
#     sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin "$USER"
#   creates the database "yubikey", an admin role that owns it (yubikey_admin;
#   --admin makes your login a member), and Radiator's login role (radiator),
#   which can read the keys but change only the counters and access time.
#
# COMMANDS
#   init      Create the database file and the yubikeys table (safe to re-run)
#   init-pg   PostgreSQL only: create the roles and database, then the table
#   add       Add one user/YubiKey (values from options, or prompted);
#             --update updates it instead if the YubiKey is already there
#   import    Bulk-load users/YubiKeys from a CSV file (or - for standard
#             input) in a single transaction (--from-export restores a file
#             written by 'export', with its passwords, times and counters)
#   list      Show users and keys (never shows AES keys or passwords)
#   enable    Set active=1 for a user (optionally only one of their keys)
#   disable   Set active=0 for a user (optionally only one of their keys)
#   delete    Remove a user (optionally only one of their keys)
#   export    Write every record and field to a CSV file, with AES keys and
#             private IDs in clear text (the file is created with mode 0600)
#   verify    Ask for a username, password and OTP, and check them against
#             the database the way Radiator does; saves the counters if accepted
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
#   sudo ./yubikey-db.sh verify                               # test a password + OTP
#   sudo ./yubikey-db.sh -d /srv/radius/yubi.db list
#   sudo ./yubikey-db.sh disable test.user
#   sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin alice
#   ./yubikey-db.sh -b pg import users.csv                    # as alice
#   ./yubikey-db.sh -b pg config
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
#   - SQL is passed to sqlite3 or psql on stdin, not on the command line, so
#     AES keys are not visible in 'ps' output. All values are validated and
#     quoted.
#
# ENVIRONMENT
#   DB_BACKEND       sqlite (default) or pg
#   DB_FILE          SQLite database path (default /etc/radiator/db/yubicred.db)
#   SQLITE3          sqlite3 binary to use (default: sqlite3 on PATH)
#   PSQL             psql binary to use (default: psql on PATH)
#   PGDATABASE       PostgreSQL database name (default yubikey; -d overrides)
#   PGHOST, PGPORT, PGUSER, PGSSLMODE, PGSERVICE
#                    Standard PostgreSQL connection settings, used by psql.
#                    Put passwords in ~/.pgpass, never on the command line.
#   PG_ADMIN_ROLE    PostgreSQL role that owns the table (default yubikey_admin)
#   PG_RADIATOR_ROLE PostgreSQL role Radiator logs in as (default radiator)
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
DB_BACKEND=${DB_BACKEND:-sqlite}   # all database access goes through the db_* functions
DB_FILE=${DB_FILE:-/etc/radiator/db/yubicred.db}
SQLITE3=${SQLITE3:-sqlite3}
PSQL=${PSQL:-psql}
PG_ADMIN_ROLE=${PG_ADMIN_ROLE:-yubikey_admin}
PG_RADIATOR_ROLE=${PG_RADIATOR_ROLE:-radiator}
SECRET_ENCODING=${SECRET_ENCODING:-base64}
PASSWORD_HASH=${PASSWORD_HASH:-crypt}
DB_OPT=       # -d value: the SQLite file or the PostgreSQL database name
DB_DESC=      # how messages name the database, set by the backend

# YubiKey "modhex" alphabet and the hex digits it maps to, position by position.
MODHEX=cbdefghijklnrtuv
HEXDIGITS=0123456789abcdef

REPLACE=0     # 1 = INSERT OR REPLACE (overwrite an existing YubiKey entry)
UPSERT=0      # 1 = --update: update a YubiKey already in the database, keeping
              # its counters unless its private ID or AES key changed
RESTORE=0     # 1 = import --from-export: restore passwords, times and counters
# Columns of an export file, in order (export writes them; import --from-export
# requires them as the header).
EXPORT_COLUMNS=username,public_id,private_id,aes_key,password,active,created,accessed,counter,low,high
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
  -b, --backend NAME            Database type: sqlite (default) | pg
  -d, --db NAME                 SQLite: database file (default: $DB_FILE)
                                PostgreSQL: database name (default: yubikey)
  -e, --secret-encoding ENC     How the AES key is stored: base64 (default) | hex
  -H, --password-hash MODE      How static passwords are stored: crypt (default) | clear
  -h, --help                    Show this help
  -V, --version                 Show the version

Commands:
  init [-o|--owner USER[:GROUP]]
        Create the database directory, file, and yubikeys table. --owner chowns
        the directory and file so Radiator can update counters (it needs write
        access to the directory too, for SQLite's journal file).
        PostgreSQL: create the table and Radiator's grants in an existing
        database (run as a member of the admin role).

  init-pg [-a|--admin LOGIN]... [--set-password]          (PostgreSQL only)
        Create the admin role ($PG_ADMIN_ROLE), Radiator's login role
        ($PG_RADIATOR_ROLE) and the database, then run init. Run it as the
        postgres superuser. Each --admin LOGIN is created if needed and made a
        member of the admin role, so it can manage users. --set-password asks
        for Radiator's password (needed only when Radiator connects over TCP).

  add [-u USER] [-P PUBLIC_ID] [-p PRIVATE_ID] [-k AES_KEY] [-w PASSWORD]
      [--no-password] [--inactive] [--replace | --update]
        Add one user. Missing values are prompted for (the key and password
        are not echoed). Options -k and -w are visible to other users in
        'ps' and shell history, so prefer the prompts or 'import'.

  import [--dry-run] [--skip-invalid] [--replace | --update] [--from-export]
         CSV_FILE|-
        Bulk-load from CSV (format: username,public_id,private_id,aes_key[,password[,active]]),
        or from standard input with -.
        Every row is validated first. If any row is invalid, nothing is
        imported unless you pass --skip-invalid. Valid rows are loaded in one
        transaction, so either all of them are loaded or none are.
        --from-export restores a file written by 'export' instead (all its
        columns, standard CSV quoting, its header required). Passwords are
        stored as they are (already hashed; -H does not apply), and created,
        accessed and the counters are restored. With --replace, counters
        never move backward: where the database is ahead, its counters stay.

  list [USER]                   List users/keys (no secrets shown)
  enable  USER [PUBLIC_ID]      Set active=1
  disable USER [PUBLIC_ID]      Set active=0
  delete  USER [PUBLIC_ID]      Delete the user's key(s)
  verify [-u USER]              Check a password and OTP against the database
        the way Radiator does (with Require2Factor and CheckSecretId): the
        user must have the OTP's YubiKey, active=1, the same static password,
        an OTP that decrypts to the stored private ID, and counters ahead of
        the stored ones. If accepted, the counters are saved, as Radiator
        would, so the OTP cannot be used again. Values are prompted for, or
        read one per line from standard input when it is not a terminal:
        the username (unless -u is given), the password, then the OTP.
  export [-f|--force] FILE|-    Write every record and field to a CSV file
        (mode 0600), or to standard output with -. Columns: username,
        public_id, private_id, aes_key, password, active, created, accessed,
        counter, low, high. AES keys are 32 hex characters and private IDs are
        in clear text; passwords are as stored ({crypt} hashes stay hashed).
        An existing FILE is replaced only with --force.
  config                        Print a sample Radiator AuthBy clause

--replace overwrites any existing row with the same public ID or private ID,
and resets its counters. Use it after reprogramming a YubiKey.
--update does the same, but keeps the counters (and the created and accessed
times) when the existing row has the same public ID, private ID and AES key,
so only the username, password and active flag change. Use it to change a
password, or when you are not sure whether a YubiKey is already loaded. If
the same values were programmed into a YubiKey again, use --replace.

PostgreSQL connections use the standard PGHOST, PGPORT, PGUSER, PGSSLMODE and
PGSERVICE settings. Keep passwords in ~/.pgpass.
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

# Turn the JSON rows from db_export_json (stdin) into CSV on stdout, and write
# the number of rows to file descriptor 3. AES keys are converted to 32 hex
# characters, whichever encoding they are stored in. Fields with a comma,
# quote or line break are quoted, with quotes doubled.
csv_from_json() {
    perl -MJSON::PP -MMIME::Base64 -e '
        my ($prog, $header) = @ARGV;
        local $/;
        my $json = <STDIN>;
        my $rows = defined $json && $json =~ /\S/ ? JSON::PP->new->utf8->decode($json) : [];
        binmode STDOUT, ":encoding(UTF-8)";
        sub csv { my $v = shift // ""; $v = "$v"; $v =~ /[",\r\n]/ ? "\"" . ($v =~ s/"/""/gr) . "\"" : $v }
        print "$header\n";
        for my $r (@$rows) {
            (my $s = $r->{secret} // "") =~ s/^ +| +$//g;
            my $key = $s =~ /^[0-9A-Fa-f]{32}$/ ? lc $s
                    : $s =~ m{^[A-Za-z0-9+/]{22}==$} ? unpack("H*", decode_base64($s))
                    : do { warn "$prog: warning: the AES key of $r->{username} ($r->{tokenid}) is not hex or base64; exported as stored\n"; $r->{secret} };
            print join(",", map { csv($_) } $r->{username}, $r->{tokenid}, $r->{userid}, $key, $r->{password},
                       $r->{active}, $r->{created}, $r->{accessed}, $r->{counter}, $r->{low}, $r->{high}), "\n";
        }
        open(my $count, ">&=", 3) or die "$prog: error: cannot report the row count\n";
        print $count scalar(@$rows), "\n";
    ' "$PROG" "$EXPORT_COLUMNS"
}

# Validate and normalize one user record. On success, sets the R_* globals.
# On failure, sets ERR and returns 1. Error messages never include the AES
# key or private ID.
#   $1 username  $2 public_id  $3 private_id  $4 aes_key  $5 password  $6 active
validate_record() {
    local user=$1 pw=${5-}
    ERR=

    [[ $user =~ ^[A-Za-z0-9._@+-]{1,255}$ ]] \
        || { ERR="invalid username '$user' (allowed: letters, digits and . _ @ + -)"; return 1; }
    validate_key_fields "$user" "$2" "$3" "$4" "${6-}" || return 1

    R_USER=$user
    # Explicit error checks: 'set -e' does not apply inside 'if validate_record'.
    R_PASSWORD=$(hash_password "$pw") || { ERR="could not hash the password for $user"; return 1; }
}

# Validate one row of an export file (import --from-export). The password is
# kept as stored (it is already hashed), and created, accessed and the
# counters are restored. Usernames may be anything the database can hold. An
# invalid time is replaced, with a note in R_NOTE; an invalid counter makes the
# row invalid. Sets the R_* globals, or ERR and returns 1.
#   $1..$11 = the export columns, in EXPORT_COLUMNS order
validate_export_record() {
    local user=$1 pw=$5 created=$7 accessed=$8 counter=$9 low=${10} high=${11}
    local ts='^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$'
    ERR=''
    R_NOTE=''

    if [[ -z $user || ${#user} -gt 255 || $user =~ [[:cntrl:]] ]]; then
        ERR="invalid username '${user//[[:cntrl:]]/?}' (must be 1-255 characters, with no control characters)"
        return 1
    fi
    validate_key_fields "$user" "$2" "$3" "$4" "$6" || return 1
    if [[ ! $counter =~ ^[0-9]{1,9}$ || ! $low =~ ^[0-9]{1,9}$ || ! $high =~ ^[0-9]{1,9}$ ]]; then
        ERR="invalid counter, low or high for $user (expected whole numbers)"; return 1
    fi
    if [[ -n $created && ! $created =~ $ts ]]; then
        R_NOTE="created '$created' for $user is not a UTC time; using the current time"
        created=
    fi
    if [[ -n $accessed && ! $accessed =~ $ts ]]; then
        R_NOTE+="${R_NOTE:+; }accessed '$accessed' for $user is not a UTC time; leaving it empty"
        accessed=
    fi

    R_USER=$user
    R_PASSWORD=$pw
    R_CREATED=$created
    R_ACCESSED=$accessed
    R_COUNTER=$((10#$counter))
    R_LOW=$((10#$low))
    R_HIGH=$((10#$high))
}

# Check and normalize the YubiKey fields that both import formats share. Sets
# R_PUB, R_PRIV, R_ACTIVE, R_SECRET and R_KEYHEX, or ERR and returns 1.
#   $1 username (for messages)  $2 public_id  $3 private_id  $4 aes_key  $5 active
validate_key_fields() {
    local user=$1 pub=${2,,} priv=${3,,} key=${4,,} active=${5-}
    active=${active,,}

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
        *) ERR="invalid active value '$5' for $user (use 1/0, true/false, yes/no)"; return 1 ;;
    esac

    R_PUB=$pub
    R_PRIV=$priv
    R_ACTIVE=$active
    R_KEYHEX=$key
    R_SECRET=$(encode_secret "$key") || { ERR="could not encode the AES key for $user"; return 1; }
}

# SQL condition that is true for a row holding the same YubiKey as the record
# in the R_* globals: the same public ID, private ID and AES key, whether the
# key is stored as base64 or as hex. $1 = prefix for the column names.
same_key_sql() {
    local b64=$R_SECRET
    if [[ $SECRET_ENCODING != base64 ]]; then
        b64=$(SECRET_ENCODING=base64 encode_secret "$R_KEYHEX")
    fi
    printf '%stokenId = %s AND %suserId = %s AND (trim(%ssecret) = %s OR lower(trim(%ssecret)) = %s)' \
        "${1-}" "$(sql_quote "$R_PUB")" "${1-}" "$(sql_quote "$R_PRIV")" \
        "${1-}" "$(sql_quote "$b64")" "${1-}" "$(sql_quote "$R_KEYHEX")"
}

# For --update: print SELECTs that report what the INSERT that follows will
# do, when it changes an existing row. A row with the same YubiKey is updated
# and keeps its counters; a row with its public or private ID but other key
# values is replaced, and the counters start again at 0. A new YubiKey prints
# nothing.
upsert_report_sql() {
    local same user pub priv
    same=$(same_key_sql) user=$(sql_quote "$R_USER")
    pub=$(sql_quote "$R_PUB") priv=$(sql_quote "$R_PRIV")
    printf "SELECT %s || CASE WHEN username <> %s THEN ', moved from ' || username ELSE '' END || %s\n  FROM yubikeys WHERE %s;\n" \
        "$(sql_quote "Updated YubiKey $R_PUB for $R_USER (active=$R_ACTIVE")" "$user" \
        "$(sql_quote "); counters kept, since its private ID and AES key are unchanged")" "$same"
    printf 'SELECT %s\n WHERE NOT EXISTS (SELECT 1 FROM yubikeys WHERE %s)\n   AND EXISTS (SELECT 1 FROM yubikeys WHERE tokenId = %s OR userId = %s);\n' \
        "$(sql_quote "Replaced YubiKey $R_PUB for $R_USER (active=$R_ACTIVE); counters reset, since its private ID or AES key changed")" \
        "$same" "$pub" "$priv"
}

# Read an export file ($1) as standard CSV (quoted fields may hold commas,
# doubled quotes and line breaks) and print, NUL-separated, for each row: its
# line number, its number of fields, and its first 11 fields (padded). The
# first row must be the export header. "@@end" follows the last row, so a
# reader can tell a complete parse from a failed one.
parse_export_csv() {
    perl -e '
        my ($prog, $file, $header) = @ARGV;
        open(my $in, "<", $file) or die "$prog: error: cannot read $file: $!\n";
        binmode $in;
        my $data = do { local $/; <$in> };
        pos($data) = 0;
        my ($line, $have_header) = (1, 0);
        while (pos($data) < length $data) {
            my ($start, @f) = ($line);
            while (1) {
                if ($data =~ /\G"((?:[^"]|"")*)"/gc) {
                    my $v = $1;
                    $line += ($v =~ tr/\n//);
                    $v =~ s/""/"/g;
                    push @f, $v;
                } else {
                    $data =~ /\G([^",\r\n]*)/gc;
                    push @f, $1;
                }
                next if $data =~ /\G,/gc;
                if ($data =~ /\G\r?\n/gc) { $line++; last }
                last if pos($data) >= length $data;
                die "$prog: error: $file line $start: malformed CSV (a quote inside an unquoted field, or an unterminated quoted field)\n";
            }
            next if @f == 1 && $f[0] eq "";              # blank line
            if (!$have_header) {
                join(",", @f) eq $header
                    or die "$prog: error: $file is not an export file; its first line must be:\n  $header\n";
                $have_header = 1;
                next;
            }
            my $n = @f;
            $#f = 10;
            print join("\0", $start, $n, map { $_ // "" } @f), "\0";
        }
        $have_header or die "$prog: error: $file is empty\n";
        print "\@\@end\0";
    ' "$PROG" "$1" "$EXPORT_COLUMNS"
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

# Like prompt_value, but with no terminal the value is read as the next line
# of standard input, so a script can pipe values in.
read_value() {
    if [[ -t 0 ]]; then
        prompt_value "$@"
    else
        IFS= read -r "$1" || [[ -n ${!1} ]] || die "standard input ended before the value for: $2"
    fi
}

# Check a password and OTP against the user's row, as Radiator does. Reads
# from stdin: the password, the OTP, then the rows from db_export_json for
# the user and the OTP's public ID. Prints one line per check, and writes the
# verdict to file descriptor 3: "accept COUNTER SESSION [unchecked]" or
# "reject REASONS". Never prints the AES key or the private ID.
#   $1 program name  $2 username  $3 the OTP's public ID
verify_otp() {
    perl -MJSON::PP -MMIME::Base64 -MCrypt::Rijndael -e '
        my ($prog, $user, $pub) = @ARGV;
        chomp(my $pw = <STDIN> // "");
        chomp(my $otp = <STDIN> // "");
        my $json = do { local $/; <STDIN> } // "";
        my $rows = $json =~ /\S/ ? JSON::PP->new->decode($json) : [];   # bytes, like $user and $pw
        open(my $res, ">&=", 3) or die "$prog: error: cannot report the result\n";
        sub show { printf "  %-17s %s\n", "$_[0]:", $_[1] }

        my ($r) = grep { $_->{username} eq $user && $_->{tokenid} eq $pub } @$rows;
        if (!$r) {
            my @keys = map { $_->{tokenid} } grep { $_->{username} eq $user } @$rows;
            my $other = grep { $_->{tokenid} eq $pub } @$rows;
            print $res "reject ", !@keys ? "$user is not in the database" . ($other ? "; YubiKey $pub belongs to another user" : "")
                : $other ? "YubiKey $pub belongs to another user; ${user}\x27s YubiKeys: @keys"
                : "$user has no YubiKey $pub; their YubiKeys: @keys", "\n";
            exit;
        }
        my (@fail, $unchecked, $ctr, $use);

        # Radiator treats a missing active value as active.
        my $active = $r->{active};
        if (defined $active && "$active" ne "1") {
            show("active", "NO (active=$active; Radiator accepts only 1)"); push @fail, "disabled";
        } else {
            show("active", "yes");
        }

        my $stored = $r->{password} // "";
        my $pw_ok;
        if ($stored eq "") {
            $pw_ok = $pw eq "";
            show("static password", $pw_ok ? "none (OTP only)" : "WRONG (none is stored, but one was entered)");
        } elsif ($stored =~ /^\{(\w+)\}(.*)$/s && lc $1 ne "crypt" && lc $1 ne "clear") {
            $unchecked = 1;
            show("static password", "not checked (stored as {$1}, which this check does not support)");
        } else {
            $pw_ok = $stored =~ /^\{crypt\}(.*)$/si ? crypt($pw, $1) eq $1
                   : $stored =~ /^\{clear\}(.*)$/si ? $1 eq $pw
                   : $stored eq $pw;
            show("static password", $pw_ok ? "matches" : "WRONG");
        }
        push @fail, "static password" if defined $pw_ok && !$pw_ok;

        (my $s = $r->{secret} // "") =~ s/^ +| +$//g;
        my $key = $s =~ /^[0-9A-Fa-f]{32}$/ ? pack("H*", $s)
                : $s =~ m{^[A-Za-z0-9+/]{22}==$} ? decode_base64($s) : undef;
        if (!defined $key) {
            show("OTP", "not checked (the stored AES key is not 32 hex characters or base64)");
            push @fail, "stored AES key";
        } else {
            (my $hex = substr($otp, -32)) =~ tr/cbdefghijklnrtuv/0123456789abcdef/;
            my $plain = Crypt::Rijndael->new($key, Crypt::Rijndael::MODE_ECB())->decrypt(pack "H*", $hex);
            # CRC-16 (ISO 13239) over the whole token leaves 0xf0b8 when it is intact.
            my $crc = 0xffff;
            for my $b (unpack "C*", $plain) {
                $crc ^= $b;
                for (1 .. 8) { my $lsb = $crc & 1; $crc >>= 1; $crc ^= 0x8408 if $lsb }
            }
            my $uid;
            ($uid, $ctr, undef, undef, $use) = unpack "H12 v v C C", $plain;
            if ($crc != 0xf0b8) {
                show("OTP", "does NOT decrypt with the stored AES key (wrong key, or a mistyped OTP)");
                push @fail, "OTP";
            } else {
                show("OTP", "decrypts with the stored AES key");
                if ($uid eq lc($r->{userid} // "")) {
                    show("private ID", "matches");
                } else {
                    show("private ID", "does NOT match the stored private ID"); push @fail, "private ID";
                }
                my ($dc, $dl) = ($r->{counter}, $r->{low} // 0);
                my $seen = "OTP counter $ctr, session $use; stored counter " . ($dc // "none") . ", session $dl";
                if (!defined $dc) {
                    show("replay check", "skipped, as Radiator does when no counter is stored ($seen)");
                } elsif ($ctr > $dc || ($ctr == $dc && $use > $dl)) {
                    show("replay check", "passed ($seen)");
                } else {
                    show("replay check", "FAILED, this OTP is not newer than the last one used ($seen)");
                    push @fail, "replayed OTP";
                }
            }
        }
        print $res @fail ? "reject " . join(", ", @fail) : "accept $ctr $use" . ($unchecked ? " unchecked" : ""), "\n";
    ' "$PROG" "$@"
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
#   db_init [OPTIONS]    create the yubikeys table, and for SQLite the database
#                        file (safe to re-run)
#   db_insert_sql        print SQL that inserts the record in the R_* globals,
#                        replacing clashing rows when REPLACE=1 or UPSERT=1
#                        (UPSERT=1 keeps the counters of a row with the same
#                        YubiKey, and first prints upsert_report_sql)
#   db_list [WHERE]      print users and keys, optionally filtered by WHERE
#   db_change SQL        run one UPDATE or DELETE and print how many rows it
#                        changed
#   db_export_json [WHERE]
#                        print every row, or those matching WHERE, as a JSON
#                        array of objects with the keys username, password,
#                        active, created, accessed (UTC text), tokenid,
#                        userid, secret, counter, low, high
#   db_config            print a sample Radiator <AuthBy SQLYUBIKEY> clause
# --------------------------------------------------------------------------

db_require_tools()   { "${DB_BACKEND}_require_tools"; }
db_run()             { "${DB_BACKEND}_run"; }
db_ensure_readable() { "${DB_BACKEND}_ensure_readable"; }
db_ensure_writable() { "${DB_BACKEND}_ensure_writable"; }
db_init()            { "${DB_BACKEND}_init" "$@"; }
db_insert_sql()      { if [[ $UPSERT == 1 ]]; then upsert_report_sql; fi; "${DB_BACKEND}_insert_sql"; }
db_list()            { "${DB_BACKEND}_list" "$@"; }
db_change()          { "${DB_BACKEND}_change" "$@"; }
db_export_json()     { "${DB_BACKEND}_export_json" "$@"; }
db_config()          { "${DB_BACKEND}_config" "$@"; }

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
# starts empty and is filled in by Radiator's UpdateQuery. When restoring an
# export, created, accessed and the counters come from the export.
sqlite_insert_sql() {
    local verb=INSERT created=CURRENT_TIMESTAMP accessed="''" counter=0 low=0 high=0
    local user pw pub priv secret
    [[ $REPLACE == 1 ]] && verb="INSERT OR REPLACE"
    if [[ $RESTORE == 1 ]]; then
        [[ -z $R_CREATED ]] || created=$(sql_quote "$R_CREATED")
        accessed=$(sql_quote "$R_ACCESSED")
        counter=$R_COUNTER low=$R_LOW high=$R_HIGH
    fi
    user=$(sql_quote "$R_USER") pw=$(sql_quote "$R_PASSWORD")
    pub=$(sql_quote "$R_PUB") priv=$(sql_quote "$R_PRIV") secret=$(sql_quote "$R_SECRET")

    if [[ $RESTORE == 1 && $REPLACE == 1 ]]; then
        # Restoring over existing rows: keep whichever counters are ahead, the
        # export's or those of a row being replaced, so a restore never lets
        # an already used OTP be accepted again.
        printf 'INSERT OR REPLACE INTO yubikeys (username, password, active, created, accessed, tokenId, userId, secret, counter, low, high)\n'
        printf 'SELECT %s, %s, %s, %s, m.accessed, %s, %s, %s, m.counter, m.low, m.high FROM (\n' \
            "$user" "$pw" "$R_ACTIVE" "$created" "$pub" "$priv" "$secret"
        printf '    SELECT %s AS counter, %s AS low, %s AS high, %s AS accessed\n' "$counter" "$low" "$high" "$accessed"
        printf '    UNION ALL SELECT coalesce(counter, 0), coalesce(low, 0), coalesce(high, 0), accessed FROM yubikeys WHERE tokenId = %s OR userId = %s\n' "$pub" "$priv"
        printf '    ORDER BY counter DESC, low DESC, accessed DESC LIMIT 1) AS m;\n'
    elif [[ $UPSERT == 1 ]]; then
        # Keep the times and counters of a row with the same YubiKey. Rows that
        # clash on the public or private ID are replaced, counters reset.
        printf 'INSERT OR REPLACE INTO yubikeys (username, password, active, created, accessed, tokenId, userId, secret, counter, low, high)\n'
        printf "SELECT %s, %s, %s, coalesce(o.created, CURRENT_TIMESTAMP), coalesce(o.accessed, ''), %s, %s, %s,\n" \
            "$user" "$pw" "$R_ACTIVE" "$pub" "$priv" "$secret"
        printf '       coalesce(o.counter, 0), coalesce(o.low, 0), coalesce(o.high, 0)\n'
        printf '  FROM (SELECT 1) LEFT JOIN yubikeys o ON %s;\n' "$(same_key_sql o.)"
    else
        printf "%s INTO yubikeys (username, password, active, created, accessed, tokenId, userId, secret, counter, low, high) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);\n" \
            "$verb" "$user" "$pw" "$R_ACTIVE" "$created" "$accessed" "$pub" "$priv" "$secret" "$counter" "$low" "$high"
    fi
}

# 'list' never selects the AES key or password.
sqlite_list() {
    {
        printf '.headers on\n.mode column\n'
        printf 'SELECT username, tokenId AS public_id, active, created, accessed, counter\n'
        printf '  FROM yubikeys %s ORDER BY username, tokenId;\n' "${1-}"
    } | sqlite_run
}

# Times are stored as UTC text and exported as they are.
sqlite_export_json() {
    {
        printf '.mode json\n'
        printf 'SELECT username, password, active, created, accessed, tokenId AS tokenid, userId AS userid,\n'
        printf '       secret, counter, low, high\n'
        printf '  FROM yubikeys %s ORDER BY username, tokenId;\n' "${1-}"
    } | sqlite_run
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
# PostgreSQL backend
#
# psql uses the standard libpq connection settings: -d sets PGDATABASE, and
# PGHOST, PGPORT, PGUSER, PGSSLMODE and PGSERVICE are used as they are set.
# Passwords come from ~/.pgpass, or are not needed with peer authentication
# on the local socket. This script never puts one on a command line.
#
# Roles (names set by PG_ADMIN_ROLE and PG_RADIATOR_ROLE):
#   admin role     owns the database and table. People who run this script
#                  are members of it (init-pg --admin LOGIN).
#   radiator role  Radiator's login. It can read the lookup columns and
#                  update only accessed and the counters.
# --------------------------------------------------------------------------

# Point psql at the database: -d wins, then PGDATABASE, then "yubikey". A
# libpq service (PGSERVICE) supplies its own dbname when neither is set.
pg_setup() {
    if [[ -n $DB_OPT ]]; then
        export PGDATABASE=$DB_OPT
    elif [[ -z ${PGDATABASE-} && -z ${PGSERVICE-} ]]; then
        export PGDATABASE=yubikey
    fi
    DB_DESC="PostgreSQL database ${PGDATABASE:-from service $PGSERVICE}"
    pg_check_name "admin role (PG_ADMIN_ROLE)" "$PG_ADMIN_ROLE"
    pg_check_name "Radiator role (PG_RADIATOR_ROLE)" "$PG_RADIATOR_ROLE"
}

# Role and database names are written into SQL as identifiers, so only
# plain lowercase names are accepted. $1 = what it is, $2 = the name.
pg_check_name() {
    [[ $2 =~ ^[a-z_][a-z0-9_]{0,62}$ ]] \
        || die "invalid $1 '$2' (use lowercase letters, digits and _, starting with a letter or _)"
}

pg_require_tools() {
    command -v "$PSQL" >/dev/null 2>&1 \
        || die "psql not found (install the postgresql-client package or set PSQL=/path/to/psql)"
}

# Run psql on SQL read from stdin, stopping at the first error. Terse errors
# leave out PostgreSQL's DETAIL line, which would show the private ID on a
# duplicate key. Arguments are passed to psql.
pg_psql() {
    {
        cat <<'EOF'
\set VERBOSITY terse
SET client_min_messages = warning;
SET standard_conforming_strings = on;
SET lock_timeout = '5s';
EOF
        cat
    } | "$PSQL" -X -q -v ON_ERROR_STOP=1 "$@"
}

pg_run() {
    pg_psql --no-align --tuples-only
}

# Print "missing" if there is no yubikeys table, "ok" if the SQL condition
# $1 is true, and "denied" otherwise. Exits if psql cannot connect.
pg_table_access() {
    local out
    out=$(printf "SELECT CASE WHEN to_regclass('yubikeys') IS NULL THEN 'missing' WHEN %s THEN 'ok' ELSE 'denied' END;\n" "$1" \
            | pg_run 2>&1) \
        || die "cannot use $DB_DESC: ${out#psql: error: }"
    printf '%s' "$out"
}

pg_ensure_readable() {
    local state
    state=$(pg_table_access "has_table_privilege('yubikeys', 'SELECT')") || exit 1
    case $state in
        ok)      ;;
        missing) die "$DB_DESC has no yubikeys table; run '$PROG -b pg init-pg' first" ;;
        *)       die "no read access to the yubikeys table in $DB_DESC (is ${PGUSER:-$(id -un)} a member of $PG_ADMIN_ROLE?)" ;;
    esac
}

pg_ensure_writable() {
    local state
    state=$(pg_table_access "has_table_privilege('yubikeys', 'INSERT')
        AND has_table_privilege('yubikeys', 'UPDATE') AND has_table_privilege('yubikeys', 'DELETE')") || exit 1
    case $state in
        ok)      ;;
        missing) die "$DB_DESC has no yubikeys table; run '$PROG -b pg init-pg' first" ;;
        *)       die "no write access to the yubikeys table in $DB_DESC (is ${PGUSER:-$(id -un)} a member of $PG_ADMIN_ROLE?)" ;;
    esac
}

# Table definition. It differs from the SQLite one where PostgreSQL is
# stricter: timestamps are real timestamps, accessed is NULL until the first
# login, active is a 0/1 smallint (a boolean column rejects 1), and the
# password column is text, because a {crypt} hash is longer than 64
# characters. Counters are NOT NULL because Radiator skips its replay check
# when the counter is NULL.
pg_schema() {
    cat <<EOF
CREATE TABLE IF NOT EXISTS yubikeys (
    username varchar(255) NOT NULL,
    password text         NOT NULL DEFAULT '',
    active   smallint     NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created  timestamptz  NOT NULL DEFAULT now(),
    accessed timestamptz,
    tokenId  varchar(60)  NOT NULL UNIQUE,   -- YubiKey public ID (modhex)
    userId   varchar(60)  PRIMARY KEY,       -- YubiKey private ID (hex)
    secret   varchar(60)  NOT NULL,          -- AES key (base64 or hex)
    counter  integer      NOT NULL DEFAULT 0,
    low      integer      NOT NULL DEFAULT 0,
    high     integer      NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS yubikeys_username ON yubikeys (username);
REVOKE ALL ON yubikeys FROM PUBLIC;
GRANT SELECT (username, password, active, tokenId, userId, secret, counter, low, high)
    ON yubikeys TO $PG_RADIATOR_ROLE;
GRANT UPDATE (accessed, counter, low, high) ON yubikeys TO $PG_RADIATOR_ROLE;
EOF
}

pg_init() {
    [[ $# -eq 0 ]] || die "init: unknown option '$1'"
    pg_require_version
    pg_create_table
}

# Exit unless the server runs PostgreSQL 18 or later, the only version this
# script supports. Arguments are passed to psql (init-pg uses -d postgres).
pg_require_version() {
    local out num ver
    out=$(echo "SELECT current_setting('server_version_num') || '|' || current_setting('server_version');" \
            | pg_psql --no-align --tuples-only "$@") \
        || die "cannot connect to PostgreSQL to check its version"
    IFS='|' read -r num ver <<<"$out"
    if ! [[ $num =~ ^[0-9]+$ ]] || (( num < 180000 )); then
        die "PostgreSQL 18 or later is required (this server runs ${ver:-an unknown version})"
    fi
}

# Create the table and Radiator's grants in an existing database. Run as a
# member of the admin role (or a superuser). The table is created as the
# admin role, so that role owns it rather than whoever ran init.
pg_create_table() {
    if ! { printf 'SET ROLE %s;\n' "$PG_ADMIN_ROLE"; pg_schema; } | pg_run; then
        die "init failed; roles $PG_ADMIN_ROLE and $PG_RADIATOR_ROLE must exist and ${PGUSER:-$(id -un)} must be a member of $PG_ADMIN_ROLE (run init-pg first)"
    fi
    info "Database ready: $DB_DESC (owner $PG_ADMIN_ROLE, Radiator role $PG_RADIATOR_ROLE)"
}

# init-pg: create the roles and the database, then the table. Run as the
# postgres superuser, or a role with CREATEROLE and CREATEDB. Safe to re-run:
# existing roles and the database are kept.
pg_init_server() {
    local -a admins=()
    local set_password=0 db login
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--admin)     admins+=("${2:?--admin needs a login role name}"); shift 2 ;;
            --set-password) set_password=1; shift ;;
            *) die "init-pg: unknown option '$1'" ;;
        esac
    done
    db=${PGDATABASE:-}
    [[ -n $db ]] || die "init-pg: name the database with -d (a service name alone is not enough)"
    pg_check_name "database name" "$db"
    for login in "${admins[@]}"; do pg_check_name "login role" "$login"; done
    if [[ $set_password == 1 && ! -t 0 ]]; then
        die "init-pg: --set-password needs a terminal to prompt on"
    fi
    pg_require_version -d postgres

    local a=$PG_ADMIN_ROLE r=$PG_RADIATOR_ROLE
    {
        printf "SELECT 'CREATE ROLE %s NOLOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s')\n\\\\gexec\n" "$a" "$a"
        printf "SELECT 'CREATE ROLE %s LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s')\n\\\\gexec\n" "$r" "$r"
        for login in "${admins[@]}"; do
            printf "SELECT 'CREATE ROLE %s LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s')\n\\\\gexec\n" "$login" "$login"
            printf 'GRANT %s TO %s;\n' "$a" "$login"
        done
        # A non-superuser can only create a database owned by a role it can act as.
        printf "SELECT 'GRANT %s TO ' || quote_ident(current_user) FROM pg_roles WHERE rolname = current_user AND NOT rolsuper AND NOT pg_has_role(current_user, '%s', 'SET')\n\\\\gexec\n" "$a" "$a"
        printf "SELECT 'CREATE DATABASE %s OWNER %s' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '%s')\n\\\\gexec\n" "$db" "$a" "$db"
        printf 'REVOKE ALL ON DATABASE %s FROM PUBLIC;\n' "$db"
        printf 'GRANT CONNECT ON DATABASE %s TO %s;\n' "$db" "$r"
    } | pg_psql --no-align --tuples-only -d postgres \
        || die "init-pg failed (run it as the postgres superuser, e.g. sudo -u postgres $PROG -b pg init-pg)"
    info "Roles ready: $a (owner) and $r (Radiator login)${admins[*]:+; members of $a: ${admins[*]}}"

    pg_create_table

    if [[ $set_password == 1 ]]; then
        info "Set the password for $r (Radiator's DBAuth):"
        "$PSQL" -X -q -d postgres -c "\\password $r" || die "could not set the password for $r"
    fi
    cat <<EOF
Next steps:
  - Radiator on this host: with Ubuntu's default peer authentication on the
    local socket, Radiator must run as the OS user "$r" and needs no password.
  - Radiator on another host: add a line like this to pg_hba.conf, above the
    generic "host all all" lines, reload PostgreSQL, and give $r a password
    with: $PROG -b pg -d $db init-pg --set-password
        hostssl  $db  $r  <radiator-ip>/32  scram-sha-256
  - Print the Radiator configuration: $PROG -b pg -d $db config
EOF
}

# Print the INSERT for the record held in the R_* globals. With --replace,
# rows that clash on the public ID or the private ID are deleted in the same
# statement (ON CONFLICT covers only one constraint), so the replacement is
# atomic. Referencing the DELETE makes it run before the INSERT.
pg_insert_sql() {
    local cols vals created=CURRENT_TIMESTAMP accessed=NULL counter=0 low=0 high=0
    if [[ $RESTORE == 1 ]]; then              # export times are UTC
        [[ -z $R_CREATED ]] || created=$(sql_quote "$R_CREATED+00")
        [[ -z $R_ACCESSED ]] || accessed=$(sql_quote "$R_ACCESSED+00")
        counter=$R_COUNTER low=$R_LOW high=$R_HIGH
    fi
    cols="username, password, active, created, accessed, tokenId, userId, secret, counter, low, high"
    vals="$(sql_quote "$R_USER"), $(sql_quote "$R_PASSWORD"), $R_ACTIVE, $created, $accessed, $(sql_quote "$R_PUB"), $(sql_quote "$R_PRIV"), $(sql_quote "$R_SECRET"), $counter, $low, $high"
    if [[ $RESTORE == 1 && $REPLACE == 1 ]]; then
        # Restoring over existing rows: keep whichever counters are ahead, the
        # export's or those of a row being replaced (read before the DELETE,
        # since all parts of one statement see the same snapshot).
        local pub priv
        pub=$(sql_quote "$R_PUB") priv=$(sql_quote "$R_PRIV")
        printf 'WITH old AS (SELECT counter, low, high, accessed FROM yubikeys WHERE tokenId = %s OR userId = %s),\n' "$pub" "$priv"
        printf '     best AS (SELECT * FROM (SELECT %s AS counter, %s AS low, %s AS high, %s::timestamptz AS accessed\n' \
            "$counter" "$low" "$high" "$accessed"
        printf '                            UNION ALL SELECT * FROM old) b\n'
        printf '               ORDER BY counter DESC, low DESC, accessed DESC NULLS LAST LIMIT 1),\n'
        printf '     replaced AS (DELETE FROM yubikeys WHERE tokenId = %s OR userId = %s RETURNING 1)\n' "$pub" "$priv"
        printf 'INSERT INTO yubikeys (%s)\nSELECT %s, %s, %s, %s, best.accessed, %s, %s, %s, best.counter, best.low, best.high\n' \
            "$cols" "$(sql_quote "$R_USER")" "$(sql_quote "$R_PASSWORD")" "$R_ACTIVE" "$created" "$pub" "$priv" "$(sql_quote "$R_SECRET")"
        printf '  FROM best WHERE (SELECT count(*) FROM replaced) >= 0;\n'
    elif [[ $UPSERT == 1 ]]; then
        # Keep the times and counters of a row with the same YubiKey (read
        # before the DELETE, as in the restore above). Rows that clash on the
        # public or private ID are replaced, counters reset.
        printf 'WITH old AS (SELECT created, accessed, counter, low, high FROM yubikeys WHERE %s),\n' "$(same_key_sql)"
        printf '     replaced AS (DELETE FROM yubikeys WHERE tokenId = %s OR userId = %s RETURNING 1)\n' \
            "$(sql_quote "$R_PUB")" "$(sql_quote "$R_PRIV")"
        printf 'INSERT INTO yubikeys (%s)\nSELECT %s, %s, %s, coalesce(old.created, CURRENT_TIMESTAMP), old.accessed, %s, %s, %s,\n' \
            "$cols" "$(sql_quote "$R_USER")" "$(sql_quote "$R_PASSWORD")" "$R_ACTIVE" \
            "$(sql_quote "$R_PUB")" "$(sql_quote "$R_PRIV")" "$(sql_quote "$R_SECRET")"
        printf '       coalesce(old.counter, 0), coalesce(old.low, 0), coalesce(old.high, 0)\n'
        printf '  FROM (SELECT 1) AS one LEFT JOIN old ON true WHERE (SELECT count(*) FROM replaced) >= 0;\n'
    elif [[ $REPLACE == 1 ]]; then
        printf 'WITH replaced AS (DELETE FROM yubikeys WHERE tokenId = %s OR userId = %s RETURNING 1)\n' \
            "$(sql_quote "$R_PUB")" "$(sql_quote "$R_PRIV")"
        printf 'INSERT INTO yubikeys (%s)\nSELECT %s WHERE (SELECT count(*) FROM replaced) >= 0;\n' "$cols" "$vals"
    else
        printf 'INSERT INTO yubikeys (%s) VALUES (%s);\n' "$cols" "$vals"
    fi
}

# Times are shown in UTC, in the same format as the SQLite backend.
pg_list() {
    cat <<EOF | pg_psql --pset=footer=off
SELECT username, tokenId AS public_id, active,
       to_char(created AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS created,
       to_char(accessed AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS accessed,
       counter
  FROM yubikeys ${1-} ORDER BY username, tokenId;
EOF
}

pg_export_json() {
    pg_run <<EOF
SELECT coalesce(json_agg(json_build_object(
           'username', username, 'password', password, 'active', active,
           'created', to_char(created AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
           'accessed', to_char(accessed AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
           'tokenid', tokenId, 'userid', userId, 'secret', secret,
           'counter', counter, 'low', low, 'high', high)
         ORDER BY username, tokenId), '[]')
  FROM yubikeys ${1-};
EOF
}

pg_change() {
    printf 'WITH changed AS (%s RETURNING 1) SELECT count(*) FROM changed;\n' "${1%;}" | pg_run
}

pg_config() {
    local dsn
    if [[ -z ${PGDATABASE-} ]]; then
        dsn="dbi:Pg:service=$PGSERVICE"
    else
        dsn="dbi:Pg:dbname=$PGDATABASE"
        if [[ -n ${PGHOST-} && $PGHOST != /* ]]; then
            dsn+=";host=$PGHOST;port=${PGPORT:-5432};sslmode=${PGSSLMODE:-verify-full}"
        fi
    fi
    cat <<EOF
# Sample Radiator <AuthBy SQLYUBIKEY> clause for $DB_DESC
# (secret stored as $SECRET_ENCODING; see the comments below)
<AuthBy SQLYUBIKEY>
    Identifier   YubiKeyLocal

    # Radiator on the database host connects over the local socket
    # (dbi:Pg:dbname=NAME). With peer authentication, the Ubuntu default,
    # Radiator must run as the OS user "$PG_RADIATOR_ROLE" and DBAuth stays empty.
    # Radiator on another host connects over TLS, for example
    #   dbi:Pg:dbname=NAME;host=db.example.com;port=5432;sslmode=verify-full
    # with DBAuth set to the $PG_RADIATOR_ROLE role's password (init-pg --set-password).
    # A standby server can be listed as a second DBSource/DBUsername/DBAuth.
    DBSource     $dsn
    DBUsername   $PG_RADIATOR_ROLE
    DBAuth

    # Columns must come back in this order: secret, active, userId,
    # counter, session_use (low), ignored (high), static_password.
    # %0 = quoted username, %3 = token (public) ID in modhex.
    AuthSelect   select secret, active, userId, counter, low, high, password from yubikeys where username=%0 and tokenId=%3

    # %0 = counter, %1 = session use, %2 = 0, %3 = quoted username,
    # %5 = Unix time, %7 = token ID in modhex. Radiator's default
    # current_timestamp() is not valid in PostgreSQL, so %5 is used.
    UpdateQuery  update yubikeys set accessed=to_timestamp(%5), counter=%0, low=%1, high=%2 where username=%3 and tokenId=%7

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
            --update)         UPSERT=1; shift ;;
            *) die "add: unknown option '$1'" ;;
        esac
    done
    [[ $REPLACE == 0 || $UPSERT == 0 ]] || die "add: use either --replace or --update, not both"
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
    local out
    if ! out=$(db_insert_sql | db_run); then
        die "could not add $R_USER (if this YubiKey is already in the database, use --replace or --update)"
    fi
    info "${out:-Added $R_USER with YubiKey $R_PUB (active=$R_ACTIVE)}"
}

# Append the INSERT for the validated record (R_* globals) to TMPFILE, unless
# its public or private ID was already used earlier in the file. Updates
# cmd_import's ok, bad, seen_pub and seen_priv. $1 = line number.
queue_record() {
    if [[ -n ${seen_pub[$R_PUB]-} ]]; then
        warn "line $1: public ID $R_PUB is already used on line ${seen_pub[$R_PUB]}"; bad=$((bad + 1)); return
    fi
    if [[ -n ${seen_priv[$R_PRIV]-} ]]; then
        warn "line $1: private ID for $R_USER is already used on line ${seen_priv[$R_PRIV]}"; bad=$((bad + 1)); return
    fi
    seen_pub[$R_PUB]=$1
    seen_priv[$R_PRIV]=$1
    db_insert_sql >>"$TMPFILE"
    ok=$((ok + 1))
}

cmd_import() {
    local file='' dry_run=0 skip_invalid=0
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)      dry_run=1; shift ;;
            --skip-invalid) skip_invalid=1; shift ;;
            --replace)      REPLACE=1; shift ;;
            --update)       UPSERT=1; shift ;;
            --from-export)  RESTORE=1; shift ;;
            -?*)            die "import: unknown option '$1'" ;;
            *)              [[ -z $file ]] || die "import: only one CSV file allowed"; file=$1; shift ;;
        esac
    done
    [[ -n $file ]] || die "import: CSV file required (or - for standard input)"
    [[ $REPLACE == 0 || $UPSERT == 0 ]] || die "import: use either --replace or --update, not both"
    [[ $RESTORE == 0 || $UPSERT == 0 ]] \
        || die "import: --update does not apply to --from-export; use --replace, which never moves counters backward"
    if [[ $file == - ]]; then file=/dev/stdin; fi
    [[ -r $file ]] || die "cannot read $file"
    if [[ $dry_run == 0 ]]; then db_ensure_writable; fi

    # Warn if other users can read the CSV, since it contains AES keys.
    if [[ $file != /dev/stdin && -n $(find "$file" -maxdepth 0 -perm /o=r 2>/dev/null) ]]; then
        warn "$file is world-readable and contains AES keys; consider: chmod 600 '$file'"
    fi

    TMPFILE=$(mktemp)          # created mode 0600
    echo 'BEGIN;' >"$TMPFILE"

    local line lineno=0 first_row=1 ok=0 bad=0 i
    local -a f items
    local -A seen_pub=() seen_priv=()
    if [[ $RESTORE == 1 ]]; then
        mapfile -d '' -t items < <(parse_export_csv "$file")
        [[ ${#items[@]} -gt 0 && ${items[-1]} == '@@end' ]] \
            || die "nothing imported"
        unset 'items[-1]'
        for (( i = 0; i < ${#items[@]}; i += 13 )); do
            lineno=${items[i]}
            f=("${items[@]:i+2:11}")
            if [[ ${items[i+1]} != 11 ]]; then
                warn "line $lineno: expected 11 fields, found ${items[i+1]}"; bad=$((bad + 1)); continue
            fi
            if ! validate_export_record "${f[@]}"; then
                warn "line $lineno: $ERR"; bad=$((bad + 1)); continue
            fi
            if [[ -n $R_NOTE ]]; then warn "line $lineno: $R_NOTE"; fi
            queue_record "$lineno"
        done
    fi
    while [[ $RESTORE == 0 ]] && { IFS= read -r line || [[ -n $line ]]; }; do
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
        queue_record "$lineno"
    done <"$file"
    echo 'COMMIT;' >>"$TMPFILE"

    info "Validated $file: $ok valid row(s), $bad invalid row(s)"
    if [[ $bad -gt 0 && $skip_invalid == 0 ]]; then
        die "nothing imported; fix the rows above or re-run with --skip-invalid"
    fi
    if [[ $ok == 0 ]]; then die "no valid rows to import"; fi
    if [[ $dry_run == 1 ]]; then info "Dry run: database not changed"; return; fi

    # --update reports each row it changes; print that only once committed.
    local out hint="--replace or --update"
    if [[ $RESTORE == 1 ]]; then hint=--replace; fi
    if ! out=$(db_run <"$TMPFILE"); then
        die "import failed and was rolled back; no rows imported (an existing YubiKey? use $hint)"
    fi
    if [[ -n $out ]]; then info "$out"; fi
    info "Imported $ok row(s) into $DB_DESC"
    if [[ $RESTORE == 1 && $REPLACE == 1 ]]; then
        info "Counters were kept from the database wherever it was ahead of the export."
    fi
}

# Check a username, static password and OTP the way Radiator's AuthBy
# SQLYUBIKEY does with Require2Factor and CheckSecretId (see verify_otp). If
# they are accepted, save the OTP's counters and the access time, as
# Radiator's UpdateQuery would, so the same OTP is not accepted again. The
# UPDATE only applies while the counters are still behind, so an OTP that
# Radiator accepts in the meantime still counts as a replay.
cmd_verify() {
    local user='' pw='' otp='' pub rows result counter session note n
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--user) user=${2?}; shift 2 ;;
            *) die "verify: unknown option '$1'" ;;
        esac
    done
    perl -MCrypt::Rijndael -e 1 2>/dev/null \
        || die "verify needs the Perl module Crypt::Rijndael (install the libcrypt-rijndael-perl package)"
    db_ensure_writable

    [[ -n $user ]] || read_value user "Username"
    read_value pw "Static password/PIN (Enter for none)" secret
    read_value otp "YubiKey OTP (touch the YubiKey)"
    otp=${otp,,}
    otp=${otp//[[:space:]]/}
    # The OTP is the public ID (2-32 modhex characters) and 32 characters of
    # encrypted token. It is not printed: it may be a password typed by mistake.
    [[ $otp =~ ^([cbdefghijklnrtuv]{2}){17,32}$ ]] \
        || die "verify: that is not a YubiKey OTP (expected 34 to 64 modhex characters, got ${#otp})"
    pub=${otp:0:${#otp}-32}

    rows=$(db_export_json "WHERE username = $(sql_quote "$user") OR tokenId = $(sql_quote "$pub")") \
        || die "verify: cannot read $DB_DESC"
    info "Checking $user with YubiKey $pub in $DB_DESC:"
    exec 4>&1
    result=$(printf '%s\n%s\n%s' "$pw" "$otp" "$rows" | verify_otp "$user" "$pub" 3>&1 1>&4) \
        || die "verify: the check failed to run"
    [[ $result == accept\ * ]] || die "verify: rejected (${result#reject })"

    read -r _ counter session note <<<"$result"
    n=$(db_change "UPDATE yubikeys SET accessed = CURRENT_TIMESTAMP, counter = $counter, low = $session
 WHERE username = $(sql_quote "$user") AND tokenId = $(sql_quote "$pub")
   AND (counter IS NULL OR counter < $counter OR (counter = $counter AND coalesce(low, 0) < $session));")
    [[ $n -gt 0 ]] || die "verify: rejected (replayed OTP: a newer one was used while this one was checked)"
    if [[ -n $note ]]; then warn "the static password was not checked"; fi
    info "Accepted. The OTP's counters were saved, so it cannot be used again."
}

cmd_list() {
    db_ensure_readable
    local where=''
    [[ $# -le 1 ]] || die "list: too many arguments"
    if [[ $# -eq 1 ]]; then where="WHERE username = $(sql_quote "$1")"; fi
    db_list "$where"
}

# Write every row to a CSV file created with mode 0600, or to stdout with "-".
# The file is written under a temporary name in the same directory and then
# renamed, so a failed export leaves no partial file behind.
cmd_export() {
    local file='' force=0
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force) force=1; shift ;;
            -?*)        die "export: unknown option '$1'" ;;
            *)          [[ -z $file ]] || die "export: only one output file allowed"; file=$1; shift ;;
        esac
    done
    [[ -n $file ]] || die "export: output file required (use - for standard output)"
    db_ensure_readable

    local count
    if [[ $file == - ]]; then
        exec 4>&1
        count=$(db_export_json | csv_from_json 3>&1 1>&4) || die "export failed"
        warn "exported $count row(s) to standard output, with every AES key and private ID in clear text"
        return
    fi

    [[ ! -d $file ]] || die "export: $file is a directory"
    if [[ $force == 0 && ( -e $file || -L $file ) ]]; then
        die "export: $file already exists (use --force to replace it)"
    fi
    local dir
    dir=$(dirname -- "$file")
    [[ -d $dir && -w $dir ]] || die "export: cannot write to the directory $dir"
    TMPFILE=$(mktemp "$dir/.yubikey-export.XXXXXX")    # mode 0600; removed on exit
    count=$(db_export_json | csv_from_json 3>&1 >"$TMPFILE") || die "export failed; $file was not written"
    if [[ $force == 1 ]]; then
        mv -f -- "$TMPFILE" "$file"
    else
        mv -n -- "$TMPFILE" "$file" 2>/dev/null || true
        [[ ! -e $TMPFILE ]] || die "export: $file already exists (use --force to replace it)"
    fi
    TMPFILE=
    info "Exported $count row(s) to $file (mode 0600)"
    warn "$file contains every AES key and private ID in clear text; keep it private and delete it with 'shred -u' when done"
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
        -b|--backend)         DB_BACKEND=${2:?--backend needs sqlite or pg}; shift 2 ;;
        -d|--db)              DB_OPT=${2:?--db needs a file or database name}; shift 2 ;;
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
case $DB_BACKEND in
    sqlite) DB_FILE=${DB_OPT:-$DB_FILE}; DB_DESC=$DB_FILE ;;
    pg)     pg_setup ;;
    *)      die "--backend must be sqlite or pg" ;;
esac
[[ $# -gt 0 ]] || { usage >&2; exit 1; }

cmd=$1; shift
case $cmd in
    config) db_config "$@"; exit ;;    # needs no tools or database
esac
require_tools
case $cmd in
    init)                   db_init "$@" ;;
    init-pg)                [[ $DB_BACKEND == pg ]] || die "init-pg is for PostgreSQL; add -b pg"
                            pg_init_server "$@" ;;
    add)                    cmd_add "$@" ;;
    import)                 cmd_import "$@" ;;
    list)                   cmd_list "$@" ;;
    enable|disable|delete)  cmd_modify "$cmd" "$@" ;;
    export)                 cmd_export "$@" ;;
    verify)                 cmd_verify "$@" ;;
    *)                      die "unknown command '$cmd' (see '$PROG help')" ;;
esac
