# Changelog

## Unreleased

- Added a regression test suite: `tests/run-tests.sh` (11 scenarios).
- Internal: moved every SQLite-specific operation in `yubikey-db.sh` behind a
  documented `db_*` backend interface, as groundwork for a PostgreSQL backend.
  No change in behavior or output.
- Supported platform is now Ubuntu 26.04 LTS only. Ubuntu 24.04 and
  PostgreSQL 16 are not supported.
- PostgreSQL backend (`-b pg`), for PostgreSQL 18 or later (`init` and
  `init-pg` refuse older servers):
  - `init-pg` creates an admin role that owns the database and table, and a
    Radiator login role that can read the keys but update only `accessed` and
    the counters (column-level grants). `--admin LOGIN` adds operators.
  - Connections use the standard libpq settings (`PGHOST`, `PGUSER`,
    `PGSERVICE`, ...), with passwords in `~/.pgpass`; `-d` names the database.
  - `config` prints a `dbi:Pg` clause, using `to_timestamp(%5)` because
    Radiator's default `current_timestamp()` is not valid in PostgreSQL.
  - Errors are terse, so a duplicate key never prints the private ID.
- `export` command (SQLite and PostgreSQL): writes every record and field to
  CSV, with AES keys as 32 hex characters and private IDs in clear text. The
  file is created with mode 0600 via a temporary file, an existing file is
  replaced only with `--force`, and `export -` writes to standard output.
- `import --from-export` restores a file written by `export`, into either
  database: standard CSV quoting, the export header required, passwords
  stored as they are, and created, accessed and the counters restored. With
  `--replace`, counters never move backward (the database's are kept where
  they are ahead). The default `import` for onboarding is unchanged.
- `yubikey-db-migrate.sh`: copies the users and keys from the SQLite database
  into PostgreSQL in one transaction.
  - Reads a consistent snapshot (`sqlite3 .backup`), so Radiator can keep
    running on SQLite; the snapshot is shredded on exit.
  - Copies counters, so previously used OTPs stay rejected, and normalizes
    rows from the old example statements (`active='true'`, hex keys, modhex
    private IDs, literal `current_timestamp`), reporting each change.
  - Verifies every row against an independent SHA-256 fingerprint of the
    snapshot and commits only if all match; `--dry-run` checks everything
    and rolls back.
  - `--mode sync`, for cutover, adds missing keys and moves counters forward
    only, never backward; rows that differ are listed and left unchanged.
  - Invalid rows are listed by user and public ID (never key or private ID)
    and block the migration unless `--skip-invalid` is given.
- Tests: 8 PostgreSQL, 5 migration, 2 export and 2 restore scenarios (28 in
  total); the ones that need a server are skipped without one.
- `add --update` and `import --update` (SQLite and PostgreSQL): add new
  YubiKeys and update the ones already in the database. A YubiKey whose
  private ID and AES key are unchanged (stored as base64 or hex) gets the new
  username, password and active value and keeps its counters and times; one
  that was reprogrammed is replaced and its counters reset. Each updated or
  replaced row is reported.
- `import -` reads the CSV from standard input (for example
  `gpg -d users.csv.gpg | yubikey-db.sh import -`), also with `--from-export`.
- `verify` command: asks for a username, static password and OTP and checks
  them the way Radiator 4.30's `<AuthBy SQLYUBIKEY>` does with the clause from
  `config` (public ID length, active, password, decryption and CRC, private
  ID, replay), one line per check, never showing the AES key or private ID.
  An accepted OTP's counters are saved, so it can't be used again. Values can
  be piped in. `--no-require2factor` matches a Radiator configured without
  `Require2Factor`. Needs `Crypt::Rijndael`. Compared with Radiator 4.30
  itself: like Radiator, it ignores the counter's trigger bit (keeping it
  would save a counter that blocks every later OTP), rejects an empty stored
  password, disables a key only for `active` 0 or empty, and checks `{SSHA}`,
  `{SHA256}`... and bare `$6$` crypt passwords.
- `yubikey-db-user.example.sh`: an example wrapper that adds or updates one
  test account from variables at the top of the file, sends them to
  `import --update -` through a pipe, and offers to check the record with
  `verify` (`require2factor=no` if Radiator runs without `Require2Factor`).
- `add` and `import` accept only 12-character public IDs: Radiator reads
  exactly 12 characters of public ID from a login. Restoring an export and
  migrating still copy whatever is there.
- `yubikey-db-migrate.sh` reports `active` values like `false` that become 0
  (Radiator treated them as active, so those keys could log in), and no
  longer claims keys with `true` could not log in.
- Documentation corrected after testing against Radiator 4.30: only `active`
  0 or empty disables a key; with `Require2Factor` a login may be
  `1234:OTP` or `1234OTP` and a user with no stored password is always
  rejected, and without it the password is optional for everyone; `Trace 4`
  logs every AES key and password hash. "Values to confirm on your first
  deployment" is now "Confirmed with Radiator 4.30". The comment that
  `config` prints above `Require2Factor` says the same.
- `tests/radiator/run.sh`: builds a Docker image with Radiator from your
  packages and runs 63 checks of real Radiator logins (SQLite and
  PostgreSQL, with and without `Require2Factor`, the example wrapper),
  comparing each with `verify`.
- Tests: `update`, `verify`, `wrapper`, `pg_update` and `pg_verify` scenarios
  (33 in total). `verify` is also checked against Yubico's published sample
  OTP. The `verify` scenarios need `openssl` and `Crypt::Rijndael`, and are
  skipped without them.

## 1.0.1 - 2026-10-06

- Added `-V` / `--version` to `yubikey-db.sh`.
- Fixed the `ykman` example in the script's header comment to use slot 2,
  matching the README and HTML guide (slot 1's factory setting can't be restored).
- README and HTML guide updates made since the 1.0 package was built.
- Added version numbers to the README and HTML guide.

## 1.0 - 2026-10-01

- First release: `init`, `add`, `import`, `list`, `enable`, `disable`,
  `delete`, and `config` commands for the SQLite backend.
