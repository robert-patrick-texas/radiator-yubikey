#!/usr/bin/env bash
#
# yubikey-db-user.example.sh - Example wrapper around yubikey-db.sh: create
#     one user/YubiKey record, or update it if that YubiKey is already in the
#     database (SQLite or PostgreSQL). Meant for test accounts. The values
#     are kept in this file, so keep your copy of it private.
#
# HOW TO USE
#   1. Copy this file somewhere private, readable only by you, since it will
#      hold an AES key:
#          install -m 0700 yubikey-db-user.example.sh ~/yk-user.sh
#   2. Fill in the cred_* values below from the 'ykman otp yubico' output, and
#      the database settings if you do not use yubikey-db.sh's defaults.
#   3. Run your copy the way you run yubikey-db.sh:
#          sudo ~/yk-user.sh       SQLite (the database belongs to Radiator)
#          ~/yk-user.sh            PostgreSQL, as a member of yubikey_admin
#   4. When asked, touch the YubiKey: the record is checked the way Radiator
#      checks a login ('yubikey-db.sh verify'). Press Enter to skip this.
#   5. When you are done, delete your copy: shred -u ~/yk-user.sh
#
# WHAT IT DOES
#   The YubiKey's public ID decides which record is meant:
#   - A YubiKey that is not in the database yet is added. Any other
#     YubiKeys the user has are left as they are.
#   - A YubiKey that is already there gets this username, password and
#     active flag. Its counters are kept if the private ID and AES key are
#     unchanged, and start again at 0 if they changed (it was reprogrammed).
#   The values reach 'yubikey-db.sh import --update -' through a pipe, so they
#   never appear in 'ps' output or in a temporary file.
#
#   yubikey-db.sh's environment variables (PGHOST, SECRET_ENCODING, ...)
#   apply as usual. sudo removes most of them unless you use 'sudo -E'.

# ---- The record --------------------------------------------------------------
cred_username=''      # login name, e.g. test.user
cred_password=''      # static password/PIN; leave empty for OTP-only logins
cred_publicid=''      # public ID, modhex (normally 12 characters)
cred_privateid=''     # private ID, 12 hex characters
cred_secret=''        # AES key, 32 hex characters
cred_active=1         # 1 = may log in, 0 = disabled

# ---- The database ------------------------------------------------------------
db_backend=sqlite     # sqlite or pg
db_name=''            # SQLite file or PostgreSQL database; empty = the default
yubikey_db=''         # path to yubikey-db.sh; empty = next to this file, or on PATH

# ------------------------------------------------------------------------------

set -euo pipefail

PROG=${0##*/}
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

if [[ -z $yubikey_db ]]; then
    yubikey_db=$(dirname -- "$(readlink -f -- "$0")")/yubikey-db.sh
    if [[ ! -x $yubikey_db ]]; then
        yubikey_db=$(command -v yubikey-db.sh) \
            || die "yubikey-db.sh not found; set yubikey_db at the top of $0"
    fi
fi

if [[ -n $(find "$0" -maxdepth 0 -perm /044 2>/dev/null) ]]; then
    printf '%s: warning: other users can read %s, which holds an AES key; run: chmod 700 %s\n' "$PROG" "$0" "$0" >&2
fi

for var in cred_username cred_publicid cred_privateid cred_secret; do
    [[ -n ${!var} ]] || die "$var is empty; set it at the top of $0"
done

# The values travel as one CSV row, so they cannot hold commas or line breaks.
# yubikey-db.sh also trims spaces around each value and removes surrounding
# double quotes, which would change a password silently. For such a password,
# use 'yubikey-db.sh add --update', which asks for it.
for var in cred_username cred_password cred_publicid cred_privateid cred_secret cred_active; do
    [[ ${!var} != *[,$'\n\r']* ]] || die "$var cannot contain a comma or a line break"
done
if [[ $cred_password =~ ^[[:space:]]|[[:space:]]$ || $cred_password == \"*\" ]]; then
    die "cred_password cannot start or end with a space or be in double quotes; use 'yubikey-db.sh add --update' for it"
fi

args=(-b "$db_backend")
if [[ -n $db_name ]]; then args+=(-d "$db_name"); fi

# printf is a shell builtin, so the values are not on any command line. The
# header row keeps a username such as "username" from being taken as one.
printf 'username,public_id,private_id,aes_key,password,active\n%s,%s,%s,%s,%s,%s\n' \
        "$cred_username" "$cred_publicid" "$cred_privateid" "$cred_secret" "$cred_password" "$cred_active" \
    | "$yubikey_db" "${args[@]}" import --update -
"$yubikey_db" "${args[@]}" list "$cred_username"

# Check the record with a real OTP, only when someone is at the keyboard.
if [[ -t 0 ]]; then
    read -rp "Touch the YubiKey to check the record (or press Enter to skip): " otp
    if [[ -n $otp ]]; then
        printf '%s\n%s\n' "$cred_password" "$otp" | "$yubikey_db" "${args[@]}" verify -u "$cred_username"
    fi
fi
