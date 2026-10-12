# Radiator YubiKey Database Tool

Version 1.0.1 · See [CHANGELOG.md](CHANGELOG.md) for changes.

`yubikey-db.sh` builds and maintains the local SQLite database that Radiator
RADIUS uses to check YubiKey one-time passwords (OTPs) **offline**, without
contacting Yubico's cloud (YubiCloud).

Use it to:

- create the database and its `yubikeys` table
- add users one at a time, or in bulk from a CSV file
- update a user's password or YubiKey without resetting its counters
- check a user's password and OTP against the database, as Radiator would
- list, enable, disable, and delete users
- print a matching Radiator configuration block

## Contents

- [How offline YubiKey authentication works](#how-offline-yubikey-authentication-works)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Step 1: Program the YubiKeys](#step-1-program-the-yubikeys)
- [Step 2: Create the database](#step-2-create-the-database)
- [Step 3: Load users](#step-3-load-users)
- [Step 4: Configure Radiator](#step-4-configure-radiator)
- [Step 5: Test a login](#step-5-test-a-login)
- [Day-to-day management](#day-to-day-management)
- [Command reference](#command-reference)
- [Database layout](#database-layout)
- [Security notes](#security-notes)
- [Troubleshooting](#troubleshooting)
- [Upgrading a database built with the old example commands](#upgrading-a-database-built-with-the-old-example-commands)
- [Running the tests](#running-the-tests)
- [References](#references)

## How offline YubiKey authentication works

Each time someone touches a YubiKey, it types a 44-character one-time password.
The first 12 characters are the key's **public ID**. The remaining 32 are
encrypted with an **AES key** that is stored on the YubiKey.

Radiator's `<AuthBy SQLYUBIKEY>` module:

1. looks up the user and public ID in the SQLite database
2. decrypts the OTP with the AES key stored for that YubiKey
3. compares the YubiKey's use counters with the saved values, so a captured
   OTP can't be replayed, and then saves the new counters

Nothing leaves the Radiator server. The catch is that Radiator must know each
YubiKey's AES key. Yubico keeps the factory-programmed key secret, so **every
YubiKey must be reprogrammed with a key you generate**, and that key must be
loaded into this database.

## Prerequisites

Supported platform: **Ubuntu 26.04 LTS**. The PostgreSQL backend (`-b pg`)
needs **PostgreSQL 18** or later, which is Ubuntu 26.04's default.

| Where | What |
|---|---|
| Machine where you run the script | `bash` 4 or later, `sqlite3`, `perl`; for `verify`, the Perl module `Crypt::Rijndael` (`libcrypt-rijndael-perl`) |
| Radiator server | Radiator 4.x with the Perl modules `DBD::SQLite`, `Auth::Yubikey_Decrypter` (0.05 or later), and `Crypt::Rijndael` |
| Machine where you program keys | [YubiKey Manager](https://www.yubico.com/support/download/yubikey-manager/) (`ykman`) |

To install the tools on Ubuntu:

```bash
sudo apt install sqlite3 perl
```

To check that Radiator's Perl modules are installed:

```bash
perl -MDBD::SQLite -MAuth::Yubikey_Decrypter -MCrypt::Rijndael -e 'print "ok\n"'
```

## Quick start

```bash
# 1. Create the database so the Radiator service account can write to it
sudo ./yubikey-db.sh init --owner radiator:radiator

# 2. Load users from a CSV file (check the file first, then import it)
sudo ./yubikey-db.sh import --dry-run users.csv
sudo ./yubikey-db.sh import users.csv

# 3. Print the Radiator config block and paste it into radius.cfg
./yubikey-db.sh config

# 4. Confirm the users are loaded
sudo ./yubikey-db.sh list
```

The database is created at `/etc/radiator/db/yubicred.db` unless you set a
different path with `-d` (see [Global options](#global-options)).

## Step 1: Program the YubiKeys

Do this once for each YubiKey, on a trusted workstation. The command
overwrites OTP slot 1 or 2, which are the slots that type an OTP when
the key is touched briefly (short touch slot 1, long touch slot 2).

> **Warning:** Slot 1's factory configuration can't be restored. After you
> reprogram it, the key no longer works with services that check OTPs
> through YubiCloud.

```bash
ykman otp yubico 2 --serial-public-id --generate-private-id --generate-key
```

`ykman` shows three values. Record them for this user:

| ykman output | CSV column | Format |
|---|---|---|
| Public ID | `public_id` | 12 modhex characters (only `cbdefghijklnrtuv`) |
| Private ID | `private_id` | 12 hex characters |
| Secret key | `aes_key` | 32 hex characters |

> **Do not** add `--upload`. That option sends the key to Yubico.

To use a public ID that you choose instead of one based on the serial number,
replace `--serial-public-id` with `--public-id <modhex>`.

## Step 2: Create the database

```bash
sudo ./yubikey-db.sh init --owner radiator:radiator
```

- `init` is safe to run again. It doesn't change an existing table or its data.
- `--owner` should be the account that the Radiator service runs as. Radiator
  writes to the database after every login to save the counters that block
  replayed OTPs. SQLite also creates a temporary journal file next to the
  database, so Radiator needs write access to the **folder** as well as the
  file. If Radiator runs as `root`, you can leave out `--owner`.
- New files are created with mode `0640` and new folders with `0750`.

## Step 3: Load users

### Option A: Bulk import from a CSV file

Create a CSV file with these columns:

```csv
username,public_id,private_id,aes_key,password,active
alice,vvccccbbcdef,4a6f8e2d1c3b,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,1234,1
bob,vvccccbbcdeg,9e8d7c6b5a41,0f1e2d3c4b5a69788796a5b4c3d2e1f0,,yes
```

| Column | Required | Notes |
|---|---|---|
| `username` | Yes | The RADIUS login name. Allowed characters: letters, digits, and `. _ @ + -` |
| `public_id` | Yes | YubiKey public ID: 12 modhex characters. Radiator accepts no other length. |
| `private_id` | Yes | 12 hex characters. 12 modhex characters are also accepted and converted to hex. |
| `aes_key` | Yes | 32 hex characters. Spaces and colons are removed. |
| `password` | No | Static password or PIN for two-factor logins. Leave it empty if users log in with the OTP only. |
| `active` | No | `1`/`0`, `true`/`false`, or `yes`/`no`. The default is `1`. |

CSV rules:

- The header row is optional.
- Blank lines and lines that start with `#` are skipped.
- Windows (CRLF) line endings are accepted.
- Spaces around fields and double quotes around a field are removed.
- **Fields can't contain commas**, including passwords.
- One user can have several YubiKeys: add one row per key.

Import steps:

```bash
chmod 600 users.csv                                # the file contains secret keys
sudo ./yubikey-db.sh import --dry-run users.csv    # check every row; makes no changes
sudo ./yubikey-db.sh import users.csv              # load the users
shred -u users.csv                                 # securely delete the file when done
```

How the import works:

- Every row is checked first: field formats, plus duplicate public IDs or
  private IDs within the file. Problems are reported with their line numbers.
- If any row is invalid, **nothing is imported**. Fix the file, or add
  `--skip-invalid` to load only the valid rows.
- Valid rows are loaded in **one transaction**. If any row fails (for
  example, because the YubiKey is already in the database), none are loaded.
- Add `--replace` to overwrite YubiKeys that are already in the database, for
  example after reprogramming them. Their counters start again at 0.
- Add `--update` to add new YubiKeys and update the ones already in the
  database. A YubiKey whose private ID and AES key are unchanged gets the new
  username, password and `active` value and **keeps its counters**. One whose
  private ID or AES key changed (it was reprogrammed) is replaced, and its
  counters start again at 0. Each updated or replaced row is reported.
- Use `-` as the file name to read the CSV from standard input, for example
  from an encrypted file: `gpg -d users.csv.gpg | sudo ./yubikey-db.sh import -`.

See `users.example.csv` for a working example.

### Option B: Add one user

If you run `add` with no values, it asks for each one. The private ID, AES
key, and password aren't shown as you type:

```bash
sudo ./yubikey-db.sh add
```

You can also pass the values as options:

```bash
sudo ./yubikey-db.sh add -u alice -P vvccccbbcdef        # asks for the private ID, key, and password
sudo ./yubikey-db.sh add -u svc.backup -P vvccccbbcdeh --no-password
```

> Values passed with `-k` (AES key) and `-w` (password) can be seen by other
> users in `ps` and are saved in your shell history. Let the script ask for
> them, or use a CSV file.

Add `--update` if the YubiKey may already be in the database: it is then
updated rather than refused, with its counters kept unless its private ID or
AES key changed (see Option A).

### Option C: Add or update one test user with a script

`yubikey-db-user.example.sh` is an example wrapper for test accounts. You put
the user's values in variables at the top of a copy of it, and run the copy
again after each change. It sends them to `import --update -` through a pipe,
so they never appear in `ps` output or a temporary file. It then shows the
user's row, and asks you to touch the YubiKey to check the record with
[`verify`](#step-5-test-a-login).

```bash
install -m 0700 yubikey-db-user.example.sh ~/yk-user.sh   # your copy will hold an AES key
nano ~/yk-user.sh            # set cred_username, cred_password, cred_publicid,
                             # cred_privateid, cred_secret (and db_backend, db_name)
sudo ~/yk-user.sh            # SQLite; for PostgreSQL run it as a member of yubikey_admin
shred -u ~/yk-user.sh        # when you no longer need the test account's values
```

Set `require2factor=no` in your copy if your Radiator configuration doesn't
have `Require2Factor`, so the check matches Radiator (see Step 4).

The YubiKey's public ID decides which record is meant. A new YubiKey is
added, and any other YubiKeys the user has are left as they are. The password
can't contain a comma, start or end with a space, or be in double quotes,
because it travels in a CSV row; use `add --update` for such a password.

## Step 4: Configure Radiator

Print a config block that already contains your database path:

```bash
./yubikey-db.sh config
# or, for a database in another location:
./yubikey-db.sh -d /srv/radius/yubi.db config
```

Paste the output into `radius.cfg` and reference it from your `<Handler>`
with `AuthBy YubiKeyLocal`. The block it prints:

```apache
<AuthBy SQLYUBIKEY>
    Identifier   YubiKeyLocal
    DBSource     dbi:SQLite:dbname=/etc/radiator/db/yubicred.db
    DBUsername
    DBAuth
    AuthSelect   select secret, active, userId, counter, low, high, password from yubikeys where username=%0 and tokenId=%3
    UpdateQuery  update yubikeys set accessed=datetime(%5,'unixepoch'), counter=%0, low=%1, high=%2 where username=%3 and tokenId=%7
    Require2Factor
    CheckSecretId
</AuthBy>
```

What the settings do:

- `AuthSelect` finds a row by **both** the username and the YubiKey's public
  ID. This lets one user have several YubiKeys and stops one user's YubiKey
  from working for another user.
- `UpdateQuery` saves the counters after each login. It takes the time from
  Radiator's `%5` value (the time in seconds) because SQLite doesn't support
  `current_timestamp()`.
- `Require2Factor` makes every login the static password followed by the
  OTP, with or without a colon: `1234:vvccccbbcdef...` or
  `1234vvccccbbcdef...`. A user with **no** stored password is then always
  rejected. **Remove this line** if users log in with the OTP only. Without
  it, Radiator accepts the OTP alone **even for users who have a password**,
  and checks a password only when one is typed in front of the OTP, so the
  password becomes optional for everyone.
- `CheckSecretId` also checks the private ID inside the OTP against the
  database.

Restart Radiator after you change its configuration.

## Step 5: Test a login

First check the record itself, without Radiator. `verify` asks for the
username, the static password, and an OTP (touch the YubiKey), and checks them
the way Radiator does with the configuration from Step 4:

```bash
sudo ./yubikey-db.sh verify
```

```text
Username: alice
Static password/PIN (Enter for none):
YubiKey OTP (touch the YubiKey): vvccccbbcdefvbvkiggllhvureilrdbnvklrcfivibet
Checking alice with YubiKey vvccccbbcdef in /etc/radiator/db/yubicred.db (Require2Factor on):
  active:           yes
  static password:  matches
  OTP:              decrypts with the stored AES key
  private ID:       matches
  replay check:     passed (OTP counter 3, session 1; stored counter 0, session 0)
Accepted. The OTP's counters were saved, so it cannot be used again.
```

Each line names one check, so a failure shows what to fix: a `WRONG` password,
an OTP that does not decrypt (the AES key in the database is not the one in
the YubiKey), a private ID that does not match, or a replayed OTP. It never
shows the AES key or the private ID. When an OTP is accepted, its counters are
saved, as Radiator saves them, so it can't be used again. In a script, pipe
the values in, one per line (`-u` gives the username):
`printf '%s\n' "$password" "$otp" | ./yubikey-db.sh verify -u alice`.

`verify` follows the checks in Radiator 4.30's `<AuthBy SQLYUBIKEY>` code, and
was compared with Radiator itself (see
[Testing against Radiator](#testing-against-radiator)). It assumes the
configuration from Step 4. If you removed `Require2Factor`, add
`--no-require2factor`.

Then test the whole path through Radiator with its `radpwtst` tool. Touch the
YubiKey where the OTP goes:

```bash
# Two-factor (Require2Factor set)
radpwtst -s 127.0.0.1 -secret <shared-secret> -noacct \
         -user alice -password '1234:<touch YubiKey here>'

# OTP only
radpwtst -s 127.0.0.1 -secret <shared-secret> -noacct \
         -user alice -password '<touch YubiKey here>'
```

Then check that the counters were updated:

```bash
sudo ./yubikey-db.sh list alice      # "accessed" and "counter" should now be filled in
```

Enter the **same** OTP a second time. It must be rejected; that's the replay
protection working.

> **`Trace 4` writes every user's AES key and password hash to Radiator's
> log** (the `AuthSQLYUBIKEY read:` lines). Use it only on a test server with
> test keys, and delete the log afterwards.

## Day-to-day management

| Task | Command |
|---|---|
| List all users and keys | `sudo ./yubikey-db.sh list` |
| Show one user | `sudo ./yubikey-db.sh list alice` |
| Suspend a user (all of their keys) | `sudo ./yubikey-db.sh disable alice` |
| Suspend one lost YubiKey | `sudo ./yubikey-db.sh disable alice vvccccbbcdef` |
| Turn a user back on | `sudo ./yubikey-db.sh enable alice` |
| Remove one YubiKey | `sudo ./yubikey-db.sh delete alice vvccccbbcdef` |
| Remove a user completely | `sudo ./yubikey-db.sh delete alice` |
| Replace a reprogrammed YubiKey | `sudo ./yubikey-db.sh add --replace -u alice -P vvccccbbcdef` |
| Change a password (counters kept) | `sudo ./yubikey-db.sh add --update -u alice -P vvccccbbcdef` |
| Check a user's password and OTP | `sudo ./yubikey-db.sh verify -u alice` |
| Import from an encrypted file | `gpg -d users.csv.gpg \| sudo ./yubikey-db.sh import -` |
| Export everything to CSV | `sudo ./yubikey-db.sh export users-export.csv` |
| Export straight into an encrypted file | `sudo ./yubikey-db.sh export - \| gpg -e -r you@example.com > users.csv.gpg` |
| Restore an export | `sudo ./yubikey-db.sh import --from-export users-export.csv` |

`list` never shows AES keys or passwords. `export` does: see
[Exporting to CSV](#exporting-to-csv).

### Exporting to CSV

`export` writes every record and field, from SQLite or PostgreSQL (`-b pg`):

```csv
username,public_id,private_id,aes_key,password,active,created,accessed,counter,low,high
alice,vvccccbbcdef,4a6f8e2d1c3b,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,{crypt}$6$...,1,2026-07-01 08:00:00,2026-10-01 12:00:00,40,7,0
```

- `aes_key` is 32 hex characters (the format `ykman` prints), whether the
  database stores it as base64 or hex. `private_id` is as stored.
- `password` is as stored: `{crypt}` hashes stay hashed, plain-text passwords
  are in plain text.
- `created` and `accessed` are UTC. `counter`, `low` and `high` are the replay
  counters.
- Fields that contain a comma, a quote or a line break are quoted, with quotes
  doubled.
- To load an export back, use `import --from-export` (see
  [Restoring an export](#restoring-an-export)). The plain `import` is for
  onboarding and doesn't accept export files.

The file holds every AES key and private ID in clear text. `export` creates it
with mode `0600`, never replaces an existing file unless you add `--force`, and
leaves no partial file if it fails. Use `export -` to write to standard output,
for example to encrypt the export without writing it to disk unencrypted.

### Restoring an export

`import --from-export` loads a file written by `export`, into either database
(so it also moves users between SQLite and PostgreSQL):

```bash
sudo ./yubikey-db.sh import --from-export --dry-run users-export.csv   # check it first
sudo ./yubikey-db.sh import --from-export users-export.csv
gpg -d users.csv.gpg > users-export.csv && ./yubikey-db.sh -b pg import --from-export users-export.csv
```

How it differs from the onboarding `import`:

| | `import` (onboarding) | `import --from-export` (restore) |
|---|---|---|
| Columns | 4 to 6, simple comma split | All 11 export columns, standard CSV quoting |
| Header | Optional | Required, and must be the export header |
| Password | Hashed (`{crypt}`) | Stored as it is (already hashed in the export) |
| `created`, `accessed` | Now, empty | Restored |
| Counters | 0 | Restored, so used OTPs stay rejected |
| Usernames | Letters, digits and `. _ @ + -` | Anything up to 255 characters without control characters |
| `--replace` | Overwrites and resets the counters | Overwrites, but never moves counters backward |

With `--replace`, if the database's counters for a key are ahead of the
export's, the database's counters and `accessed` time are kept. Restoring an
old export can't make a used OTP valid again.

Rows from the old example statements are normalized as `import` always does
(`active` `true` becomes `1`, a modhex private ID becomes hex). An invalid
`created` time is replaced with the current time, and an invalid `accessed`
time is cleared, each with a warning. Invalid counters make the row invalid.

## Command reference

```text
yubikey-db.sh [global options] <command> [command options]
```

### Global options

| Option | Environment variable | Default | Meaning |
|---|---|---|---|
| `-d, --db FILE` | `DB_FILE` | `/etc/radiator/db/yubicred.db` | Database file |
| `-e, --secret-encoding ENC` | `SECRET_ENCODING` | `base64` | How the AES key is stored: `base64` or `hex` |
| `-H, --password-hash MODE` | `PASSWORD_HASH` | `crypt` | How passwords are stored: `crypt` (SHA-512 hash) or `clear` (plain text) |
| `-h, --help` | | | Show help |
| `-V, --version` | | | Show the script version |
| | `SQLITE3` | `sqlite3` | Path to the `sqlite3` program |

Global options go **before** the command, for example
`./yubikey-db.sh -d /tmp/test.db list`.

### Commands

| Command | Options | Description |
|---|---|---|
| `init` | `-o, --owner USER[:GROUP]` | Create the folder, database file, table, and index |
| `add` | `-u USER`, `-P PUBLIC_ID`, `-p PRIVATE_ID`, `-k AES_KEY`, `-w PASSWORD`, `--no-password`, `--inactive`, `--replace` or `--update` | Add one user and YubiKey. Asks for any value you leave out. |
| `import` | `--dry-run`, `--skip-invalid`, `--replace` or `--update`, `--from-export`, `CSV_FILE` or `-` | Bulk-load users from a CSV file or standard input, or restore an export (`--from-export`) |
| `list` | `[USER]` | Show users and keys without their secrets |
| `enable` | `USER [PUBLIC_ID]` | Set `active = 1` |
| `disable` | `USER [PUBLIC_ID]` | Set `active = 0` |
| `delete` | `USER [PUBLIC_ID]` | Delete the user's rows (or one key) |
| `verify` | `-u USER` | Check a password and OTP the way Radiator does, and save the counters if they're accepted |
| `export` | `-f, --force`, `FILE` or `-` | Write every record and field to CSV, including AES keys and private IDs |
| `config` | | Print a sample `<AuthBy SQLYUBIKEY>` block |

The script exits with `0` on success and `1` on any error, so you can use it
in other scripts and automation.

## Database layout

The table is `yubikeys`. There is one row per YubiKey.

| Column | Contents |
|---|---|
| `username` | RADIUS login name. Indexed. Not unique, because one user can have several YubiKeys. |
| `password` | Static password or PIN: `{crypt}$6$...`, plain text, or empty |
| `active` | `1` = allowed, `0` = disabled. Radiator disables a key only when this is `0` or empty; any other value, even the text `false`, lets it log in. |
| `created` | When the row was added (UTC) |
| `accessed` | Time of the last successful login (UTC). Empty until the first login. |
| `tokenId` | YubiKey public ID in modhex. Unique. |
| `userId` | YubiKey private ID in hex. Unique. This is the primary key. |
| `secret` | AES key, in base64 by default |
| `counter`, `low`, `high` | Counters that Radiator uses to block replayed OTPs |

`--replace` resets a YubiKey's counters to 0. Only use it for a YubiKey that
has just been reprogrammed. `--update` keeps them, unless the private ID or
AES key changed.

## Security notes

- **The database holds every user's AES key.** Anyone who can read the file
  can copy those YubiKeys. Keep the file at `0640` or stricter, readable only
  by the Radiator account and root. Include it in encrypted backups only.
- **Export files hold every secret in clear text**, AES keys and private IDs
  included. Encrypt them (`export - | gpg -e ...`), or delete them with
  `shred -u` as soon as you're done.
- **CSV files hold the same secrets.** Set them to `chmod 600`, don't commit
  them to Git or attach them to tickets, and delete them with `shred -u` after
  importing. The script warns you if a CSV file is readable by all users.
- **A filled-in copy of `yubikey-db-user.example.sh` holds an AES key.** Keep
  it at mode `0700`, outside the repository, and delete it with `shred -u`
  when you're done. It warns you if other users can read it.
- AES keys and passwords are sent to `sqlite3` through its input, not on its
  command line, so `ps` doesn't show them. The script checks the format of
  every value and quotes it safely.
- Passwords are stored as salted SHA-512 `{crypt}` hashes by default. Only
  use `-H clear` if something else needs to read the plain-text password.
- To revoke a lost YubiKey, use `disable` or `delete` straight away. Logins
  are checked against this database only, so there's nothing to revoke in a
  cloud service.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `sqlite3 not found` | Install `sqlite3`, or set `SQLITE3=/path/to/sqlite3`. |
| `no write access to ... (run with sudo?)` | Run the script with `sudo`, or as the account that owns the database. |
| `UNIQUE constraint failed: yubikeys.tokenId` (or `userId`) | That YubiKey is already in the database. Add `--replace` if it was reprogrammed. |
| `import failed and was rolled back` | No rows were loaded. Fix the cause shown above the message and run the import again. |
| `nothing imported; fix the rows above` | One or more CSV rows are invalid. Fix them, or add `--skip-invalid`. |
| A disabled user can still log in, and `active` shows `false` | The row was created with the old example commands; Radiator treats the text `false` as active. Run `disable` for the user, or see [Upgrading a database built with the old example commands](#upgrading-a-database-built-with-the-old-example-commands). |
| A user with no static password is always rejected | `Require2Factor` is set, and Radiator then rejects an empty stored password. Give the user a password, or remove `Require2Factor` (see Step 4). |
| Logins fail and Radiator logs `attempt to write a readonly database` | Radiator can't write to the file **or its folder**. Run `init --owner <radiator-user>` again. |
| Logins fail and Radiator logs `Bad Yubikey password` | The AES key in the database isn't the one in the YubiKey. Check with `verify`, and load the key again with `add --update`. |
| Logins fail and Radiator logs `Bad Yubikey Secret-Id` | The private ID in the database isn't the one in the YubiKey (`CheckSecretId`). Check it against the `ykman` output. |
| The first OTP works but the next ones fail | `UpdateQuery` isn't saving counters. Check the folder permissions and the `UpdateQuery` line. |
| `database is locked` | Radiator is writing at that moment. The script waits up to 5 seconds, so run it again. |
| `verify` says the OTP does NOT decrypt | The AES key in the database isn't the one programmed into the YubiKey. Load the key from the `ykman` output again with `add --update`. |
| `verify` says the private ID does NOT match | The private ID in the database isn't the one programmed into the YubiKey. Correct it with `add --update`. |
| Radiator logs `Replay attack detected` | That OTP, or a newer one from the same YubiKey, was already used. Touch the YubiKey again for a new OTP. |
| Radiator logs `Yubikey secret not found in database` | No row has that username and public ID, or the public ID isn't 12 characters. Check with `list USER`. |
| `verify` passes but `radpwtst` fails | The database is right; check the Radiator configuration (on a test server, with `Trace 4`). |

### Confirmed with Radiator 4.30

These were open questions in the Radiator reference manual. Radiator 4.30's
source code and a test run against it (see
[Testing against Radiator](#testing-against-radiator)) settle them:

1. **AES key format.** Radiator reads a `secret` of 32 hex characters as hex
   and anything else as base64, so the default (`base64`) and `-e hex` both
   work, even mixed in one database.
2. **Quoting of `%3` and `%7`.** Radiator quotes the public ID, so the SQL
   reads `tokenId='vvccccbbcdef'`.
3. **Two-factor login format.** `1234:OTP` and `1234OTP` both work.
4. **Public ID length.** Radiator takes exactly 12 characters of public ID
   from a login, so `add` and `import` accept no other length.
5. **`active`.** Only `0` or an empty value disables a key.
6. **Counters.** Radiator ignores the top bit of the YubiKey's usage counter
   (it only records how the OTP was triggered), and the `UpdateQuery` from
   `config` sets `high` to 0.
7. **PostgreSQL.** The `-b pg` clause from `config` works as printed: Radiator
   logs in as `radiator` over the local socket, its column grants are enough,
   and `to_timestamp(%5)` stores the access time.

With a different Radiator version, run that test against it before you load
users in bulk.

## Upgrading a database built with the old example commands

The original example commands created rows with these problems:

- `"current_timestamp"` in double quotes stored the literal text
  `current_timestamp` in `created`, not the date and time.
- `active="true"` stored the text `true`, and `false` the text `false`.
  Radiator treats both as active, so a key set to `false` was **not**
  disabled.

To fix the existing rows:

```bash
sudo sqlite3 /etc/radiator/db/yubicred.db <<'SQL'
UPDATE yubikeys SET active = 1 WHERE active = 'true';
UPDATE yubikeys SET active = 0 WHERE active = 'false';
UPDATE yubikeys SET created = CURRENT_TIMESTAMP WHERE created = 'current_timestamp';
SQL
```

The old commands also stored the AES key in hex, the private ID in modhex, and
passwords in plain text. The cleanest fix is to export your source data to
the CSV format above and re-import it with `--replace`, so that every row
matches what this script creates.

## Running the tests

`tests/run-tests.sh` runs the script through a fixed set of scenarios against
throwaway SQLite and PostgreSQL databases. It compares each transcript (commands, output, exit codes,
and the final table contents) with the files in `tests/expected/`. It needs
only `bash`, `sqlite3`, and `perl`, and must run as a normal user, not root.
The `verify` scenarios also need `openssl` (to make test OTPs) and the Perl
module `Crypt::Rijndael`, and are skipped without them.

```bash
tests/run-tests.sh                 # run every scenario
tests/run-tests.sh add modify      # run only some scenarios
tests/run-tests.sh --update        # accept a deliberate change in behavior
```

After `--update`, review the changes to `tests/expected/` with `git diff`
before committing them. The test values are not real keys.

The `pg_*` scenarios test the PostgreSQL backend, and the `migrate_*`
scenarios test `yubikey-db-migrate.sh`. Both need `psql` and a
PostgreSQL 18 or later server that you can reach as a role with `CREATEDB` and
`CREATEROLE`. One-time setup on a test machine:

```bash
sudo apt install postgresql postgresql-client
sudo -u postgres createuser --createdb --createrole "$USER"
```

The scenarios create databases and roles named `yk_test_<pid>_*` and drop them
afterwards. `pg_radiator` also logs in as the Radiator role over TCP to
`127.0.0.1` with a password, which Ubuntu's default `pg_hba.conf` allows.
Without a reachable PostgreSQL 18 server, these scenarios are skipped, not
failed.

### Testing against Radiator

`tests/radiator/run.sh` tests the scripts against a real Radiator in a Docker
container. It needs Radiator's packages from Radiator Software, which aren't
in this repository, and Docker that works without `sudo` (membership of the
`docker` group):

```bash
tests/radiator/run.sh ~/downloads/radiator   # holds radiator_*.deb and radiator-radius-utilxs_*.deb
```

It builds an Ubuntu 26.04 image with Radiator, SQLite and PostgreSQL 18, sets
up databases with `yubikey-db.sh`, starts `radiusd` with the clause from
`config`, and logs in with `radpwtst`. For each login it checks Radiator's
answer and the reason Radiator logs, and that `verify` reaches the same
verdict. It covers both databases, Radiator with and without
`Require2Factor`, and the example wrapper, and exits non-zero if any check
fails. A run takes about a minute after the first image build. Run it again
when you upgrade Radiator.

## References

- [Radiator reference: `<AuthBy SQLYUBIKEY>`](https://files.radiatorsoftware.com/radiator/ref/AuthBySQLYUBIKEY.html)
- [Radiator reference: `AuthSelect` for SQLYUBIKEY](https://files.radiatorsoftware.com/radiator/ref/AuthSelect_AuthBySQLYUBIKEY.html)
- The Radiator distribution's `goodies/yubikey.cfg` and `goodies/yubikey.txt`
- [YubiKey Manager CLI (`ykman`) documentation](https://docs.yubico.com/software/yubikey/tools/ykman/)
