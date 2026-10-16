#!/usr/bin/env bash
#
# yubikey-db.sh - Manage the SQLite or PostgreSQL YubiKey database used by
#                 Radiator RADIUS (<AuthBy SQLYUBIKEY>) for offline YubiKey
#                 OTP authentication with no YubiCloud dependency.
#
# VERSION
#   In the file VERSION, next to this script; -V shows it.
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
#   init      Create the database file and the yubikeys table (safe to re-run;
#             it also brings a database made by an older version up to date)
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
#   label     Set or remove the label of one of a user's keys, such as
#             "primary, slot 2", to tell their keys apart
#   export    Write every record and field to a CSV file, with AES keys and
#             private IDs in clear text (the file is created with mode 0600)
#   verify    Ask for a username, password and OTP, and check them against
#             the database the way Radiator 4.30 does; saves the counters if
#             accepted
#   config    Print a sample Radiator <AuthBy SQLYUBIKEY> clause for this
#             database, and the clauses for service accounts and groups
#   service   Service accounts (svc.NAME), which log in with a password
#             instead of a YubiKey: add, password, list, enable, disable,
#             delete, label
#   group     Groups of accounts: add, delete, list, label
#   member    Put accounts in a group, or take them out: add, delete
#   access    Which device groups a group may log in to, with the TACACS+
#             privilege level and RADIUS reply: set, delete, list, check
#   rule      TACACS+ command rules for a group on a device group: add,
#             delete, list
#   Run "yubikey-db.sh help" for every option.
#
# CSV FORMAT (for 'import')
#   username,public_id,private_id,aes_key,password,active,label
#   test.user,cbdefghijkln,456789abcdef,0123456789abcdef0123456789abcdef,abc123,1,primary slot 2
#
#   - The header row is optional. Blank lines and lines starting with '#' are skipped.
#   - public_id : YubiKey public ID: 12 modhex characters (Radiator's
#                 AuthBy SQLYUBIKEY accepts no other length)
#   - private_id: 12 hex characters (12 modhex characters are also accepted)
#   - aes_key   : 32 hex characters (spaces and colons are removed)
#   - password  : optional static password/PIN, used with Require2Factor
#   - active    : optional; 1/0, true/false, yes/no (default 1)
#   - label     : optional description of the key, up to 255 characters,
#                 shown by 'list'. Empty keeps the label an existing key
#                 already has (with --update or --replace).
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
#   sudo ./yubikey-db.sh label test.user cbdefghijkln 'spare, slot 2'
#   sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin alice
#   ./yubikey-db.sh -b pg import users.csv                    # as alice
#   ./yubikey-db.sh -b pg config
#
# DIFFERENCES FROM THE ORIGINAL EXAMPLE STATEMENTS
#   - created is set with an unquoted CURRENT_TIMESTAMP. In SQLite,
#     "current_timestamp" in double quotes stores the literal text.
#   - active is stored as 1/0. Radiator disables a key only when active is
#     0 or empty: the text 'false' from the original example still lets the
#     key log in.
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
#   PGHOST, PGPORT, PGUSER, PGSSLMODE, PGSSLROOTCERT, PGSERVICE,
#   PGCONNECT_TIMEOUT, PGTARGETSESSIONATTRS
#                    Standard PostgreSQL connection settings, used by psql.
#                    Put passwords in ~/.pgpass, never on the command line.
#                    'config' copies them (except PGUSER and PGSERVICE)
#                    into Radiator's DBSource. With two servers
#                    (PGHOST=db1,db2), PGTARGETSESSIONATTRS defaults to
#                    read-write, so changes go to the primary.
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
# The version is in the file VERSION, next to this script (the package has it
# written here instead).
VERSION=$(cat -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/VERSION" 2>/dev/null) || VERSION=unknown
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
# requires them as the header). Exports made before 1.8.0 have no label.
EXPORT_COLUMNS=username,public_id,private_id,aes_key,password,active,created,accessed,counter,low,high,label
OLD_EXPORT_COLUMNS=${EXPORT_COLUMNS%,label}
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
        database (run as a member of the admin role). Safe to re-run: it also
        brings a database made by an older version up to date.

  init-pg [-a|--admin LOGIN]... [--set-password]          (PostgreSQL only)
        Create the admin role ($PG_ADMIN_ROLE), Radiator's login role
        ($PG_RADIATOR_ROLE) and the database, then run init. Run it as the
        postgres superuser. Each --admin LOGIN is created if needed and made a
        member of the admin role, so it can manage users. --set-password asks
        for Radiator's password (needed only when Radiator connects over TCP).

  add [-u USER] [-P PUBLIC_ID] [-p PRIVATE_ID] [-k AES_KEY] [-w PASSWORD]
      [-l LABEL] [--no-password] [--inactive] [--replace | --update]
        Add one user. Missing values are prompted for (the key and password
        are not echoed). Options -k and -w are visible to other users in
        'ps' and shell history, so prefer the prompts or 'import'. LABEL
        describes the YubiKey (e.g. "spare, slot 2"), up to 255 characters.

  import [--dry-run] [--skip-invalid] [--replace | --update] [--from-export]
         CSV_FILE|-
        Bulk-load from CSV (format:
        username,public_id,private_id,aes_key[,password[,active[,label]]]),
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
  label   USER PUBLIC_ID LABEL  Set the label of one of the user's keys
                                ('' removes it)
  verify [-u USER] [--no-require2factor]
        Check a password and OTP against the database the way Radiator 4.30
        does with the configuration from 'config': the user must have the
        OTP's YubiKey (with a 12-character public ID), active must not be 0
        or empty, the static password must match a non-empty stored one, the
        OTP must decrypt to the stored private ID, and its counters must be
        ahead of the stored ones. With --no-require2factor (for a Radiator
        without Require2Factor), the password is checked only if one is
        entered. If accepted, the counters are saved, as Radiator would, so
        the OTP cannot be used again. Values are prompted for, or read one per
        line from standard input when it is not a terminal: the username
        (unless -u is given), the password, then the OTP.
  export [-f|--force] FILE|-    Write every record and field to a CSV file
        (mode 0600), or to standard output with -. Columns: username,
        public_id, private_id, aes_key, password, active, created, accessed,
        counter, low, high, label. AES keys are 32 hex characters and private
        IDs are in clear text; passwords are as stored ({crypt} hashes stay
        hashed). An existing FILE is replaced only with --force.
  config                        Print a sample Radiator AuthBy clause, and the
                                clauses ServiceAccounts and GroupAccess

Service accounts and groups (the tables are added by init):
  service add NAME [-l LABEL] [--inactive] [--generate]
        Add a service account. NAME is svc. followed by letters, digits and
        . _ @ + -. Its password (at least 12 characters) is asked for twice,
        read from standard input when it is not a terminal, or generated
        (--generate: 32 random characters, shown once). It is stored hashed
        like static passwords (-H).
  service password NAME [--generate]   Change the password
  service list                         List the accounts (no passwords shown)
  service enable|disable NAME          Let the account log in, or not
  service delete NAME                  Delete it, and take it out of its groups
  service label NAME LABEL             Set its label ('' removes it)
  group add NAME [-l LABEL]            Add a group (up to 64 letters, digits
                                       and . _ -)
  group delete NAME                    Delete it, with its members, access
                                       and rules
  group list                           List groups, members and access
  group label NAME LABEL               Set its label ('' removes it)
  member add|delete GROUP USER...      Put YubiKey users or service accounts
                                       in a group, or take them out
  access set GROUP DEVICE_GROUP PRIV_LVL [-r RADIUS_REPLY]
        Let GROUP log in to the devices in DEVICE_GROUP (the Identifier of
        their <Client> clauses in Radiator, or * for every device), at
        TACACS+ privilege level PRIV_LVL (0-15), or change the level. -r
        sets the RADIUS reply attributes for those logins, such as
        'cisco-avpair="shell:priv-lvl=15"' ('' removes them). An account in
        several groups gets the most privileged one allowed on the device.
  access delete GROUP DEVICE_GROUP     Take that access away, with its rules
  access list [GROUP]                  List the access of every group
  access check USER DEVICE_GROUP
        Show what Radiator finds for USER on a device in DEVICE_GROUP: the
        group, privilege level, TACACS+ rules and RADIUS reply. Exits 1 when
        USER may not log in there.
  rule add GROUP DEVICE_GROUP 'RULE' [--seq N]
        Add a TACACS+ command rule, after the last one (or at N). RULE is
        permit|permitreplace|deny, then a Perl regular expression for each
        argument of the command, in order, each matched whole, e.g.
        'deny service=shell cmd=reload' or 'permit service=shell cmd=show'.
        The first rule that matches decides; a command no rule matches is
        denied. With no rules, every command is allowed.
  rule delete GROUP DEVICE_GROUP SEQ   Delete a rule
  rule list GROUP DEVICE_GROUP         List the rules, in order

--replace overwrites any existing row with the same public ID or private ID,
and resets its counters. Use it after reprogramming a YubiKey.
--update does the same, but keeps the counters (and the created and accessed
times) when the existing row has the same public ID, private ID and AES key,
so only the username, password and active flag change. Use it to change a
password, or when you are not sure whether a YubiKey is already loaded. If
the same values were programmed into a YubiKey again, use --replace.
With either, a YubiKey given no label keeps the label it has.

PostgreSQL connections use the standard PGHOST, PGPORT, PGUSER, PGSSLMODE and
PGSERVICE settings. Keep passwords in ~/.pgpass. With a primary and a standby,
list both (PGHOST=db1,db2): changes then go to the one that accepts writes.
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
                       $r->{active}, $r->{created}, $r->{accessed}, $r->{counter}, $r->{low}, $r->{high},
                       $r->{label}), "\n";
        }
        open(my $count, ">&=", 3) or die "$prog: error: cannot report the row count\n";
        print $count scalar(@$rows), "\n";
    ' "$PROG" "$EXPORT_COLUMNS"
}

# Validate and normalize one user record. On success, sets the R_* globals.
# On failure, sets ERR and returns 1. Error messages never include the AES
# key or private ID.
#   $1 username  $2 public_id  $3 private_id  $4 aes_key  $5 password  $6 active
#   $7 label
validate_record() {
    local user=$1 pw=${5-}
    ERR=

    [[ $user =~ ^[A-Za-z0-9._@+-]{1,255}$ ]] \
        || { ERR="invalid username '$user' (allowed: letters, digits and . _ @ + -)"; return 1; }
    validate_key_fields "$user" "$2" "$3" "$4" "${6-}" || return 1
    # Radiator reads exactly 12 characters of public ID from a login.
    [[ ${#R_PUB} -eq 12 ]] \
        || { ERR="public ID '$2' for $user has ${#R_PUB} characters; Radiator accepts only 12"; return 1; }
    validate_label "$user" "${7-}" || return 1

    R_USER=$user
    # Explicit error checks: 'set -e' does not apply inside 'if validate_record'.
    R_PASSWORD=$(hash_password "$pw") || { ERR="could not hash the password for $user"; return 1; }
}

# Validate one row of an export file (import --from-export). The password is
# kept as stored (it is already hashed), and created, accessed and the
# counters are restored. Usernames may be anything the database can hold. An
# invalid time is replaced, with a note in R_NOTE; an invalid counter makes the
# row invalid. Sets the R_* globals, or ERR and returns 1.
#   $1..$12 = the export columns, in EXPORT_COLUMNS order
validate_export_record() {
    local user=$1 pw=$5 created=$7 accessed=$8 counter=$9 low=${10} high=${11} label=${12-}
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
    validate_label "$user" "$label" || return 1
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

# Check a YubiKey's label: UTF-8 text of at most 255 characters, with no
# control characters (it is shown by 'list'). Empty means no label. Sets
# R_LABEL, or ERR and returns 1. The message does not repeat the label.
#   $1 username (for messages)  $2 label
validate_label() {
    local rc=0
    R_LABEL=
    if [[ -n $2 ]]; then
        LABEL=$2 perl -MEncode -e '
            my $s = eval { Encode::decode("UTF-8", $ENV{LABEL}, Encode::FB_CROAK | Encode::LEAVE_SRC) };
            exit 2 unless defined $s;
            exit 3 if $s =~ /[[:cntrl:]]/;
            exit 4 if length $s > 255;' || rc=$?
    fi
    case $rc in
        0) R_LABEL=$2 ;;
        2) ERR="invalid label for $1 (it is not UTF-8 text)"; return 1 ;;
        3) ERR="invalid label for $1 (it contains control characters)"; return 1 ;;
        4) ERR="invalid label for $1 (it is longer than 255 characters)"; return 1 ;;
        *) ERR="could not check the label for $1"; return 1 ;;
    esac
}

# SQL for the label to store with the record in the R_* globals: its own, or
# when it has none and --update or --replace may replace a row, the label of
# the row with the same public ID (read before that row is replaced).
label_sql() {
    if [[ -n $R_LABEL ]]; then
        sql_quote "$R_LABEL"
    elif [[ $REPLACE == 1 || $UPSERT == 1 ]]; then
        printf "coalesce((SELECT label FROM yubikeys WHERE tokenId = %s), '')" "$(sql_quote "$R_PUB")"
    else
        printf "''"
    fi
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
# doubled quotes and line breaks) and print, NUL-separated, the number of
# columns its header has, then for each row: its line number, its number of
# fields, and its first 12 fields (padded). The first row must be the export
# header, or that of an export made before 1.8.0 (11 columns, no label).
# "@@end" follows the last row, so a reader can tell a complete parse from a
# failed one.
parse_export_csv() {
    perl -e '
        my ($prog, $file, $header, $old_header) = @ARGV;
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
                my $h = join(",", @f);
                $h eq $header || $h eq $old_header
                    or die "$prog: error: $file is not an export file; its first line must be:\n  $header\n";
                print scalar(@f), "\0";
                $have_header = 1;
                next;
            }
            my $n = @f;
            $#f = 11;
            print join("\0", $start, $n, map { $_ // "" } @f), "\0";
        }
        $have_header or die "$prog: error: $file is empty\n";
        print "\@\@end\0";
    ' "$PROG" "$1" "$EXPORT_COLUMNS" "$OLD_EXPORT_COLUMNS"
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

# Check a password and OTP against the user's row the way Radiator 4.30's
# AuthBy SQLYUBIKEY does (Radius::AuthYUBIKEYGENERIC::checkYubikey), with
# CheckSecretId set. Reads from stdin: the password, the OTP, then the rows
# from db_export_json for the user and the OTP's public ID. Prints one line
# per check, and writes the verdict to file descriptor 3: "accept COUNTER
# SESSION [unchecked]" or "reject REASONS". Never prints the AES key or the
# private ID.
#   $1 program name  $2 username  $3 the OTP's public ID
#   $4 1 if Radiator's configuration has Require2Factor, else 0
verify_otp() {
    perl -MJSON::PP -MMIME::Base64 -MDigest::SHA -MCrypt::Rijndael -e '
        my ($prog, $user, $pub, $two_factor) = @ARGV;
        chomp(my $pw = <STDIN> // "");
        chomp(my $otp = <STDIN> // "");
        my $json = do { local $/; <STDIN> } // "";
        my $rows = $json =~ /\S/ ? JSON::PP->new->decode($json) : [];   # bytes, like $user and $pw
        open(my $res, ">&=", 3) or die "$prog: error: cannot report the result\n";
        sub show { printf "  %-17s %s\n", "$_[0]:", $_[1] }

        # Radiator checks a password against a stored one as check_plain_password
        # does. Returns undef for the formats this check does not implement.
        sub password_matches {
            my ($pw, $s) = @_;
            if ($s =~ /^\{SS?HA\}(.*)/si) {
                my ($hash, $salt) = unpack("a20a*", decode_base64($1));
                return $hash eq Digest::SHA::sha1($pw . $salt);
            }
            if ($s =~ /^\{SS?HA(256|384|512)\}(.*)/si) {
                my ($bits, $hash, $salt) = ($1, unpack("a" . $1 / 8 . "a*", decode_base64($2)));
                return $hash eq Digest::SHA->new($bits)->add($pw . $salt)->digest;
            }
            return crypt($pw, $1) eq $1 if $s =~ /^\{crypt\}(.*)/si;
            return undef if $s =~ /^\{(PBKDF2|mysql|mssql|nthash|dechpwd|MD5|NS-MTA-MD5|OSC-pw-hook|rcrypt)\}/i
                         || $s =~ /^(md5|sha1)\$[0-9a-f]{5}\$/i;
            return crypt($pw, $s) eq $s if $s =~ /^\$(1|[56]|2[axy])\$/;
            $s =~ s/^\{clear\}//;
            return $pw eq $s;
        }

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

        # The label only names the YubiKey; Radiator never reads it.
        show("label", $r->{label}) if length($r->{label} // "");

        # Radiator reads a 12-character public ID from the login, so no other
        # length is ever found in the database.
        if (length $pub != 12) {
            show("public ID", "NOT 12 characters (" . length($pub) . "); Radiator looks up only 12-character public IDs");
            push @fail, "public ID length";
        }

        # Radiator rejects the key only when active is 0 or empty; a missing
        # (NULL) value, or any other value such as "true" or "false", is active.
        my $active = $r->{active};
        if (defined $active && !$active) {
            show("active", "NO (active=$active)"); push @fail, "disabled";
        } elsif (defined $active && "$active" ne "1") {
            show("active", "yes, as Radiator treats active=$active as active (only 0 or empty disable a key)");
        } else {
            show("active", "yes");
        }

        # The static password is checked when one is entered, and always with
        # Require2Factor. An empty stored password never matches.
        my $stored = $r->{password} // "";
        if (!length $pw && !$two_factor) {
            show("static password", "not checked (none entered, and Require2Factor is off)");
        } elsif ($stored eq "" || $stored eq "{clear}") {
            show("static password", "WRONG (none is stored, and Radiator rejects an empty one)");
            push @fail, "static password";
        } else {
            my $ok = password_matches($pw, $stored);
            if (!defined $ok) {
                $unchecked = 1;
                show("static password", "not checked (stored in a format this check does not support)");
            } else {
                show("static password", $ok ? "matches" : "WRONG");
                push @fail, "static password" unless $ok;
            }
        }

        # A 32-hex-character key is hex; anything else is decoded as base64.
        my $s = $r->{secret} // "";
        my $key = $s =~ /^[0-9a-fA-F]{32}$/ ? pack("H*", $s) : decode_base64($s);
        if (length $key != 16) {
            show("OTP", "does NOT decrypt (the stored AES key is not 32 hex characters or base64 of 16 bytes)");
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
            $ctr &= 0x7fff;    # the top bit only says how the OTP was triggered
            if ($crc != 0xf0b8) {
                show("OTP", "does NOT decrypt with the stored AES key (wrong key, or a mistyped OTP)");
                push @fail, "OTP";
            } else {
                show("OTP", "decrypts with the stored AES key");
                if ($uid eq ($r->{userid} // "")) {
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
#   db_ensure_readable   exit unless the database exists, is up to date (see
#                        db_init) and can be read
#   db_ensure_writable   exit unless the database exists, is up to date and
#                        can be changed
#   db_init [OPTIONS]    create the yubikeys table, and for SQLite the database
#                        file, or bring a table made by an older version up
#                        to date (safe to re-run)
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
#                        userid, secret, counter, low, high, label
#   db_config            print a sample Radiator <AuthBy SQLYUBIKEY> clause,
#                        and the clauses for service accounts and groups
#   db_table             run one SELECT read from stdin and print its rows as
#                        a table with a header
#   db_groups_ready read|write
#                        exit unless the database can be read (or changed)
#                        and has the service-account and group tables
#   db_service_list      print the service accounts (never their passwords)
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
db_table()           { "${DB_BACKEND}_table"; }
db_groups_ready()    { "${DB_BACKEND}_groups_ready" "$@"; }
db_service_list()    { "${DB_BACKEND}_service_list"; }

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
    sqlite_check_table
}

sqlite_ensure_readable() {
    [[ -f $DB_FILE ]] || die "database $DB_FILE does not exist; run '$PROG init' first"
    [[ -r $DB_FILE ]] || die "no read access to $DB_FILE (run with sudo?)"
    sqlite_check_table
}

# Exit unless the yubikeys table exists and has the label column (new in
# 1.8.0), which 'init' adds to a table made by an older version.
sqlite_check_table() {
    local state
    state=$(sqlite_run 2>&1 <<'EOF'
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'yubikeys') THEN 'missing'
            WHEN NOT EXISTS (SELECT 1 FROM pragma_table_info('yubikeys') WHERE name = 'label') THEN 'old'
            ELSE 'ok' END;
EOF
    ) || die "cannot read $DB_FILE: $state"
    case $state in
        ok)      ;;
        missing) die "$DB_FILE has no yubikeys table; run '$PROG init' first" ;;
        *)       die "$DB_FILE was made by an older version of $PROG; run '$PROG init' to bring it up to date" ;;
    esac
}

# The service-account and group tables, for both backends ($1 = the type for
# times, $2 = the type for the active flag). Radiator reads them through the
# view access_replies (and service_accounts for passwords); they replace
# nothing in yubikeys.
#   service_accounts  accounts that log in with a password instead of a
#                     YubiKey (svc.NAME), as {crypt} hashes
#   user_groups       groups of accounts (YubiKey users and service accounts)
#   group_members     who is in each group, by username
#   group_access      the device groups (the Identifier of the devices'
#                     <Client> clauses, or * for every device) each group
#                     may log in to, with the TACACS+ privilege level and
#                     the RADIUS reply attributes for those devices
#   group_rules       TACACS+ command rules for a group on a device group,
#                     tried in seq order; none means every command
groups_schema() {
    local time=$1 flag=$2 check=''
    [[ $flag == smallint ]] && check=' CHECK (active IN (0, 1))'
    cat <<EOF
CREATE TABLE IF NOT EXISTS service_accounts (
    username varchar(255) PRIMARY KEY,                  -- svc.NAME
    password text         NOT NULL,                     -- {crypt} hash
    active   $flag NOT NULL DEFAULT 1$check,
    created  $time NOT NULL DEFAULT CURRENT_TIMESTAMP,
    changed  $time NOT NULL DEFAULT CURRENT_TIMESTAMP,  -- password last set
    label    varchar(255) NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS user_groups (
    name  varchar(64)  PRIMARY KEY,
    label varchar(255) NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS group_members (
    user_group varchar(64)  NOT NULL REFERENCES user_groups (name) ON DELETE CASCADE,
    username   varchar(255) NOT NULL,
    PRIMARY KEY (user_group, username)
);
CREATE INDEX IF NOT EXISTS group_members_username ON group_members (username);
CREATE TABLE IF NOT EXISTS group_access (
    user_group   varchar(64) NOT NULL REFERENCES user_groups (name) ON DELETE CASCADE,
    device_group varchar(64) NOT NULL,
    priv_lvl     smallint    NOT NULL CHECK (priv_lvl BETWEEN 0 AND 15),
    radius_reply text        NOT NULL DEFAULT '',
    PRIMARY KEY (user_group, device_group)
);
CREATE TABLE IF NOT EXISTS group_rules (
    user_group   varchar(64) NOT NULL,
    device_group varchar(64) NOT NULL,
    seq          integer     NOT NULL CHECK (seq > 0),
    rule         text        NOT NULL,
    PRIMARY KEY (user_group, device_group, seq),
    FOREIGN KEY (user_group, device_group) REFERENCES group_access (user_group, device_group) ON DELETE CASCADE
);
EOF
}

# The body of the view access_replies: one row for each account that can log
# in (it has a YubiKey that Radiator counts as active, whose active is not 0
# or empty, or it is an active service account), group it is in, and device
# group that group may use, with what Radiator replies. So disabling an
# account also ends its TACACS+ authorizations, in sessions already open.
# tacacs_reply holds the rules Radiator's <ServerTACACSPLUS> applies
# (AuthorizeGroupAttr OSC-Authorize-Group): first the privilege level, for a
# login's exec authorization (cmd* or an empty cmd=), then the group's
# command rules, or when it has none, a rule that allows every command. The
# first rule that matches decides, and a request no rule matches is denied.
access_replies_sql() {
    cat <<'EOF'
SELECT m.username, a.user_group, a.device_group, a.priv_lvl, a.radius_reply,
       'OSC-Authorize-Group="permit service=shell cmd[*=] {priv-lvl=' || a.priv_lvl || '}"'
       || coalesce((SELECT ',' || string_agg('OSC-Authorize-Group="' || r.rule || '"', ',' ORDER BY r.seq)
                      FROM group_rules r
                     WHERE r.user_group = a.user_group AND r.device_group = a.device_group),
                   ',OSC-Authorize-Group="permit service=shell"') AS tacacs_reply
  FROM group_members m JOIN group_access a ON a.user_group = m.user_group
 WHERE EXISTS (SELECT 1 FROM yubikeys y
                WHERE y.username = m.username AND coalesce(CAST(y.active AS text), '1') NOT IN ('0', ''))
    OR EXISTS (SELECT 1 FROM service_accounts s WHERE s.username = m.username AND s.active = 1);
EOF
}

# Table definition from the original example, with a label column. The
# username index speeds up Radiator's lookups by user. The trigger is
# explained at pg_schema.
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
    label    varchar(255) not null default '',   -- describes the YubiKey; Radiator ignores it
    primary key (userId)
);
CREATE INDEX IF NOT EXISTS yubikeys_username ON yubikeys (username);
CREATE TRIGGER IF NOT EXISTS yubikeys_counters_forward
BEFORE UPDATE OF counter, low ON yubikeys
FOR EACH ROW WHEN NEW.counter < OLD.counter OR (NEW.counter = OLD.counter AND NEW.low <= OLD.low)
BEGIN
    SELECT RAISE(ABORT, 'counter violation: this YubiKey already used this OTP or a later one');
END;
EOF
    groups_schema datetime boolean
    # The view is made again on every init, so an older one is replaced.
    printf 'DROP VIEW IF EXISTS access_replies;\nCREATE VIEW access_replies AS\n'
    access_replies_sql
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

    local had_groups=1
    if [[ $created_file == 0 ]]; then
        had_groups=$(echo "SELECT count(*) FROM sqlite_master WHERE name = 'service_accounts';" | sqlite_run)
    fi
    sqlite_schema | sqlite_run
    if [[ $had_groups == 0 ]]; then info "Added the service-account and group tables"; fi
    if [[ $created_file == 1 ]]; then
        chmod 0640 -- "$DB_FILE"
    fi
    # A table made before 1.8.0 has no label column. SQLite has no ADD
    # COLUMN IF NOT EXISTS, and adds the column at the end, as CREATE does.
    if [[ $(echo "SELECT count(*) FROM pragma_table_info('yubikeys') WHERE name = 'label';" | sqlite_run) == 0 ]]; then
        echo "ALTER TABLE yubikeys ADD COLUMN label varchar(255) not null default '';" | sqlite_run
        info "Added the label column to the yubikeys table"
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
    local user pw pub priv secret label
    [[ $REPLACE == 1 ]] && verb="INSERT OR REPLACE"
    if [[ $RESTORE == 1 ]]; then
        [[ -z $R_CREATED ]] || created=$(sql_quote "$R_CREATED")
        accessed=$(sql_quote "$R_ACCESSED")
        counter=$R_COUNTER low=$R_LOW high=$R_HIGH
    fi
    user=$(sql_quote "$R_USER") pw=$(sql_quote "$R_PASSWORD")
    pub=$(sql_quote "$R_PUB") priv=$(sql_quote "$R_PRIV") secret=$(sql_quote "$R_SECRET")
    label=$(label_sql)

    if [[ $RESTORE == 1 && $REPLACE == 1 ]]; then
        # Restoring over existing rows: keep whichever counters are ahead, the
        # export's or those of a row being replaced, so a restore never lets
        # an already used OTP be accepted again.
        printf 'INSERT OR REPLACE INTO yubikeys (username, password, active, created, accessed, tokenId, userId, secret, counter, low, high, label)\n'
        printf 'SELECT %s, %s, %s, %s, m.accessed, %s, %s, %s, m.counter, m.low, m.high, %s FROM (\n' \
            "$user" "$pw" "$R_ACTIVE" "$created" "$pub" "$priv" "$secret" "$label"
        printf '    SELECT %s AS counter, %s AS low, %s AS high, %s AS accessed\n' "$counter" "$low" "$high" "$accessed"
        printf '    UNION ALL SELECT coalesce(counter, 0), coalesce(low, 0), coalesce(high, 0), accessed FROM yubikeys WHERE tokenId = %s OR userId = %s\n' "$pub" "$priv"
        printf '    ORDER BY counter DESC, low DESC, accessed DESC LIMIT 1) AS m;\n'
    elif [[ $UPSERT == 1 ]]; then
        # Keep the times and counters of a row with the same YubiKey. Rows that
        # clash on the public or private ID are replaced, counters reset.
        printf 'INSERT OR REPLACE INTO yubikeys (username, password, active, created, accessed, tokenId, userId, secret, counter, low, high, label)\n'
        printf "SELECT %s, %s, %s, coalesce(o.created, CURRENT_TIMESTAMP), coalesce(o.accessed, ''), %s, %s, %s,\n" \
            "$user" "$pw" "$R_ACTIVE" "$pub" "$priv" "$secret"
        printf '       coalesce(o.counter, 0), coalesce(o.low, 0), coalesce(o.high, 0), %s\n' "$label"
        printf '  FROM (SELECT 1) LEFT JOIN yubikeys o ON %s;\n' "$(same_key_sql o.)"
    else
        printf "%s INTO yubikeys (username, password, active, created, accessed, tokenId, userId, secret, counter, low, high, label) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);\n" \
            "$verb" "$user" "$pw" "$R_ACTIVE" "$created" "$accessed" "$pub" "$priv" "$secret" "$counter" "$low" "$high" "$label"
    fi
}

# 'list' never selects the AES key or password.
sqlite_list() {
    {
        printf '.headers on\n.mode column\n'
        printf 'SELECT username, tokenId AS public_id, active, created, accessed, counter, label\n'
        printf '  FROM yubikeys %s ORDER BY username, tokenId;\n' "${1-}"
    } | sqlite_run
}

# Times are stored as UTC text and exported as they are.
sqlite_export_json() {
    {
        printf '.mode json\n'
        printf 'SELECT username, password, active, created, accessed, tokenId AS tokenid, userId AS userid,\n'
        printf '       secret, counter, low, high, label\n'
        printf '  FROM yubikeys %s ORDER BY username, tokenId;\n' "${1-}"
    } | sqlite_run
}

sqlite_change() {
    printf '%s\nSELECT changes();\n' "$1" | sqlite_run
}

sqlite_table() {
    { printf '.headers on\n.mode column --wrap 0\n'; cat; } | sqlite_run
}

sqlite_groups_ready() {
    if [[ $1 == write ]]; then sqlite_ensure_writable; else sqlite_ensure_readable; fi
    [[ $(echo "SELECT count(*) FROM sqlite_master WHERE name IN ('service_accounts', 'user_groups', 'group_members', 'group_access', 'group_rules', 'access_replies');" | sqlite_run) == 6 ]] \
        || die "$DB_FILE has no service-account and group tables; run '$PROG init' to add them"
}

sqlite_service_list() {
    sqlite_table <<'EOF'
SELECT username, active, created, changed, label FROM service_accounts ORDER BY username;
EOF
}

# Print the clauses ServiceAccounts and GroupAccess, for the database in DSN
# ($1), as the login $2 (empty for SQLite), with the connection settings in
# $3 (lines, may be empty).
groups_config() {
    local dsn=$1 user=$2 settings=$3
    cat <<EOF

# Service accounts (svc.NAME) log in with a password from the table
# service_accounts ('$PROG service add'): the Handler for svc.* users
# uses this clause instead of the YubiKey one. NoDefault: never fall back to
# an account called DEFAULT.
<AuthBy SQL>
    Identifier       ServiceAccounts
    DBSource         $dsn
    DBUsername${user:+       $user}
    DBAuth
$settings    NoDefault
    AuthSelect       SELECT password FROM service_accounts WHERE username = ? AND active = 1
    AuthSelectParam  %0
    AuthColumnDef    0, User-Password, check
</AuthBy>

# The group check, after the YubiKey or password check of every login (with
# AuthByPolicy ContinueWhileAccept in the Handler): one of the account's
# groups must be allowed on the device's group ('$PROG access set'),
# which is the Identifier of the device's <Client> clause. The most
# privileged of those groups decides. A TACACS+ request (marked
# YubiKey-Via=tacacs by <ServerTACACSPLUS>) gets that group's name and
# command rules, for its GroupMemberAttr and AuthorizeGroupAttr; a RADIUS
# request gets the group's RADIUS reply attributes. No group: the login is
# rejected.
<AuthBy SQL>
    Identifier       GroupAccess
    DBSource         $dsn
    DBUsername${user:+       $user}
    DBAuth
$settings    NoCheckPassword
    NoDefault
    AuthSelect       SELECT CASE WHEN ? = 'tacacs' THEN user_group END, CASE WHEN ? = 'tacacs' THEN tacacs_reply ELSE radius_reply END FROM access_replies WHERE username = ? AND device_group IN (?, '*') ORDER BY priv_lvl DESC, device_group = '*', user_group LIMIT 1
    AuthSelectParam  %{YubiKey-Via}
    AuthSelectParam  %{YubiKey-Via}
    AuthSelectParam  %0
    AuthSelectParam  %{Client:Identifier}
    AuthColumnDef    0, OSC-Group-Identifier, reply
    AuthColumnDef    1, GENERIC, reply
</AuthBy>
EOF
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

    # Require2Factor: every login is the static password/PIN followed by the
    # OTP ("1234:OTP", or "1234OTP"), and a user with no stored password is
    # always rejected. Without it the OTP alone is accepted, even for users
    # who have a password; a password is checked only if one is entered.
    Require2Factor

    # Also check that the private ID in the OTP matches userId.
    CheckSecretId

    # Never fall back to a user called DEFAULT. Radiator's YubiKey clauses
    # already don't (and look up the login's own username in any case); it
    # is written here so that it stays so.
    NoDefault
</AuthBy>
EOF
    groups_config "dbi:SQLite:dbname=$DB_FILE" '' ''
}

# --------------------------------------------------------------------------
# PostgreSQL backend
#
# psql uses the standard libpq connection settings: -d sets PGDATABASE, and
# PGHOST, PGPORT, PGUSER, PGSSLMODE and PGSERVICE are used as they are set;
# with several hosts in PGHOST, PGTARGETSESSIONATTRS defaults to read-write.
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
    # With a primary and a standby (PGHOST=db1,db2), changes must go to
    # whichever server accepts writes.
    if [[ ${PGHOST-} == *,* && -z ${PGTARGETSESSIONATTRS-} ]]; then
        export PGTARGETSESSIONATTRS=read-write
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

# Print "missing" if there is no yubikeys table, "denied" if the SQL
# condition $1 is false, "old" if the table has no label column (new in
# 1.8.0; 'init' adds it), and "ok" otherwise. Exits if psql cannot connect.
pg_table_access() {
    local out
    out=$(printf "SELECT CASE WHEN to_regclass('yubikeys') IS NULL THEN 'missing' WHEN NOT (%s) THEN 'denied'
    WHEN NOT EXISTS (SELECT FROM pg_attribute WHERE attrelid = to_regclass('yubikeys') AND attname = 'label' AND NOT attisdropped)
        THEN 'old'
    ELSE 'ok' END;\n" "$1" \
            | pg_run 2>&1) \
        || die "cannot use $DB_DESC: ${out#psql: error: }"
    printf '%s' "$out"
}

pg_old_table() {
    die "the yubikeys table in $DB_DESC was made by an older version of $PROG; run '$PROG -b pg init' to bring it up to date"
}

pg_ensure_readable() {
    local state
    state=$(pg_table_access "has_table_privilege('yubikeys', 'SELECT')") || exit 1
    case $state in
        ok)      ;;
        missing) die "$DB_DESC has no yubikeys table; run '$PROG -b pg init-pg' first" ;;
        old)     pg_old_table ;;
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
        old)     pg_old_table ;;
        *)       die "no write access to the yubikeys table in $DB_DESC (is ${PGUSER:-$(id -un)} a member of $PG_ADMIN_ROLE?)" ;;
    esac
}

# Table definition. It differs from the SQLite one where PostgreSQL is
# stricter: timestamps are real timestamps, accessed is NULL until the first
# login, active is a 0/1 smallint (a boolean column rejects 1), and the
# password column is text, because a {crypt} hash is longer than 64
# characters. Counters are NOT NULL because Radiator skips its replay check
# when the counter is NULL. The label describes the YubiKey for people:
# Radiator's role cannot read it. ADD COLUMN IF NOT EXISTS gives a table
# made before 1.8.0 the label column, and an older table the login_id
# column (below), without rewriting the table.
#
# The trigger refuses to save counters that do not move forward. Radiator
# reads the counters, checks the OTP, then saves them, so the same OTP sent
# to two Radiator servers (or two farm instances) at the same moment could
# pass both checks before either save. The second save now fails, and
# Radiator gives that login no answer ("Database update failed"). The
# message contains "violation" because Radiator then keeps its database
# connection instead of reconnecting. The scripts never move counters back
# with UPDATE ('--replace' deletes and inserts the row).
#
# The one save of the same counters that passes is the same login's again.
# A primary that stops (as in a switchover) while a save waits for a
# standby has saved it, but drops the connection, so Radiator saves again
# on the new primary, and without this would get no answer for a login it
# had saved. Radiator's UpdateQuery names the login with set_config
# (yubikey.login_id, a random ID from the YubiKeyConnect clause), and the
# trigger keeps that ID in login_id with the counters. Every other save,
# from the scripts or from an older Radiator clause, names none and empties
# it. Radiator's role cannot read or write login_id.
#
# Of the service-account and group tables (groups_schema), Radiator's role
# reads only the passwords of service accounts and the view access_replies,
# which reads the group tables with its owner's rights.
pg_schema() {
    cat <<EOF
-- An older database (with a yubikeys table) that has no service_accounts
-- table gets the service-account and group tables: say so.
SELECT to_regclass('service_accounts') IS NOT NULL OR to_regclass('yubikeys') IS NULL AS had_groups \\gset
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
    high     integer      NOT NULL DEFAULT 0,
    label    varchar(255) NOT NULL DEFAULT '',
    login_id varchar(64)  NOT NULL DEFAULT ''    -- the login that last saved the counters
);
SELECT EXISTS (SELECT FROM pg_attribute WHERE attrelid = 'yubikeys'::regclass AND attname = 'label'
               AND NOT attisdropped) AS had_label \\gset
SELECT EXISTS (SELECT FROM pg_attribute WHERE attrelid = 'yubikeys'::regclass AND attname = 'login_id'
               AND NOT attisdropped) AS had_login_id \\gset
ALTER TABLE yubikeys ADD COLUMN IF NOT EXISTS label varchar(255) NOT NULL DEFAULT '';
ALTER TABLE yubikeys ADD COLUMN IF NOT EXISTS login_id varchar(64) NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS yubikeys_username ON yubikeys (username);
REVOKE ALL ON yubikeys FROM PUBLIC;
GRANT SELECT (username, password, active, tokenId, userId, secret, counter, low, high)
    ON yubikeys TO $PG_RADIATOR_ROLE;
GRANT UPDATE (accessed, counter, low, high) ON yubikeys TO $PG_RADIATOR_ROLE;
CREATE OR REPLACE FUNCTION yubikeys_counters_forward() RETURNS trigger LANGUAGE plpgsql AS \$\$
DECLARE
    id text := coalesce(current_setting('yubikey.login_id', true), '');
BEGIN
    IF (NEW.counter, NEW.low) > (OLD.counter, OLD.low)
       OR ((NEW.counter, NEW.low) = (OLD.counter, OLD.low) AND id <> '' AND id = OLD.login_id) THEN
        NEW.login_id := id;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'counter violation: YubiKey % already used this OTP or a later one', OLD.tokenId
        USING ERRCODE = 'check_violation';
END
\$\$;
CREATE OR REPLACE TRIGGER yubikeys_counters_forward
    BEFORE UPDATE OF counter, low ON yubikeys FOR EACH ROW
    EXECUTE FUNCTION yubikeys_counters_forward();
$(groups_schema timestamptz smallint)
CREATE OR REPLACE VIEW access_replies AS
$(access_replies_sql)
REVOKE ALL ON service_accounts, user_groups, group_members, group_access, group_rules, access_replies FROM PUBLIC;
GRANT SELECT (username, password, active) ON service_accounts TO $PG_RADIATOR_ROLE;
GRANT SELECT ON access_replies TO $PG_RADIATOR_ROLE;
\\if :had_label
\\else
\\echo 'Added the label column to the yubikeys table'
\\endif
\\if :had_login_id
\\else
\\echo 'Added the login_id column to the yubikeys table'
\\endif
\\if :had_groups
\\else
\\echo 'Added the service-account and group tables'
\\endif
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
    local cols vals label created=CURRENT_TIMESTAMP accessed=NULL counter=0 low=0 high=0
    label=$(label_sql)
    if [[ $RESTORE == 1 ]]; then              # export times are UTC
        [[ -z $R_CREATED ]] || created=$(sql_quote "$R_CREATED+00")
        [[ -z $R_ACCESSED ]] || accessed=$(sql_quote "$R_ACCESSED+00")
        counter=$R_COUNTER low=$R_LOW high=$R_HIGH
    fi
    cols="username, password, active, created, accessed, tokenId, userId, secret, counter, low, high, label"
    vals="$(sql_quote "$R_USER"), $(sql_quote "$R_PASSWORD"), $R_ACTIVE, $created, $accessed, $(sql_quote "$R_PUB"), $(sql_quote "$R_PRIV"), $(sql_quote "$R_SECRET"), $counter, $low, $high, $label"
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
        printf 'INSERT INTO yubikeys (%s)\nSELECT %s, %s, %s, %s, best.accessed, %s, %s, %s, best.counter, best.low, best.high, %s\n' \
            "$cols" "$(sql_quote "$R_USER")" "$(sql_quote "$R_PASSWORD")" "$R_ACTIVE" "$created" "$pub" "$priv" "$(sql_quote "$R_SECRET")" "$label"
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
        printf '       coalesce(old.counter, 0), coalesce(old.low, 0), coalesce(old.high, 0), %s\n' "$label"
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
       counter, label
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
           'counter', counter, 'low', low, 'high', high, 'label', label)
         ORDER BY username, tokenId), '[]')
  FROM yubikeys ${1-};
EOF
}

pg_change() {
    printf 'WITH changed AS (%s RETURNING 1) SELECT count(*) FROM changed;\n' "${1%;}" | pg_run
}

pg_table() {
    pg_psql --pset=footer=off
}

# The tables exist, and this role may read them (or change them).
pg_groups_ready() {
    local priv=SELECT state
    if [[ $1 == write ]]; then pg_ensure_writable; priv=INSERT; else pg_ensure_readable; fi
    state=$(pg_run <<EOF 2>&1
SELECT CASE WHEN to_regclass('group_rules') IS NULL OR to_regclass('access_replies') IS NULL THEN 'missing'
            WHEN NOT (has_table_privilege('service_accounts', '$priv') AND has_table_privilege('user_groups', '$priv')
                      AND has_table_privilege('group_members', '$priv') AND has_table_privilege('group_access', '$priv')
                      AND has_table_privilege('group_rules', '$priv')) THEN 'denied'
            ELSE 'ok' END;
EOF
    ) || die "cannot use $DB_DESC: ${state#psql: error: }"
    case $state in
        ok)      ;;
        missing) die "$DB_DESC has no service-account and group tables; run '$PROG -b pg init' to add them" ;;
        *)       die "no access to the service-account and group tables in $DB_DESC (is ${PGUSER:-$(id -un)} a member of $PG_ADMIN_ROLE?)" ;;
    esac
}

pg_service_list() {
    pg_table <<'EOF'
SELECT username, active,
       to_char(created AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS created,
       to_char(changed AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS changed, label
  FROM service_accounts ORDER BY username;
EOF
}

pg_config() {
    local dsn hosts ct=${PGCONNECT_TIMEOUT:-2} connect_timeout=5
    [[ $ct =~ ^[1-9][0-9]{0,2}$ ]] || die "PGCONNECT_TIMEOUT must be 1 to 999 seconds (0 would wait for ever)"
    if [[ -z ${PGDATABASE-} ]]; then
        dsn="dbi:Pg:service=$PGSERVICE"
    else
        dsn="dbi:Pg:dbname=$PGDATABASE"
        if [[ -n ${PGHOST-} && $PGHOST != /* ]]; then
            dsn+=";host=$PGHOST;port=${PGPORT:-5432};sslmode=${PGSSLMODE:-verify-full}"
            if [[ -n ${PGSSLROOTCERT-} ]]; then dsn+=";sslrootcert=$PGSSLROOTCERT"; fi
            # libpq's connect_timeout applies to each server in turn, and
            # Radiator's ConnectTimeout to the whole attempt: allow for all.
            dsn+=";connect_timeout=$ct"
            hosts=$(($(tr -cd , <<<"$PGHOST" | wc -c) + 1))
            connect_timeout=$((hosts * ct + 1))
            if [[ -n ${PGTARGETSESSIONATTRS-} ]]; then
                dsn+=";target_session_attrs=$PGTARGETSESSIONATTRS"
            fi
        fi
    fi
    cat <<EOF
# Sample Radiator <AuthBy SQLYUBIKEY> clause for $DB_DESC
# (secret stored as $SECRET_ENCODING; see the comments below), and the
# clause YubiKeyLocal that the Handlers use (at the end)
<AuthBy SQLYUBIKEY>
    Identifier   YubiKeySQL

    # Radiator on the database host connects over the local socket
    # (dbi:Pg:dbname=NAME). With peer authentication, the Ubuntu default,
    # Radiator must run as the OS user "$PG_RADIATOR_ROLE" and DBAuth stays empty.
    # Radiator on another host connects over TLS, for example
    #   dbi:Pg:dbname=NAME;host=db.example.com;port=5432;sslmode=verify-full
    # with DBAuth set to the $PG_RADIATOR_ROLE role's password (init-pg --set-password).
    # With a primary and a standby server, list both in one DBSource:
    #   host=db1.example.com,db2.example.com;target_session_attrs=read-write
    # libpq then connects to whichever server accepts writes, so Radiator
    # follows a promoted standby. Never list two independent databases:
    # each would keep its own counters, and an OTP used on one would be
    # accepted by the other.
    DBSource     $dsn
    DBUsername   $PG_RADIATOR_ROLE
    DBAuth

    # Give up quickly on a database server that does not answer, and try
    # again soon. Radiator's defaults wait up to 60 s for each query, and
    # when no server can be reached they reject every login for 600 s.
    # ConnectTimeout must cover connect_timeout for each listed server.
    # After finding no server that accepts writes, each Radiator process
    # rejects logins without trying for FailureBackoffTime seconds: keep it
    # short, so logins work again soon after a standby is promoted.
    Timeout             2
    ConnectTimeout      $connect_timeout
    FailureBackoffTime  2
EOF
    # Quoted: the hooks are Perl, with \ continuing their lines.
    cat <<'EOF'

    # While no server accepts writes but every listed server answers, as
    # during a planned switchover, hold the login and try again every 0.5 s,
    # for up to 5 s from the first failure, instead of rejecting it at once
    # (YubiKeyConnect below does the same before the login is looked up).
    # Each of Radiator's processes holds one login at a time. When a server
    # doesn't answer at all (powered off, network cut), or after those 5 s,
    # back off as above. For 10 s after each new connection, which follows a
    # failure, a query may take 6 s, not Timeout: a primary just promoted
    # commits only once a standby streams from it, which can take 3 s, and
    # a counter update cut short by Timeout would be saved again, after
    # waiting for the first one. The hooks change SQLRetries (default
    # 2), FailureBackoffTime and Timeout while Radiator runs, which works
    # with Radiator 4.30's SQL module: run tests/radiator/run.sh with each
    # new version.
    ConnectionHook sub { my ($self) = @_; \
        $self->{yk_failed_at} = 0; $self->{SQLRetries} = 2; \
        $self->{yk_timeout} ||= $self->{Timeout}; $self->{Timeout} = 6; \
        $self->{yk_slow_until} = time + 10; \
        Radius::Select::add_timeout(time + 10, sub { my $s = $_[1]; \
            $s->{Timeout} = $s->{yk_timeout} if time >= $s->{yk_slow_until}; }, $self); }
    NoConnectionsHook sub { my ($self) = @_; \
        require Time::HiRes; my $now = Time::HiRes::time(); \
        $self->{yk_hold_until} = $now + 5 if $now - ($self->{yk_failed_at} || 0) > 30; \
        $self->{yk_failed_at} = $now; \
        if ($now < $self->{yk_hold_until} \
            && ($DBI::errstr // '') !~ /timeout|no route|unreachable|authentication|pg_hba/i) { \
            $self->log($main::LOG_WARNING, 'No database server accepts writes: trying again in 0.5 s'); \
            $self->{FailureBackoffTime} = 0; $self->{SQLRetries}++; \
            select(undef, undef, undef, 0.5); \
        } else { \
            $self->log($main::LOG_ERR, 'Could not connect to any SQL database. Backing off for 2 seconds'); \
            $self->{FailureBackoffTime} = 2; $self->{SQLRetries} = 2; \
        } }

    # Columns must come back in this order: secret, active, userId,
    # counter, session_use (low), ignored (high), static_password.
    # %0 = quoted username, %3 = token (public) ID in modhex.
    AuthSelect   select secret, active, userId, counter, low, high, password from yubikeys where username=%0 and tokenId=%3

    # %0 = counter, %1 = session use, %2 = 0, %3 = quoted username,
    # %5 = Unix time, %7 = token ID in modhex. Radiator's default
    # current_timestamp() is not valid in PostgreSQL, so %5 is used.
    # set_config (always true) names the login, with the random ID that
    # YubiKeyConnect below gives it, for this save only. When the answer to
    # a save is lost, as when the primary stops while the save waits for a
    # standby, Radiator saves again on the new primary; the database finds
    # the counters already saved by the same login and accepts the save,
    # instead of refusing it as a replay.
    UpdateQuery  update yubikeys set accessed=to_timestamp(%5), counter=%0, low=%1, high=%2 where username=%3 and tokenId=%7 and set_config('yubikey.login_id', '%{RequestVar:yk_login_id}', true) is not null

    # Require2Factor: every login is the static password/PIN followed by the
    # OTP ("1234:OTP", or "1234OTP"), and a user with no stored password is
    # always rejected. Without it the OTP alone is accepted, even for users
    # who have a password; a password is checked only if one is entered.
    Require2Factor

    # Also check that the private ID in the OTP matches userId.
    CheckSecretId

    # Never fall back to a user called DEFAULT. Radiator's YubiKey clauses
    # already don't (and look up the login's own username in any case); it
    # is written here so that it stays so.
    NoDefault
</AuthBy>

# Before the YubiKey check: a Radiator process with no database connection
# connects first, and holds the login as above while no server accepts
# writes. YubiKeySQL builds its query (it quotes the username with the
# connection) before it queries, so a query built without one would fail.
# It also gives the login its random ID, for UpdateQuery.
<AuthBy INTERNAL>
    Identifier   YubiKeyConnect
    RequestHook sub { my $id = ''; \
        if (open(my $r, '<', '/dev/urandom')) { read($r, $id, 16); close($r); } \
        $_[0]->{internal_vars}{yk_login_id} = unpack('H*', $id); \
        my $sql = Radius::Configurable::find('AuthBy', 'YubiKeySQL'); \
        for (1 .. 20) { last if $sql->reconnect(); } \
        return ($main::IGNORE, 'database connection checked'); }
</AuthBy>

# The clause that the Handlers use: YubiKeyConnect, then YubiKeySQL.
<AuthBy GROUP>
    Identifier   YubiKeyLocal
    AuthBy       YubiKeyConnect
    AuthBy       YubiKeySQL
</AuthBy>
EOF
    # These two only read, so any server will do, the primary or a standby:
    # with several, the first one that answers.
    local read_dsn=${dsn/target_session_attrs=${PGTARGETSESSIONATTRS-}/target_session_attrs=any}
    groups_config "$read_dsn" "$PG_RADIATOR_ROLE" "    Timeout             2
    ConnectTimeout      $connect_timeout
    FailureBackoffTime  2
"
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

cmd_add() {
    local user='' pub='' priv='' key='' pw='' pw_set=0 active=1 label='' label_set=0
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--user)        user=${2?}; shift 2 ;;
            -P|--public-id)   pub=${2?};  shift 2 ;;
            -p|--private-id)  priv=${2?}; shift 2 ;;
            -k|--key)         key=${2?};  shift 2 ;;
            -w|--password)    pw=${2?}; pw_set=1; shift 2 ;;
            -l|--label)       label=${2?}; label_set=1; shift 2 ;;
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
    if [[ $label_set == 0 && -t 0 ]]; then
        if [[ $REPLACE == 1 || $UPSERT == 1 ]]; then
            prompt_value label "Label for this YubiKey, e.g. spare, slot 2 (Enter keeps its label, if any)"
        else
            prompt_value label "Label for this YubiKey, e.g. spare, slot 2 (Enter for none)"
        fi
    fi

    validate_record "$user" "$pub" "$priv" "$key" "$pw" "$active" "$label" || die "$ERR"
    local out
    if ! out=$(db_insert_sql | db_run); then
        die "could not add $R_USER (if this YubiKey is already in the database, use --replace or --update)"
    fi
    info "${out:-Added $R_USER with YubiKey $R_PUB (active=$R_ACTIVE${R_LABEL:+, label: $R_LABEL})}"
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

    local line lineno=0 first_row=1 ok=0 bad=0 i columns
    local -a f items
    local -A seen_pub=() seen_priv=()
    if [[ $RESTORE == 1 ]]; then
        # The header's number of columns, the rows (14 items each), "@@end"
        mapfile -d '' -t items < <(parse_export_csv "$file")
        [[ ${#items[@]} -gt 1 && ${items[-1]} == '@@end' ]] \
            || die "nothing imported"
        unset 'items[-1]'
        columns=${items[0]}
        for (( i = 1; i < ${#items[@]}; i += 14 )); do
            lineno=${items[i]}
            f=("${items[@]:i+2:12}")
            if [[ ${items[i+1]} != "$columns" ]]; then
                warn "line $lineno: expected $columns fields, found ${items[i+1]}"; bad=$((bad + 1)); continue
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

        if (( ${#f[@]} < 4 || ${#f[@]} > 7 )); then
            warn "line $lineno: expected 4-7 fields, found ${#f[@]}"; bad=$((bad + 1)); continue
        fi
        if ! validate_record "${f[0]}" "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]-}" "${f[5]-}" "${f[6]-}"; then
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
# SQLYUBIKEY does with the configuration from 'config' (see verify_otp). If
# they are accepted, save the OTP's counters and the access time, as the
# UpdateQuery from 'config' would, so the same OTP is not accepted again. The
# UPDATE only applies while the counters are still behind, so an OTP that
# Radiator accepts in the meantime still counts as a replay.
cmd_verify() {
    local user='' pw='' otp='' pub rows result counter session note n two_factor=1
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--user)            user=${2?}; shift 2 ;;
            --no-require2factor)  two_factor=0; shift ;;
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
    # The OTP is the public ID (12 modhex characters; see verify_otp for other
    # lengths) and 32 characters of encrypted token. It is not printed: it may
    # be a password typed by mistake.
    [[ $otp =~ ^([cbdefghijklnrtuv]{2}){17,32}$ ]] \
        || die "verify: that is not a YubiKey OTP (expected 34 to 64 modhex characters, got ${#otp})"
    pub=${otp:0:${#otp}-32}

    rows=$(db_export_json "WHERE username = $(sql_quote "$user") OR tokenId = $(sql_quote "$pub")") \
        || die "verify: cannot read $DB_DESC"
    info "Checking $user with YubiKey $pub in $DB_DESC (Require2Factor $( ((two_factor)) && echo on || echo off)):"
    exec 4>&1
    result=$(printf '%s\n%s\n%s' "$pw" "$otp" "$rows" | verify_otp "$user" "$pub" "$two_factor" 3>&1 1>&4) \
        || die "verify: the check failed to run"
    [[ $result == accept\ * ]] || die "verify: rejected (${result#reject })"

    read -r _ counter session note <<<"$result"
    n=$(db_change "UPDATE yubikeys SET accessed = CURRENT_TIMESTAMP, counter = $counter, low = $session, high = 0
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

# label USER PUBLIC_ID LABEL: set the label of one YubiKey, or remove it ('').
cmd_label() {
    [[ $# -eq 3 ]] || die "label: usage: $PROG label USER PUBLIC_ID LABEL ('' removes the label)"
    local user=$1 pub=${2,,} n
    validate_label "$user" "$3" || die "label: $ERR"
    db_ensure_writable
    n=$(db_change "UPDATE yubikeys SET label = $(sql_quote "$R_LABEL")
 WHERE username = $(sql_quote "$user") AND tokenId = $(sql_quote "$pub");")
    [[ $n -gt 0 ]] || die "label: $user has no YubiKey $pub"
    if [[ -n $R_LABEL ]]; then
        info "Labeled YubiKey $pub of $user: $R_LABEL"
    else
        info "Removed the label of YubiKey $pub of $user"
    fi
}

# --------------------------------------------------------------------------
# Service accounts and groups
#
# Service accounts (svc.NAME) log in with a password instead of a YubiKey.
# Groups say which device groups (the Identifier of the devices' <Client>
# clauses in Radiator, or * for every device) their members may log in to,
# with what TACACS+ privilege level and command rules, and what RADIUS reply
# attributes. Radiator reads them with the clauses ServiceAccounts and
# GroupAccess from 'config'.
# --------------------------------------------------------------------------

check_service_name() {
    [[ $1 =~ ^svc\.[A-Za-z0-9._@+-]{1,251}$ ]] \
        || die "$2: invalid service account '$1' (svc. followed by letters, digits and . _ @ + -)"
}
check_group_name() {
    [[ $1 =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
        || die "$2: invalid group name '$1' (up to 64 letters, digits and . _ -)"
}
check_device_group() {
    [[ $1 == '*' || $1 =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
        || die "$2: invalid device group '$1' (a <Client> Identifier: up to 64 letters, digits and . _ -; or * for every device)"
}
check_username() {
    [[ $1 =~ ^[A-Za-z0-9._@+-]{1,255}$ ]] \
        || die "$2: invalid username '$1' (allowed: letters, digits and . _ @ + -)"
}
check_priv_lvl() {
    [[ $1 =~ ^([0-9]|1[0-5])$ ]] || die "$2: invalid privilege level '$1' (0 to 15)"
}

# db_value SQL: print what a SELECT of one value returns.
db_value() {
    printf '%s\n' "$1" | db_run
}

# group_exists NAME COMMAND: exit unless the group exists.
group_exists() {
    [[ $(db_value "SELECT count(*) FROM user_groups WHERE name = $(sql_quote "$1");") == 1 ]] \
        || die "$2: no group '$1' (add it with '$PROG group add $1')"
}

# Read a service account's password into SVC_PW: generated (--generate),
# asked for twice on a terminal, or the next line of standard input.
# $1 = account, $2 = 1 to generate.
read_service_password() {
    local name=$1 pw='' again=''
    if [[ $2 == 1 ]]; then
        # 32 characters from 62, without modulo bias (bytes 248-255 skipped).
        pw=$(perl -e '
            open(my $r, "<", "/dev/urandom") or die "cannot read /dev/urandom: $!\n";
            my @c = ("a".."z", "A".."Z", 0..9);
            my $pw = "";
            while (length $pw < 32) {
                read($r, my $b, 1) == 1 or die "short read from /dev/urandom\n";
                $pw .= $c[ord($b) % 62] if ord($b) < 248;
            }
            print $pw;') || die "could not generate a password"
    elif [[ -t 0 ]]; then
        prompt_value pw "Password for $name" secret
        prompt_value again "The same password again" secret
        [[ $pw == "$again" ]] || die "the two passwords differ"
    else
        IFS= read -r pw || [[ -n $pw ]] || die "standard input ended before the password for $name"
    fi
    [[ ${#pw} -ge 12 ]] || die "the password for $name is too short (at least 12 characters)"
    [[ ! $pw =~ [[:cntrl:]] ]] || die "the password for $name contains control characters"
    SVC_PW=$pw
}

cmd_service() {
    local sub=${1-}
    [[ $# -eq 0 ]] || shift
    case $sub in
        add)                   service_add "$@" ;;
        password)              service_password "$@" ;;
        list)                  [[ $# -eq 0 ]] || die "service list: too many arguments"
                               db_groups_ready read
                               db_service_list ;;
        enable|disable|delete) service_modify "$sub" "$@" ;;
        label)                 service_label "$@" ;;
        *) die "service: usage: $PROG service add|password|list|enable|disable|delete|label ... (see '$PROG help')" ;;
    esac
}

# service add NAME [-l LABEL] [--inactive] [--generate]
service_add() {
    local name='' label='' active=1 generate=0 hash
    while [[ $# -gt 0 ]]; do
        case $1 in
            -l|--label)  label=${2?--label needs a value}; shift 2 ;;
            --inactive)  active=0; shift ;;
            --generate)  generate=1; shift ;;
            -?*)         die "service add: unknown option '$1'" ;;
            *)           [[ -z $name ]] || die "service add: only one account at a time"; name=$1; shift ;;
        esac
    done
    [[ -n $name ]] || die "service add: usage: $PROG service add NAME [-l LABEL] [--inactive] [--generate]"
    check_service_name "$name" "service add"
    validate_label "$name" "$label" || die "service add: $ERR"
    db_groups_ready write
    [[ $(db_value "SELECT count(*) FROM service_accounts WHERE username = $(sql_quote "$name");") == 0 ]] \
        || die "service add: $name already exists (change its password with '$PROG service password $name')"
    read_service_password "$name" "$generate"
    hash=$(hash_password "$SVC_PW") || die "could not hash the password for $name"
    printf 'INSERT INTO service_accounts (username, password, active, label) VALUES (%s, %s, %s, %s);\n' \
        "$(sql_quote "$name")" "$(sql_quote "$hash")" "$active" "$(sql_quote "$R_LABEL")" | db_run >/dev/null
    info "Added service account $name$( ((active)) || echo ' (inactive)')"
    if [[ $generate == 1 ]]; then info "Its password, shown only now: $SVC_PW"; fi
}

# service password NAME [--generate]
service_password() {
    local name='' generate=0 hash n
    while [[ $# -gt 0 ]]; do
        case $1 in
            --generate) generate=1; shift ;;
            -?*)        die "service password: unknown option '$1'" ;;
            *)          [[ -z $name ]] || die "service password: only one account at a time"; name=$1; shift ;;
        esac
    done
    [[ -n $name ]] || die "service password: usage: $PROG service password NAME [--generate]"
    check_service_name "$name" "service password"
    db_groups_ready write
    [[ $(db_value "SELECT count(*) FROM service_accounts WHERE username = $(sql_quote "$name");") == 1 ]] \
        || die "service password: no service account $name"
    read_service_password "$name" "$generate"
    hash=$(hash_password "$SVC_PW") || die "could not hash the password for $name"
    n=$(db_change "UPDATE service_accounts SET password = $(sql_quote "$hash"), changed = CURRENT_TIMESTAMP
 WHERE username = $(sql_quote "$name");")
    [[ $n -gt 0 ]] || die "service password: no service account $name"
    info "Changed the password of $name"
    if [[ $generate == 1 ]]; then info "Its password, shown only now: $SVC_PW"; fi
}

# service enable|disable|delete NAME. Deleting an account also takes it out
# of its groups.
service_modify() {
    local action=$1 name=${2-} q n m=0
    [[ $# -eq 2 ]] || die "service $action: usage: $PROG service $action NAME"
    check_service_name "$name" "service $action"
    db_groups_ready write
    q=$(sql_quote "$name")
    case $action in
        enable)  n=$(db_change "UPDATE service_accounts SET active = 1 WHERE username = $q;") ;;
        disable) n=$(db_change "UPDATE service_accounts SET active = 0 WHERE username = $q;") ;;
        delete)  n=$(db_change "DELETE FROM service_accounts WHERE username = $q;")
                 if [[ $n -gt 0 ]]; then m=$(db_change "DELETE FROM group_members WHERE username = $q;"); fi ;;
    esac
    [[ $n -gt 0 ]] || die "service $action: no service account $name"
    case $action in
        enable)  info "Enabled $name" ;;
        disable) info "Disabled $name" ;;
        delete)  info "Deleted $name$( ((m)) && echo ", and took it out of $m group(s)")" ;;
    esac
}

# service label NAME LABEL ('' removes it)
service_label() {
    [[ $# -eq 2 ]] || die "service label: usage: $PROG service label NAME LABEL ('' removes the label)"
    local name=$1 n
    check_service_name "$name" "service label"
    validate_label "$name" "$2" || die "service label: $ERR"
    db_groups_ready write
    n=$(db_change "UPDATE service_accounts SET label = $(sql_quote "$R_LABEL") WHERE username = $(sql_quote "$name");")
    [[ $n -gt 0 ]] || die "service label: no service account $name"
    if [[ -n $R_LABEL ]]; then info "Labeled $name: $R_LABEL"; else info "Removed the label of $name"; fi
}

cmd_group() {
    local sub=${1-}
    [[ $# -eq 0 ]] || shift
    case $sub in
        add)    group_add "$@" ;;
        delete) group_delete "$@" ;;
        list)   [[ $# -eq 0 ]] || die "group list: too many arguments"
                db_groups_ready read
                db_table <<'EOF'
SELECT g.name AS "group",
       coalesce((SELECT string_agg(m.username, ' ' ORDER BY m.username)
                   FROM group_members m WHERE m.user_group = g.name), '') AS members,
       coalesce((SELECT string_agg(a.device_group || ':' || a.priv_lvl, ' ' ORDER BY a.device_group)
                   FROM group_access a WHERE a.user_group = g.name), '') AS "device groups:priv-lvl",
       g.label
  FROM user_groups g ORDER BY g.name;
EOF
                ;;
        label)  group_label "$@" ;;
        *) die "group: usage: $PROG group add|delete|list|label ... (see '$PROG help')" ;;
    esac
}

# group add NAME [-l LABEL]
group_add() {
    local name='' label=''
    while [[ $# -gt 0 ]]; do
        case $1 in
            -l|--label) label=${2?--label needs a value}; shift 2 ;;
            -?*)        die "group add: unknown option '$1'" ;;
            *)          [[ -z $name ]] || die "group add: only one group at a time"; name=$1; shift ;;
        esac
    done
    [[ -n $name ]] || die "group add: usage: $PROG group add NAME [-l LABEL]"
    check_group_name "$name" "group add"
    validate_label "$name" "$label" || die "group add: $ERR"
    db_groups_ready write
    [[ $(db_value "SELECT count(*) FROM user_groups WHERE name = $(sql_quote "$name");") == 0 ]] \
        || die "group add: group $name already exists"
    printf 'INSERT INTO user_groups (name, label) VALUES (%s, %s);\n' "$(sql_quote "$name")" "$(sql_quote "$R_LABEL")" \
        | db_run >/dev/null
    info "Added group $name"
}

# group delete NAME: with its members, access and rules, in one transaction.
group_delete() {
    [[ $# -eq 1 ]] || die "group delete: usage: $PROG group delete NAME"
    local q out
    check_group_name "$1" "group delete"
    db_groups_ready write
    group_exists "$1" "group delete"
    q=$(sql_quote "$1")
    out=$(db_run <<EOF
BEGIN;
SELECT (SELECT count(*) FROM group_members WHERE user_group = $q) || ' ' || (SELECT count(*) FROM group_access WHERE user_group = $q);
DELETE FROM group_rules WHERE user_group = $q;
DELETE FROM group_access WHERE user_group = $q;
DELETE FROM group_members WHERE user_group = $q;
DELETE FROM user_groups WHERE name = $q;
COMMIT;
EOF
    ) || die "group delete: could not delete $1"
    info "Deleted group $1, with its ${out%% *} member(s) and ${out##* } device group(s)"
}

# group label NAME LABEL ('' removes it)
group_label() {
    [[ $# -eq 2 ]] || die "group label: usage: $PROG group label NAME LABEL ('' removes the label)"
    local n
    check_group_name "$1" "group label"
    validate_label "$1" "$2" || die "group label: $ERR"
    db_groups_ready write
    n=$(db_change "UPDATE user_groups SET label = $(sql_quote "$R_LABEL") WHERE name = $(sql_quote "$1");")
    [[ $n -gt 0 ]] || die "group label: no group '$1'"
    if [[ -n $R_LABEL ]]; then info "Labeled group $1: $R_LABEL"; else info "Removed the label of group $1"; fi
}

# member add|delete GROUP USER...
cmd_member() {
    local sub=${1-} group user q added=0 n
    [[ $# -eq 0 ]] || shift
    [[ ($sub == add || $sub == delete) && $# -ge 2 ]] \
        || die "member: usage: $PROG member add|delete GROUP USER..."
    group=$1; shift
    check_group_name "$group" "member $sub"
    for user in "$@"; do check_username "$user" "member $sub"; done
    db_groups_ready write
    group_exists "$group" "member $sub"
    q=$(sql_quote "$group")
    for user in "$@"; do
        if [[ $sub == add ]]; then
            n=$(db_change "INSERT INTO group_members (user_group, username) VALUES ($q, $(sql_quote "$user"))
 ON CONFLICT (user_group, username) DO NOTHING;")
            if [[ $n == 0 ]]; then info "$user is already in $group"; continue; fi
            if [[ $(db_value "SELECT (SELECT count(*) FROM yubikeys WHERE username = $(sql_quote "$user"))
     + (SELECT count(*) FROM service_accounts WHERE username = $(sql_quote "$user"));") == 0 ]]; then
                warn "$user has no YubiKey and is not a service account (yet)"
            fi
        else
            n=$(db_change "DELETE FROM group_members WHERE user_group = $q AND username = $(sql_quote "$user");")
            [[ $n -gt 0 ]] || die "member delete: $user is not in $group"
        fi
        added=$((added + 1))
    done
    if [[ $sub == add ]]; then
        if [[ $added -gt 0 ]]; then info "Added $added member(s) to $group"; fi
    else
        info "Took $added member(s) out of $group"
    fi
}

cmd_access() {
    local sub=${1-}
    [[ $# -eq 0 ]] || shift
    case $sub in
        set)    access_set "$@" ;;
        delete) access_delete "$@" ;;
        list)   access_list "$@" ;;
        check)  access_check "$@" ;;
        *) die "access: usage: $PROG access set|delete|list|check ... (see '$PROG help')" ;;
    esac
}

# access set GROUP DEVICE_GROUP PRIV_LVL [-r RADIUS_REPLY]: add the access,
# or change its privilege level (and its RADIUS reply, if -r is given).
access_set() {
    local -a args=()
    local reply='' reply_set=0 group dev priv update
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--radius-reply) reply=${2?--radius-reply needs a value}; reply_set=1; shift 2 ;;
            -?*)               die "access set: unknown option '$1'" ;;
            *)                 args+=("$1"); shift ;;
        esac
    done
    [[ ${#args[@]} -eq 3 ]] \
        || die "access set: usage: $PROG access set GROUP DEVICE_GROUP PRIV_LVL [-r RADIUS_REPLY]"
    group=${args[0]} dev=${args[1]} priv=${args[2]}
    check_group_name "$group" "access set"
    check_device_group "$dev" "access set"
    check_priv_lvl "$priv" "access set"
    if [[ $reply_set == 1 ]]; then check_radius_reply "$reply" "access set"; fi
    db_groups_ready write
    group_exists "$group" "access set"
    update="priv_lvl = excluded.priv_lvl"
    if [[ $reply_set == 1 ]]; then update+=", radius_reply = excluded.radius_reply"; fi
    printf 'INSERT INTO group_access (user_group, device_group, priv_lvl, radius_reply) VALUES (%s, %s, %s, %s)\n ON CONFLICT (user_group, device_group) DO UPDATE SET %s;\n' \
        "$(sql_quote "$group")" "$(sql_quote "$dev")" "$priv" "$(sql_quote "$reply")" "$update" | db_run >/dev/null
    info "Group $group may use device group $dev, at privilege level $priv"
}

# access delete GROUP DEVICE_GROUP: with its rules.
access_delete() {
    [[ $# -eq 2 ]] || die "access delete: usage: $PROG access delete GROUP DEVICE_GROUP"
    local g d out
    check_group_name "$1" "access delete"
    check_device_group "$2" "access delete"
    db_groups_ready write
    g=$(sql_quote "$1") d=$(sql_quote "$2")
    out=$(db_run <<EOF
BEGIN;
SELECT (SELECT count(*) FROM group_access WHERE user_group = $g AND device_group = $d) || ' '
    || (SELECT count(*) FROM group_rules WHERE user_group = $g AND device_group = $d);
DELETE FROM group_rules WHERE user_group = $g AND device_group = $d;
DELETE FROM group_access WHERE user_group = $g AND device_group = $d;
COMMIT;
EOF
    ) || die "access delete: could not delete the access"
    [[ ${out%% *} -gt 0 ]] || die "access delete: group $1 has no access to device group $2"
    info "Group $1 may no longer use device group $2 (${out##* } rule(s) deleted)"
}

# access list [GROUP]
access_list() {
    [[ $# -le 1 ]] || die "access list: usage: $PROG access list [GROUP]"
    local where=''
    if [[ $# -eq 1 ]]; then
        check_group_name "$1" "access list"
        where="WHERE a.user_group = $(sql_quote "$1")"
    fi
    db_groups_ready read
    db_table <<EOF
SELECT a.user_group AS "group", a.device_group AS "device group", a.priv_lvl AS "priv-lvl",
       CASE (SELECT count(*) FROM group_rules r WHERE r.user_group = a.user_group AND r.device_group = a.device_group)
            WHEN 0 THEN 'every command'
            ELSE (SELECT count(*) FROM group_rules r WHERE r.user_group = a.user_group AND r.device_group = a.device_group) || ' rule(s)'
       END AS "TACACS+ commands",
       a.radius_reply AS "RADIUS reply"
  FROM group_access a $where ORDER BY a.user_group, a.device_group;
EOF
}

# access check USER DEVICE_GROUP: what Radiator's GroupAccess clause finds
# for USER on a device in DEVICE_GROUP, with the same query. Exits 1 when
# USER may not log in there.
access_check() {
    [[ $# -eq 2 ]] || die "access check: usage: $PROG access check USER DEVICE_GROUP"
    local user=$1 dev=$2 from row rules reply g p d q
    check_username "$user" "access check"
    check_device_group "$dev" "access check"
    db_groups_ready read
    from="FROM access_replies WHERE username = $(sql_quote "$user") AND device_group IN ($(sql_quote "$dev"), '*')
 ORDER BY priv_lvl DESC, device_group = '*', user_group LIMIT 1"
    row=$(db_value "SELECT user_group || ' ' || priv_lvl || ' ' || device_group $from;")
    if [[ -z $row ]]; then
        q=$(sql_quote "$user")
        if [[ $(db_value "SELECT (SELECT count(*) FROM yubikeys WHERE username = $q
                                  AND coalesce(CAST(active AS text), '1') NOT IN ('0', ''))
                              + (SELECT count(*) FROM service_accounts WHERE username = $q AND active = 1);") == 0 ]]; then
            info "$user may not log in to devices in $dev: they have no active YubiKey and are no active service account"
        else
            info "$user may not log in to devices in $dev: none of their groups may use it"
        fi
        exit 1
    fi
    rules=$(db_value "SELECT tacacs_reply $from;")
    reply=$(db_value "SELECT radius_reply $from;")
    read -r g p d <<<"$row"
    info "$user may log in to devices in $dev, as a member of $g (access to $d), at privilege level $p"
    info "TACACS+ rules, the first that matches decides:"
    RULES=$rules perl -e 'print map { "  $_\n" } $ENV{RULES} =~ /OSC-Authorize-Group="([^"]*)"/g'
    info "RADIUS reply: ${reply:-(none)}"
}

# rule add|delete|list GROUP DEVICE_GROUP ...
cmd_rule() {
    local sub=${1-}
    [[ $# -eq 0 ]] || shift
    case $sub in
        add)    rule_add "$@" ;;
        delete) rule_delete "$@" ;;
        list)   rule_list "$@" ;;
        *) die "rule: usage: $PROG rule add|delete|list GROUP DEVICE_GROUP ... (see '$PROG help')" ;;
    esac
}

# access_exists GROUP DEVICE_GROUP COMMAND
access_exists() {
    [[ $(db_value "SELECT count(*) FROM group_access WHERE user_group = $(sql_quote "$1") AND device_group = $(sql_quote "$2");") == 1 ]] \
        || die "$3: group $1 has no access to device group $2 (add it with '$PROG access set $1 $2 PRIV_LVL')"
}

# rule add GROUP DEVICE_GROUP RULE [--seq N]: by default after the last rule.
rule_add() {
    local -a args=()
    local seq='' g d n
    while [[ $# -gt 0 ]]; do
        case $1 in
            --seq) seq=${2?--seq needs a number}; shift 2 ;;
            -?*)   die "rule add: unknown option '$1'" ;;
            *)     args+=("$1"); shift ;;
        esac
    done
    [[ ${#args[@]} -eq 3 ]] || die "rule add: usage: $PROG rule add GROUP DEVICE_GROUP 'RULE' [--seq N]"
    check_group_name "${args[0]}" "rule add"
    check_device_group "${args[1]}" "rule add"
    [[ -z $seq || $seq =~ ^[1-9][0-9]{0,8}$ ]] || die "rule add: invalid --seq '$seq' (a whole number from 1)"
    check_rule "${args[2]}" "rule add"
    db_groups_ready write
    access_exists "${args[0]}" "${args[1]}" "rule add"
    g=$(sql_quote "${args[0]}") d=$(sql_quote "${args[1]}")
    if [[ -z $seq ]]; then
        seq=$(db_value "SELECT coalesce(max(seq), 0) + 10 FROM group_rules WHERE user_group = $g AND device_group = $d;")
    elif [[ $(db_value "SELECT count(*) FROM group_rules WHERE user_group = $g AND device_group = $d AND seq = $seq;") != 0 ]]; then
        die "rule add: there is already a rule $seq for group ${args[0]} on device group ${args[1]}"
    fi
    printf 'INSERT INTO group_rules (user_group, device_group, seq, rule) VALUES (%s, %s, %s, %s);\n' \
        "$g" "$d" "$seq" "$(sql_quote "$RULE")" | db_run >/dev/null
    n=$(db_value "SELECT count(*) FROM group_rules WHERE user_group = $g AND device_group = $d;")
    info "Added rule $seq for group ${args[0]} on device group ${args[1]} ($n rule(s); a command no rule matches is denied)"
}

# rule delete GROUP DEVICE_GROUP SEQ
rule_delete() {
    [[ $# -eq 3 ]] || die "rule delete: usage: $PROG rule delete GROUP DEVICE_GROUP SEQ"
    local n
    check_group_name "$1" "rule delete"
    check_device_group "$2" "rule delete"
    [[ $3 =~ ^[1-9][0-9]{0,8}$ ]] || die "rule delete: invalid SEQ '$3'"
    db_groups_ready write
    n=$(db_change "DELETE FROM group_rules WHERE user_group = $(sql_quote "$1") AND device_group = $(sql_quote "$2") AND seq = $3;")
    [[ $n -gt 0 ]] || die "rule delete: group $1 has no rule $3 on device group $2"
    info "Deleted rule $3 for group $1 on device group $2"
}

# rule list GROUP DEVICE_GROUP
rule_list() {
    [[ $# -eq 2 ]] || die "rule list: usage: $PROG rule list GROUP DEVICE_GROUP"
    check_group_name "$1" "rule list"
    check_device_group "$2" "rule list"
    db_groups_ready read
    access_exists "$1" "$2" "rule list"
    db_table <<EOF
SELECT seq, rule FROM group_rules
 WHERE user_group = $(sql_quote "$1") AND device_group = $(sql_quote "$2") ORDER BY seq;
EOF
}

# Check a TACACS+ command rule as Radiator's <ServerTACACSPLUS> parses it
# (AuthorizeGroup syntax without the group name):
#   permit|permitreplace|deny PATTERN... [{REPLY...}] [{CHECK...}]
# Each PATTERN is a Perl regular expression for one argument of the request,
# in order (service=shell, cmd=show, cmd-arg=version, ...), matched whole.
# Double quotes are refused (the rule is stored inside a quoted attribute),
# and so are octal escapes like \101, which Radiator would turn into
# characters. Sets RULE.
check_rule() {
    local rc=0
    RULE_TEXT=$1 perl -e '
        my $s = $ENV{RULE_TEXT};
        exit 2 if $s =~ /["[:cntrl:]]/;
        exit 3 if $s =~ /\\[0-7]{3}/;
        exit 4 if length $s > 1000;
        $s =~ /^(permit|permitreplace|deny)\s+([^{]*?)\s*(?:\{([^}]*)\})?\s*(?:\{([^}]*)\})?$/ or exit 5;
        my ($m, $reply, $check) = ($2, $3, $4);
        my @p = grep { length } split /\s+/, $m;
        exit 5 unless @p;
        for (@p) { eval { qr/^$_$/ } or exit 6 }
        for (grep { length } split(/\s+/, $reply // ""), split(/\s+/, $check // "")) {
            /^\S+?[=*]\S*$/ or exit 7;
        }' || rc=$?
    case $rc in
        0) RULE=$1 ;;
        2) die "$2: the rule contains a double quote or a control character" ;;
        3) die "$2: the rule contains an octal escape (\\NNN), which Radiator would change" ;;
        4) die "$2: the rule is longer than 1000 characters" ;;
        5) die "$2: invalid rule '$1' (permit|permitreplace|deny, then the patterns, e.g. 'permit service=shell cmd=show')" ;;
        6) die "$2: invalid rule '$1': a pattern is not a valid regular expression" ;;
        7) die "$2: invalid rule '$1': items in braces must be like priv-lvl=15" ;;
        *) die "$2: could not check the rule" ;;
    esac
}

# Check RADIUS reply attributes as Radiator reads them from the database:
# NAME=VALUE or NAME="VALUE", separated by commas.
check_radius_reply() {
    local rc=0
    [[ -n $1 ]] || return 0
    REPLY_TEXT=$1 perl -e '
        my $s = $ENV{REPLY_TEXT};
        exit 2 if $s =~ /[[:cntrl:]]/;
        exit 4 if length $s > 2000;
        while ($s =~ /\S/) {
            $s =~ s/^[\s,]*//;
            next if $s =~ s/^[A-Za-z0-9][A-Za-z0-9:._-]* *= *"(?:\\"|[^"])*"\s*(?:,|$)//;
            next if $s =~ s/^[A-Za-z0-9][A-Za-z0-9:._-]* *= *[^,"]*(?:,|$)//;
            exit 5;
        }' || rc=$?
    case $rc in
        0) ;;
        2) die "$2: the RADIUS reply contains a control character" ;;
        4) die "$2: the RADIUS reply is longer than 2000 characters" ;;
        *) die "$2: invalid RADIUS reply '$1' (NAME=VALUE or NAME=\"VALUE\", separated by commas)" ;;
    esac
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
    label)                  cmd_label "$@" ;;
    export)                 cmd_export "$@" ;;
    verify)                 cmd_verify "$@" ;;
    service)                cmd_service "$@" ;;
    group)                  cmd_group "$@" ;;
    member)                 cmd_member "$@" ;;
    access)                 cmd_access "$@" ;;
    rule)                   cmd_rule "$@" ;;
    *)                      die "unknown command '$cmd' (see '$PROG help')" ;;
esac
